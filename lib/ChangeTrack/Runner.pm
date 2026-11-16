# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# ChangeTrack::Runner - Main orchestration engine: config -> lock -> file
#   list -> process -> commit -> notify.
#

package ChangeTrack::Runner;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Runner - main orchestration for changetrack-ng

=head1 SYNOPSIS

  my $runner = ChangeTrack::Runner->new(
      config  => '/etc/changetrack-ng/changetrack-ng.conf',
      message => 'post-install: apt',
      quiet   => 0,
      verbose => 0,
  );
  my $report = $runner->run;

=head1 DESCRIPTION

Loads config and metadata, builds the file list (applying ignore patterns),
processes each file (stat compare, VCS diff, Report accumulation), triggers
all enabled notifiers, and commits the VCS.  Subcommand helpers (C<status>,
C<diff_path>, C<log_path>, C<show_path>, C<revert_path>) are also exposed for
the CLI.

=head1 CLASS METHODS

=over 4

=item ChangeTrack::Runner->new(%opts)

Accepted options: C<config>, C<message>, C<no_auto_init>, C<quiet>,
C<verbose>, C<debug>, C<trace>, C<dry_run>, C<force>, C<lock_timeout>.

=back

=head1 INSTANCE METHODS

=over 4

=item $runner->run

Perform a full scan-commit-notify cycle.  Returns the C<ChangeTrack::Report>
object.  Dies on VCS-level failure.

=item $runner->init_vcs

Initialize the VCS repository if not already initialized.
Returns C<($vcs, $output_dir, $already_initialized)>.

=item $runner->status

Return an arrayref of hashrefs for files that have changed since the last
commit.  Each hashref has at least a C<path> key.

=item $runner->diff_path($path, [$rev1, $rev2])

Return a hashref mapping file paths to arrayrefs of diff lines.  If
I<$path> is undef, all pending diffs are returned.  If I<$path> is a tracked
directory (with no revisions), diffs for all matching tracked files under
that directory are returned.  When I<$rev1> (and optionally I<$rev2>) is
specified, returns historical or live-vs-historical diff lines for I<$path>.

=item $runner->log_path([$path])

Return a hashref mapping file paths (or C<'(repository)'> when I<$path> is
undef) to arrayrefs of log lines.

=item $runner->show_path($path, $rev)

Retrieve historical content and recorded metadata for I<$path> at revision
I<$rev> without mutating disk or mirror state.  Returns a formatted string.

=item $runner->revert_path($path, $rev)

Restore I<$path> to VCS revision I<$rev>.  Acquires the advisory run lock
(honoring C<lock_timeout>, with C<force =E<gt> 0>) to prevent concurrent
repository mutations; croaks if the lock cannot be acquired.  When
C<dry_run> is enabled, returns a preview hashref without acquiring the lock
or modifying disk.

=back

=cut

use feature qw(say);
use Carp qw(croak);
use File::Find qw(find);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use POSIX qw(strftime);

use ChangeTrack::Config;
use ChangeTrack::Lock;
use ChangeTrack::Metadata;
use ChangeTrack::Report;
use ChangeTrack::Util qw(hostname set_debug redact_secrets);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

########################################################################
# Module-level data
########################################################################

my %VCS_CLASSES = (
    rcs       => 'ChangeTrack::VCS::RCS',
    git       => 'ChangeTrack::VCS::Git',
    fossil    => 'ChangeTrack::VCS::Fossil',
    svn       => 'ChangeTrack::VCS::SVN',
    hg        => 'ChangeTrack::VCS::Mercurial',
    mercurial => 'ChangeTrack::VCS::Mercurial',
);

my %NOTIFY_CLASSES = (
    email   => 'ChangeTrack::Notify::Email',
    file    => 'ChangeTrack::Notify::File',
    webhook => 'ChangeTrack::Notify::Webhook',
    otlp    => 'ChangeTrack::Notify::OTLP',
);

# Foreign VCS control directories and Fossil checkout DB files; mirroring them
# nests a repo inside output_dir so the backend silently skips paths below it.
my %FOREIGN_VCS_DIRS  = map { $_ => 1 } qw(.git .hg .svn CVS .bzr _darcs);
my %FOREIGN_VCS_FILES = map { $_ => 1 } qw(.fslckout _FOSSIL_);

# Built-in ignore patterns applied on top of user config.
# Note: #*# cannot go in qw() (# starts a comment there), so it's added separately.
# Path-containing patterns (with /) match as a suffix of the full path.
our @BUILTIN_IGNORE = (qw(
    *.swp *~ .*.sw? *.bak
    *.gz *.bz2 *.bzip2 *.xz *.zst *.7z *.zip *.tar *.tgz *.tbz2 *.txz
    *.dpkg-* *.dpkg-old *.rpmnew *.rpmsave
    *.pacnew *.pacorig *.pacsave *.apk-new
    *.pyc *.pyo *.elc
    mtab mtab.fuselock ld.so.cache prelink.cache
    adjtime .pwd.lock nologin
    udev/hwdb.bin lvm/cache lvm/archive
    network/run init.d/.depend.*
), '#*#');

sub builtin_ignore_patterns {
    return @BUILTIN_IGNORE;
}

# new -- Construct a Runner.
# Accepts: config, message, no_auto_init, quiet, verbose, debug, trace,
#          dry_run, force, warn_special_files, lock_timeout.
# Enforces the implication chain: trace -> debug -> verbose.
sub new {
    my ($class, %args) = @_;

    # Enforce implication chain: trace -> debug -> verbose
    my $trace   = $args{trace}   // 0;
    my $debug   = $args{debug}   // 0;
    my $verbose = $args{verbose} // 0;
    $debug   = 1 if $trace;
    $verbose = 1 if $debug;

    set_debug($debug ? 1 : 0);

    return bless {
        config_path        => $args{config}             // '/etc/changetrack-ng/changetrack-ng.conf',
        no_auto_init       => $args{no_auto_init}       // 0,
        message            => $args{message}            // '',
        quiet              => $args{quiet}              // 0,
        verbose            => $verbose,
        debug              => $debug,
        trace              => $trace,
        dry_run            => $args{dry_run}            // 0,
        force              => $args{force}              // 0,
        warn_special_files => $args{warn_special_files} // 1,
        lock_timeout       => $args{lock_timeout},
    }, $class;
}

########################################################################
# Main run
########################################################################

# run -- Perform a full scan-commit-notify cycle.
# Loads config, acquires lock, resolves file list, processes each file,
# saves metadata, commits the VCS (for whole-repo backends), dispatches
# notifications, and returns the ChangeTrack::Report.
# Croaks on VCS-level or lock configuration failure.
sub run {
    my ($self) = @_;
    my $start_time = time();

    # Enable debug logging in Util (for run_cmd) early
    set_debug(1) if $self->{debug};

    my $cfg = (ref($self->{config_path}) && ref($self->{config_path})->isa('ChangeTrack::Config'))
        ? $self->{config_path}
        : ChangeTrack::Config->load($self->{config_path});
    $self->_verbose("Config loaded from " . (ref($self->{config_path}) ? 'object' : $self->{config_path}));

    # Bound every external command so a hung tool cannot hang the scheduled
    # run.  command_timeout defaults to 120s; 0 disables the cap.
    ChangeTrack::Util::set_default_timeout($cfg->global('command_timeout') // 120);

    $self->_warn_insecure_config_permissions($cfg, $self->{config_path}) unless ref($self->{config_path});
    my @notifiers  = $self->_build_notifiers($cfg);
    $self->_validate_notifiers(\@notifiers);
    my $vcs_name   = lc($cfg->global('vcs')        // 'git');
    my $output_dir = $cfg->global('output_dir')     // '/var/lib/changetrack-ng';

    $self->_verbose("VCS: $vcs_name, output_dir: $output_dir");
    $self->_verbose("Notify: " . (@notifiers ? join(', ', map { ref($_) } @notifiers) : 'none'));

    # Acquire run lock  --  silently skip if another instance is running (safe for cron)
    my $lock = $self->_lock_for($cfg, $self->{force});
    $self->_verbose("Acquiring lock: $lock->{path} (timeout=$lock->{timeout}s)");
    unless ($lock->acquire) {
        $self->_verbose("Skipping: another instance holds lock");
        $self->_info("Another instance is running; skipping this run.");
        return ChangeTrack::Report->new(
            start_time => $start_time,
            vcs        => $vcs_name,
            message    => ($self->{message} || ''),
        );
    }
    $self->_verbose("Lock acquired");

    # Config overrides constructor default for warn_special_files
    my $cfg_wsf = $cfg->global('warn_special_files');
    $self->{warn_special_files} = defined($cfg_wsf) ? ($cfg_wsf ? 1 : 0) : $self->{warn_special_files};

    # Global sensitivity auto-detection toggle (default: enabled)
    $self->{sensitive_auto} = _bool_or_default($cfg->global('sensitive_auto'), 1);

    # Maximum file size threshold for content tracking (default: 10MB)
    $self->{max_file_size} = $cfg->global('max_file_size') // (10 * 1024 * 1024);

    # Instantiate VCS backend
    my $vcs_class = $VCS_CLASSES{$vcs_name}
        or croak "Unknown VCS '$vcs_name'";
    eval "require $vcs_class; 1" or croak "Cannot load $vcs_class: $@";
    {
        no warnings 'redefine';
        no strict 'refs';
        *{"${vcs_class}::sync_mirror_path"} = \&ChangeTrack::Util::sync_mirror_path;
    }

    my $vcs = $vcs_class->new(
        output_dir => $output_dir,
        options    => { push_remote => $cfg->global('push_remote') },
        verbose    => $self->{verbose} // 0,
        debug      => $self->{debug}   // 0,
        trace      => $self->{trace}   // 0,
    );

    # Auto-init
    unless ($vcs->is_initialized) {
        croak "VCS not initialized for --dry-run. Run 'changetrack-ng init' first."
            if $self->{dry_run};
        croak "VCS not initialized and --no-auto-init is set. Run 'changetrack-ng init'."
            if $self->{no_auto_init};
        $self->_info("Initializing $vcs_name repository in $output_dir");
        $vcs->init;
    }

    # Load metadata sidecar
    my $meta_path = "$output_dir/.changetrack-metadata";
    my $md = ChangeTrack::Metadata->load($meta_path, max_file_size => $self->{max_file_size});
    $self->_debug("Metadata sidecar: $meta_path (" . scalar(keys %{ $md->{records} }) . " entries loaded)");
    $self->_debug("Hostname resolved: " . hostname());
    $self->_debug("Lock path: $lock->{path} (running as uid=$>)");

    # Debug: dump effective config values (redact secrets)
    if ($self->{debug}) {
        for my $key (sort keys %{ $cfg->{global} }) {
            $self->_debug("config: $key = " . _redacted_config_value($key, $cfg->{global}{$key}));
        }
        if (my $ign = $cfg->ignore) {
            $self->_debug("config: ignore = " . join(' ', @$ign)) if @$ign;
        }
        my $notifiers = $cfg->notifiers;
        for my $type (sort keys %$notifiers) {
            for my $inst (@{ $notifiers->{$type} }) {
                my $iname = $inst->{instance_name} // 'default';
                for my $key (sort keys %$inst) {
                    next if $key eq 'instance_name';
                    $self->_debug("config: notifier:$type:$iname:$key = " . _redacted_config_value($key, $inst->{$key}));
                }
            }
        }
    }

    # Build combined ignore list
    my @user_ignore = @{ $cfg->ignore // [] };
    my @ignore_pats = (@BUILTIN_IGNORE, @user_ignore);
    my $compiled_ignore = _compile_ignore_patterns(\@ignore_pats);

    # Commit message
    my $ts         = strftime('%Y-%m-%dT%H:%M:%S', localtime($start_time));
    my $commit_msg = "changetrack-ng run \@ $ts";
    $commit_msg   .= " [hook: $self->{message}]" if $self->{message};

    my $report = ChangeTrack::Report->new(
        start_time => $start_time,
        vcs        => $vcs_name,
        message    => ($self->{message} || $commit_msg),
    );

    # Build file list from track entries
    $self->_verbose("Building file list...");
    my @entries = $self->_build_file_list($cfg->tracks, $compiled_ignore, _internal_exclude_paths($cfg), $md, $report);
    my $track_count  = scalar @{ $cfg->tracks };
    my $ignore_count = scalar @user_ignore;
    $self->_verbose("Tracking $track_count entries, $ignore_count user ignore patterns, " . scalar(@entries) . " resolved paths");

    # Enforce private permissions (0700 dirs, 0600 files) on output_dir and siblings
    $self->_enforce_output_permissions($output_dir, $report);

    # Warn if an existing whole-repo mirror contains a nested VCS repository
    $self->_warn_nested_mirror_repos($output_dir, $report) if $vcs->model eq 'whole-repo';

    $self->_verbose("Processing " . scalar(@entries) . " tracked paths");

    for my $entry (@entries) {
        eval { $self->_process_file($entry, $vcs, $md, $report, $commit_msg) };
        if ($@) {
            (my $err = $@) =~ s/\n$//;
            my $real_path = $entry->{path};
            $md->rollback($real_path);
            $self->_warn($err);
            $report->add_warning($err);
        }
    }

    # Batch commit for whole-repo VCS and metadata sidecar saving
    if (!$self->{dry_run}) {
        if ($vcs->model eq 'whole-repo') {
            if ($report->has_changes || $md->is_dirty) {
                my $change_count = scalar @{ $report->changes };
                $self->_verbose("Committing $change_count changes to $vcs_name");

                # 1. Back up existing $meta_path bytes in memory so if $vcs->commit fails,
                # $meta_path can be restored on disk (CORR-6 invariant).
                my $prev_meta_bytes = -f $meta_path ? do {
                    open my $fh, '<', $meta_path;
                    local $/;
                    <$fh>
                } : undef;

                # 2. Save $md->save($meta_path) before $vcs->commit($commit_msg)
                # (whenever $md->is_dirty || !-f $meta_path)
                if ($md->is_dirty || !-f $meta_path) {
                    $self->_verbose("Saving metadata sidecar: $meta_path");
                    eval { $md->save($meta_path); 1 }
                        or croak "metadata save failed: $@";
                }

                # 3. Stage .changetrack-metadata into VCS repository
                $vcs->add('/.changetrack-metadata');

                # 4. Commit to VCS
                my $commit_res = eval { $vcs->commit($commit_msg) };

                # 5. Handle commit failure: restore $meta_path and croak
                if ($@) {
                    my $err = $@;
                    if (defined $prev_meta_bytes) {
                        open my $fh, '>', $meta_path;
                        print {$fh} $prev_meta_bytes;
                        close $fh;
                    } else {
                        unlink $meta_path;
                    }
                    croak "VCS commit failed: $err";
                }

                # 6. Process commit result
                if (ref($commit_res) eq 'HASH') {
                    $report->set_revision($commit_res->{revision})
                        if defined $commit_res->{revision};
                    for my $w (@{ $commit_res->{warnings} // [] }) {
                        $self->_warn($w);
                        $report->add_warning($w);
                    }
                }
            } elsif ($self->{verbose}) {
                $self->_verbose("No changes to commit");
            }
        } else {
            # per-file (RCS)
            $vcs->commit($commit_msg);
            if ($md->is_dirty) {
                $self->_verbose("Saving metadata sidecar: $meta_path");
                eval { $md->save($meta_path); 1 }
                    or croak "metadata save failed (aborting after commit): $@";
            }
        }
    } elsif ($self->{verbose} && !$report->has_changes) {
        $self->_verbose("No changes to commit");
    }

    $report->set_end_time(time());

    print $report->to_text unless $self->{quiet};

    # Dispatch notifications
    if (@notifiers) {
        $self->_verbose("Sending notifications via: " . join(', ', map { ref($_) } @notifiers));
    }
    for my $notifier (@notifiers) {
        my $label = ref($notifier) . ($notifier->{instance_name} ? ":$notifier->{instance_name}" : '');
        unless ($self->{dry_run}) {
            $self->_debug("Notifier $label: sending...");
            eval { $notifier->send($report) };
            if ($@) {
                (my $err = $@) =~ s/\n$//;
                $self->_warn("Notifier $label failed: $err");
                $report->add_warning("Notifier $label failed: $err");
            } else {
                $self->_debug("Notifier $label: sent OK");
            }
        }
    }

    # Run summary
    if ($self->{verbose}) {
        my $n_new     = scalar grep { $_->{is_new} && !$_->{is_removed} } @{ $report->changes };
        my $n_changed = scalar grep { !$_->{is_new} && !$_->{is_removed} } @{ $report->changes };
        my $n_removed = scalar grep { $_->{is_removed} } @{ $report->changes };
        $self->_verbose("Run complete ($n_new new, $n_changed changed, $n_removed removed)");
    }

    return $report;
}

########################################################################
# Per-file processing
########################################################################

# _process_file -- Process a single tracked path for one run.
# Handles: missing files, fast-path skips, type classification,
# and per-type actions (new/changed/removed, VCS checkin, Report entry).
# Per-file errors are caught by the caller and added as warnings.
sub _process_file {
    my ($self, $entry, $vcs, $md, $report, $commit_msg) = @_;
    my $real_path = $entry->{path};
    my $sensitive = $entry->{sensitive};
    my $recipients = $entry->{recipients} && ref($entry->{recipients}) eq 'ARRAY'
        ? $entry->{recipients}
        : [];

    $report->increment_tracked;

    my $existing          = $md->record_for($real_path);
    my $prev_type         = defined($existing) ? ($existing->{type} // '') : '';
    my $prev_vcs_eligible = ($prev_type eq 'file' || $prev_type eq 'symlink' || $prev_type eq 'empty');

    my @st = lstat($real_path);

    # File no longer on disk
    unless (@st) {
        if (defined $existing) {
            unless ($self->{dry_run}) {
                eval { $vcs->remove($real_path) };
                if (my $err = $@) {
                    $err =~ s/\n$//;
                    $self->_warn("VCS remove failed for $real_path (will retry next run): $err");
                    $report->add_warning("VCS remove failed for $real_path: $err");
                    return;    # keep metadata record so the next run retries
                }
            }
            $report->add_removed(path => $real_path, recipients => $recipients);
            $md->mark_removed($real_path);
            $self->_debug("Removed: $real_path");
            $self->_info("Removed: $real_path");
        } else {
            $self->_trace("$real_path: not on disk, no prior record");
        }
        return;
    }

    # Fast path: if metadata is unchanged, skip without touching VCS.
    # For known files where mtime+size (or symlink target) haven't changed,
    # there is nothing to process regardless of type.
    if (defined $existing && $md->can_skip_content_diff($real_path, \@st, $self->{max_file_size})
        && !$md->changed_since_load($real_path, \@st, $self->{max_file_size})) {
        # Refresh the record (preserves the type as-is).
        $md->update_from_stat($real_path, \@st, $self->{max_file_size});
        $self->_trace("$real_path: skipped (mtime+size unchanged)");
        return;
    }

    # Classify the file (stat it once, determine type)
    my $meta_changed = defined($existing) && $md->changed_since_load($real_path, \@st, $self->{max_file_size});
    my $meta_summary = $meta_changed ? $md->diff_summary($real_path, \@st, $self->{max_file_size}) : '';

    $md->update_from_stat($real_path, \@st, $self->{max_file_size});
    my $rec  = $md->record_for($real_path);
    my $type = $rec->{type};

    # Non-trackable types: special, unreadable, binary, oversize
    if ($type eq 'special' || $type eq 'unreadable' || $type eq 'binary' || $type eq 'oversize') {
        $self->_handle_non_trackable(
            $real_path, $type, $prev_type, $prev_vcs_eligible,
            $rec, $recipients, $vcs, $md, $report,
            $entry, $meta_changed, $meta_summary, $existing, \@st
        );
        return;
    }

    my $mode_oct = defined($rec->{mode}) ? oct($rec->{mode}) : ($st[2] & 07777);

    if ($type eq 'empty') {
        # Empty files have no content to diff unless transitioning from a non-empty file.
        if (defined $existing && $prev_vcs_eligible && $md->changed_since_load($real_path, \@st, $self->{max_file_size})) {
            my $meta_summary = $md->diff_summary($real_path, \@st, $self->{max_file_size});
            my $diff_lines = (defined $existing && defined $prev_type && $prev_type eq 'file')
                ? $vcs->diff($real_path)
                : [];
            my $rev;
            unless ($self->{dry_run}) {
                if ($vcs->model eq 'per-file') {
                    $rev = $vcs->checkin($real_path, "$commit_msg ($meta_summary)");
                } else {
                    my $msg = $meta_summary ? "$commit_msg [meta: $meta_summary]" : $commit_msg;
                    $vcs->checkin($real_path, $msg);
                }
            }
            my $is_sensitive = _resolve_sensitive($real_path, $sensitive, $self->{sensitive_auto},
                $mode_oct);
            $report->add_change(
                path         => $real_path,
                is_new       => 0,
                is_sensitive => $is_sensitive,
                diff         => $diff_lines,
                meta_change  => $meta_summary,
                recipients   => $recipients,
                stat         => $rec,
                (defined $rev ? (revision => $rev) : ()),
            );
            $self->_debug("Changed (meta): $real_path ($meta_summary)");
        } elsif (!defined $existing || !$prev_vcs_eligible) {
            my $rev;
            unless ($self->{dry_run}) {
                if ($vcs->model eq 'per-file') {
                    $rev = $vcs->checkin($real_path, $commit_msg);
                } else {
                    $vcs->checkin($real_path, $commit_msg);
                }
            }
            my $is_sensitive = _resolve_sensitive($real_path, $sensitive, $self->{sensitive_auto},
                $mode_oct);
            my $trans_meta = (defined $existing && !$prev_vcs_eligible)
                ? "transition from $prev_type to $type"
                : '';
            $report->add_change(
                path         => $real_path,
                is_new       => 1,
                is_sensitive => $is_sensitive,
                diff         => ['(new empty file)'],
                meta_change  => $trans_meta,
                recipients   => $recipients,
                stat         => $rec,
                (defined $rev ? (revision => $rev) : ()),
            );
            $self->_debug("New: $real_path (type=$type, mode=" . ($rec->{mode} // '?') . ")");
            $self->_info("New: $real_path");
        } else {
            $self->_trace("$real_path: empty, unchanged");
        }
        return;
    }

    # Warn about hardlinked regular files
    if ($type eq 'file') {
        if ($st[3] > 1) {
            $self->_warn("$real_path has $st[3] hard links  --  changes via other names will not be tracked");
        }
    }

    # Trackable types: file, symlink
    my $is_sensitive = _resolve_sensitive($real_path, $sensitive, $self->{sensitive_auto},
        $mode_oct);

    if (!defined $existing || !$prev_vcs_eligible) {
        # New file / symlink or transitioned from non-trackable
        my $rev;
        unless ($self->{dry_run}) {
            if ($vcs->model eq 'per-file') {
                $rev = $vcs->checkin($real_path, $commit_msg);
            } else {
                $vcs->checkin($real_path, $commit_msg);
            }
        }
        my $trans_meta = (defined $existing && !$prev_vcs_eligible)
            ? "transition from $prev_type to $type"
            : '';
        $report->add_change(
            path         => $real_path,
            is_new       => 1,
            is_sensitive => $is_sensitive,
            diff         => ['(new file)'],
            meta_change  => $trans_meta,
            recipients   => $recipients,
            stat         => $rec,
            (defined $rev ? (revision => $rev) : ()),
        );
        $self->_debug("New: $real_path (type=$type, mode=" . ($rec->{mode} // '?') . ")");
        $self->_info("New: $real_path");
    } else {
        # Existing file / symlink  --  check for changes
        my $meta_changed = $md->changed_since_load($real_path, \@st, $self->{max_file_size});
        my $meta_summary = $meta_changed ? $md->diff_summary($real_path, \@st, $self->{max_file_size}) : '';

        # Symlinks: content is the target, already captured by changed_since_load.
        # Regular files: diff only if mtime+size moved.
        my $skip_content_diff = ($type eq 'symlink') ? 1 : $md->can_skip_content_diff($real_path, \@st, $self->{max_file_size});
        my $diff_lines = $skip_content_diff ? [] : $vcs->diff($real_path);
        my $content_changed = @$diff_lines > 0;

        if ($meta_changed || $content_changed) {
            my $rev;
            unless ($self->{dry_run}) {
                if ($vcs->model eq 'per-file') {
                    my $ci_msg = (!$content_changed && $meta_changed)
                        ? "$commit_msg ($meta_summary)"
                        : (defined $meta_summary && length $meta_summary ? "$commit_msg [meta: $meta_summary]" : $commit_msg);
                    $rev = $vcs->checkin($real_path, $ci_msg);
                } else {
                    my $msg = $meta_summary ? "$commit_msg [meta: $meta_summary]" : $commit_msg;
                    $vcs->checkin($real_path, $msg);
                }
            }
            $report->add_change(
                path         => $real_path,
                is_new       => 0,
                is_sensitive => $is_sensitive,
                diff         => $diff_lines,
                meta_change  => $meta_summary,
                recipients   => $recipients,
                stat         => $rec,
                (defined $rev ? (revision => $rev) : ()),
            );
            $self->_debug("Changed: $real_path"
                . ($meta_summary ? " (meta: $meta_summary)" : ''));
        } else {
            $self->_trace("$real_path: unchanged");
        }
    }
}

# _handle_non_trackable -- Handle non-trackable files (special, unreadable, binary, oversize).
# Inputs: $real_path, $type, $prev_type, $prev_vcs_eligible, $rec, $recipients,
#         $vcs, $md, $report, $entry, $meta_changed, $meta_summary, $existing, $st_ref
# Handles trace logging, VCS removal staging on transitions from trackable types,
# change report recording, and skip warnings for non-trackable file types.
sub _handle_non_trackable {
    my ($self, $real_path, $type, $prev_type, $prev_vcs_eligible,
        $rec, $recipients, $vcs, $md, $report,
        $entry, $meta_changed, $meta_summary, $existing, $st_ref) = @_;

    $self->_trace("$real_path: classified as $type, metadata only");

    if ($prev_vcs_eligible) {
        unless ($self->{dry_run}) {
            eval { $vcs->remove($real_path) };
            if (my $err = $@) {
                $err =~ s/\n$//;
                $md->rollback($real_path);
                $self->_warn("VCS remove failed for $real_path (will retry next run): $err");
                $report->add_warning("VCS remove failed for $real_path: $err");
                return;
            }
        }
        my $diff_msg = ($type eq 'oversize')
            ? [ "(file became oversize (" . ($rec->{size} // 0) . " bytes); removed from VCS tracking)" ]
            : [];
        $report->add_change(
            path         => $real_path,
            is_new       => 0,
            is_removed   => 1,
            is_sensitive => 0,
            diff         => $diff_msg,
            meta_change  => "transition from $prev_type to $type (removed from VCS)",
            meta_changed => "transition from $prev_type to $type (removed from VCS)",
            recipients   => $recipients,
            stat         => $rec,
        );
        $self->_debug("Transitioned to non-trackable ($type), removed from VCS: $real_path");
        $self->_info("Removed from VCS (became $type): $real_path");
        if ($type eq 'oversize') {
            my $size = $rec->{size} // (-s $real_path) // 0;
            my $warn_msg = "skipping oversize file ($size bytes > max_file_size $self->{max_file_size}): $real_path";
            $self->_warn($warn_msg);
            $report->add_warning($warn_msg);
        }
        return;
    }

    # Already non-trackable file: report metadata changes if any (CORR-17)
    if (defined $existing && $meta_changed) {
        my $st_mode = defined($st_ref) ? $st_ref->[2] : undef;
        my $mode_oct = defined($rec->{mode}) ? oct($rec->{mode}) : (defined($st_mode) ? ($st_mode & 07777) : 0644);
        my $is_sensitive = _resolve_sensitive($real_path, $entry ? $entry->{sensitive} : undef, $self->{sensitive_auto}, $mode_oct);
        $report->add_change(
            path         => $real_path,
            diff         => [ "(metadata changed: $meta_summary)" ],
            meta_change  => $meta_summary,
            meta_changed => $meta_summary,
            sensitive    => $is_sensitive,
            is_sensitive => $is_sensitive,
            recipients   => ($entry && $entry->{recipients}) ? $entry->{recipients} : ($recipients // []),
            stat         => $rec,
        );
        $self->_debug("Changed (non-trackable meta): $real_path ($meta_summary)");
    }

    if ($type eq 'special') {
        if (!($prev_type eq 'special' && !$meta_changed)) {
            if ($self->{warn_special_files}) {
                $self->_warn("skipping special file (FIFO/socket/device): $real_path");
            }
            $report->add_warning("Skipping special file: $real_path");
        }
    } elsif ($type eq 'unreadable') {
        if (!($prev_type eq 'unreadable' && !$meta_changed)) {
            $report->add_warning("Skipping unreadable: $real_path");
        }
    } elsif ($type eq 'binary') {
        if ($prev_type ne 'binary') {
            if ($self->{warn_special_files}) {
                $self->_warn("skipping binary file: $real_path");
            }
            $report->add_warning("Skipping binary file: $real_path");
        }
    } elsif ($type eq 'oversize') {
        if ($prev_type ne 'oversize') {
            my $size = $rec->{size} // (-s $real_path) // 0;
            my $warn_msg = "skipping oversize file ($size bytes > max_file_size $self->{max_file_size}): $real_path";
            $self->_warn($warn_msg);
            $report->add_warning($warn_msg);
        }
    }

    return;
}

########################################################################
# File list building
########################################################################

# _merge_file_entry -- Merge a resolved file path into the deduplicated table.
# Inputs: by_path hashref, path, sensitive option, recipients arrayref, from_file flag.
sub _merge_file_entry {
    my ($by_path, $p, $opt_sensitive, $recips, $from_file) = @_;

    if (!$by_path->{$p}) {
        my @unique_recips;
        my %seen;
        for my $r (@{ $recips || [] }) {
            next unless defined $r && length $r;
            push @unique_recips, $r unless $seen{$r}++;
        }
        $by_path->{$p} = {
            path       => $p,
            sensitive  => $opt_sensitive,
            recipients => \@unique_recips,
            _from_file => $from_file,
        };
        return;
    }

    my $existing = $by_path->{$p};

    # Merge recipients preserving order without duplicates
    my %seen = map { $_ => 1 } @{ $existing->{recipients} || [] };
    for my $r (@{ $recips || [] }) {
        next unless defined $r && length $r;
        push @{ $existing->{recipients} }, $r unless $seen{$r}++;
    }

    # Resolve sensitive option precedence
    if ($from_file && !$existing->{_from_file}) {
        if (defined $opt_sensitive && $opt_sensitive ne 'auto') {
            $existing->{sensitive}  = $opt_sensitive;
            $existing->{_from_file} = 1;
        }
    } elsif ($existing->{_from_file} && !$from_file) {
        my $cur = $existing->{sensitive};
        my $cur_explicit = (defined $cur && ($cur eq 'yes' || $cur eq 'no')) ? 1 : 0;
        my $new_explicit = (defined $opt_sensitive && ($opt_sensitive eq 'yes' || $opt_sensitive eq 'no')) ? 1 : 0;
        if (!$cur_explicit && $new_explicit) {
            $existing->{sensitive} = $opt_sensitive;
        }
    } else {
        # Both have the same _from_file flag
        my $cur = $existing->{sensitive};
        my $cur_explicit = (defined $cur && ($cur eq 'yes' || $cur eq 'no')) ? 1 : 0;
        my $new_explicit = (defined $opt_sensitive && ($opt_sensitive eq 'yes' || $opt_sensitive eq 'no')) ? 1 : 0;
        if (!$cur_explicit && $new_explicit) {
            $existing->{sensitive} = $opt_sensitive;
        } elsif ($cur_explicit && $new_explicit) {
            if ($opt_sensitive eq 'yes' && $cur ne 'yes') {
                $existing->{sensitive} = 'yes';
            }
        }
    }
}

# _build_file_list -- Resolve all track entries into a sorted list of
# { path, sensitive, recipients } hashrefs, applying ignore and exclude
# patterns.  Directory entries are expanded recursively via File::Find.
# When $md is provided, reconciles deleted files from tracked directories.
# When $report is provided, records warnings directly to the report.
sub _build_file_list {
    my ($self, $tracks, $ignore_pats, $exclude_paths, $md, $report) = @_;
    my %by_path;
    $exclude_paths ||= [];

    my %dir_opts;

    for my $track (@$tracks) {
        my $kind          = $track->{kind};
        my $p             = $track->{path};
        my $opt_sensitive = $track->{options}{sensitive};

        my $recips = $track->{emails} && ref($track->{emails}) eq 'ARRAY'
            ? [ @{ $track->{emails} } ]
            : [];

        if ($kind eq 'file' && -d $p && !-l $p) {
            my $warn_msg = "[track] entry '$p' is a directory; treating as 'DIRECTORY $p'";
            $self->_warn($warn_msg);
            $report->add_warning($warn_msg) if $report;
            $kind = 'directory';
        }

        if ($kind eq 'file') {
            if (_is_foreign_vcs_path($p)) {
                $self->_trace("$p: skipped (foreign VCS path)");
                next;
            }
            if (_should_ignore($p, basename($p), $ignore_pats)) {
                $self->_trace("$p: ignored by pattern");
                next;
            }
            if (_is_excluded_path($p, $exclude_paths)) {
                $self->_trace("$p: excluded (internal path)");
                next;
            }
            _merge_file_entry(\%by_path, $p, $opt_sensitive, $recips, 1);

        } elsif ($kind eq 'directory') {
            my $dir = $p;
            if (!$dir_opts{$dir}) {
                $dir_opts{$dir} = {
                    sensitive  => $opt_sensitive,
                    recipients => [ @$recips ],
                };
            } else {
                my %seen = map { $_ => 1 } @{ $dir_opts{$dir}{recipients} || [] };
                for my $r (@$recips) {
                    push @{ $dir_opts{$dir}{recipients} }, $r unless $seen{$r}++;
                }
                my $cur = $dir_opts{$dir}{sensitive};
                my $cur_explicit = (defined $cur && ($cur eq 'yes' || $cur eq 'no')) ? 1 : 0;
                my $new_explicit = (defined $opt_sensitive && ($opt_sensitive eq 'yes' || $opt_sensitive eq 'no')) ? 1 : 0;
                if (!$cur_explicit && $new_explicit) {
                    $dir_opts{$dir}{sensitive} = $opt_sensitive;
                } elsif ($cur_explicit && $new_explicit) {
                    if ($opt_sensitive eq 'yes' && $cur ne 'yes') {
                        $dir_opts{$dir}{sensitive} = 'yes';
                    }
                }
            }

            next unless -d $dir;
            next if _is_excluded_path($dir, $exclude_paths);
            if (_is_foreign_vcs_path($dir)) {
                $self->_trace("$dir: pruned (foreign VCS dir)");
                next;
            }
            if (_should_ignore($dir, basename($dir), $ignore_pats)) {
                $self->_trace("$dir: pruned (ignored directory)");
                next;
            }

            find({
                wanted => sub {
                    if (-d $_ && !-l $_) {
                        my $p = $File::Find::name;
                        if ($FOREIGN_VCS_DIRS{ basename($p) } || _is_excluded_path($p, $exclude_paths)) {
                            $self->_trace("$p: pruned (foreign VCS dir or internal path)");
                            $File::Find::prune = 1;
                            return;
                        }
                        if (_should_ignore($p, basename($p), $ignore_pats)) {
                            $self->_trace("$p: pruned (ignored directory)");
                            $File::Find::prune = 1;
                            return;
                        }
                        return;
                    }
                    return unless -f $_ || -l $_;
                    my $p = $File::Find::name;
                    if (_is_foreign_vcs_path($p)) {
                        $self->_trace("$p: skipped (foreign VCS path)");
                        return;
                    }
                    if (_should_ignore($p, basename($p), $ignore_pats)) {
                        $self->_trace("$p: ignored by pattern");
                        return;
                    }
                    if (_is_excluded_path($p, $exclude_paths)) {
                        $self->_trace("$p: excluded (internal path)");
                        return;
                    }
                    _merge_file_entry(\%by_path, $p, $opt_sensitive, $recips, 0);
                },
                no_chdir => 1,
            }, $dir);
        }
    }

    # Post-filter so [ignore] always overrides [track]
    for my $p (keys %by_path) {
        if (_should_ignore($p, basename($p), $ignore_pats)) {
            $self->_trace("$p: ignored by pattern (post-filter)");
            delete $by_path{$p};
        }
    }

    # Reconcile deleted files from tracked directories using metadata
    if ($md && $md->{records}) {
        for my $stored_path (sort keys %{ $md->{records} }) {
            if (_is_foreign_vcs_path($stored_path)) {
                $md->mark_removed($stored_path);
                next;
            }
            if (_should_ignore($stored_path, basename($stored_path), $ignore_pats)) {
                $md->mark_removed($stored_path);
                next;
            }
            next if $by_path{$stored_path};
            next if -e $stored_path || -l $stored_path;

            # Check if stored path falls under an actively tracked directory
            my @matching_dirs = grep {
                my $prefix = $_ =~ m{/$} ? $_ : "$_/";
                index($stored_path, $prefix) == 0;
            } sort { length($b) <=> length($a) } keys %dir_opts;

            next unless @matching_dirs;

            # Skip if the path matches exclude patterns
            next if _is_excluded_path($stored_path, $exclude_paths);

            # Most specific (longest prefix) directory determines sensitive override
            my $sensitive_override = $dir_opts{ $matching_dirs[0] }{sensitive};

            # Collect and union recipients across all enclosing tracked directories
            my %seen_recips;
            my @all_recips;
            for my $dir (@matching_dirs) {
                for my $r (@{ $dir_opts{$dir}{recipients} || [] }) {
                    next unless defined $r && length $r;
                    push @all_recips, $r unless $seen_recips{$r}++;
                }
            }

            $by_path{$stored_path} = {
                path       => $stored_path,
                sensitive  => $sensitive_override,
                recipients => \@all_recips,
            };
        }
    }

    for my $entry (values %by_path) {
        delete $entry->{_from_file};
    }
    return map { $by_path{$_} } sort keys %by_path;
}

# _internal_exclude_paths -- Return paths that should never be tracked
# (the output_dir itself, metadata sidecar, VCS-specific paths, lockfile,
# and file notifier targets).
sub _internal_exclude_paths {
    my ($cfg) = @_;
    my $output_dir = $cfg->global('output_dir') // '/var/lib/changetrack-ng';
    my $vcs_name   = lc($cfg->global('vcs') // 'git');

    my @exclude = (
        $output_dir,
        "$output_dir/.changetrack-metadata",
    );
    push @exclude, "$output_dir.fossil"  if $vcs_name eq 'fossil';
    push @exclude, "$output_dir-svnrepo" if $vcs_name eq 'svn';

    my $lock_path = $cfg->global('lock_path');
    if (defined $lock_path && length $lock_path) {
        push @exclude, $lock_path;
    }

    for my $inst (@{ $cfg->notifiers->{file} // [] }) {
        if ($inst->{enabled} && defined $inst->{path} && length $inst->{path}) {
            push @exclude, $inst->{path};
        }
    }

    return \@exclude;
}

# _is_excluded_path -- Return true if $path equals or is a child of any
# path in $exclude_paths.  Handles path-separator normalization.
sub _is_excluded_path {
    my ($path, $exclude_paths) = @_;
    my $norm_path = $path;
    $norm_path =~ s{\\}{/}g;
    for my $exclude (@$exclude_paths) {
        next unless defined $exclude && $exclude =~ /\S/;
        my $norm_exclude = $exclude;
        $norm_exclude =~ s{\\}{/}g;
        return 1 if $norm_path eq $norm_exclude;
        return 1 if index($norm_path, "$norm_exclude/") == 0;
    }
    return 0;
}

# _is_foreign_vcs_path -- Return true if any path segment is a foreign VCS
# control directory (or .git file) or the filename is a Fossil checkout DB.
sub _is_foreign_vcs_path {
    my ($path) = @_;
    return 0 unless defined $path && length $path;
    (my $norm = $path) =~ s{\\}{/}g;
    my @segs = grep { length $_ } split m{/}, $norm;
    return 0 unless @segs;
    return 1 if $FOREIGN_VCS_FILES{ $segs[-1] };
    return (grep { $FOREIGN_VCS_DIRS{$_} } @segs) ? 1 : 0;
}

# _should_ignore -- Return true if $full_path or its basename matches
# any compiled ignore pattern.
sub _should_ignore {
    my ($full_path, $base, $compiled_patterns) = @_;
    if (@$compiled_patterns && ref($compiled_patterns->[0]) ne 'HASH') {
        $compiled_patterns = _compile_ignore_patterns($compiled_patterns);
    }
    my $norm_full_path = $full_path;
    $norm_full_path =~ s{\\}{/}g;
    $base = basename($norm_full_path) unless defined $base;
    for my $spec (@$compiled_patterns) {
        if ($spec->{path}) {
            return 1 if $norm_full_path =~ $spec->{re};
        } else {
            return 1 if (defined $spec->{seg_re} && $norm_full_path =~ $spec->{seg_re})
                     || ($base =~ $spec->{re});
        }
    }
    return 0;
}

# _compile_ignore_patterns -- Convert a list of glob strings to an
# arrayref of { path => bool, re => qr//, seg_re => qr// } hashrefs.
# Path-containing patterns (with /) match directory prefixes/suffixes or full paths;
# plain patterns match only the filename or individual path segments.
sub _compile_ignore_patterns {
    my ($patterns) = @_;
    my @compiled;
    for my $pat (@$patterns) {
        next unless defined $pat;
        $pat =~ s{/+$}{};
        next if $pat eq '';
        if ($pat =~ m{/}) {
            my $re = _glob_to_re($pat);
            push @compiled, { path => 1, re => qr{(?:^|/)${re}(?:/|$)} };
        } else {
            my $re = _glob_to_re($pat);
            push @compiled, {
                path   => 0,
                re     => qr/^${re}$/,
                seg_re => qr{(?:^|/)${re}(?:/|$)},
            };
        }
    }
    return \@compiled;
}

# _glob_to_re -- Convert a glob pattern to a regex fragment.
# Handles **, /**/, *, ?, [...], and escapes regex metacharacters.
sub _glob_to_re {
    my ($glob) = @_;
    return '' unless defined $glob;

    my $re = '';
    my $len = length($glob);
    my $i = 0;

    while ($i < $len) {
        # Check for '/**/'
        if (substr($glob, $i, 4) eq '/**/') {
            $re .= '(?:/|/.*/)';
            $i += 4;
            next;
        }

        # Check for '**'
        if (substr($glob, $i, 2) eq '**') {
            $re .= '.*';
            $i += 2;
            next;
        }

        my $ch = substr($glob, $i, 1);

        if ($ch eq '*') {
            $re .= '[^/]*';
            $i++;
        } elsif ($ch eq '?') {
            $re .= '[^/]';
            $i++;
        } elsif ($ch eq '.') {
            $re .= '\.';
            $i++;
        } elsif ($ch eq '[') {
            # Character class parsing (DEBT-5):
            # scan for closing ']'
            # handling leading '!' or '^' as negation '[^...]' and disallowing '/' inside the class
            # if unclosed '[', escape as '\['
            my $j = $i + 1;
            my $neg = '';
            if ($j < $len && (substr($glob, $j, 1) eq '!' || substr($glob, $j, 1) eq '^')) {
                $neg = '^';
                $j++;
            }
            my $found_close = 0;
            my $class_start = $j;
            while ($j < $len) {
                my $c = substr($glob, $j, 1);
                if ($c eq '/') {
                    # / is not allowed inside a character class
                    last;
                }
                if ($c eq ']') {
                    if ($j > $class_start) {
                        $found_close = 1;
                    }
                    last;
                }
                $j++;
            }
            if ($found_close) {
                my $body = substr($glob, $class_start, $j - $class_start);
                $re .= '[' . $neg . $body . ']';
                $i = $j + 1;
            } else {
                $re .= '\[';
                $i++;
            }
        } elsif ($ch =~ /[\[\]{}()+^\$|\\]/) {
            $re .= "\\$ch";
            $i++;
        } else {
            $re .= $ch;
            $i++;
        }
    }
    return $re;
}

########################################################################
# Helpers: sensitive detection, config parsing, locking
########################################################################

# _resolve_sensitive -- Determine whether a file should be treated as sensitive.
# Priority: per-track 'sensitive' option (yes/no) > auto-detection by mode.
# Auto-detection: files with no world-read bit (mode & 0004 == 0) are sensitive.
sub _resolve_sensitive {
    my ($real_path, $override, $auto_enabled, $mode_oct) = @_;
    if (defined $override) {
        return 1 if $override =~ /^(yes|1)$/i;
        return 0 if $override =~ /^(no|0)$/i;
    }
    $auto_enabled = 1 unless defined $auto_enabled;
    return 0 unless $auto_enabled;
    # Auto-detect: no world-read permission (includes 0600 and 0640).
    # Use the pre-computed mode from metadata when available to avoid re-stat.
    unless (defined $mode_oct) {
        my @s = stat($real_path);
        return 0 unless @s;
        $mode_oct = $s[2];
    }
    return (($mode_oct & 0004) == 0) ? 1 : 0;
}

# _bool_or_default -- Parse a config boolean string to 1/0.
# Returns $default if $raw is undef or unrecognized.
sub _bool_or_default {
    my ($raw, $default) = @_;
    return $default unless defined $raw;
    return 1 if $raw =~ /^(?:1|true|yes|on)$/i;
    return 0 if $raw =~ /^(?:0|false|no|off)$/i;
    return $default;
}

# _redacted_config_value -- Format and redact a config value for debug logging.
sub _redacted_config_value {
    my ($key, $val) = @_;
    $val = join(' ', @$val) if ref $val eq 'ARRAY';
    $val //= '';
    return '***REDACTED***'
        if $key =~ /header|secret|token|password|url|uri|endpoint|remote|key|auth|bearer|credential/i;
    return redact_secrets($val);
}

# _lock_for -- Construct a ChangeTrack::Lock from $cfg, ensuring parent dir exists.
sub _lock_for {
    my ($self, $cfg, $force) = @_;
    my $lock_path = $cfg->global('lock_path');
    unless (defined($lock_path) && $lock_path =~ /\S/) {
        $lock_path = _default_lock_path();
    }
    _ensure_lock_parent_dir($lock_path);
    return ChangeTrack::Lock->new(
        path    => $lock_path,
        timeout => $self->{lock_timeout} // $cfg->global('lock_timeout') // 0,
        force   => $force ? 1 : 0,
    );
}

# _default_lock_path -- Return the appropriate lock file path.
# root gets /var/run/changetrack-ng.lock;
# unprivileged users get $XDG_CACHE_HOME/changetrack-ng.lock.
sub _default_lock_path {
    return '/var/run/changetrack-ng.lock' if $> == 0;

    # Prefer a private, user-owned runtime/cache directory.  Never fall back to
    # a bare, world-writable /tmp path (predictable name -> symlink/DoS prone);
    # use a per-UID name only as a last resort.
    for my $dir ($ENV{XDG_RUNTIME_DIR}, $ENV{XDG_CACHE_HOME}) {
        next unless defined($dir) && $dir =~ /\S/;
        next unless -d $dir || eval { make_path($dir, { mode => 0700 }); 1 };
        return "$dir/changetrack-ng.lock";
    }

    my $home = $ENV{HOME};
    if (!(defined($home) && $home =~ /\S/)) {
        my @pw = getpwuid($<);
        $home = $pw[7] if @pw;
    }
    return "$home/.cache/changetrack-ng.lock" if defined($home) && $home =~ /\S/;

    return "/tmp/changetrack-ng-$<.lock";
}

# _ensure_lock_parent_dir -- Create the parent directory for $lock_path
# if it does not already exist (mode 0700).
sub _ensure_lock_parent_dir {
    my ($lock_path) = @_;
    return unless defined($lock_path) && $lock_path =~ /\S/;

    my $dir = dirname($lock_path);
    return unless defined($dir) && $dir ne '' && $dir ne '.';
    return if -d $dir;

    make_path($dir, { mode => 0700 });
}

########################################################################
# Subcommand helpers
########################################################################

# _setup -- Load config and instantiate the VCS backend.
# Croaks if the VCS repository is not yet initialized.
sub _setup {
    my ($self, %opts) = @_;
    my $cfg = (ref($self->{config_path}) && ref($self->{config_path})->isa('ChangeTrack::Config'))
        ? $self->{config_path}
        : ChangeTrack::Config->load($self->{config_path});
    my $vcs_name   = lc($cfg->global('vcs')        // 'git');
    my $output_dir = $cfg->global('output_dir')     // '/var/lib/changetrack-ng';

    ChangeTrack::Util::set_default_timeout($cfg->global('command_timeout') // 120);

    my $vcs_class  = $VCS_CLASSES{$vcs_name}
        or croak "Unknown VCS '$vcs_name'";
    eval "require $vcs_class; 1" or croak "Cannot load $vcs_class: $@";
    {
        no warnings 'redefine';
        no strict 'refs';
        *{"${vcs_class}::sync_mirror_path"} = \&ChangeTrack::Util::sync_mirror_path;
    }

    my $vcs = $vcs_class->new(
        output_dir => $output_dir,
        options    => { push_remote => $cfg->global('push_remote') },
        verbose    => $self->{verbose} // 0,
    );
    my $caller_sub = (caller(1))[3] // '';
    my $skip_init_check = $opts{no_init_check} || ($caller_sub =~ /init_vcs$/);
    croak "VCS not initialized. Run 'changetrack-ng init' first."
        unless $skip_init_check || $vcs->is_initialized;

    return ($vcs, $cfg, $output_dir);
}

# init_vcs -- Initialize the VCS repository if not already initialized.
# Returns ($vcs, $output_dir, $already_initialized).
sub init_vcs {
    my ($self) = @_;
    my ($vcs, $md, $output_dir) = $self->_setup();
    if ($vcs->is_initialized) {
        return ($vcs, $output_dir, 1);
    }
    $vcs->init();
    return ($vcs, $output_dir, 0);
}

# _tracked_entries -- Resolve all track entries for the current config,
# applying ignore and exclude patterns.  Returns an arrayref.
sub _tracked_entries {
    my ($self, $cfg, $md) = @_;
    my @user_ignore = @{ $cfg->ignore // [] };
    my @ignore_pats = ($self->builtin_ignore_patterns, @user_ignore);
    my $compiled_ignore = _compile_ignore_patterns(\@ignore_pats);
    return [$self->_build_file_list($cfg->tracks, $compiled_ignore, _internal_exclude_paths($cfg), $md)];
}

# _build_notifiers -- Instantiate all enabled notifier instances from config.
# Returns a list of notifier objects ready to send.
sub _build_notifiers {
    my ($self, $cfg) = @_;

    my $sensitive_notify = $cfg->global('sensitive_notify') // 'suppress';
    my $all_notifiers    = $cfg->notifiers;
    my @objects;

    for my $type (sort keys %$all_notifiers) {
        my $nclass = $NOTIFY_CLASSES{$type} or do {
            $self->_warn("no class registered for notifier type '$type'; skipping");
            next;
        };
        eval "require $nclass; 1" or do {
            $self->_warn("cannot load $nclass: $@");
            next;
        };
        my @instances = @{ $all_notifiers->{$type} // [] };
        if ($type eq 'email') {
            my $primary_idx = 0;
            for my $i (0 .. $#instances) {
                if (($instances[$i]{instance_name} // '') eq 'default') {
                    $primary_idx = $i;
                    last;
                }
            }
            for my $i (0 .. $#instances) {
                my $inst = $instances[$i];
                my %extra = (sensitive_notify => $sensitive_notify);
                if (@instances > 1) {
                    $extra{use_track_recipients} = ($i == $primary_idx) ? 1 : 0;
                }
                push @objects, $nclass->new(%$inst, %extra);
            }
        } else {
            for my $inst (@instances) {
                push @objects, $nclass->new(%$inst, sensitive_notify => $sensitive_notify);
            }
        }
    }

    return @objects;
}

# status -- Return an arrayref of { path, diff } for all tracked files with pending changes.
sub status {
    my ($self) = @_;
    my ($vcs, $cfg) = $self->_setup;
    $self->{max_file_size} = $cfg->global('max_file_size') // (10 * 1024 * 1024);
    my $md      = $self->_load_metadata($cfg);
    my $entries = $self->_tracked_entries($cfg, $md);

    my @results;
    for my $entry (@$entries) {
        my $path = $entry->{path};
        if (!-e $path && !-l $path) {
            if (defined $md->record_for($path)) {
                push @results, { path => $path, diff => ['(deleted)'] };
            }
            next;
        }
        my $has_rec      = defined $md->record_for($path);
        my $meta_changed = $has_rec && $md->changed_since_load($path, undef, $self->{max_file_size});
        if ($self->_is_non_diffable($path, $md)) {
            if ($meta_changed) {
                push @results, {
                    path => $path,
                    diff => ['(meta: ' . $md->diff_summary($path, undef, $self->{max_file_size}) . ')'],
                };
            }
            next;
        }
        next if $has_rec
             && $md->can_skip_content_diff($path, undef, $self->{max_file_size})
             && !$meta_changed;
        my $diff = eval { $vcs->diff($path) };
        croak "status: diff failed for $path: $@" if $@;
        $diff //= [];
        if (!@$diff && $meta_changed) {
            $diff = ['(meta: ' . $md->diff_summary($path, undef, $self->{max_file_size}) . ')'];
        }
        push @results, { path => $path, diff => $diff } if @$diff;
    }
    return \@results;
}

# _pending_diff_for -- Compute pending diff lines (content or metadata-only)
# for a single tracked path against the live filesystem.
sub _pending_diff_for {
    my ($self, $ep, $vcs, $md) = @_;
    if (!-e $ep && !-l $ep) {
        return defined($md->record_for($ep)) ? ['(deleted)'] : [];
    }
    my $has_rec      = defined $md->record_for($ep);
    my $meta_changed = $has_rec && $md->changed_since_load($ep, undef, $self->{max_file_size});
    if ($self->_is_non_diffable($ep, $md)) {
        return $meta_changed
            ? ['(metadata changed: ' . $md->diff_summary($ep, undef, $self->{max_file_size}) . ')']
            : [];
    }
    return [] if $has_rec
        && $md->can_skip_content_diff($ep, undef, $self->{max_file_size})
        && !$meta_changed;

    my $diff = eval { $vcs->diff($ep) };
    croak "diff failed for $ep: $@" if $@;
    $diff //= [];
    if (!@$diff && $meta_changed) {
        return ['(metadata changed: ' . $md->diff_summary($ep, undef, $self->{max_file_size}) . ')'];
    }
    return $diff;
}

# diff_path -- Return a hashref of path => diff_lines for tracked files.
# When $rev1 (and optionally $rev2) is given, returns historical or
# rev-vs-live diff for $path.  Otherwise computes pending diffs for $path
# (expanding directory paths) or for all tracked paths when $path is undef.
sub diff_path {
    my ($self, $path, $rev1, $rev2) = @_;
    my ($vcs, $cfg) = $self->_setup;
    $self->{max_file_size} = $cfg->global('max_file_size') // (10 * 1024 * 1024);

    if (defined $rev1) {
        croak 'diff: path required when revision is specified'
            unless defined $path && length $path;
        return { $path => $vcs->diff($path, $rev1, $rev2) };
    }

    my $md = $self->_load_metadata($cfg);

    if (defined $path) {
        (my $dir_prefix = $path) =~ s{/+$}{};
        $dir_prefix = '/' if $path =~ m{\A/+\z};
        my $prefix_slash = $dir_prefix eq '/' ? '/' : "$dir_prefix/";
        my $entries      = $self->_tracked_entries($cfg, $md);
        my @matching     = grep {
            $_->{path} eq $dir_prefix || index($_->{path}, $prefix_slash) == 0
        } @$entries;

        if ((-d $path && !-l $path) || @matching > 1) {
            my %result;
            for my $entry (@matching) {
                my $ep   = $entry->{path};
                my $diff = $self->_pending_diff_for($ep, $vcs, $md);
                $result{$ep} = $diff if @$diff;
            }
            return \%result;
        }

        return { $path => $self->_pending_diff_for($path, $vcs, $md) };
    }

    my $entries = $self->_tracked_entries($cfg, $md);
    my %result;
    for my $entry (@$entries) {
        my $ep   = $entry->{path};
        my $diff = $self->_pending_diff_for($ep, $vcs, $md);
        $result{$ep} = $diff if @$diff;
    }
    return \%result;
}

# log_path -- Return a hashref of path => log_lines for tracked files.
# When $path is undef, returns repo-wide history under '(repository)'.
# When $path is a directory on per-file/non-dir backends (RCS/Fossil),
# expands matching tracked, metadata-recorded, and archive paths under $path.
sub log_path {
    my ($self, $path) = @_;
    my ($vcs, $cfg) = $self->_setup;

    if (!defined $path) {
        return { '(repository)' => $vcs->log_history(undef) };
    }

    if (-d $path && !-l $path && ($vcs->isa('ChangeTrack::VCS::RCS') || $vcs->isa('ChangeTrack::VCS::Fossil'))) {
        my $md = $self->_load_metadata($cfg);
        (my $dir_prefix = $path) =~ s{/+$}{};
        $dir_prefix = '/' if $path =~ m{\A/+\z};
        my $prefix_slash = $dir_prefix eq '/' ? '/' : "$dir_prefix/";

        my %seen;
        my @paths;
        my $entries = $self->_tracked_entries($cfg, $md);
        for my $e (@$entries) {
            my $p = $e->{path};
            next unless index($p, $prefix_slash) == 0;
            push @paths, $p unless $seen{$p}++;
        }
        if ($md && $md->{records}) {
            for my $p (keys %{ $md->{records} }) {
                next unless index($p, $prefix_slash) == 0;
                push @paths, $p unless $seen{$p}++;
            }
        }
        if ($vcs->isa('ChangeTrack::VCS::RCS')) {
            my $output_dir = $cfg->global('output_dir') // '/var/lib/changetrack-ng';
            my $rcs_dir    = "$output_dir/RCS";
            if (-d $rcs_dir && opendir(my $dh, $rcs_dir)) {
                my $enc_prefix = '';
                if ($dir_prefix ne '/') {
                    my $rel = $dir_prefix;
                    $rel =~ s{\A/+}{};
                    $rel =~ s/%/%25/g;
                    $rel =~ s/:/%3A/g;
                    $rel =~ s{/}{:}g;
                    $enc_prefix = "$rel:";
                }
                while (my $arch = readdir($dh)) {
                    next unless $arch =~ s/,v\z//;
                    next if $arch eq '.changetrack-metadata';
                    next unless $enc_prefix eq '' || index($arch, $enc_prefix) == 0;
                    my $decoded = $arch;
                    $decoded =~ s{:}{/}g;
                    $decoded =~ s{%3A}{:}gi;
                    $decoded =~ s{%25}{%}g;
                    $decoded = "/$decoded";
                    push @paths, $decoded unless $seen{$decoded}++;
                }
                closedir($dh);
            }
        }
        @paths = sort @paths;
        if (@paths) {
            my %result;
            for my $p (@paths) {
                my $log = eval { $vcs->log_history($p) };
                croak "log failed for $p: $@" if $@;
                $result{$p} = $log // [];
            }
            return \%result;
        }
    }

    return { $path => $vcs->log_history($path) };
}

# show_path -- Retrieve historical content and metadata for $path at $rev.
# Returns a formatted string suitable for printing to STDOUT.
sub show_path {
    my ($self, $path, $rev) = @_;
    croak 'show: path and revision required'
        unless defined $path && length $path && defined $rev && length $rev;

    my ($vcs, $cfg) = $self->_setup;
    my $show      = $vcs->show_at_revision($path, $rev);
    my $hist_meta = eval { $vcs->metadata_at_revision($path, $rev) };

    my $out = "# Path: $path\n# Revision: $rev\n";
    if (defined $hist_meta && ref($hist_meta) eq 'HASH' && keys %$hist_meta) {
        my $type  = $hist_meta->{type} // ($show->{is_symlink} ? 'symlink' : 'file');
        my $mode  = $hist_meta->{mode} // '-';
        my $owner = (defined $hist_meta->{user} && defined $hist_meta->{group})
            ? "$hist_meta->{user}:$hist_meta->{group}"
            : (defined $hist_meta->{uid} && defined $hist_meta->{gid})
                ? "$hist_meta->{uid}:$hist_meta->{gid}"
                : '-';
        $out .= "# Type: $type  Mode: $mode  Owner: $owner\n";
    }
    if ($show->{is_symlink}) {
        $out .= "# Symlink-Target: $show->{target}\n";
        $out .= "symlink -> $show->{target}\n";
    } else {
        my $content = $show->{content} // '';
        $out .= $content;
        $out .= "\n" if length($content) && $content !~ /\n\z/;
    }
    return $out;
}

# _load_metadata -- Load the metadata sidecar for the configured output_dir.
sub _load_metadata {
    my ($self, $cfg) = @_;
    my $output_dir = $cfg->global('output_dir') // '/var/lib/changetrack-ng';
    my $max_size   = $self->{max_file_size} // $cfg->global('max_file_size') // (10 * 1024 * 1024);
    return ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata", max_file_size => $max_size);
}

# _is_non_diffable -- Return true for file types that cannot produce meaningful diffs.
# (binary, special, unreadable, oversize).  Symlinks are always diffable (target is text).
# Empty files (0 bytes) are considered diffable so truncations show deleted content.
sub _is_non_diffable {
    my $self = (ref($_[0]) || $_[0] eq __PACKAGE__) ? shift : undef;
    my ($path, $md) = @_;
    return 1 unless defined $path;
    return 0 if -l $path;          # symlinks are always diffable (target is text)
    return 1 unless -f $path;      # special files
    return 1 unless -r $path;      # unreadable
    return 0 if -z $path;          # empty files are diffable (truncations show deleted content)
    if (defined $md && $md->can('record_for')) {
        my $rec = $md->record_for($path);
        if ($rec && defined $rec->{type}) {
            return 1 if $rec->{type} eq 'oversize' || $rec->{type} eq 'binary' || $rec->{type} eq 'special' || $rec->{type} eq 'unreadable';
        }
    }
    my $max_size = $self ? $self->{max_file_size} : undef;
    if (defined $max_size && $max_size > 0) {
        my @s = stat($path);
        return 1 if @s && $s[7] > $max_size;
    }
    return (-B $path) ? 1 : 0;     # binary
}

# validate_revert -- Verify config, initialized VCS, and that $path exists
# at $rev before prompting for interactive confirmation.
sub validate_revert {
    my ($self, $path, $rev) = @_;
    my ($vcs, $cfg) = $self->_setup;
    $vcs->show_at_revision($path, $rev);
    return 1;
}

# revert_path -- Revert $path to $rev via the VCS under the run lock,
# restoring historical mode and ownership after the VCS restore.
# When dry_run is enabled, returns a preview hashref without locking or mutating disk.
sub revert_path {
    my ($self, $path, $rev) = @_;
    my ($vcs, $cfg) = $self->_setup;

    if ($self->{dry_run}) {
        my $show      = $vcs->show_at_revision($path, $rev);
        my $hist_meta = eval { $vcs->metadata_at_revision($path, $rev) };
        my $md        = $self->_load_metadata($cfg);
        my $curr_meta = $md ? $md->record_for($path) : undef;
        my $target_meta = (defined $hist_meta && keys %$hist_meta)
            ? $hist_meta
            : (defined $curr_meta && keys %$curr_meta)
                ? $curr_meta
                : undef;

        my $diff;
        if (-e $path || -l $path) {
            $diff = eval { $vcs->diff($path, $rev) };
            $diff //= [];
        } else {
            $diff = ['(file not currently on disk; would restore from revision)'];
        }

        return {
            dry_run  => 1,
            path     => $path,
            revision => $rev,
            metadata => $target_meta,
            show     => $show,
            diff     => $diff,
        };
    }

    # Never pass force => 1: CLI --force skips the revert prompt, not the run lock.
    my $lock = $self->_lock_for($cfg, 0);
    $lock->acquire
        or croak "Another changetrack-ng run holds the lock ($lock->{path}); retry shortly";

    my $hist_meta = eval { $vcs->metadata_at_revision($path, $rev) };
    my $md        = $self->_load_metadata($cfg);
    my $curr_meta = $md ? $md->record_for($path) : undef;
    my $pre       = $self->_snapshot_existing_file($path);

    my $target_meta = (defined $hist_meta && keys %$hist_meta)
        ? $hist_meta
        : (defined $curr_meta && keys %$curr_meta)
            ? $curr_meta
            : ($pre && !$pre->{is_symlink})
                ? $pre
                : undef;

    eval {
        $vcs->revert($path, $rev);
        $self->_restore_file_metadata($path, $target_meta);
    };
    my $err = $@;
    $lock->release;
    croak $err if $err;
}

# _snapshot_existing_file -- Capture the current mode/uid/gid of $path
# before a VCS revert so ownership can be restored afterwards.
sub _snapshot_existing_file {
    my $path = @_ > 1 ? $_[1] : $_[0];
    return undef unless defined $path && (-e $path || -l $path);

    my @st = lstat($path);
    return undef unless @st;

    return {
        mode       => $st[2] & 07777,
        uid        => $st[4] + 0,
        gid        => $st[5] + 0,
        is_symlink => (-l $path ? 1 : 0),
    };
}

# _restore_file_metadata -- Re-apply historical or target mode and ownership to $path.
# chown is only attempted when running as root (uid 0).  The target is
# re-checked immediately before chmod/chown: mode/ownership restore applies
# only to a regular file, so if the path now resolves to a symlink or a
# non-regular file it is skipped rather than risk operating on the wrong target.
sub _restore_file_metadata {
    my ($self, $path, $target_meta) = @_;
    if (@_ == 2 && !ref($_[0])) {
        ($self, $path, $target_meta) = (undef, @_);
    }

    my @st = lstat($path);
    # Return immediately without warning if !@st or -l _ (CORR-14)
    return if !@st || -l _;

    # If !-f _: emit warning and return
    if (!-f _) {
        $self->_warn("revert metadata restore skipped (not a regular file): $path") if $self;
        return;
    }

    # Determine $mode:
    my $mode;
    if (defined $target_meta && defined $target_meta->{mode}
        && !$target_meta->{is_symlink}
        && (($target_meta->{type} // '') ne 'symlink')) {
        if ($target_meta->{mode} =~ /^0[0-7]+$/) {
            $mode = oct($target_meta->{mode});
        } else {
            $mode = $target_meta->{mode} & 07777;
        }
    } else {
        $mode = 0644;
    }

    chmod($mode, $path)
        or ($self && $self->_warn("revert metadata restore failed (chmod $path): $!"));

    if ($> == 0 && defined $target_meta && defined $target_meta->{uid} && defined $target_meta->{gid}) {
        chown($target_meta->{uid}, $target_meta->{gid}, $path)
            or ($self && $self->_warn("revert metadata restore failed (chown $path): $!"));
    }
}

# _validate_notifiers -- Validate all instantiated notifiers before the run begins.
# Croaks with a user-facing error if any notifier's validate_config returns errors.
sub _validate_notifiers {
    my ($self, $notifiers) = @_;
    return unless $notifiers && @$notifiers;

    for my $notifier (@$notifiers) {
        my @errors = $notifier->validate_config;
        if (@errors) {
            my $label = ref($notifier)
                . ($notifier->{instance_name} ? ":$notifier->{instance_name}" : '');
            croak "Notifier '$label' configuration error: " . join('; ', @errors);
        }
    }
}

# _warn_insecure_config_permissions -- Warn if any loaded config file is world-readable
# and the configuration contains notifier secrets (OTLP headers, webhook URLs).
sub _warn_insecure_config_permissions {
    my ($self, $cfg, $path) = @_;
    return unless defined $cfg;

    my $all = $cfg->notifiers;
    my $has_secret = 0;

    # OTLP instances with headers configured.
    for my $inst (@{ $all->{otlp} // [] }) {
        my $h = $inst->{headers} // '';
        $has_secret = 1 if !ref($h) && $h =~ /\S/;
        last if $has_secret;
    }

    # Webhook instances have URLs (treat as sensitive operational data).
    unless ($has_secret) {
        for my $inst (@{ $all->{webhook} // [] }) {
            my $u = $inst->{url};
            if (ref $u eq 'ARRAY') {
                $has_secret = 1 if grep { defined $_ && /\S/ } @$u;
            } elsif (defined $u && !ref $u && $u =~ /\S/) {
                $has_secret = 1;
            }
            last if $has_secret;
        }
    }

    return unless $has_secret;

    my @files = $cfg->can('loaded_files') ? $cfg->loaded_files : ();
    push @files, $path if defined $path && !grep { $_ eq $path } @files;

    for my $f (@files) {
        next unless defined $f && -e $f;
        my @st = stat($f);
        next unless @st;
        my $mode = $st[2] & 07777;
        if ($mode & 0004) { # world-readable
            $self->_warn(sprintf(
                'config %s is world-readable (%04o) and contains notifier secrets; set mode 0640 or stricter',
                $f,
                $mode,
            ));
        }
    }
}

# _enforce_output_permissions -- Verify and tighten permissions on output_dir and
# sibling VCS repositories ($output_dir.fossil, $output_dir-svnrepo).
# Warns and records a warning in $report if permissions are group- or world-accessible.
sub _enforce_output_permissions {
    my ($self, $output_dir, $report) = @_;
    return unless defined $output_dir;

    my @check_paths = ($output_dir, "$output_dir.fossil", "$output_dir-svnrepo");
    for my $path (@check_paths) {
        next unless -e $path;
        my @st = stat($path);
        next unless @st;
        my $mode = $st[2];
        if (($mode & 0077) != 0) {
            my $new_mode = ($mode & ~0077) & 07777;
            my $msg = chmod($new_mode, $path)
                ? sprintf("Tightened insecure permissions on %s from %04o to %04o", $path, $mode & 07777, $new_mode)
                : sprintf("Cannot tighten insecure permissions on %s (%04o): %s", $path, $mode & 07777, $!);
            $self->_warn($msg);
            $report->add_warning($msg) if $report;
        }
    }
}

# _warn_nested_mirror_repos -- Scan a whole-repo mirror for nested .git/.hg/.svn
# repositories (left behind by pre-fix runs on trees like etckeeper's /etc) and
# emit an actionable warning without deleting anything automatically.
sub _warn_nested_mirror_repos {
    my ($self, $output_dir, $report) = @_;
    return unless defined $output_dir && -d $output_dir;
    (my $root = $output_dir) =~ s{(?<=.)/+$}{};

    my %nested_markers = map { $_ => 1 } qw(.git .hg .svn);
    my @nested;

    find({
        wanted => sub {
            my $p = $File::Find::name;
            return if $p eq $root;
            my $base = basename($p);
            return unless $nested_markers{$base};

            my $is_dir     = (-d $_ && !-l $_);
            my $is_gitfile = ($base eq '.git' && -f $_ && !-l $_);
            return unless $is_dir || $is_gitfile;

            $File::Find::prune = 1 if $is_dir;
            return if dirname($p) eq $root;    # backend's own root control dir
            push @nested, $p;
        },
        no_chdir => 1,
    }, $root);

    for my $nested_path (sort @nested) {
        my $msg = "Nested repository at $nested_path inside the mirror; files below it were not being committed.";
        $self->_warn($msg);
        $report->add_warning($msg) if $report;
    }
}

########################################################################
# Logging helpers
########################################################################

# _info -- Print an informational message to STDOUT (suppressed with --quiet).
sub _info {
    my ($self, $msg) = @_;
    return if $self->{quiet};
    $self->_log('INFO', $msg);
}

# _verbose -- Emit a [VERBOSE] message to STDERR (only with --verbose/-v).
sub _verbose {
    my ($self, $msg) = @_;
    return unless $self->{verbose};
    $self->_log('VERBOSE', $msg, 1);
}

# _debug -- Emit a [DEBUG] message to STDERR (only with --debug/-d).
sub _debug {
    my ($self, $msg) = @_;
    return unless $self->{debug};
    $self->_log('DEBUG', $msg, 1);
}

# _trace -- Emit a [TRACE] message to STDERR (only with --trace/-t).
sub _trace {
    my ($self, $msg) = @_;
    return unless $self->{trace};
    $self->_log('TRACE', $msg, 1);
}

# _warn -- Emit a [WARN] message to STDERR unconditionally.
sub _warn {
    my ($self, $msg) = @_;
    $self->_log('WARN', $msg, 1);
}

# _log -- Format and emit a timestamped log line.
# $to_stderr=1 sends to STDERR; otherwise to STDOUT.
sub _log {
    my ($self, $level, $msg, $to_stderr) = @_;
    my $ts = strftime('%Y-%m-%dT%H:%M:%S%z', localtime(time()));
    my $line = "[changetrack-ng][$ts][$level] $msg\n";
    if ($to_stderr) {
        warn $line;
    } else {
        print $line;
    }
}

1;

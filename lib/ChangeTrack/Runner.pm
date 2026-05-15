# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
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
C<diff_path>, C<log_path>, C<revert_path>) are also exposed for the CLI.

=head1 CLASS METHODS

=over 4

=item ChangeTrack::Runner->new(%opts)

Accepted options: C<config>, C<message>, C<no_auto_init>, C<quiet>,
C<verbose>, C<debug>, C<trace>, C<force>.

=back

=head1 INSTANCE METHODS

=over 4

=item $runner->run

Perform a full scan-commit-notify cycle.  Returns the C<ChangeTrack::Report>
object.  Dies on VCS-level failure.

=item $runner->status

Return an arrayref of hashrefs for files that have changed since the last
commit.  Each hashref has at least a C<path> key.

=item $runner->diff_path($path)

Return a hashref mapping file paths to arrayrefs of diff lines.  If
I<$path> is undef, all pending diffs are returned.

=item $runner->log_path($path)

Return a hashref mapping file paths to arrayrefs of log lines.

=item $runner->revert_path($path, $rev)

Restore I<$path> to VCS revision I<$rev>.

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
use ChangeTrack::Util qw(hostname set_debug);

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
#          dry_run, force, warn_special_files.
# Enforces the implication chain: trace -> debug -> verbose.
sub new {
    my ($class, %args) = @_;

    # Enforce implication chain: trace -> debug -> verbose
    my $trace   = $args{trace}   // 0;
    my $debug   = $args{debug}   // 0;
    my $verbose = $args{verbose} // 0;
    $debug   = 1 if $trace;
    $verbose = 1 if $debug;

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

    my $cfg        = ChangeTrack::Config->load($self->{config_path});
    $self->_verbose("Config loaded from $self->{config_path}");
    $self->_warn_insecure_config_permissions($cfg, $self->{config_path});
    my @notify_names = @{ $cfg->global('notify') // [] };
    $self->_validate_notifier_startup($cfg, \@notify_names);
    my $vcs_name   = lc($cfg->global('vcs')        // 'rcs');
    my $output_dir = $cfg->global('output_dir')     // '/var/lib/changetrack-ng';

    $self->_verbose("VCS: $vcs_name, output_dir: $output_dir");
    $self->_verbose("Notify: " . (@notify_names ? join(', ', @notify_names) : 'none'));

    # Acquire run lock  --  silently skip if another instance is running (safe for cron)
    my $lock_path = $cfg->global('lock_path');
    unless (defined($lock_path) && $lock_path =~ /\S/) {
        $lock_path = _default_lock_path();
    }
    _ensure_lock_parent_dir($lock_path);

    my $lock_timeout = $cfg->global('lock_timeout') // 0;
    $self->_verbose("Acquiring lock: $lock_path (timeout=${lock_timeout}s)");

    my $lock = ChangeTrack::Lock->new(
        path    => $lock_path,
        timeout => $lock_timeout,
        force   => $self->{force},
    );
    unless ($lock->acquire) {
        $self->_verbose("Skipping: another instance holds lock");
        $self->_info("Another instance is running; skipping this run.");
        return ChangeTrack::Report->new(start_time => $start_time);
    }
    $self->_verbose("Lock acquired");

    # Config overrides constructor default for warn_special_files
    my $cfg_wsf = $cfg->global('warn_special_files');
    $self->{warn_special_files} = defined($cfg_wsf) ? ($cfg_wsf ? 1 : 0) : $self->{warn_special_files};

    # Global sensitivity auto-detection toggle (default: enabled)
    $self->{sensitive_auto} = _bool_or_default($cfg->global('sensitive_auto'), 1);

    # Instantiate VCS backend
    my $vcs_class = $VCS_CLASSES{$vcs_name}
        or croak "Unknown VCS '$vcs_name'";
    eval "require $vcs_class; 1" or croak "Cannot load $vcs_class: $@";

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
    my $md = ChangeTrack::Metadata->load($meta_path);
    $self->_debug("Metadata sidecar: $meta_path (" . scalar(keys %{ $md->{records} }) . " entries loaded)");
    $self->_debug("Hostname resolved: " . hostname());
    $self->_debug("Lock path: $lock_path (running as uid=$>)");

    # Debug: dump effective config values (redact secrets)
    if ($self->{debug}) {
        for my $key (sort keys %{ $cfg->{global} }) {
            my $val = $cfg->{global}{$key};
            $val = join(' ', @$val) if ref $val eq 'ARRAY';
            $val //= '';
            if ($key =~ /header|secret|token|password/i) {
                $val = '***REDACTED***';
            }
            $self->_debug("config: $key = $val");
        }
    }

    # Build combined ignore list
    my @user_ignore = @{ $cfg->global('ignore') // [] };
    my @ignore_pats = (@BUILTIN_IGNORE, @user_ignore);
    my $compiled_ignore = _compile_ignore_patterns(\@ignore_pats);

    # Build file list from track entries
    $self->_verbose("Building file list...");
    my @entries = $self->_build_file_list($cfg->tracks, $compiled_ignore, _internal_exclude_paths($cfg));
    my $track_count  = scalar @{ $cfg->tracks };
    my $ignore_count = scalar @user_ignore;
    $self->_verbose("Tracking $track_count entries, $ignore_count user ignore patterns, " . scalar(@entries) . " resolved paths");

    # Commit message
    my $ts         = strftime('%Y-%m-%dT%H:%M:%S', localtime($start_time));
    my $commit_msg = "changetrack-ng run \@ $ts";
    $commit_msg   .= " [hook: $self->{message}]" if $self->{message};

    my $report = ChangeTrack::Report->new(start_time => $start_time);

    $self->_verbose("Processing " . scalar(@entries) . " tracked paths");

    for my $entry (@entries) {
        eval { $self->_process_file($entry, $vcs, $md, $report, $commit_msg) };
        if ($@) {
            (my $err = $@) =~ s/\n$//;
            $self->_warn($err);
            $report->add_warning($err);
        }
    }

    # Save metadata
    unless ($self->{dry_run}) {
        eval { $md->save($meta_path) };
        $self->_warn("metadata save failed: $@") if $@;
    }

    # Batch commit for whole-repo VCS
    if (!$self->{dry_run} && $vcs->model eq 'whole-repo' && $report->has_changes) {
        my $change_count = scalar @{ $report->changes };
        $self->_verbose("Committing $change_count changes to $vcs_name");
        eval { $vcs->commit($commit_msg) };
        croak "VCS commit failed: $@" if $@;
    } elsif ($self->{verbose} && !$report->has_changes) {
        $self->_verbose("No changes to commit");
    }

    $report->set_end_time(time());

    print $report->to_text unless $self->{quiet};

    # Dispatch notifications
    if (@notify_names) {
        $self->_verbose("Sending notifications via: " . join(', ', @notify_names));
    }
    for my $nname (@notify_names) {
        my $nclass = $NOTIFY_CLASSES{lc($nname)} or do {
            $self->_warn("unknown notifier '$nname'");
            next;
        };
        eval "require $nclass; 1" or do {
            $self->_warn("cannot load $nclass: $@");
            next;
        };
        my $notifier = $self->_build_notifier($nclass, $cfg);
        unless ($self->{dry_run}) {
            $self->_debug("Notifier $nname: sending...");
            eval { $notifier->send($report) };
            if ($@) {
                (my $err = $@) =~ s/\n$//;
                $self->_debug("Notifier $nname: failed: $err");
            } else {
                $self->_debug("Notifier $nname: sent OK");
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

    my $existing = $md->record_for($real_path);
    my $prev_type = defined($existing) ? ($existing->{type} // '') : '';

    # File no longer on disk
    unless (-e $real_path || -l $real_path) {
        if (defined $existing) {
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
    if (defined $existing && $md->can_skip_content_diff($real_path)
        && !$md->changed_since_load($real_path)) {
        # Refresh the record (preserves the type as-is).
        $md->update_from_stat($real_path);
        $self->_trace("$real_path: skipped (mtime+size unchanged)");
        return;
    }

    # Classify the file (stat it once, determine type)
    $md->update_from_stat($real_path);
    my $rec  = $md->record_for($real_path);
    my $type = $rec->{type};

    # Non-trackable types: special, unreadable, binary, empty
    if ($type eq 'special') {
        $self->_trace("$real_path: classified as special, metadata only");
        unless ($prev_type eq 'special' && !$md->changed_since_load($real_path)) {
            if ($self->{warn_special_files}) {
                $self->_warn("skipping special file (FIFO/socket/device): $real_path");
            }
            $report->add_warning("Skipping special file: $real_path");
        }
        return;
    }

    if ($type eq 'unreadable') {
        $self->_trace("$real_path: classified as unreadable, metadata only");
        unless ($prev_type eq 'unreadable' && !$md->changed_since_load($real_path)) {
            $report->add_warning("Skipping unreadable: $real_path");
        }
        return;
    }

    if ($type eq 'binary') {
        $self->_trace("$real_path: classified as binary, metadata only");
        unless ($prev_type eq 'binary') {
            if ($self->{warn_special_files}) {
                $self->_warn("skipping binary file: $real_path");
            }
            $report->add_warning("Skipping binary file: $real_path");
        }
        return;
    }

    if ($type eq 'empty') {
        # Empty files have no content to diff.  Report only meta changes.
        if (defined $existing && $md->changed_since_load($real_path)) {
            my $meta_summary = $md->diff_summary($real_path);
            my $msg = $meta_summary ? "$commit_msg [meta: $meta_summary]" : $commit_msg;
            $vcs->checkin($real_path, $msg) unless $self->{dry_run};
            my $is_sensitive = _resolve_sensitive($real_path, $sensitive, $self->{sensitive_auto},
                defined($rec->{mode}) ? oct($rec->{mode}) : undef);
            $report->add_change(
                path         => $real_path,
                is_new       => 0,
                is_sensitive => $is_sensitive,
                diff         => [],
                meta_change  => $meta_summary,
                recipients   => $recipients,
            );
            $self->_debug("Changed (meta): $real_path ($meta_summary)");
        } elsif (!defined $existing) {
            $vcs->checkin($real_path, $commit_msg) unless $self->{dry_run};
            my $is_sensitive = _resolve_sensitive($real_path, $sensitive, $self->{sensitive_auto},
                defined($rec->{mode}) ? oct($rec->{mode}) : undef);
            $report->add_change(
                path         => $real_path,
                is_new       => 1,
                is_sensitive => $is_sensitive,
                diff         => ['(new empty file)'],
                meta_change  => '',
                recipients   => $recipients,
            );
            $self->_debug("New: $real_path (type=$type, mode=" . ($rec->{mode} // '?') . ")");
            $self->_info("New: $real_path");
        } elsif (!defined $existing) {
            $self->_trace("$real_path: empty, unchanged");
        }
        return;
    }

    # Warn about hardlinked regular files
    if ($type eq 'file') {
        my @st = stat($real_path);
        if (@st && $st[3] > 1) {
            $self->_warn("$real_path has $st[3] hard links  --  changes via other names will not be tracked");
        }
    }

    # Trackable types: file, symlink
    my $is_sensitive = _resolve_sensitive($real_path, $sensitive, $self->{sensitive_auto},
        defined($rec->{mode}) ? oct($rec->{mode}) : undef);

    if (!defined $existing) {
        # New file / symlink
        $vcs->checkin($real_path, $commit_msg) unless $self->{dry_run};
        $report->add_change(
            path         => $real_path,
            is_new       => 1,
            is_sensitive => $is_sensitive,
            diff         => ['(new file)'],
            meta_change  => '',
            recipients   => $recipients,
        );
        $self->_debug("New: $real_path (type=$type, mode=" . ($rec->{mode} // '?') . ")");
        $self->_info("New: $real_path");
    } else {
        # Existing file / symlink  --  check for changes
        my $meta_changed = $md->changed_since_load($real_path);
        my $meta_summary = $meta_changed ? $md->diff_summary($real_path) : '';

        # Symlinks: content is the target, already captured by changed_since_load.
        # Regular files: diff only if mtime+size moved.
        my $skip_content_diff = ($type eq 'symlink') ? 1 : $md->can_skip_content_diff($real_path);
        my $diff_lines = $skip_content_diff ? [] : $vcs->diff($real_path);
        my $content_changed = @$diff_lines > 0;

        if ($meta_changed || $content_changed) {
            my $msg = $meta_summary ? "$commit_msg [meta: $meta_summary]" : $commit_msg;
            $vcs->checkin($real_path, $msg) unless $self->{dry_run};
            $report->add_change(
                path         => $real_path,
                is_new       => 0,
                is_sensitive => $is_sensitive,
                diff         => $diff_lines,
                meta_change  => $meta_summary,
                recipients   => $recipients,
            );
            $self->_debug("Changed: $real_path"
                . ($meta_summary ? " (meta: $meta_summary)" : ''));
        } else {
            $self->_trace("$real_path: unchanged");
        }
    }
}

########################################################################
# File list building
########################################################################

# _build_file_list -- Resolve all track entries into a sorted list of
# { path, sensitive, recipients } hashrefs, applying ignore and exclude
# patterns.  Directory entries are expanded recursively via File::Find.
sub _build_file_list {
    my ($self, $tracks, $ignore_pats, $exclude_paths) = @_;
    my @entries;
    $exclude_paths ||= [];

    for my $track (@$tracks) {
        my $opt_sensitive = $track->{options}{sensitive};

        my $recips = $track->{emails} && ref($track->{emails}) eq 'ARRAY'
            ? [ @{ $track->{emails} } ]
            : [];

        if ($track->{kind} eq 'file') {
            my $p = $track->{path};
            if (_should_ignore($p, basename($p), $ignore_pats)) {
                $self->_trace("$p: ignored by pattern");
                next;
            }
            if (_is_excluded_path($p, $exclude_paths)) {
                $self->_trace("$p: excluded (internal path)");
                next;
            }
            push @entries, { path => $p, sensitive => $opt_sensitive, recipients => $recips };

        } elsif ($track->{kind} eq 'directory') {
            my $dir = $track->{path};
            next unless -d $dir;
            next if _is_excluded_path($dir, $exclude_paths);

            find({
                wanted => sub {
                    return unless -f $_ || -l $_;
                    my $p = $File::Find::name;
                    if (_should_ignore($p, basename($p), $ignore_pats)) {
                        $self->_trace("$p: ignored by pattern");
                        return;
                    }
                    if (_is_excluded_path($p, $exclude_paths)) {
                        $self->_trace("$p: excluded (internal path)");
                        return;
                    }
                    push @entries, { path => $p, sensitive => $opt_sensitive, recipients => $recips };
                },
                no_chdir => 1,
            }, $dir);
        }
    }

    @entries = sort { $a->{path} cmp $b->{path} } @entries;
    return @entries;
}

# _internal_exclude_paths -- Return paths that should never be tracked
# (the output_dir itself and the metadata sidecar).
sub _internal_exclude_paths {
    my ($cfg) = @_;
    my $output_dir = $cfg->global('output_dir') // '/var/lib/changetrack-ng';
    my $vcs_name   = lc($cfg->global('vcs') // 'rcs');

    my @exclude = (
        $output_dir,
        "$output_dir/.changetrack-metadata",
    );
    push @exclude, "$output_dir.fossil" if $vcs_name eq 'fossil';
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

# _should_ignore -- Return true if $full_path or its basename matches
# any compiled ignore pattern.
sub _should_ignore {
    my ($full_path, $base, $compiled_patterns) = @_;
    if (@$compiled_patterns && ref($compiled_patterns->[0]) ne 'HASH') {
        $compiled_patterns = _compile_ignore_patterns($compiled_patterns);
    }
    my $norm_full_path = $full_path;
    $norm_full_path =~ s{\\}{/}g;
    for my $spec (@$compiled_patterns) {
        if ($spec->{path}) {
            return 1 if $norm_full_path =~ $spec->{re};
        } else {
            return 1 if $base =~ $spec->{re};
        }
    }
    return 0;
}

# _compile_ignore_patterns -- Convert a list of glob strings to an
# arrayref of { path => bool, re => qr// } hashrefs.
# Path-containing patterns (with /) match as a path suffix;
# plain patterns match only the filename.
sub _compile_ignore_patterns {
    my ($patterns) = @_;
    my @compiled;
    for my $pat (@$patterns) {
        next unless defined $pat && $pat ne '';
        if ($pat =~ m{/}) {
            my $re = _glob_to_re($pat);
            push @compiled, { path => 1, re => qr{(?:^|/)${re}$} };
        } else {
            my $re = _glob_to_re($pat);
            push @compiled, { path => 0, re => qr/^${re}$/ };
        }
    }
    return \@compiled;
}

# _glob_match -- Test a single glob string against a plain string.
# Used in tests; not called in the main run path.
sub _glob_match {
    my ($glob, $str) = @_;
    my $re = _glob_to_re($glob);
    return $str =~ /^${re}$/;
}

# _glob_to_re -- Convert a simple glob pattern to a regex fragment.
# Handles *, ?, and escapes regex metacharacters.  Does not support ** or [].
sub _glob_to_re {
    my ($glob) = @_;
    my $re = '';
    for my $ch (split //, $glob) {
        if    ($ch eq '*') { $re .= '[^/]*' }
        elsif ($ch eq '?') { $re .= '[^/]'  }
        elsif ($ch eq '.') { $re .= '\.'    }
        elsif ($ch =~ /[\[\]{}()+^\$|\\]/) { $re .= "\\$ch" }
        else               { $re .= $ch     }
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

# _default_lock_path -- Return the appropriate lock file path.
# root gets /var/run/changetrack-ng.lock;
# unprivileged users get $XDG_CACHE_HOME/changetrack-ng.lock.
sub _default_lock_path {
    return '/var/run/changetrack-ng.lock' if $> == 0;

    my $cache_dir = $ENV{XDG_CACHE_HOME};
    unless (defined($cache_dir) && $cache_dir =~ /\S/) {
        my $home = $ENV{HOME};
        if (!(defined($home) && $home =~ /\S/)) {
            my @pw = getpwuid($<);
            $home = $pw[7] if @pw;
        }
        $cache_dir = (defined($home) && $home =~ /\S/) ? "$home/.cache" : '/tmp';
    }

    return "$cache_dir/changetrack-ng.lock";
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
    my ($self) = @_;
    my $cfg        = ChangeTrack::Config->load($self->{config_path});
    my $vcs_name   = lc($cfg->global('vcs')        // 'rcs');
    my $output_dir = $cfg->global('output_dir')     // '/var/lib/changetrack-ng';

    my $vcs_class  = $VCS_CLASSES{$vcs_name}
        or croak "Unknown VCS '$vcs_name'";
    eval "require $vcs_class; 1" or croak "Cannot load $vcs_class: $@";

    my $vcs = $vcs_class->new(
        output_dir => $output_dir,
        options    => { push_remote => $cfg->global('push_remote') },
        verbose    => $self->{verbose} // 0,
    );
    croak "VCS not initialized. Run 'changetrack-ng init' first."
        unless $vcs->is_initialized;

    return ($vcs, $cfg);
}

# _tracked_entries -- Resolve all track entries for the current config,
# applying ignore and exclude patterns.  Returns an arrayref.
sub _tracked_entries {
    my ($self, $cfg) = @_;
    my @user_ignore = @{ $cfg->global('ignore') // [] };
    my @ignore_pats = ($self->builtin_ignore_patterns, @user_ignore);
    my $compiled_ignore = _compile_ignore_patterns(\@ignore_pats);
    return [$self->_build_file_list($cfg->tracks, $compiled_ignore, _internal_exclude_paths($cfg))];
}

# _build_notifier -- Instantiate the notifier class $nclass with config values.
# Passes only the keys each notifier declares via config_keys(), plus
# the shared sensitive_notify key.
sub _build_notifier {
    my ($self, $nclass, $cfg) = @_;

    # Build the complete pool of config args (all possible keys across all notifiers).
    # _build_notifier then filters to only the keys the target notifier class declares
    # via config_keys(), plus the shared sensitive_notify key.
    my %all_args = (
        # Email
        email_from                => $cfg->global('email_from'),
        email_to                  => $cfg->global('email_to') // [],
        sendmail_path             => $cfg->global('sendmail_path'),
        # File
        log_path                  => $cfg->global('notify_log_path'),
        file_heartbeat            => $cfg->global('file_heartbeat') // 0,
        file_full_diff            => $cfg->global('file_full_diff') // 1,
        # Webhook
        webhook_url               => $cfg->global('webhook_url'),
        webhook_full_diff         => $cfg->global('webhook_full_diff') // 0,
        webhook_heartbeat         => $cfg->global('webhook_heartbeat') // 0,
        webhook_insecure          => $cfg->global('webhook_insecure') // 0,
        webhook_timeout           => $cfg->global('webhook_timeout') // 10,
        # OTLP
        otlp_endpoint             => $cfg->global('otlp_endpoint'),
        otlp_headers              => $cfg->global('otlp_headers') // '',
        otlp_compression          => $cfg->global('otlp_compression') // '',
        otlp_full_diff            => $cfg->global('otlp_full_diff') // 0,
        otlp_heartbeat            => $cfg->global('otlp_heartbeat') // 1,
        otlp_timeout              => $cfg->global('otlp_timeout') // 10,
        otlp_insecure             => $cfg->global('otlp_insecure') // 0,
        otlp_resource_attributes  => $cfg->global('otlp_resource_attributes') // {},
    );

    # Filter to only the keys this notifier class accepts, plus the shared key.
    my %accepted = map { $_ => 1 } ($nclass->config_keys, 'sensitive_notify');
    my %args = (
        sensitive_notify => $cfg->global('sensitive_notify') // 'suppress',
        map  { $_ => $all_args{$_} }
        grep { exists $all_args{$_} }
        keys %accepted,
    );

    return $nclass->new(%args);
}

# status -- Return an arrayref of { path, diff } for all tracked files with pending changes.
sub status {
    my ($self) = @_;
    my ($vcs, $cfg) = $self->_setup;
    my $entries = $self->_tracked_entries($cfg);
    my $md      = $self->_load_metadata($cfg);

    my @results;
    for my $entry (@$entries) {
        my $path = $entry->{path};
        next unless -e $path || -l $path;
        next if _is_non_diffable($path);
        next if defined $md->record_for($path)
             && $md->can_skip_content_diff($path)
             && !$md->changed_since_load($path);
        my $diff = eval { $vcs->diff($path) } // [];
        push @results, { path => $path, diff => $diff } if @$diff;
    }
    return \@results;
}

# diff_path -- Return a hashref of path => diff_lines for tracked files with pending diffs.
# If $path is defined, only that file is checked.
sub diff_path {
    my ($self, $path) = @_;
    my ($vcs, $cfg) = $self->_setup;
    my $md          = $self->_load_metadata($cfg);

    if (defined $path) {
        if (defined $md->record_for($path)
            && $md->can_skip_content_diff($path)
            && !$md->changed_since_load($path)) {
            return { $path => [] };
        }
        return { $path => $vcs->diff($path) };
    }

    my $entries = $self->_tracked_entries($cfg);
    my %result;
    for my $entry (@$entries) {
        my $ep = $entry->{path};
        next unless -e $ep || -l $ep;
        next if _is_non_diffable($ep);
        next if defined $md->record_for($ep)
             && $md->can_skip_content_diff($ep)
             && !$md->changed_since_load($ep);
        my $diff = eval { $vcs->diff($ep) } // [];
        $result{$ep} = $diff if @$diff;
    }
    return \%result;
}

# log_path -- Return a hashref of path => log_lines for tracked files.
# If $path is defined, only that file's history is returned.
sub log_path {
    my ($self, $path) = @_;
    my ($vcs, $cfg) = $self->_setup;

    if (defined $path) {
        return { $path => $vcs->log_history($path) };
    }

    my $entries = $self->_tracked_entries($cfg);
    my %result;
    for my $entry (@$entries) {
        my $ep = $entry->{path};
        next unless -e $ep || -l $ep;
        next if _is_non_diffable($ep);
        next unless -e $vcs->output_path($ep);
        my $log = eval { $vcs->log_history($ep) } // [];
        $result{$ep} = $log;
    }
    return \%result;
}

# _load_metadata -- Load the metadata sidecar for the configured output_dir.
sub _load_metadata {
    my ($self, $cfg) = @_;
    my $output_dir = $cfg->global('output_dir') // '/var/lib/changetrack-ng';
    return ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
}

# _is_non_diffable -- Return true for file types that cannot produce meaningful diffs.
# (binary, empty, special, unreadable).  Symlinks are always diffable (target is text).
sub _is_non_diffable {
    my ($path) = @_;
    return 1 unless defined $path;
    return 0 if -l $path;          # symlinks are always diffable (target is text)
    return 1 unless -f $path;      # special files
    return 1 unless -r $path;      # unreadable
    return 1 if -z $path;          # empty
    return (-B $path) ? 1 : 0;     # binary
}

# revert_path -- Revert $path to $rev via the VCS, preserving original
# file mode and ownership after the VCS restore.
sub revert_path {
    my ($self, $path, $rev) = @_;
    my ($vcs) = $self->_setup;

    my $pre = _snapshot_existing_file($path);
    $vcs->revert($path, $rev);
    _restore_file_metadata($self, $path, $pre) if $pre;
}

# _snapshot_existing_file -- Capture the current mode/uid/gid of $path
# before a VCS revert so ownership can be restored afterwards.
sub _snapshot_existing_file {
    my ($path) = @_;
    return undef unless defined $path && (-e $path || -l $path);

    my @st = lstat($path);
    return undef unless @st;

    return {
        mode => $st[2] & 07777,
        uid  => $st[4] + 0,
        gid  => $st[5] + 0,
        is_symlink => (-l $path ? 1 : 0),
    };
}

# _restore_file_metadata -- Re-apply pre-revert mode and ownership to $path.
# chown is only attempted when running as root (uid 0).
sub _restore_file_metadata {
    my ($self, $path, $pre) = @_;
    return unless defined $pre;
    return unless -e $path || -l $path;

    # Mode/ownership restore is only safe on regular files.
    return if -l $path;

    chmod($pre->{mode}, $path)
        or $self->_warn("revert metadata restore failed (chmod $path): $!");

    if ($> == 0) {
        chown($pre->{uid}, $pre->{gid}, $path)
                or $self->_warn("revert metadata restore failed (chown $path): $!");
    }
}

# _validate_notifier_startup -- Instantiate and validate all configured
# notifiers at startup, before any files are processed.
# Croaks with a user-facing error if any notifier's config is invalid.
sub _validate_notifier_startup {
    my ($self, $cfg, $notify_names) = @_;
    return unless $notify_names && @$notify_names;

    for my $nname (@$notify_names) {
        my $nclass = $NOTIFY_CLASSES{lc($nname)}
            or croak "Unknown notifier '$nname'";
        eval "require $nclass; 1" or croak "Cannot load $nclass: $@";

        my $notifier = $self->_build_notifier($nclass, $cfg);

        my @errors = $notifier->validate_config;
        if (@errors) {
            croak "Notifier '$nname' configuration error: " . join('; ', @errors);
        }
    }
}

# _warn_insecure_config_permissions -- Warn if the config file is world-readable
# and contains notifier secrets (OTLP headers, webhook URLs).
sub _warn_insecure_config_permissions {
    my ($self, $cfg, $path) = @_;
    return unless defined $path && -e $path;

    my @st = stat($path);
    return unless @st;
    my $mode = $st[2] & 07777;

    my $has_secret = 0;
    my $otlp_headers = $cfg->global('otlp_headers');
    $has_secret = 1 if defined($otlp_headers) && !ref($otlp_headers) && $otlp_headers =~ /\S/;

    # Treat configured webhook URLs as sensitive operational data.
    my $webhook_url = $cfg->global('webhook_url');
    if (ref $webhook_url eq 'ARRAY') {
        $has_secret = 1 if grep { defined $_ && /\S/ } @$webhook_url;
    } elsif (defined $webhook_url && !ref $webhook_url && $webhook_url =~ /\S/) {
        $has_secret = 1;
    }

    return unless $has_secret;
    return unless ($mode & 0004); # world-readable

    $self->_warn(sprintf(
        'config %s is world-readable (%04o) and contains notifier secrets; set mode 0640 or stricter',
        $path,
        $mode,
    ));
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

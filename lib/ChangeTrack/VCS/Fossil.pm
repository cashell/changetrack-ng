# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::VCS::Fossil - Whole-repo with chdir-based commands and
#   UTF-8 handling.
#

package ChangeTrack::VCS::Fossil;

use strict;
use warnings;
=head1 NAME

ChangeTrack::VCS::Fossil - Fossil VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using Fossil.  Tracked
files are copied into a mirror tree under C<output_dir>, which is an open
Fossil working directory.

=cut

use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak carp);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec ();
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

# _repo_path -- Return the path to the Fossil repository file (.fossil).
sub _repo_path {
    my ($self) = @_;
    return $self->{options}{fossil_repo} // "$self->{output_dir}.fossil";
}

# output_path -- Map a real path to its mirror location.
# /etc/passwd -> $output_dir/etc/passwd  (mirror tree)
sub output_path {
    my ($self, $real_path) = @_;
    my $rel = $self->_mirror_rel($real_path);
    return "$self->{output_dir}/$rel";
}

# _rel_path -- Strip the output_dir prefix to get the repo-relative path.
sub _rel_path {
    my ($self, $mirror) = @_;
    (my $rel = $mirror) =~ s{^\Q$self->{output_dir}\E/?}{};
    return $rel;
}

# _run -- Run a Fossil command inside the checkout using fossil's --chdir option.
# Using --chdir avoids calling Perl's chdir(), which is unreliable under
# systemd where the process CWD may not be a usable directory.
# Also sets FOSSIL_HOME to output_dir when HOME is unset, so Fossil can
# create/find its .fossil user database alongside the checkout state files.
sub _run {
    my ($self, @cmd) = @_;
    my ($prog, @rest) = @cmd;
    my $r;
    my $err;
    if ($self->{verbose}) {
        warn "[Fossil] run in $self->{output_dir}: @rest\n";
    }
    # Fossil needs a home directory for its user database (.fossil file). Under
    # systemd, HOME is not set in the service environment, causing fossil to fail
    # even when the checkout is accessible. Use output_dir so fossil can
    # create/find its .fossil file alongside the other fossil state files.
    local $ENV{FOSSIL_HOME} = $self->{output_dir}
        unless $ENV{HOME} || $ENV{FOSSIL_HOME};

    eval {
        $r = run_cmd(cmd => [$prog, '--chdir', $self->{output_dir}, @rest]);
        1;
    } or do {
        $err = $@ || 'unknown fossil command failure';
    };
    die $err if defined $err;
    if ($self->{verbose}) {
        my $stdout = $r->{stdout} // '';
        my $stderr = $r->{stderr} // '';
        warn "[Fossil] exit=" . ($r->{success} ? 0 : ($r->{exit_code} // '?'))
           . (length($stdout) ? " stdout=$stdout" : '')
           . (length($stderr) ? " stderr=$stderr" : '') . "\n"
            if $stdout =~ /\S/ || $stderr =~ /\S/ || !$r->{success};
    }
    return $r;
}

# _ensure_crlf_setting -- Set crlf-glob=* in fossil settings to prevent
# commit failures from CR/LF line-ending checks.
sub _ensure_crlf_setting {
    my ($self) = @_;
    my $r = $self->_run('fossil', 'settings', 'crlf-glob', '*');
    carp "fossil settings crlf-glob failed: $r->{stderr}" unless $r->{success};
}

# _extract_invalid_utf8_path -- Parse a fossil error message to extract
# the offending path when a commit fails due to invalid UTF-8 content.
sub _extract_invalid_utf8_path {
    my ($self, $stderr) = @_;
    return undef unless defined $stderr && length $stderr;
    return undef unless $stderr =~ /invalid\s+UTF-8\s+in\s+([^\r\n]+)/i;

    my $path = $1;
    $path =~ s/^\s+|\s+$//g;
    $path =~ s/^['"]//;
    $path =~ s/['"]$//;
    $path =~ s{^\./}{};
    return length($path) ? $path : undef;
}

# _merge_glob_list -- Merge $entry into a comma-separated glob list,
# deduplicating existing entries.  Returns the merged string.
sub _merge_glob_list {
    my ($self, $existing, $entry) = @_;
    my %seen;
    my @parts = grep { length $_ } map {
        s/^\s+|\s+$//gr
    } split /,/, ($existing // '');

    @parts = grep { !$seen{$_}++ } @parts;

    if (defined $entry && length $entry && !$seen{$entry}++) {
        push @parts, $entry;
    }

    return join(',', @parts);
}

# _fossil_settings_dir -- Return the path to the .fossil-settings directory.
sub _fossil_settings_dir {
    my ($self) = @_;
    return File::Spec->catdir($self->{output_dir}, '.fossil-settings');
}

# _set_binary_glob_for_path -- Add $rel_path to the versioned binary-glob
# settings file so Fossil skips UTF-8 validation for that file.
# Writing directly to .fossil-settings/binary-glob is more reliable than
# 'fossil settings binary-glob', which behaves differently across versions.
sub _set_binary_glob_for_path {
    my ($self, $rel_path) = @_;
    return 0 unless defined $rel_path && length $rel_path;

    my $settings_dir  = $self->_fossil_settings_dir();
    my $glob_file     = File::Spec->catfile($settings_dir, 'binary-glob');

    # Read existing entries from the versioned settings file first.
    my $current = '';
    if (-f $glob_file) {
        open(my $fh, '<', $glob_file)
            or do { carp "Cannot read $glob_file: $!"; return 0 };
        $current = do { local $/; <$fh> };
        close $fh;
        $current =~ s/\r//g;
        $current =~ s/^\s+|\s+$//g;
    }

    my $merged = $self->_merge_glob_list($current, $rel_path);
    return 1 if $merged eq $current;   # nothing to change

    make_path($settings_dir, { mode => 0700 }) unless -d $settings_dir;

    open(my $fh, '>', $glob_file)
        or do { carp "Cannot write $glob_file: $!"; return 0 };
    print $fh "$merged\n";
    close($fh) or carp "close $glob_file: $!";

    if ($self->{verbose}) {
        warn "[Fossil] wrote binary-glob: $merged\n";
    }

    # Stage the settings file so it is committed alongside the data file.
    $self->_run('fossil', 'add', '--', '.fossil-settings/binary-glob');

    return 1;
}

# init -- Create the Fossil repository, open it as a working checkout,
# and configure CR/LF handling.
sub init {
    my ($self) = @_;
    make_path($self->{output_dir}, { mode => 0700 }) unless -d $self->{output_dir};
    my $repo = $self->_repo_path;
    my $r;
    if (!-f $repo) {
        $r = run_cmd(cmd => ['fossil', 'init', $repo]);
        croak "fossil init failed: $r->{stderr}" unless $r->{success};
    }
    $r = $self->_run('fossil', 'open', $repo);
    croak "fossil open failed: $r->{stderr}" unless $r->{success};

    # Configure Fossil to accept mixed line endings (CR/LF)
    # This prevents "Abandoning commit due to CR/LF line endings" errors.
    $self->_ensure_crlf_setting();
}

# is_initialized -- Return true if the checkout manifest file exists.
sub is_initialized {
    my ($self) = @_;
    return -f "$self->{output_dir}/.fslckout" || -f "$self->{output_dir}/_FOSSIL_";
}

# add -- Copy the real file to the mirror and register it with fossil add.
sub add {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);

    # 'fossil add' is idempotent: new files are ADDED, tracked files are SKIP.
    my $r = $self->_run('fossil', 'add', '--', $rel);
    croak "fossil add failed for '$real_path': $r->{stderr}" unless $r->{success};
}

# checkin -- Stage the file for the next batch commit (whole-repo model).
sub checkin {
    my ($self, $real_path, $msg) = @_;
    $self->add($real_path);
}

# remove -- Unregister file from Fossil and remove mirror file.
sub remove {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    my $r      = $self->_run('fossil', 'rm', '--', $rel);
    if (-e $mirror || -l $mirror) {
        unlink($mirror) or croak "unlink '$mirror' failed: $!";
    }
}

# commit -- Commit all pending changes with $msg.
# If the commit fails due to invalid UTF-8, retries after flagging the
# offending file as binary in .fossil-settings/binary-glob.
sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    # Existing repos may predate this default, so enforce each run.
    $self->_ensure_crlf_setting();

    # Skip if nothing pending.
    my $changes = $self->_run('fossil', 'changes', '--classify', '--hash');
    return unless $changes->{stdout} =~ /\S/;

    # --no-warnings suppresses interactive abandonment on encoding/CR-LF issues.
    my $r = $self->_run('fossil', 'commit', '--no-prompt', '--no-warnings', '-m', $msg);
    return if $r->{stdout} =~ /nothing\s+(has\s+)?changed/i
           || $r->{stderr} =~ /nothing\s+(has\s+)?changed/i;

    if (!$r->{success}) {
        my $err_text = join("\n", grep { defined && length } ($r->{stderr}, $r->{stdout}));
        my $bad_path = $self->_extract_invalid_utf8_path($err_text);
        if (defined $bad_path && length $bad_path) {
            warn "[changetrack-ng] Fossil: flagging '$bad_path' as binary in .fossil-settings/binary-glob\n";
            if ($self->_set_binary_glob_for_path($bad_path)) {
                # Commit again; the settings file is now staged too.
                my $retry = $self->_run('fossil', 'commit', '--no-prompt', '--no-warnings', '-m', $msg);
                return if $retry->{stdout} =~ /nothing\s+(has\s+)?changed/i
                       || $retry->{stderr} =~ /nothing\s+(has\s+)?changed/i;
                $r = $retry;
            } else {
                carp "fossil binary-glob update failed for '$bad_path'";
            }
        }
    }

    croak "fossil commit failed: $r->{stderr}" unless $r->{success};

    my $push_remote = $self->{options}{push_remote};
    return unless defined $push_remote;

    my @remotes = ref($push_remote) eq 'ARRAY' ? @$push_remote : ($push_remote);
    for my $remote (@remotes) {
        my $url = $remote =~ m{^[a-z]+://} ? $remote : "file://$remote";
        my $pr  = $self->_run('fossil', 'push', $url);
        carp 'fossil push ' . ChangeTrack::Util::redact_secrets($remote) . ' failed: ' . ChangeTrack::Util::redact_secrets($pr->{stderr}) unless $pr->{success};
    }
}

# diff -- Return unified diff lines for $real_path.
# Returns ['(new file)'] if the file is newly added; [] if unchanged.
sub diff {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);

    # Ensure the file is tracked and mtime-based false negatives are avoided.
    $self->add($real_path);
    my $changes = $self->_run('fossil', 'changes', '--classify', '--hash', '--', $rel);
    return ['(new file)'] if $changes->{stdout} =~ /^ADDED\b/m;
    return [] unless $changes->{stdout} =~ /\S/;

    my $r = $self->_run('fossil', 'diff', '--unified', '--', $rel);
    return [] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# is_dirty -- Return true if $real_path has uncommitted changes.
sub is_dirty {
    my ($self, $real_path) = @_;
    return scalar(@{ $self->diff($real_path) }) > 0;
}

# log_history -- Return fossil finfo -l lines for $real_path.
sub log_history {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    my $r = $self->_run('fossil', 'finfo', '-l', '--', $rel);
    return ['(no history yet)'] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# revert -- Restore $real_path to revision $rev and copy back to live file.
sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    my $r = $self->_run('fossil', 'revert', '-r', $rev, '--', $rel);
    croak "fossil revert failed: $r->{stderr}" unless $r->{success};
    restore_mirror_path($mirror, $real_path);
}

1;

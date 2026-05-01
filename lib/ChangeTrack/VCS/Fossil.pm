package ChangeTrack::VCS::Fossil;

=head1 NAME

ChangeTrack::VCS::Fossil - Fossil VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using Fossil.  Tracked
files are copied into a mirror tree under C<output_dir>, which is an open
Fossil working directory.

=cut

use strict;
use warnings;
use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak carp);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Cwd qw(getcwd);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

sub _repo_path {
    my ($self) = @_;
    return $self->{options}{fossil_repo} // "$self->{output_dir}.fossil";
}

# /etc/passwd  →  $output_dir/etc/passwd  (mirror tree)
sub output_path {
    my ($self, $real_path) = @_;
    (my $rel = $real_path) =~ s{^/}{};
    return "$self->{output_dir}/$rel";
}

sub _rel_path {
    my ($self, $mirror) = @_;
    (my $rel = $mirror) =~ s{^\Q$self->{output_dir}\E/?}{};
    return $rel;
}

# Run a fossil command from within the output_dir (the open checkout).
sub _run {
    my ($self, @cmd) = @_;
    my $old = getcwd();
    chdir($self->{output_dir}) or croak "chdir $self->{output_dir}: $!";
    my $r = run_cmd(cmd => \@cmd);
    chdir($old) or carp "chdir back to $old: $!";
    return $r;
}

sub _ensure_crlf_setting {
    my ($self) = @_;
    my $r = $self->_run('fossil', 'settings', 'crlf-glob', '*');
    carp "fossil settings crlf-glob failed: $r->{stderr}" unless $r->{success};
}

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

sub _set_binary_glob_for_path {
    my ($self, $rel_path) = @_;
    return 0 unless defined $rel_path && length $rel_path;

    my $current_r = $self->_run('fossil', 'settings', 'binary-glob');
    my $current = '';
    if ($current_r->{success}) {
        $current = $current_r->{stdout} // '';
        if ($current =~ /^binary-glob(?:\s*[:=])?\s*(.*)$/m) {
            $current = $1;
        }
    } else {
        # Some fossil versions return non-zero for unset values. Treat as empty.
        my $all_r = $self->_run('fossil', 'settings');
        if ($all_r->{success} && ($all_r->{stdout} // '') =~ /^binary-glob\s+(.+)$/m) {
            $current = $1;
        }
    }
    $current =~ s/\r//g;
    $current =~ s/^\s+|\s+$//g;

    my $merged = $self->_merge_glob_list($current, $rel_path);

    # Try common syntax variants for better fossil-version compatibility.
    my @cmds = (
        ['fossil', 'settings', 'binary-glob', $merged],
        ['fossil', 'settings', '--local', 'binary-glob', $merged],
        ['fossil', 'settings', 'binary-glob', $merged, '--local'],
    );
    for my $cmd (@cmds) {
        my $set_r = $self->_run(@$cmd);
        return 1 if $set_r->{success};
    }

    return 0;
}

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

sub is_initialized {
    my ($self) = @_;
    return -f "$self->{output_dir}/.fslckout" || -f "$self->{output_dir}/_FOSSIL_";
}

sub add {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);

    # 'fossil add' is idempotent: new files are ADDED, tracked files are SKIP.
    my $r = $self->_run('fossil', 'add', '--', $rel);
    croak "fossil add failed: $r->{stderr}" unless $r->{success};
}

sub checkin {
    my ($self, $real_path, $msg) = @_;
    $self->add($real_path);
}

sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    # Existing repos may predate this default, so enforce each run.
    $self->_ensure_crlf_setting();

    # Skip if nothing pending.
    my $changes = $self->_run('fossil', 'changes', '--classify', '--hash');
    return unless $changes->{stdout} =~ /\S/;

    my $r = $self->_run('fossil', 'commit', '--no-prompt', '-m', $msg);
    return if $r->{stdout} =~ /nothing\s+(has\s+)?changed/i
           || $r->{stderr} =~ /nothing\s+(has\s+)?changed/i;

    if (!$r->{success}) {
        my $err_text = join("\n", grep { defined && length } ($r->{stderr}, $r->{stdout}));
        my $bad_path = $self->_extract_invalid_utf8_path($err_text);
        if (defined $bad_path && length $bad_path) {
            if ($self->_set_binary_glob_for_path($bad_path)) {
                my $retry = $self->_run('fossil', 'commit', '--no-prompt', '-m', $msg);
                return if $retry->{stdout} =~ /nothing\s+(has\s+)?changed/i
                       || $retry->{stderr} =~ /nothing\s+(has\s+)?changed/i;
                $r = $retry;
            } else {
                carp "fossil settings binary-glob update failed for '$bad_path'";
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
        carp "fossil push $remote failed: $pr->{stderr}" unless $pr->{success};
    }
}

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

sub is_dirty {
    my ($self, $real_path) = @_;
    return scalar(@{ $self->diff($real_path) }) > 0;
}

sub log_history {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    my $r = $self->_run('fossil', 'finfo', '-l', '--', $rel);
    return ['(no history yet)'] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

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

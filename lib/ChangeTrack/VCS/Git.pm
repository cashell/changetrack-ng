package ChangeTrack::VCS::Git;

=head1 NAME

ChangeTrack::VCS::Git - Git VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using Git.  Tracked files
are copied into a mirror tree under C<output_dir> and committed as a batch.
Supports optional push to one or more remotes after each commit.

=cut

use strict;
use warnings;
use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak carp);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

# /etc/passwd  →  $output_dir/etc/passwd  (mirror tree)
sub output_path {
    my ($self, $real_path) = @_;
    (my $rel = $real_path) =~ s{^/}{};
    return "$self->{output_dir}/$rel";
}

# Relative path within the git repo (strip output_dir prefix).
sub _rel_path {
    my ($self, $mirror) = @_;
    (my $rel = $mirror) =~ s{^\Q$self->{output_dir}\E/}{};
    return $rel;
}

sub init {
    my ($self) = @_;
    make_path($self->{output_dir}, { mode => 0700 }) unless -d $self->{output_dir};
    my $r = run_cmd(cmd => ['git', 'init', $self->{output_dir}]);
    croak "git init failed: $r->{stderr}" unless $r->{success};
    my $name  = $self->{options}{git_user}  // 'changetrack-ng';
    my $email = $self->{options}{git_email} // 'changetrack-ng@localhost';
    run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'config', 'user.name',  $name]);
    run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'config', 'user.email', $email]);
}

sub is_initialized {
    my ($self) = @_;
    return -d "$self->{output_dir}/.git";
}

# Copy real file to mirror tree and stage it.
sub add {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);
    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'add', $mirror]);
    croak "git add failed: $r->{stderr}" unless $r->{success};
}

# For whole-repo VCS, checkin just stages (commits are deferred until commit()).
sub checkin {
    my ($self, $real_path, $msg) = @_;
    $self->add($real_path);
}

# Commit all staged changes.  No-op if nothing is staged.
# If push_remote is configured, push after commit (best-effort).
sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    my $staged = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'diff', '--cached', '--quiet']);
    return if $staged->{exit_code} == 0;

    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'commit', '-m', $msg]);
    croak "git commit failed: $r->{stderr}" unless $r->{success};

    my $push_remote = $self->{options}{push_remote};
    return unless defined $push_remote;

    my @remotes = ref($push_remote) eq 'ARRAY' ? @$push_remote : ($push_remote);
    my $branch_r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rev-parse', '--abbrev-ref', 'HEAD']);
    my $branch   = ($branch_r->{success} && $branch_r->{stdout} =~ /(\S+)/) ? $1 : 'main';

    for my $remote (@remotes) {
        my $pr = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'push', $remote, "HEAD:refs/heads/$branch"]);
        carp "git push $remote failed: $pr->{stderr}" unless $pr->{success};
    }
}

# Diff real file against HEAD (copies to mirror first).
# Returns ['(new file)'] if no HEAD exists or file not yet committed.
# Returns [] if unchanged.
sub diff {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);

    my $head = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rev-parse', '--verify', 'HEAD']);
    return ['(new file)'] unless $head->{success};

    my $rel     = $self->_rel_path($mirror);
    my $in_head = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'cat-file', '-e', "HEAD:$rel"]);
    return ['(new file)'] unless $in_head->{success};

    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'diff', '--no-color', 'HEAD', '--', $mirror]);
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
    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'log', '--no-color', '--', $mirror]);
    return ['(no history yet)'] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'checkout', $rev, '--', $rel]);
    croak "git checkout failed: $r->{stderr}" unless $r->{success};
    restore_mirror_path($mirror, $real_path);
}

1;

# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::VCS::Git - Whole-repo mirror model with batch commits and
#   optional push_remote.
#

package ChangeTrack::VCS::Git;

use strict;
use warnings;
=head1 NAME

ChangeTrack::VCS::Git - Git VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using Git.  Tracked files
are copied into a mirror tree under C<output_dir> and committed as a batch.
Supports optional push to one or more remotes after each commit.

=cut

use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak carp);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

# output_path -- Map a real absolute path to its mirror location.
# /etc/passwd -> $output_dir/etc/passwd  (mirror tree)
sub output_path {
    my ($self, $real_path) = @_;
    my $rel = $self->_mirror_rel($real_path);
    return "$self->{output_dir}/$rel";
}

# _rel_path -- Strip the output_dir prefix to get the repo-relative path.
# Used when passing paths to git commands that need relative names.
sub _rel_path {
    my ($self, $mirror) = @_;
    (my $rel = $mirror) =~ s{^\Q$self->{output_dir}\E/}{};
    return $rel;
}

# init -- Initialize a new git repository in output_dir and configure a
# minimal user identity so commits succeed without a global git config.
sub init {
    my ($self) = @_;
    make_path($self->{output_dir}, { mode => 0700 }) unless -d $self->{output_dir};
    my $r = run_cmd(cmd => ['git', 'init', $self->{output_dir}]);
    croak "git init failed: $r->{stderr}" unless $r->{success};
    my $name  = $self->{options}{git_user}  // 'changetrack-ng';
    my $email = $self->{options}{git_email} // 'changetrack-ng@localhost';
    my $cn = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'config', 'user.name',  $name]);
    carp "git config user.name failed: $cn->{stderr}"  unless $cn->{success};
    my $ce = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'config', 'user.email', $email]);
    carp "git config user.email failed: $ce->{stderr}" unless $ce->{success};
}

# is_initialized -- Return true if a .git directory exists in output_dir.
sub is_initialized {
    my ($self) = @_;
    return -d "$self->{output_dir}/.git";
}

# add -- Copy the real file to the mirror tree and stage it with git add.
sub add {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);
    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'add', $mirror]);
    croak "git add failed: $r->{stderr}" unless $r->{success};
}

# checkin -- Stage the file for the next batch commit (whole-repo model).
# Commits are deferred until commit() is called at end-of-run.
sub checkin {
    my ($self, $real_path, $msg) = @_;
    $self->add($real_path);
}

# remove -- Unlink mirror file and stage removal from Git.
sub remove {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    if (-e $mirror || -l $mirror) {
        unlink($mirror) or croak "unlink '$mirror' failed: $!";
    }
    my $in_head = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'cat-file', '-e', "HEAD:$rel"]);
    if ($in_head->{success}) {
        my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rm', '-f', '--', $rel]);
        croak "git rm failed for '$rel': $r->{stderr}" unless $r->{success};
    }
}

# commit -- Commit all staged changes with $msg.
# No-ops if nothing is staged.  After a successful commit, pushes to
# each configured push_remote (best-effort; failures only warn).
sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    my $staged = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'diff', '--cached', '--quiet']);
    # 'git diff --quiet' exits 0 (no staged changes) or 1 (staged changes);
    # anything else (or an exec failure) is a real error, not "has changes".
    croak "git diff --cached failed: $staged->{stderr}"
        unless $staged->{exit_code} == 0 || $staged->{exit_code} == 1;
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
        carp 'git push ' . ChangeTrack::Util::redact_secrets($remote) . ' failed: ' . ChangeTrack::Util::redact_secrets($pr->{stderr}) unless $pr->{success};
    }
}

# diff -- Return unified diff lines for $real_path vs HEAD.
# Returns ['(new file)'] if the file has no prior commit; [] if unchanged.
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
    croak "git diff failed: $r->{stderr}" unless $r->{success};
    return [] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# is_dirty -- Return true if $real_path has uncommitted changes.
sub is_dirty {
    my ($self, $real_path) = @_;
    return scalar(@{ $self->diff($real_path) }) > 0;
}

# log_history -- Return git log lines for the mirror path of $real_path.
sub log_history {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'log', '--no-color', '--', $mirror]);
    return ['(no history yet)'] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# revert -- Restore $real_path to revision $rev via git checkout,
# then copy the mirror content back to the live file.
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

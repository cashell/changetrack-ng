package ChangeTrack::VCS::SVN;

=head1 NAME

ChangeTrack::VCS::SVN - Subversion VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using Subversion (svn).
Tracked files are copied into a mirror tree under C<output_dir>, which is
an svn working copy.

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
    return $self->{options}{svn_repo} // "$self->{output_dir}-svnrepo";
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

# Run an SVN command from within the output_dir (the working copy root).
sub _run {
    my ($self, @cmd) = @_;
    my $old = getcwd();
    chdir($self->{output_dir}) or croak "chdir $self->{output_dir}: $!";
    my $r = run_cmd(cmd => \@cmd);
    chdir($old) or carp "chdir back to $old: $!";
    return $r;
}

sub init {
    my ($self) = @_;
    my $repo = $self->_repo_path;
    my $r = run_cmd(cmd => ['svnadmin', 'create', $repo]);
    croak "svnadmin create failed: $r->{stderr}" unless $r->{success};
    # 'file://' + absolute path gives the required three-slash file:/// URI.
    $r = run_cmd(cmd => ['svn', 'checkout', "file://$repo", $self->{output_dir}]);
    croak "svn checkout failed: $r->{stderr}" unless $r->{success};
}

sub is_initialized {
    my ($self) = @_;
    return -d "$self->{output_dir}/.svn";
}

sub add {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);

    # --force is idempotent for already-versioned paths and adds missing parents.
    my $r = $self->_run('svn', 'add', '--parents', '--force', $rel);
    croak "svn add failed: $r->{stderr}" unless $r->{success};
}

sub checkin {
    my ($self, $real_path, $msg) = @_;
    $self->add($real_path);
}

sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    # Skip if nothing pending.
    my $st = $self->_run('svn', 'status');
    return unless $st->{stdout} =~ /\S/;

    my $r = $self->_run('svn', 'commit', '-m', $msg);
    croak "svn commit failed: $r->{stderr}" unless $r->{success};
    # SVN commit is push — no separate push step needed.
}

# SVN has no native push_remote concept; the checkout URL is the repository.
# To use a remote SVN repo, point output_dir at a checkout of that URL.

sub diff {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);
    $self->add($real_path);

    my $st = $self->_run('svn', 'status', $rel);
    return ['(new file)'] if $st->{stdout} =~ /^\?/m || $st->{stdout} =~ /^A/m;

    my $r = $self->_run('svn', 'diff', $rel);
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
    return ['(no history yet)'] unless -e $mirror;
    my $r = $self->_run('svn', 'log', $rel);
    return ['(no history yet)'] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    # 'svn cat -rN path' outputs the file content at revision N.
    my $r = $self->_run('svn', 'cat', "-r$rev", $rel);
    croak "svn cat failed: $r->{stderr}" unless $r->{success};
    open(my $fh, '>', $mirror) or croak "open $mirror for write: $!";
    print $fh $r->{stdout};
    close($fh);
    restore_mirror_path($mirror, $real_path);
}

1;

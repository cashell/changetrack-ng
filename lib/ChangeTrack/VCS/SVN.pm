# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::VCS::SVN - Whole-repo with local file:// svnadmin
#   repository.
#

package ChangeTrack::VCS::SVN;

use strict;
use warnings;
=head1 NAME

ChangeTrack::VCS::SVN - Subversion VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using Subversion (svn).
Tracked files are copied into a mirror tree under C<output_dir>, which is
an svn working copy.

=cut

use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

# _repo_path -- Return the path to the svnadmin repository directory.
sub _repo_path {
    my ($self) = @_;
    return $self->{options}{svn_repo} // "$self->{output_dir}-svnrepo";
}

# _run -- Run an svn command with the given arguments.
sub _run {
    my ($self, @cmd) = @_;
    return run_cmd(cmd => \@cmd);
}

# init -- Create a local svnadmin repository and check it out into output_dir.
# Uses file:// URI for the local repo (three slashes: file:///abs/path).
sub init {
    my ($self) = @_;
    my $repo = $self->_repo_path;
    my $r = run_cmd(cmd => ['svnadmin', 'create', $repo]);
    croak "svnadmin create failed: $r->{stderr}" unless $r->{success};
    # 'file://' + absolute path gives the required three-slash file:/// URI.
    $r = run_cmd(cmd => ['svn', 'checkout', "file://$repo", $self->{output_dir}]);
    croak "svn checkout failed: $r->{stderr}" unless $r->{success};
}

# is_initialized -- Return true if a .svn directory exists in output_dir.
sub is_initialized {
    my ($self) = @_;
    return -d "$self->{output_dir}/.svn";
}

# add -- Copy the real file to the mirror and register it with svn add.
# --force is idempotent for already-versioned paths; --parents creates
# intermediate directories as needed.
sub add {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);
    my $r = $self->_run('svn', 'add', '--parents', '--force', $mirror);
    croak "svn add failed: $r->{stderr}" unless $r->{success};
}

# remove -- Unregister file from Subversion and remove mirror file.
sub remove {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $st     = $self->_run('svn', 'status', $mirror);
    if ($st->{stdout} =~ /^[ MA]/m) {
        my $r = $self->_run('svn', 'rm', '--force', $mirror);
        croak "svn rm failed for '$mirror': $r->{stderr}" unless $r->{success};
    } elsif (-e $mirror || -l $mirror) {
        unlink($mirror) or croak "unlink '$mirror' failed: $!";
    }
}

# commit -- Commit all pending changes with $msg.
# SVN commit is inherently a push (no separate push step needed).
sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    # Skip if nothing pending.
    my $st = $self->_run('svn', 'status', $self->{output_dir});
    return unless $st->{stdout} =~ /\S/;

    my $r = $self->_run('svn', 'commit', '-m', $msg, $self->{output_dir});
    croak "svn commit failed: $r->{stderr}" unless $r->{success};
    # SVN commit is push  --  no separate push step needed.
}

# SVN has no native push_remote concept; the checkout URL is the repository.
# To use a remote SVN repo, point output_dir at a checkout of that URL.

# diff -- Return unified diff lines for $real_path.
# Returns ['(new file)'] for unversioned or newly-added files; [] if unchanged.
sub diff {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);
    $self->add($real_path);

    my $st = $self->_run('svn', 'status', $mirror);
    return ['(new file)'] if $st->{stdout} =~ /^\?/m || $st->{stdout} =~ /^A/m;

    my $r = $self->_run('svn', 'diff', $mirror);
    croak "svn diff failed: $r->{stderr}" unless $r->{success};
    return [] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# log_history -- Return svn log lines for the mirror path of $real_path.
sub log_history {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    return ['(no history yet)'] unless -e $mirror;
    my $r = $self->_run('svn', 'log', $mirror);
    return ['(no history yet)'] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# revert -- Restore $real_path to revision $rev using svn cat,
# then copy the content back to the live file.
sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    my $mirror = $self->output_path($real_path);
    # 'svn cat -rN path' outputs the file content at revision N.
    my $r = $self->_run('svn', 'cat', "-r$rev", $mirror);
    croak "svn cat failed: $r->{stderr}" unless $r->{success};
    open(my $fh, '>', $mirror) or croak "open $mirror for write: $!";
    print $fh $r->{stdout};
    close($fh) or croak "close $mirror after write: $!";
    restore_mirror_path($mirror, $real_path);
}

1;

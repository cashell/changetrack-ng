# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
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
an svn working copy.  Passes C<--no-ignore> on file addition to preserve
mirror isolation from in-tree ignore configurations.  Reverting restores the
live file while keeping the Subversion mirror clean at HEAD.

=head1 METHODS

=over 4

=item diff($real_path, [$rev1, $rev2])

Return unified diff lines for I<$real_path>: pending diff against HEAD when
no revisions are given, I<$rev1> against the live file when only I<$rev1> is
given, or I<$rev1> against I<$rev2> in Subversion history when both are given.

=item log_history([$real_path])

Return C<svn log> output lines for I<$real_path> (supporting deleted paths via
peg revision lookup), or repository-wide C<svn log -v> when I<$real_path> is
C<undef> or empty.

=item show_at_revision($real_path, $rev)

Retrieve the content of I<$real_path> at revision I<$rev> via C<svn cat>
without mutating the live file or mirror working copy.

=back

=cut

use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

# _repo_path -- Return the path to the svnadmin repository directory.
sub _repo_path {
    my ($self) = @_;
    return $self->{options}{svn_repo} // "$self->{output_dir}-svnrepo";
}

# _repo_url -- Return the repository URL for svn remote operations.
sub _repo_url {
    my ($self) = @_;
    return $self->{repo_url} // ('file://' . $self->_repo_path);
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
    my $r = $self->_run('svn', 'add', '--parents', '--force', '--no-ignore', $mirror);
    croak "svn add failed: $r->{stderr}" unless $r->{success};
}

# remove -- Unregister file from Subversion and remove mirror file.
sub remove {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $st     = $self->_run('svn', 'status', '-v', $mirror);
    if ($st->{stdout} =~ /^[ MA!]/m) {
        my $r = $self->_run('svn', 'rm', '--force', $mirror);
        croak "svn rm failed for '$mirror': $r->{stderr}" unless $r->{success};
    } elsif (-e $mirror || -l $mirror) {
        unlink($mirror) or croak "unlink '$mirror' failed: $!";
    }
}

# _normalize_rev -- Strip leading 'r' before digits (e.g. 'r2' -> '2').
sub _normalize_rev {
    my $rev = @_ > 1 ? $_[1] : $_[0];
    return undef unless defined $rev;
    $rev =~ s/^r(?=\d+$)//i;
    return $rev;
}

# commit -- Commit all pending changes with $msg.
# SVN commit is inherently a push (no separate push step needed).
# Returns { committed => 0, revision => undef, warnings => [] } when no changes,
# or { committed => 1, revision => "r<N>", warnings => [] }.
sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    # Skip if nothing pending.
    my $st = $self->_run('svn', 'status', $self->{output_dir});
    return { committed => 0, revision => undef, warnings => [] } unless $st->{stdout} =~ /\S/;

    my $r = $self->_run('svn', 'commit', '-m', $msg, $self->{output_dir});
    croak "svn commit failed: $r->{stderr}" unless $r->{success};

    my $rev;
    if ($r->{stdout} =~ /Committed revision (\d+)\./i) {
        $rev = "r$1";
    }
    return { committed => 1, revision => $rev, warnings => [] };
}

# SVN has no native push_remote concept; the checkout URL is the repository.
# To use a remote SVN repo, point output_dir at a checkout of that URL.

# diff -- Return unified diff lines for $real_path.
# With no revisions: live file vs HEAD (returns ['(new file)'] if unversioned).
# With $rev1 only: $rev1 vs live file on disk.
# With $rev1 and $rev2: $rev1 vs $rev2 in Subversion history.
sub diff {
    my ($self, $real_path, $rev1, $rev2) = @_;
    $self->_validate_path($real_path, 'diff');
    croak 'diff: rev1 required when rev2 is specified'
        if defined $rev2 && !defined $rev1;

    if (defined $rev1) {
        $self->_validate_rev($rev1, 'diff');
        $rev1 = _normalize_rev($rev1);
        $self->_validate_rev($rev1, 'diff');
    }
    if (defined $rev2) {
        $self->_validate_rev($rev2, 'diff');
        $rev2 = _normalize_rev($rev2);
        $self->_validate_rev($rev2, 'diff');
    }

    my $mirror = $self->output_path($real_path);

    if (defined $rev1 && defined $rev2) {
        my $rel = $self->_rel_path($mirror);
        my $url = $self->_repo_url . '/' . $rel;
        my $r   = $self->_run('svn', 'diff', '-r', "$rev1:$rev2", "$url\@$rev2");
        $r      = $self->_run('svn', 'diff', '-r', "$rev1:$rev2", "$url\@$rev1") unless $r->{success};
        croak "svn diff failed: $r->{stderr}" unless $r->{success};
        return [] unless $r->{stdout} =~ /\S/;
        return [split /\n/, $r->{stdout}];
    }

    if (defined $rev1) {
        croak "diff: '$real_path' does not exist" unless -e $real_path || -l $real_path;
        return $self->_with_temp_mirror_sync($real_path, $mirror, sub {
            my $r = $self->_run('svn', 'diff', '-r', $rev1, $mirror);
            croak "svn diff failed: $r->{stderr}" unless $r->{success};
            return [] unless $r->{stdout} =~ /\S/;
            return [split /\n/, $r->{stdout}];
        });
    }

    return ['(new file)'] unless -e $mirror;

    my $st = $self->_run('svn', 'status', $mirror);
    return ['(new file)'] if $st->{stdout} =~ /^\?/m || $st->{stdout} =~ /^A/m;

    return $self->_with_temp_mirror_sync($real_path, $mirror, sub {
        my $r = $self->_run('svn', 'diff', $mirror);
        croak "svn diff failed: $r->{stderr}" unless $r->{success};
        return [] unless $r->{stdout} =~ /\S/;
        return [split /\n/, $r->{stdout}];
    });
}

# log_history -- Return svn log lines for $real_path, or repo-wide svn log -v
# when $real_path is undef or empty.
sub log_history {
    my ($self, $real_path) = @_;
    my $repo_url = $self->_repo_url;
    if (!defined $real_path || !length $real_path) {
        my $r = $self->_run('svn', 'log', '-v', $repo_url);
        return ['(no history yet)'] unless $r->{success} && $r->{stdout} =~ /\S/;
        return [split /\n/, $r->{stdout}];
    }

    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    my $url    = "$repo_url/$rel";
    my $r      = $self->_run('svn', 'log', "$url\@HEAD");
    $r         = $self->_run('svn', 'log', $mirror) unless $r->{success};

    # If the file was deleted, $url@HEAD and $mirror fail. Find the latest
    # revision where the file existed from repository history.
    if (!$r->{success}) {
        my $repo_log = $self->_run('svn', 'log', '-v', '-q', $repo_url);
        if ($repo_log->{success}) {
            my ($curr_rev, $peg_rev);
            for my $line (split /\n/, $repo_log->{stdout}) {
                if ($line =~ /^r(\d+)\s/) {
                    $curr_rev = $1;
                }
                elsif (defined $curr_rev && $line =~ /^\s+D\s+\/?\Q$rel\E(?:\s|$)/) {
                    $peg_rev = $curr_rev - 1 if $curr_rev > 1;
                    last if defined $peg_rev;
                }
                elsif (defined $curr_rev && $line =~ /^\s+[AMR]\s+\/?\Q$rel\E(?:\s|$)/) {
                    $peg_rev = $curr_rev;
                    last;
                }
            }
            if (defined $peg_rev) {
                $r = $self->_run('svn', 'log', "$url\@$peg_rev");
            }
        }
    }

    return ['(no history yet)'] unless $r->{success} && $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# show_at_revision -- Retrieve historical content of $real_path at $rev
# via svn cat without mutating the live file or working copy.
sub show_at_revision {
    my ($self, $real_path, $rev) = @_;
    $self->_validate_path($real_path, 'show_at_revision');
    $self->_validate_rev($rev, 'show_at_revision');
    $rev = _normalize_rev($rev);
    $self->_validate_rev($rev, 'show_at_revision');

    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    my $url    = $self->_repo_url . '/' . $rel;
    my $r      = $self->_run('svn', 'cat', '-r', $rev, "$url\@$rev");
    $r         = $self->_run('svn', 'cat', '-r', $rev, "$mirror\@$rev") unless $r->{success};
    croak "svn cat failed for '$real_path' at '$rev': $r->{stderr}"
        unless $r->{success};

    return $self->_format_show_result($r->{stdout});
}

# revert -- Restore $real_path to revision $rev using svn cat,
# restoring to the live path while leaving the Subversion mirror clean at HEAD.
sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    $rev = _normalize_rev($rev);
    croak "unsafe revision: $rev" if $rev =~ /^-/;

    my $mirror   = $self->output_path($real_path);
    my $rel      = $self->_rel_path($mirror);
    my $repo_url = $self->{repo_url} // ('file://' . $self->_repo_path);
    my $url      = "$repo_url/$rel";
    my $r        = $self->_run('svn', 'cat', '-r', $rev, "$url\@$rev");
    $r           = $self->_run('svn', 'cat', '-r', $rev, "$mirror\@$rev") unless $r->{success};
    croak "svn cat failed: $r->{stderr}" unless $r->{success};

    my ($tmp_fh, $tmp_file) = File::Temp::tempfile(CLEANUP => 1);
    binmode($tmp_fh);
    print {$tmp_fh} $r->{stdout};
    close($tmp_fh);

    restore_mirror_path($tmp_file, $real_path);
}

# metadata_at_revision -- Retrieve historical metadata record for $real_path
# at $rev from .changetrack-metadata in Subversion history.
sub metadata_at_revision {
    my ($self, $real_path, $rev) = @_;
    return undef unless defined $rev && length $rev;
    $rev = _normalize_rev($rev);
    return undef if $rev =~ /^-/;

    my $repo_url = $self->{repo_url} // ('file://' . $self->_repo_path);
    my $r = $self->_run('svn', 'cat', '-r', $rev, "$repo_url/.changetrack-metadata\@$rev");
    return undef unless $r->{success};
    return $self->_parse_metadata_jsonl($r->{stdout}, $real_path);
}

1;

# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::VCS::Base - Abstract base class for all VCS backends.
#

package ChangeTrack::VCS::Base;

use strict;
use warnings;
use Carp qw(croak);
use File::Copy qw(copy move);
use File::Temp qw(tempdir);
use ChangeTrack::Util qw(sync_mirror_path);
=head1 NAME

ChangeTrack::VCS::Base - abstract base class for changetrack-ng VCS backends

=head1 DESCRIPTION

Defines the interface implemented by all VCS backends.
Subclasses: L<ChangeTrack::VCS::RCS>, L<ChangeTrack::VCS::Git>,
L<ChangeTrack::VCS::Fossil>, L<ChangeTrack::VCS::SVN>,
L<ChangeTrack::VCS::Mercurial>.

=head1 INTERFACE

Subclasses must implement: C<init>, C<is_initialized>, C<add>, C<commit>,
C<diff>, C<remove>, C<log_history>, C<revert>, C<model>.

Subclasses may override the default implementations of: C<output_path>,
C<checkin>, C<is_dirty>.

=over 4

=item $vcs->init

Initialize the VCS repository in C<output_dir>.

=item $vcs->is_initialized

Return true if the repository already exists.

=item $vcs->add($src_path)

Stage I<$src_path> for the next commit.

=item $vcs->checkin($src_path, $message)

Prepare I<$src_path> for commit in backend-specific ways. Implementations are
responsible for any required staging (for example, calling C<add> internally
for whole-repo backends).

=item $vcs->commit($message)

Commit all staged changes with I<$message>.

=item $vcs->diff($path)

Return a unified diff string for I<$path>.

=item $vcs->remove($real_path)

Remove or unregister I<$real_path> from the VCS mirror/repository.

=item $vcs->output_path($real_path)

Return the mirror/archive path under C<output_dir> for I<$real_path>.

=item $vcs->log_history($path)

Return the revision history for I<$path>.

=item $vcs->revert($path, $rev)

Restore I<$path> to revision I<$rev>.

=item $vcs->is_dirty($path)

Return true if I<$path> has uncommitted changes in the mirror.

=item $vcs->model

Return the backend storage model: C<'whole-repo'> or C<'per-file'>.

=back

=cut


our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct a VCS backend object with output_dir, options, and
# verbosity flags.  Not called directly; use the subclass constructor.
sub new {
    my ($class, %args) = @_;
    return bless {
        output_dir => $args{output_dir} // '/var/lib/changetrack-ng',
        options    => $args{options}    // {},
        verbose    => $args{verbose}    // 0,
        debug      => $args{debug}     // 0,
        trace      => $args{trace}     // 0,
    }, $class;
}

# _unimpl -- Die with a 'not implemented' message for unoverridden abstract methods.
sub _unimpl { die ref(shift) . "::$_[0] not implemented\n" }

# _mirror_rel -- Return $real_path with its leading slash(es) removed, after
# asserting it contains no '..' segment.  Defense-in-depth shared by the
# whole-repo backends so a computed mirror path can never escape output_dir
# even if config-level validation is bypassed.
sub _mirror_rel {
    my ($self, $real_path) = @_;
    require Carp;
    Carp::croak("unsafe tracked path (contains '..'): $real_path")
        if grep { $_ eq '..' } split m{/+}, $real_path;
    (my $rel = $real_path) =~ s{^/+}{};
    return $rel;
}

# _with_temp_mirror_sync -- Temporarily sync $real_path to $mirror, run
# $code->(), and restore the original $mirror file and timestamps afterward.
sub _with_temp_mirror_sync {
    my ($self, $real_path, $mirror, $code) = @_;
    my $had_mirror = -e $mirror;
    my ($tmp_dir, $backup, @st);
    if ($had_mirror) {
        @st      = stat($mirror);
        $tmp_dir = tempdir(CLEANUP => 1);
        $backup  = "$tmp_dir/mirror.bak";
        copy($mirror, $backup) or croak "Failed to backup $mirror: $!";
    }

    sync_mirror_path($real_path, $mirror);
    my $res = eval { $code->() };
    my $err = $@;

    if ($had_mirror) {
        move($backup, $mirror) or croak "Failed to restore $mirror: $!";
        if (@st) {
            chmod($st[2] & 07777, $mirror);
            utime($st[8], $st[9], $mirror);
        }
    }
    else {
        unlink $mirror;
    }

    die $err if $err;
    return $res;
}

# output_path -- Map a real absolute path to its mirror location under output_dir.
# Default whole-repo implementation: /etc/passwd -> $output_dir/etc/passwd
sub output_path {
    my ($self, $real_path) = @_;
    my $rel = $self->_mirror_rel($real_path);
    return "$self->{output_dir}/$rel";
}

# _rel_path -- Strip output_dir prefix to get relative working tree path.
sub _rel_path {
    my ($self, $mirror) = @_;
    (my $rel = $mirror) =~ s{^\Q$self->{output_dir}\E/?}{};
    return $rel;
}

# checkin -- Stage file for next batch commit; default delegates to add().
sub checkin {
    my ($self, $real_path, $msg) = @_;
    $self->add($real_path);
}

# is_dirty -- Return true if $real_path has uncommitted changes in the mirror.
sub is_dirty {
    my ($self, $real_path) = @_;
    return scalar(@{ $self->diff($real_path) }) > 0;
}

sub init           { _unimpl(shift, 'init')           }
sub is_initialized { _unimpl(shift, 'is_initialized') }
sub add            { _unimpl(shift, 'add')            }
sub commit         { _unimpl(shift, 'commit')         }
sub diff           { _unimpl(shift, 'diff')           }
sub remove         { _unimpl(shift, 'remove')         }
sub log_history    { _unimpl(shift, 'log_history')    }
sub revert         { _unimpl(shift, 'revert')         }
sub model          { _unimpl(shift, 'model')          }

1;

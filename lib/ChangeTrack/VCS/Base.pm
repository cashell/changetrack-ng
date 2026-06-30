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
=head1 NAME

ChangeTrack::VCS::Base - abstract base class for changetrack-ng VCS backends

=head1 DESCRIPTION

Defines the interface implemented by all VCS backends.
Subclasses: L<ChangeTrack::VCS::RCS>, L<ChangeTrack::VCS::Git>,
L<ChangeTrack::VCS::Fossil>, L<ChangeTrack::VCS::SVN>,
L<ChangeTrack::VCS::Mercurial>.

=head1 INTERFACE

Subclasses must implement: C<init>, C<is_initialized>, C<output_path>,
C<add>, C<checkin>, C<commit>, C<diff>, C<log_history>, C<revert>,
C<is_dirty>, C<model>.

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

sub init           { _unimpl(shift, 'init')           }
sub is_initialized { _unimpl(shift, 'is_initialized') }
sub output_path    { _unimpl(shift, 'output_path')    }
sub checkin        { _unimpl(shift, 'checkin')        }
sub add            { _unimpl(shift, 'add')            }
sub commit         { _unimpl(shift, 'commit')         }
sub diff           { _unimpl(shift, 'diff')           }
sub log_history    { _unimpl(shift, 'log_history')    }
sub revert         { _unimpl(shift, 'revert')         }
sub is_dirty       { _unimpl(shift, 'is_dirty')       }
sub model          { _unimpl(shift, 'model')          }

1;

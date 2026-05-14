package ChangeTrack::VCS::Base;

=head1 NAME

ChangeTrack::VCS::Base - abstract base class for changetrack-ng VCS backends

=head1 DESCRIPTION

Defines the interface implemented by all VCS backends.
Subclasses: L<ChangeTrack::VCS::RCS>, L<ChangeTrack::VCS::Git>,
L<ChangeTrack::VCS::Fossil>, L<ChangeTrack::VCS::SVN>,
L<ChangeTrack::VCS::Mercurial>.

=head1 INTERFACE

Subclasses must implement: C<init>, C<is_initialized>, C<add>, C<commit>,
C<diff>, C<log>, C<revert>.

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

=item $vcs->log($path)

Return a log string for I<$path>.

=item $vcs->revert($path, $rev)

Restore I<$path> to revision I<$rev>.

=back

=cut

use strict;
use warnings;

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

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

sub _unimpl { die ref(shift) . "::$_[0] not implemented\n" }

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

# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Lock - flock-based run locking to prevent concurrent runs.
#

package ChangeTrack::Lock;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Lock - flock-based run lock for changetrack-ng

=head1 SYNOPSIS

  my $lock = ChangeTrack::Lock->new(path => '/var/run/changetrack-ng.lock', timeout => 0);
  $lock->acquire or exit 0;   # timeout=0: skip silently if locked
  # ... do work ...
  $lock->release;

=head1 DESCRIPTION

Creates and C<flock>s a lock file.  With C<timeout = 0> the acquire returns
false immediately if the lock is held (cron-friendly).  With a positive
C<timeout> it retries until the timeout expires and then C<croak>s.  The lock
file holds no PID; mutual exclusion comes from the advisory C<flock> alone.

=head1 INSTANCE METHODS

=over 4

=item ChangeTrack::Lock->new(path => $path, timeout => $seconds)

Construct a lock object.  Does not acquire the lock.

=item $lock->acquire

Try to acquire the lock.  Returns true on success.  With C<timeout = 0>
returns false immediately if the lock is held; with a positive C<timeout>
C<croak>s if the deadline passes; with C<force> blocks until acquired.

=item $lock->release

Release the lock and close the file.

=back

=cut

use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT);
use Carp qw(croak);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct a lock object. Does not acquire the lock.
# Args: path => $path (lock file path), timeout => $seconds,
#       force => $bool (acquire even if another instance holds it).
sub new {
    my ($class, %args) = @_;
    return bless {
        path    => $args{path}    // '/var/run/changetrack-ng.lock',
        timeout => $args{timeout} // 0,
        force   => $args{force}   // 0,
        _fh     => undef,
    }, $class;
}

# acquire -- Try to obtain an exclusive flock on the lock file.
# With timeout=0 (default): returns 0 immediately if lock is held (cron-safe).
# With force=1: warns and blocks until acquired regardless of contention.
# With timeout>0: retries until deadline, then croaks.
# Returns 1 on success, 0 if skipped.
sub acquire {
    my ($self) = @_;

    # Open with O_NOFOLLOW where available so a pre-planted symlink at the lock
    # path cannot redirect the open to an arbitrary file (relevant for non-root
    # runs whose lock dir may be less protected).  Mode 0600.
    my $flags = O_WRONLY | O_APPEND | O_CREAT;
    if (my $nofollow = eval { Fcntl::O_NOFOLLOW() }) {
        $flags |= $nofollow;
    }
    sysopen(my $fh, $self->{path}, $flags, 0600)
        or croak "Cannot open lock file $self->{path}: $!";

    if ($self->{force}) {
        # Try non-blocking first to detect contention, then force
        if (!flock($fh, LOCK_EX | LOCK_NB)) {
            warn "[changetrack-ng] lock: another instance holds $self->{path}, forcing acquisition\n";
            flock($fh, LOCK_EX)
                or croak "Cannot acquire lock $self->{path}: $!";
        }
        $self->{_fh} = $fh;
        return 1;
    }

    if ($self->{timeout} == 0) {
        if (!flock($fh, LOCK_EX | LOCK_NB)) {
            close($fh);
            return 0;
        }
        $self->{_fh} = $fh;
        return 1;
    }

    # Positive timeout: poll until deadline
    my $deadline = time() + $self->{timeout};
    while (1) {
        if (flock($fh, LOCK_EX | LOCK_NB)) {
            $self->{_fh} = $fh;
            return 1;
        }
        if (time() >= $deadline) {
            close($fh);
            croak "Timed out waiting for lock $self->{path} after $self->{timeout}s";
        }
        $self->_sleep(1);
    }
}

# release -- Release the flock and close the lock file.
sub release {
    my ($self) = @_;
    return unless defined $self->{_fh};
    flock($self->{_fh}, LOCK_UN);
    close($self->{_fh});
    $self->{_fh} = undef;
}

# DESTROY -- Auto-release the lock when the object goes out of scope.
sub DESTROY {
    my ($self) = @_;
    $self->release if defined $self->{_fh};
}

# _sleep -- Wrapper around sleep() for testability (tests redefine this).
sub _sleep { sleep($_[1]) }

1;

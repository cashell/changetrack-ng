package ChangeTrack::Lock;

=head1 NAME

ChangeTrack::Lock - flock-based run lock for changetrack-ng

=head1 SYNOPSIS

  my $lock = ChangeTrack::Lock->new(path => '/var/run/changetrack-ng.lock', timeout => 0);
  $lock->acquire or exit 0;   # timeout=0: skip silently if locked
  # ... do work ...
  $lock->release;

=head1 DESCRIPTION

Creates and C<flock>s a pidfile.  With C<timeout = 0> the acquire returns
false immediately if the lock is held (cron-friendly).  With a positive
C<timeout> it retries until the timeout expires, then warns and returns false.

=head1 INSTANCE METHODS

=over 4

=item ChangeTrack::Lock->new(path => $path, timeout => $seconds)

Construct a lock object.  Does not acquire the lock.

=item $lock->acquire

Try to acquire the lock.  Returns true on success.

=item $lock->release

Release the lock and close the file.

=back

=cut

use strict;
use warnings;
use Fcntl qw(:flock);
use Carp qw(croak);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub new {
    my ($class, %args) = @_;
    return bless {
        path    => $args{path}    // '/var/run/changetrack-ng.lock',
        timeout => $args{timeout} // 0,
        force   => $args{force}   // 0,
        _fh     => undef,
    }, $class;
}

sub acquire {
    my ($self) = @_;

    open(my $fh, '>>', $self->{path})
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

sub release {
    my ($self) = @_;
    return unless defined $self->{_fh};
    flock($self->{_fh}, LOCK_UN);
    close($self->{_fh});
    $self->{_fh} = undef;
}

sub DESTROY {
    my ($self) = @_;
    $self->release if defined $self->{_fh};
}

sub _sleep { sleep($_[1]) }

1;

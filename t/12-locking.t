# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 12-locking.t - Tests for locking.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use Fcntl qw(:flock);

if ($^O eq 'MSWin32') {
    plan skip_all => 'fork-based locking tests not supported on Windows';
}

use_ok('ChangeTrack::Lock');

my $tmpdir    = tempdir(CLEANUP => 1);
my $lock_path = File::Spec->catfile($tmpdir, 'test.lock');

# Suppress backoff sleep
no warnings 'redefine';
*ChangeTrack::Lock::_sleep = sub {};
use warnings 'redefine';

########################################################################
# Basic Acquire / Release
########################################################################
{
    my $lock = ChangeTrack::Lock->new(path => $lock_path, timeout => 0);
    my $got = $lock->acquire;
    ok($got, 'acquire returns 1 on first call');
    ok(-e $lock_path, 'lock file is created');
    $lock->release;
}

########################################################################
# Release Allows Re-Acquire
########################################################################
{
    my $lock = ChangeTrack::Lock->new(path => $lock_path, timeout => 0);
    $lock->acquire;
    $lock->release;
    my $lock2 = ChangeTrack::Lock->new(path => $lock_path, timeout => 0);
    ok($lock2->acquire, 're-acquire succeeds after release');
    $lock2->release;
}

########################################################################
# DESTROY Auto-Releases
########################################################################
{
    {
        my $lock = ChangeTrack::Lock->new(path => $lock_path, timeout => 0);
        $lock->acquire;
    }   # $lock goes out of scope -> DESTROY

    my $lock2 = ChangeTrack::Lock->new(path => $lock_path, timeout => 0);
    ok($lock2->acquire, 'acquire succeeds after DESTROY auto-releases');
    $lock2->release;
}

########################################################################
# Non-Blocking Returns 0 When Another Process Holds Lock
########################################################################
{
    pipe(my $pr, my $pw);

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        close($pr);
        open(my $fh, '>>', $lock_path) or exit 1;
        flock($fh, LOCK_EX) or exit 1;
        print $pw "ready\n";
        close($pw);
        sleep 5;
        exit 0;
    }

    close($pw);
    <$pr>;    # wait for child to hold lock
    close($pr);

    my $lock = ChangeTrack::Lock->new(path => $lock_path, timeout => 0);
    my $got  = $lock->acquire;
    ok(!$got, 'acquire returns 0 when another process holds lock (timeout=0)');

    kill 'TERM', $pid;
    waitpid($pid, 0);
}

########################################################################
# Timeout Exceeded -> Dies
########################################################################
{
    pipe(my $pr, my $pw);

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        close($pr);
        open(my $fh, '>>', $lock_path) or exit 1;
        flock($fh, LOCK_EX) or exit 1;
        print $pw "ready\n";
        close($pw);
        sleep 5;
        exit 0;
    }

    close($pw);
    <$pr>;
    close($pr);

    my $lock = ChangeTrack::Lock->new(path => $lock_path, timeout => 1);
    eval { $lock->acquire };
    ok($@, 'acquire dies when timeout is exceeded');
    like($@, qr/[Tt]imed out|timeout/i, 'error message mentions timeout');

    kill 'TERM', $pid;
    waitpid($pid, 0);
}

########################################################################
# Force=1 Acquires Even When Lock Is Held
########################################################################
{
    pipe(my $pr, my $pw);

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        close($pr);
        open(my $fh, '>>', $lock_path) or exit 1;
        flock($fh, LOCK_EX) or exit 1;
        print $pw "ready\n";
        close($pw);
        sleep 2;
        # Release lock so force can proceed
        flock($fh, LOCK_UN);
        sleep 2;
        exit 0;
    }

    close($pw);
    <$pr>;
    close($pr);

    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };

    my $lock = ChangeTrack::Lock->new(path => $lock_path, force => 1);
    my $got  = $lock->acquire;
    ok($got, 'force=1: acquire returns 1');
    $lock->release;

    waitpid($pid, 0);
}

done_testing();

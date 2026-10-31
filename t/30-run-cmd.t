# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 30-run-cmd.t - Tests for run_cmd drain-to-EOF, signal-aware exit code,
#   and the optional wall-clock timeout watchdog (CTNG-06, CTNG-23).
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use lib File::Spec->catdir($RealBin, '..', 'lib');

# run_cmd drains child stdout/stderr via IO::Select on pipe handles, which is
# unreliable on Windows (select() only works on sockets there).  These tests
# exercise the real subprocess path and run on Unix / CI.
plan skip_all => 'run_cmd IO::Select pipe drain requires Unix semantics'
    if $^O eq 'MSWin32';

use_ok('ChangeTrack::Util', qw(run_cmd));

my $perl = $^X;

# Clean exit, small output.
{
    my $r = run_cmd(cmd => [$perl, '-e', 'print "hello"']);
    ok($r->{success},                 'success on exit 0');
    is($r->{exit_code}, 0,            'exit_code 0');
    is($r->{stdout}, 'hello',         'stdout captured');
    ok(!$r->{timed_out},              'not timed out');
}

# Non-zero exit code is reported and success is false.
{
    my $r = run_cmd(cmd => [$perl, '-e', 'exit 3']);
    ok(!$r->{success},                'failure on non-zero exit');
    is($r->{exit_code}, 3,            'exit_code reflects child exit');
}

# Large output must be drained fully without truncation (no idle bail).
{
    my $n = 200_000;
    my $r = run_cmd(cmd => [$perl, '-e', "print 'x' x $n"]);
    ok($r->{success},                 'large-output command succeeds');
    is(length($r->{stdout}), $n,      'full large output captured (no truncation)');
}

# stderr is captured independently of stdout.
{
    my $r = run_cmd(cmd => [$perl, '-e', 'print STDERR "err"; print STDOUT "out"']);
    is($r->{stdout}, 'out',           'stdout captured');
    is($r->{stderr}, 'err',           'stderr captured');
}

# Optional timeout watchdog kills a hung child and flags timed_out.
{
    my $start = time();
    my $r = run_cmd(cmd => [$perl, '-e', 'sleep 30'], timeout => 1);
    my $elapsed = time() - $start;
    ok($r->{timed_out},               'timed_out flag set on watchdog expiry');
    ok(!$r->{success},                'timed-out command is not a success');
    cmp_ok($elapsed, '<', 15,         "watchdog terminated child promptly ($elapsed s)");
}

# Signal-aware exit code (Unix only; Windows has no real signals).
SKIP: {
    skip 'signal semantics require Unix', 1 if $^O eq 'MSWin32';
    my $r = run_cmd(cmd => [$perl, '-e', 'kill "TERM", $$; sleep 5']);
    cmp_ok($r->{exit_code}, '>=', 128, 'signal termination reported as 128+signal');
}

# The default wall-clock timeout (configurable) bounds a command that was
# given no explicit timeout, so a hung command cannot hang a scheduled run.
{
    ChangeTrack::Util::set_default_timeout(1);
    my $start = time();
    my $r = run_cmd(cmd => [$perl, '-e', 'sleep 30']);    # no explicit timeout
    my $elapsed = time() - $start;
    ok($r->{timed_out}, 'default timeout bounds a command with no explicit timeout');
    cmp_ok($elapsed, '<', 15, "default-timeout watchdog fired promptly ($elapsed s)");
    ChangeTrack::Util::set_default_timeout(120);
}

# An explicit timeout => 0 disables the cap (drains to completion).
{
    ChangeTrack::Util::set_default_timeout(1);
    my $r = run_cmd(cmd => [$perl, '-e', 'print "ok"'], timeout => 0);
    ok(!$r->{timed_out}, 'timeout => 0 disables the wall-clock cap');
    is($r->{stdout}, 'ok', 'output captured with cap disabled');
    ChangeTrack::Util::set_default_timeout(120);
}

# SIGPIPE protection: writing input to a process that exits without reading stdin.
{
    my $r = run_cmd(
        cmd   => [$perl, '-e', 'exit 0'],
        input => ('x' x 100_000),
    );
    ok($r->{success}, 'SIGPIPE ignored when child exits without reading stdin');
    is($r->{exit_code}, 0, 'exit code is 0');
}

# Hung stdin reader protection: large stdin write to a non-reading child is bounded by timeout.
SKIP: {
    skip 'alarm does not interrupt blocking I/O on Windows', 3 if $^O eq 'MSWin32';
    my $t0 = time();
    my $r  = run_cmd(
        cmd     => [$perl, '-e', 'sleep 30'],
        input   => ('x' x 1_000_000),
        timeout => 2,
    );
    ok($r->{timed_out}, 'stdin write to a non-reading child is bounded by timeout');
    cmp_ok(time() - $t0, '<', 10, 'returned promptly on hung stdin reader');
    ok(!$r->{success}, 'reported as failure');
}

done_testing();

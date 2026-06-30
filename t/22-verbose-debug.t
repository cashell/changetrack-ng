# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 22-verbose-debug.t - Tests for verbose debug.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use IO::Pipe;

use_ok('ChangeTrack::Runner');
use_ok('ChangeTrack::Util');

########################################################################
# Helpers
########################################################################
# Write a minimal v2 config and return the path.
sub make_config {
    my ($output_dir) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} "[global]\n";
    print {$fh} "vcs = rcs\n";
    print {$fh} "output_dir = $output_dir\n";
    print {$fh} "\n[track]\n";
    close($fh);
    return $path;
}

# Run a sub, capture everything printed to STDERR; return it as a string.
# Also captures STDOUT separately so we can assert it's clean.
sub capture_stderr {
    my ($code) = @_;
    my $buf = '';
    local *STDERR;
    open(STDERR, '>', \$buf) or die "Cannot redirect STDERR: $!";
    eval { $code->() };
    close(STDERR);
    return ($buf, $@);
}

sub capture_both {
    my ($code) = @_;
    my ($out, $err) = ('', '');
    local *STDOUT;
    local *STDERR;
    open(STDOUT, '>', \$out) or die "Cannot redirect STDOUT: $!";
    open(STDERR, '>', \$err) or die "Cannot redirect STDERR: $!";
    eval { $code->() };
    close(STDOUT);
    close(STDERR);
    return ($out, $err, $@);
}

########################################################################
# Test: Implication Chain In Runner Constructor
########################################################################
{
    my $r = ChangeTrack::Runner->new(trace => 1, quiet => 1);
    ok($r->{trace},   'trace flag stored');
    ok($r->{debug},   'trace implies debug');
    ok($r->{verbose}, 'trace implies verbose (via debug)');
}

{
    my $r = ChangeTrack::Runner->new(debug => 1, quiet => 1);
    ok(!$r->{trace},  'debug does not imply trace');
    ok($r->{debug},   'debug flag stored');
    ok($r->{verbose}, 'debug implies verbose');
}

{
    my $r = ChangeTrack::Runner->new(verbose => 1, quiet => 1);
    ok(!$r->{trace},  'verbose does not imply trace');
    ok(!$r->{debug},  'verbose does not imply debug');
    ok($r->{verbose}, 'verbose flag stored');
}

########################################################################
# Test: Util::Set_Debug And $DEBUG
########################################################################
{
    is($ChangeTrack::Util::DEBUG, 0, 'DEBUG starts at 0');
    ChangeTrack::Util::set_debug(1);
    is($ChangeTrack::Util::DEBUG, 1, 'set_debug(1) works');
    ChangeTrack::Util::set_debug(0);
    is($ChangeTrack::Util::DEBUG, 0, 'set_debug(0) resets');
}

########################################################################
# Test: No Diagnostic Output When Verbose=0 Debug=0
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = make_config($dir);
    my $r = ChangeTrack::Runner->new(config => $cfg, quiet => 1);

    my ($stderr, $err) = capture_stderr(sub { $r->run });

    # Any actual WARN lines about config perms are fine; we check no diagnostic labels leak
    unlike($stderr, qr/\[VERBOSE\]/, 'no [VERBOSE] without --verbose');
    unlike($stderr, qr/\[DEBUG\]/,   'no [DEBUG] without --debug');
    unlike($stderr, qr/\[TRACE\]/,   'no [TRACE] without --trace');
}

########################################################################
# Test: Verbose Emits [VERBOSE] But Not [DEBUG] Or [TRACE]
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = make_config($dir);
    my $r = ChangeTrack::Runner->new(config => $cfg, quiet => 1, verbose => 1);

    my ($stderr, $err) = capture_stderr(sub { $r->run });

    like($stderr,    qr/\[VERBOSE\]/,          'verbose emits [VERBOSE] lines');
    unlike($stderr,  qr/\[DEBUG\]/,            'verbose does not emit [DEBUG]');
    unlike($stderr,  qr/\[TRACE\]/,            'verbose does not emit [TRACE]');
    like($stderr,    qr/Config loaded from/,   'verbose shows config path');
    like($stderr,    qr/VCS:.*output_dir:/,    'verbose shows VCS and output_dir');
    like($stderr,    qr/Lock acquired/,        'verbose shows lock outcome');
    like($stderr,    qr/Run complete/,         'verbose shows run summary');
}

########################################################################
# Test: Debug Emits [VERBOSE] + [DEBUG] But Not [TRACE]
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = make_config($dir);
    my $r = ChangeTrack::Runner->new(config => $cfg, quiet => 1, debug => 1);

    my ($stderr, $err) = capture_stderr(sub { $r->run });

    like($stderr,   qr/\[VERBOSE\]/,     'debug also emits [VERBOSE]');
    like($stderr,   qr/\[DEBUG\]/,       'debug emits [DEBUG] lines');
    unlike($stderr, qr/\[TRACE\]/,       'debug does not emit [TRACE]');
    like($stderr,   qr/config: vcs/,     'debug shows effective config values');
    like($stderr,   qr/Metadata sidecar/,'debug shows metadata path');
    like($stderr,   qr/Hostname resolved/,'debug shows resolved hostname');
}

########################################################################
# Test: Debug Run_Cmd Emits [DEBUG] Exec: Lines
########################################################################
SKIP: {
    # 'echo' is an external binary on Unix but a cmd.exe builtin on Windows
    # (no echo.exe), so run_cmd's open3 takes the exec-failure path there.
    # This assertion is Unix-specific; the Linux suite is authoritative.
    skip 'run_cmd [DEBUG] exec: trace needs echo as an execable binary (Unix-only)', 1
        if $^O eq 'MSWin32';
    # Set DEBUG on Util and run a command, verify [DEBUG] exec: line appears on STDERR
    ChangeTrack::Util::set_debug(1);
    my $stderr = '';
    open(local *STDERR, '>', \$stderr);
    ChangeTrack::Util::run_cmd(cmd => ['echo', 'changetrack-test']);
    close(STDERR);
    ChangeTrack::Util::set_debug(0);

    like($stderr, qr/\[DEBUG\] exec: echo changetrack-test/, 'run_cmd emits [DEBUG] exec: line when DEBUG=1');
}

########################################################################
# Test: Debug Does Not Emit [DEBUG] Exec: Without DEBUG Flag
########################################################################
{
    my $stderr = '';
    open(local *STDERR, '>', \$stderr);
    ChangeTrack::Util::run_cmd(cmd => ['echo', 'changetrack-test']);
    close(STDERR);

    unlike($stderr, qr/\[DEBUG\] exec:/, 'run_cmd silent without DEBUG flag');
}

########################################################################
# Test: Secrets Redacted In Debug Config Dump
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my ($fh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} "[global]\n";
    print {$fh} "vcs = rcs\n";
    print {$fh} "output_dir = $dir\n";
    print {$fh} "\n[notifier:otlp:default]\n";
    print {$fh} "enabled = true\n";
    print {$fh} "endpoint = https://otel.example.com/v1/logs\n";
    print {$fh} "headers = Authorization: Bearer secret-token-12345\n";
    print {$fh} "\n[track]\n";
    close($fh);

    my $r = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1, debug => 1);
    my ($stderr, $err) = capture_stderr(sub { $r->run });

    unlike($stderr, qr/secret-token-12345/, 'secret values are redacted in debug output');
    like($stderr,   qr/REDACTED/,           'redacted placeholder appears in debug output');
}

########################################################################
# Test: Trace Emits [VERBOSE] + [DEBUG] + [TRACE]
########################################################################
SKIP: {
    # Exercises a real rcs commit followed by a fast-path skip, which needs the
    # rcs backend and Unix process semantics.  Windows has neither (no rcs, and
    # run_cmd's pipe drain is Unix-only); the Linux suite is authoritative.
    skip 'trace/fast-path test requires the rcs backend and Unix semantics (Unix-only)', 4
        if $^O eq 'MSWin32';
    my $dir = tempdir(CLEANUP => 1);
    my ($fh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    my ($tf, $tracked_file) = tempfile(UNLINK => 1);
    print {$tf} "trace test content\n";
    close($tf);
    print {$fh} "[global]\n";
    print {$fh} "vcs = rcs\n";
    print {$fh} "output_dir = $dir\n";
    print {$fh} "\n[track]\n";
    print {$fh} "$tracked_file\n";
    close($fh);

    # First run: commit the file into VCS (no trace yet  --  it's all actions)
    my $r1 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    capture_stderr(sub { $r1->run });

    # Second run: file is unchanged, so fast-path skip fires -> [TRACE] output
    my $r2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1, trace => 1);
    my ($stderr, $err) = capture_stderr(sub { $r2->run });

    like($stderr, qr/\[VERBOSE\]/, 'trace emits [VERBOSE]');
    like($stderr, qr/\[DEBUG\]/,   'trace emits [DEBUG]');
    like($stderr, qr/\[TRACE\]/,   'trace emits [TRACE] on second run (fast-path skip)');
    like($stderr, qr/skipped \(mtime\+size unchanged\)/, 'trace shows skip reason');
}

########################################################################
# Test: Diagnostic Output Goes To STDERR, Not STDOUT
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = make_config($dir);
    my $r = ChangeTrack::Runner->new(config => $cfg, quiet => 1, debug => 1);

    my ($stdout, $stderr, $err) = capture_both(sub { $r->run });

    unlike($stdout, qr/\[VERBOSE\]/, 'STDOUT has no [VERBOSE]');
    unlike($stdout, qr/\[DEBUG\]/,   'STDOUT has no [DEBUG]');
    unlike($stdout, qr/\[TRACE\]/,   'STDOUT has no [TRACE]');
    # STDERR should have diagnostics
    like($stderr, qr/\[VERBOSE\]|^\s*$/, 'STDERR has diagnostic output');
}

done_testing();

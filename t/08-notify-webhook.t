# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 08-notify-webhook.t - Tests for notify webhook.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use ChangeTrack::Version;
use IO::Socket::INET qw(SOCK_STREAM);
use JSON::PP ();

# fork() is required for the embedded HTTP server
unless (defined &POSIX::_SC_OPEN_MAX || $^O ne 'MSWin32') {
    # emulated fork on Windows may not support socket inheritance reliably
}
unless (eval { require POSIX; 1 }) {
    plan skip_all => 'POSIX not available';
}

use_ok('ChangeTrack::Notify::Webhook');
use_ok('ChangeTrack::Report');

# Suppress backoff sleep in all tests so retries are instant
no warnings 'redefine';
*ChangeTrack::Notify::Webhook::_sleep = sub {};
use warnings 'redefine';

my $tmpdir = tempdir(CLEANUP => 1);


# Helper: start a minimal HTTP server that accepts N requests (one per response
# code in @$codes), saves the last request body to $body_file if given, and exits.
# Returns ($port, $pid).

sub start_server {
    my (%opts) = @_;
    my $codes     = $opts{codes}     // [200];
    my $body_file = $opts{body_file} // '';

    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Type      => SOCK_STREAM,
        Listen    => 10,
        ReuseAddr => 1,
    ) or die "Cannot create test server: $!";

    my $port = $server->sockport;

    my $pid = fork();
    die "fork() failed: $!" unless defined $pid;

    if ($pid == 0) {
        for my $code (@$codes) {
            my $client = $server->accept;
            unless ($client) { exit 1 }

            # Read request headers
            my $content_length = 0;
            while (defined(my $line = <$client>)) {
                $line =~ s/\r?\n$//;
                last if $line eq '';
                $content_length = $1 if $line =~ /^Content-Length:\s*(\d+)/i;
            }

            # Read body
            my $body = '';
            read($client, $body, $content_length) if $content_length > 0;

            # Save body for last successful-code response only
            if ($body_file && $code < 400) {
                open(my $fh, '>', $body_file) or die "body_file write: $!";
                print $fh $body;
                close($fh);
            } elsif ($body_file && @$codes == 1) {
                # even on error response, save if single-response server
                open(my $fh, '>', $body_file) or die "body_file write: $!";
                print $fh $body;
                close($fh);
            }

            my %text = (200 => 'OK', 404 => 'Not Found', 500 => 'Internal Server Error',
                        503 => 'Service Unavailable');
            my $reason = $text{$code} // 'Unknown';
            print $client "HTTP/1.1 $code $reason\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            $client->close;
        }
        $server->close;
        exit 0;
    }

    $server->close;
    return ($port, $pid);
}

# helper: read JSON payload file written by the mock server
sub read_payload {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $data = <$fh>;
    return eval { JSON::PP->new->decode($data) };
}

# helper: make a standard report
sub make_report {
    my (%args) = @_;
    my $r = ChangeTrack::Report->new(start_time => 1000000000);
    if ($args{with_change}) {
        $r->add_change(
            path         => '/etc/passwd',
            is_new       => 0,
            is_sensitive => 0,
            diff         => ['+root:x:0:0:root:/root:/bin/bash', '-root:x:0:0:root:/root:/bin/sh'],
            meta_change  => '',
            recipients   => [],
        );
    }
    if ($args{sensitive}) {
        $r->add_change(
            path         => '/etc/shadow',
            is_new       => 0,
            is_sensitive => 1,
            diff         => ['-old_hash', '+new_hash'],
            meta_change  => '',
            recipients   => [],
        );
    }
    $r->set_end_time(1000000002);
    return $r;
}

########################################################################
# Name / Defaults
########################################################################
{
    my $n = ChangeTrack::Notify::Webhook->new(url => '');
    is($n->name, 'webhook', 'name() returns webhook');
    ok(!$n->heartbeat_enabled, 'heartbeat disabled by default');
}

########################################################################
# No POST On Clean Run With Heartbeat Off
########################################################################
{
    # No server started; if a POST were attempted, HTTP::Tiny would warn.
    my $n      = ChangeTrack::Notify::Webhook->new(url => '');
    my $report = make_report();
    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    $n->send($report);
    ok(!grep { /failed|error/i } @w, 'No POST warning on clean run with heartbeat off');
    pass('send() returns without dying on empty URL list');
}

########################################################################
# Single URL: Summary Payload On Changes
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'single.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    my $n = ChangeTrack::Notify::Webhook->new(
        url => "http://127.0.0.1:$port/",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(defined $p,                              'Single URL: payload is valid JSON');
    is($p->{tool},    'changetrack-ng',         'tool field');
    is($p->{version}, $ChangeTrack::Version::VERSION, 'version field');
    ok(defined $p->{hostname},                  'hostname field present');
    ok(defined $p->{timestamp},                 'timestamp field present');
    ok(!$p->{heartbeat},                        'heartbeat=false on change run');
    is(scalar @{ $p->{files} }, 1,             'one file entry');
    is($p->{files}[0]{path}, '/etc/passwd',     'file path correct');
    ok(!$p->{files}[0]{is_new},                 'is_new false');
    is($p->{files}[0]{diff_lines_added},   1,   'diff_lines_added');
    is($p->{files}[0]{diff_lines_removed}, 1,   'diff_lines_removed');
    ok(!exists $p->{files}[0]{diff},            'no diff field without full_diff');
    ok(defined $p->{files_tracked},             'files_tracked present');
}

########################################################################
# Diff Counters Ignore Unified Header Lines
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'header_count.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(
        path         => '/etc/hosts',
        is_new       => 0,
        is_sensitive => 0,
        diff         => [
            '--- a/etc/hosts',
            '+++ b/etc/hosts',
            '@@ -1 +1 @@',
            '-127.0.0.1 localhost',
            '+127.0.0.1 localhost.localdomain',
        ],
        meta_change  => '',
        recipients   => [],
    );
    $report->set_end_time(1000000002);

    my $n = ChangeTrack::Notify::Webhook->new(
        url => "http://127.0.0.1:$port/",
    );
    $n->send($report);
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(defined $p, 'Header counter: payload is valid JSON');
    is($p->{files}[0]{diff_lines_added}, 1, 'Header counter: +++ header is excluded');
    is($p->{files}[0]{diff_lines_removed}, 1, 'Header counter: --- header is excluded');
}

########################################################################
# Webhook_Full_Diff=1 Includes Diff Content
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'fulldiff.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    my $n = ChangeTrack::Notify::Webhook->new(
        url       => "http://127.0.0.1:$port/",
        full_diff => 1,
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(defined $p,                    'Full diff: valid JSON');
    ok(exists $p->{files}[0]{diff},   'diff field present with full_diff=1');
    like($p->{files}[0]{diff}, qr/\+root/, 'diff content included');
}

########################################################################
# Multiple Urls All Receive Payload
########################################################################
{
    my $body1 = File::Spec->catfile($tmpdir, 'multi1.json');
    my $body2 = File::Spec->catfile($tmpdir, 'multi2.json');
    my ($port1, $pid1) = start_server(codes => [200], body_file => $body1);
    my ($port2, $pid2) = start_server(codes => [200], body_file => $body2);

    my $n = ChangeTrack::Notify::Webhook->new(
        url => "http://127.0.0.1:$port1/ http://127.0.0.1:$port2/",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid1, 0);
    waitpid($pid2, 0);

    ok(-e $body1, 'First URL received payload');
    ok(-e $body2, 'Second URL received payload');
    my ($p1, $p2) = (read_payload($body1), read_payload($body2));
    is($p1->{tool}, 'changetrack-ng', 'First URL payload valid');
    is($p2->{tool}, 'changetrack-ng', 'Second URL payload valid');
}

########################################################################
# URL Arrayref Is Accepted And Split Correctly
########################################################################
{
    my $body1 = File::Spec->catfile($tmpdir, 'multi_array_1.json');
    my $body2 = File::Spec->catfile($tmpdir, 'multi_array_2.json');
    my ($port1, $pid1) = start_server(codes => [200], body_file => $body1);
    my ($port2, $pid2) = start_server(codes => [200], body_file => $body2);

    my $n = ChangeTrack::Notify::Webhook->new(
        url => [
            "http://127.0.0.1:$port1/",
            "http://127.0.0.1:$port2/",
        ],
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid1, 0);
    waitpid($pid2, 0);

    ok(-e $body1, 'Arrayref URL #1 received payload');
    ok(-e $body2, 'Arrayref URL #2 received payload');
}

########################################################################
# 500 Response: Retries Then Logs Warning
########################################################################
{
    # Server returns 500 three times (one per retry attempt)
    my ($port, $pid) = start_server(codes => [500, 500, 500]);

    my $n = ChangeTrack::Notify::Webhook->new(
        url => "http://127.0.0.1:$port/",
    );
    my @sleep_calls;
    my @w;
    local *ChangeTrack::Notify::Webhook::_sleep = sub { push @sleep_calls, $_[1] };
    local $SIG{__WARN__} = sub { push @w, @_ };
    eval { $n->send(make_report(with_change => 1)) };
    my $err = $@;
    waitpid($pid, 0);

    is_deeply(\@sleep_calls, [1, 2], '500 response: retries use expected exponential backoff delays');
    ok(scalar(grep { /500|failed|attempts/i } @w) || $err =~ /500|failed|attempts/i, 'Warning/error logged after 500 retries');
    ok($err, 'Exception raised on 500 response after retries exhausted');
}

########################################################################
# 404 Response: No Retry, Warning Logged
########################################################################
{
    my ($port, $pid) = start_server(codes => [404]);

    my $n = ChangeTrack::Notify::Webhook->new(
        url => "http://127.0.0.1:$port/",
    );
    my @sleep_calls;
    my @w;
    local *ChangeTrack::Notify::Webhook::_sleep = sub { push @sleep_calls, $_[1] };
    local $SIG{__WARN__} = sub { push @w, @_ };
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    is_deeply(\@sleep_calls, [], '404 response: no retry backoff sleep calls');
    ok(scalar(grep { /404|client error/i } @w), 'Warning logged on 404 (client error)');
    pass('Run did not die on 404 response');
}

########################################################################
# Unreachable Host: Error Propagated To Caller
########################################################################
{
    # Use a port that should not be listening
    my $n = ChangeTrack::Notify::Webhook->new(
        url => 'http://127.0.0.1:19753/',
    );
    my $report = make_report(with_change => 1);
    eval { $n->send($report) };
    ok($@, 'Exception raised on unreachable host');
}

########################################################################
# Heartbeat_Enabled With Webhook_Heartbeat=1
########################################################################
{
    my $n = ChangeTrack::Notify::Webhook->new(
        url       => '',
        heartbeat => 1,
    );
    ok($n->heartbeat_enabled, 'heartbeat_enabled true when heartbeat=1');
}

########################################################################
# Heartbeat=1: POST With Heartbeat=True On Clean Run
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'heartbeat.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    my $n = ChangeTrack::Notify::Webhook->new(
        url       => "http://127.0.0.1:$port/",
        heartbeat => 1,
    );
    my $r = ChangeTrack::Report->new(start_time => 1000000000);
    $r->set_end_time(1000000002);
    $n->send($r);
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(defined $p,                       'Heartbeat: valid JSON received');
    ok($p->{heartbeat},                  'Heartbeat: heartbeat=true');
    is(scalar @{ $p->{files} }, 0,       'Heartbeat: empty files array');
    like($p->{message}, qr/heartbeat/i,  'Heartbeat: message field set');
}

########################################################################
# Heartbeat=0 (Default): No POST On Clean Run
########################################################################
{
    my $n = ChangeTrack::Notify::Webhook->new(
        url       => 'http://127.0.0.1:19754/',
        heartbeat => 0,
    );
    ok(!$n->heartbeat_enabled, 'heartbeat_enabled false when heartbeat=0');
    # send() on a clean report with heartbeat off should not attempt a POST
    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    my $r = ChangeTrack::Report->new;
    $r->set_end_time(time());
    $n->send($r);
    ok(!grep { /failed|error/i } @w, 'No POST warning on clean run when heartbeat=0');
}

########################################################################
# Sensitive File: Diff Omitted Even With Webhook_Full_Diff=1
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'sensitive.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    my $n = ChangeTrack::Notify::Webhook->new(
        url       => "http://127.0.0.1:$port/",
        full_diff => 1,
        sensitive_notify  => 'suppress',
    );
    $n->send(make_report(sensitive => 1));
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(defined $p,                              'Sensitive: valid JSON');
    ok($p->{files}[0]{is_sensitive},            'Sensitive: is_sensitive=true');
    ok(!exists $p->{files}[0]{diff},            'Sensitive: diff field omitted');
}

########################################################################
# Sensitive_Notify=Allow: Diff Included
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'sens-allow.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    my $n = ChangeTrack::Notify::Webhook->new(
        url       => "http://127.0.0.1:$port/",
        full_diff => 1,
        sensitive_notify  => 'allow',
    );
    $n->send(make_report(sensitive => 1));
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(exists $p->{files}[0]{diff},  'sensitive_notify=allow: diff field present');
    like($p->{files}[0]{diff}, qr/old_hash/, 'sensitive_notify=allow: diff content included');
}

done_testing();

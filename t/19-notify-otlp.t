# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 19-notify-otlp.t - Tests for notify otlp.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use IO::Socket::INET qw(SOCK_STREAM);
use JSON::PP ();

plan skip_all => 'fork() not available on this platform'
    if $^O eq 'MSWin32';

unless (eval { require POSIX; 1 }) {
    plan skip_all => 'POSIX not available';
}

use_ok('ChangeTrack::Notify::OTLP');
use_ok('ChangeTrack::Report');

# Suppress backoff sleep in all tests so retries are instant
no warnings 'redefine';
*ChangeTrack::Notify::OTLP::_sleep = sub {};
use warnings 'redefine';

my $tmpdir = tempdir(CLEANUP => 1);


# Mock OTLP HTTP receiver.
# Accepts N requests (one per code in @$codes).  Saves the last body to
# $body_file; also saves request headers to $headers_file if given.
# Returns ($port, $pid).

sub start_server {
    my (%opts) = @_;
    my $codes        = $opts{codes}        // [200];
    my $body_file    = $opts{body_file}    // '';
    my $headers_file = $opts{headers_file} // '';

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

            my $content_length = 0;
            my %req_headers;
            while (defined(my $line = <$client>)) {
                $line =~ s/\r?\n$//;
                last if $line eq '';
                $content_length = $1 if $line =~ /^Content-Length:\s*(\d+)/i;
                if ($line =~ /^([^:]+):\s*(.*)$/) {
                    $req_headers{lc $1} = $2;
                }
            }

            my $body = '';
            read($client, $body, $content_length) if $content_length > 0;

            if ($body_file && ($code < 400 || @$codes == 1)) {
                open(my $fh, '>:raw', $body_file) or die $!;
                print $fh $body;
                close $fh;
            }

            if ($headers_file && ($code < 400 || @$codes == 1)) {
                open(my $fh, '>', $headers_file) or die $!;
                for my $k (sort keys %req_headers) {
                    print $fh "$k: $req_headers{$k}\n";
                }
                close $fh;
            }

            my %text = (200 => 'OK', 400 => 'Bad Request', 503 => 'Service Unavailable');
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

# Read and decode payload (handles gzip if present).
sub read_payload {
    my ($file) = @_;
    open(my $fh, '<:raw', $file) or return undef;
    local $/;
    my $data = <$fh>;
    close $fh;

    # Try gunzip
    my $json = $data;
    eval {
        require IO::Compress::Gunzip;
        my $out = '';
        IO::Compress::Gunzip::gunzip(\$data, \$out)
            or die $IO::Compress::Gunzip::GunzipError;
        $json = $out;
    };

    return eval { JSON::PP->new->decode($json) };
}

# Read saved request headers into a hash.
sub read_headers {
    my ($file) = @_;
    my %h;
    open(my $fh, '<', $file) or return %h;
    while (<$fh>) {
        chomp;
        $h{$1} = $2 if /^([^:]+):\s*(.*)$/;
    }
    return %h;
}

# Build a standard report with optional changes.
sub make_report {
    my (%args) = @_;
    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
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
    if ($args{with_warning}) {
        $r->add_warning('Skipping special file: /dev/sda');
    }
    $r->set_end_time(1_000_000_002);
    return $r;
}

########################################################################
# Name / Heartbeat_Enabled Defaults
########################################################################
{
    my $n = ChangeTrack::Notify::OTLP->new;
    is($n->name, 'otlp', 'name() returns otlp');
    ok($n->heartbeat_enabled, 'heartbeat_enabled is true by default');
}

{
    my $n = ChangeTrack::Notify::OTLP->new(heartbeat => 0);
    ok(!$n->heartbeat_enabled, 'heartbeat_enabled false when heartbeat=0');
}

########################################################################
# No POST When No Endpoint Configured
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(endpoint => '');
    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    $n->send(make_report(with_change => 1));
    diag "Unexpected warnings: " . join("; ", @w) if grep { /failed|error/i } @w;
    ok(!(grep { /failed|error/i } @w), 'No error when no endpoint configured');
    pass('send() returns without dying when endpoint is empty');
}

########################################################################
# OTLP Payload Structure
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'structure.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(defined $p,                                       'Payload: valid JSON');
    ok(exists $p->{resourceLogs},                        'Payload: resourceLogs key present');
    ok(ref $p->{resourceLogs} eq 'ARRAY',                'Payload: resourceLogs is array');
    my $rl = $p->{resourceLogs}[0];
    ok(defined $rl,                                      'Payload: resourceLogs[0] defined');
    ok(exists $rl->{resource}{attributes},               'Payload: resource.attributes present');
    ok(ref $rl->{resource}{attributes} eq 'ARRAY',       'Payload: resource.attributes is array');
    ok(exists $rl->{scopeLogs},                          'Payload: scopeLogs present');
    my $sl = $rl->{scopeLogs}[0];
    ok(defined $sl,                                      'Payload: scopeLogs[0] defined');
    is($sl->{scope}{name}, 'changetrack-ng',             'Payload: scope.name correct');
    ok(exists $sl->{logRecords},                         'Payload: logRecords present');
    is(scalar @{ $sl->{logRecords} }, 1,                 'Payload: one logRecord for one change');
}

########################################################################
# Resource Attributes
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'resource.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    my %ra = map { $_->{key} => $_->{value} }
             @{ $p->{resourceLogs}[0]{resource}{attributes} };

    ok(exists $ra{'service.name'},    'resource: service.name present');
    ok(exists $ra{'service.version'}, 'resource: service.version present');
    ok(exists $ra{'host.name'},       'resource: host.name present');
    ok(exists $ra{'os.type'},         'resource: os.type present');
    is($ra{'service.name'}{stringValue}, 'changetrack-ng', 'resource: service.name = changetrack-ng');
    like($ra{'service.version'}{stringValue}, qr/\d/, 'resource: service.version is non-empty');
}

########################################################################
# Typed Attribute Values And Timeunixnano As String
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'typed.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];

    # timeUnixNano must be a JSON string, not a number
    my $raw = JSON::PP->new->encode($p);
    like($raw, qr/"timeUnixNano"\s*:\s*"/, 'timeUnixNano encoded as JSON string');

    my %a = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    ok(exists $a{'file.path'}{stringValue},          'file.path uses stringValue');
    ok(exists $a{'config_change.type'}{stringValue}, 'config_change.type uses stringValue');
    is($a{'config_change.type'}{stringValue}, 'modified', 'config_change.type=modified for an edit');
    ok(exists $a{'config_change.sensitive'}{boolValue}, 'config_change.sensitive uses boolValue');
    ok(exists $a{'changetrack.files_tracked'}{intValue}, 'changetrack.files_tracked uses intValue');
    is(ref($a{'changetrack.files_tracked'}{intValue}), '', 'files_tracked intValue is a scalar (string)');
    ok(exists $a{'event.name'}{stringValue},         'event.name present on change record');
    is($a{'event.name'}{stringValue}, 'changetrack.file.changed', 'event.name=changetrack.file.changed');
}

########################################################################
# Event.Name Discriminates Change Vs Heartbeat Records
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'evname.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    is($a{'event.name'}{stringValue}, 'changetrack.file.changed',
        'change record event.name is changetrack.file.changed (not heartbeat)');
    ok(!exists $a{'ct.heartbeat'}, 'ct.heartbeat attribute removed');
}

########################################################################
# Changetrack.Files_Tracked And Changetrack.Run_Duration_Ms Present
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'fields.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    ok(exists $a{'changetrack.files_tracked'},    'changetrack.files_tracked present');
    ok(exists $a{'changetrack.run_duration_ms'},  'changetrack.run_duration_ms present');
}

########################################################################
# Heartbeat Record: Ct.Heartbeat=True
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'hb_record.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint  => "http://127.0.0.1:$port/v1/logs",
        heartbeat => 1,
    );
    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->set_end_time(1_000_000_002);
    $n->send($r);
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    ok(defined $rec,                     'Heartbeat: log record present');
    is($rec->{severityNumber}, 5,        'Heartbeat: severityNumber = DEBUG(5)');
    is($a{'event.name'}{stringValue}, 'changetrack.run.heartbeat',
        'Heartbeat: event.name is changetrack.run.heartbeat');
    like($rec->{body}{stringValue}, qr/heartbeat/i, 'Heartbeat: body message mentions heartbeat');
}

########################################################################
# Heartbeat=0: No POST On Clean Run
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint  => 'http://127.0.0.1:19754/v1/logs',
        heartbeat => 0,
    );
    ok(!$n->heartbeat_enabled, 'heartbeat disabled when heartbeat=0');
    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    my $r = ChangeTrack::Report->new;
    $r->set_end_time(time());
    $n->send($r);
    ok(!grep { /failed|error/i } @w, 'No POST on clean run when heartbeat=0');
}

########################################################################
# Endpoint Normalization Warning
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'epnorm.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port",
    );
    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    ok(scalar(grep { m{/v1/logs} } @w),
        'Endpoint normalization: warning emitted when /v1/logs was appended');
    my $p = read_payload($body_file);
    ok(defined $p, 'Endpoint normalization: POST succeeded after normalization');
}

{
    # Second send on same object: warning fires only once
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => 'http://127.0.0.1:19755',
    );
    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    $n->_resolve_endpoint;
    $n->_resolve_endpoint;
    my $warn_count = scalar grep { m{/v1/logs} } @w;
    is($warn_count, 1, 'Endpoint normalization warning fires only once per object');
}

########################################################################
# Env Var: OTEL_EXPORTER_OTLP_LOGS_ENDPOINT Takes Precedence
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'envlogs.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT}      = 'http://127.0.0.1:19756/v1/logs';
    local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT} = "http://127.0.0.1:$port/v1/logs";
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => 'http://127.0.0.1:19757/v1/logs',
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(defined $p, 'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT used when set (highest precedence)');
}

########################################################################
# Env Var: OTEL_EXPORTER_OTLP_ENDPOINT Overrides Config
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'envep.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT}      = "http://127.0.0.1:$port/v1/logs";
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => 'http://127.0.0.1:19758/v1/logs',
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p = read_payload($body_file);
    ok(defined $p, 'OTEL_EXPORTER_OTLP_ENDPOINT overrides endpoint config');
}

########################################################################
# Env Var: OTEL_EXPORTER_OTLP_HEADERS Merged Into Request Headers
########################################################################
{
    my $headers_file = File::Spec->catfile($tmpdir, 'envhdrs.txt');
    my $body_file    = File::Spec->catfile($tmpdir, 'envhdrs.json');
    my ($port, $pid) = start_server(
        codes        => [200],
        body_file    => $body_file,
        headers_file => $headers_file,
    );

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    local $ENV{OTEL_EXPORTER_OTLP_HEADERS}        = 'x-custom-token=secret123,x-tenant=myorg';
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my %hdrs = read_headers($headers_file);
    is($hdrs{'x-custom-token'}, 'secret123', 'OTEL_EXPORTER_OTLP_HEADERS: x-custom-token forwarded');
    is($hdrs{'x-tenant'},       'myorg',     'OTEL_EXPORTER_OTLP_HEADERS: x-tenant forwarded');
}

########################################################################
# Env Var Headers Take Precedence Over Config Headers
########################################################################
{
    my $headers_file = File::Spec->catfile($tmpdir, 'hdrpref.txt');
    my ($port, $pid) = start_server(
        codes        => [200],
        headers_file => $headers_file,
    );

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    local $ENV{OTEL_EXPORTER_OTLP_HEADERS}        = 'x-auth=env-value';
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
        headers  => 'x-auth=config-value',
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my %hdrs = read_headers($headers_file);
    is($hdrs{'x-auth'}, 'env-value', 'Env-var header takes precedence over config header');
}

########################################################################
# Config Header Parsing Accepts Arrayref And Hashref Values
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_HEADERS};
    my $n = ChangeTrack::Notify::OTLP->new(
        headers => ['x-token=Bearer\\ token', 'x-tenant=myorg'],
    );
    my %hdrs = $n->_resolve_headers;

    is($hdrs{'x-token'}, 'Bearer token', 'Arrayref headers parsed with escaped spaces');
    is($hdrs{'x-tenant'}, 'myorg',       'Arrayref headers key/value parsed');
}

{
    delete local $ENV{OTEL_EXPORTER_OTLP_HEADERS};
    my $n = ChangeTrack::Notify::OTLP->new(
        headers => { 'x-api-key' => 'abc123' },
    );
    my %hdrs = $n->_resolve_headers;

    is($hdrs{'x-api-key'}, 'abc123', 'Hashref headers parsed correctly');
}

########################################################################
# Resource Attributes Accept Arrayref And Hashref Values
########################################################################
{
    my $n = ChangeTrack::Notify::OTLP->new(
        resource_attributes => ['deployment.environment=prod', 'service.name=custom-svc'],
    );
    my %attrs = map { $_->{key} => $_->{value}{stringValue} } @{ $n->_resource_attrs };

    is($attrs{'deployment.environment'}, 'prod',       'Arrayref resource attr parsed');
    is($attrs{'service.name'},           'custom-svc', 'Arrayref resource attrs can override defaults');
}

{
    my $n = ChangeTrack::Notify::OTLP->new(
        resource_attributes => { 'team.name' => 'platform' },
    );
    my %attrs = map { $_->{key} => $_->{value}{stringValue} } @{ $n->_resource_attrs };

    is($attrs{'team.name'}, 'platform', 'Hashref resource attr parsed correctly');
}

########################################################################
# Gzip Compression
########################################################################
SKIP: {
    eval { require IO::Compress::Gzip; require IO::Compress::Gunzip; 1 }
        or skip 'IO::Compress::Gzip not available', 3;

    my $body_file    = File::Spec->catfile($tmpdir, 'gzip.bin');
    my $headers_file = File::Spec->catfile($tmpdir, 'gzip_hdrs.txt');
    my ($port, $pid) = start_server(
        codes        => [200],
        body_file    => $body_file,
        headers_file => $headers_file,
    );

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint    => "http://127.0.0.1:$port/v1/logs",
        compression => 'gzip',
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my %hdrs = read_headers($headers_file);
    is(lc($hdrs{'content-encoding'} // ''), 'gzip',
        'Gzip: Content-Encoding: gzip header sent');

    # Verify body starts with gzip magic bytes
    open(my $fh, '<:raw', $body_file) or die $!;
    read($fh, my $magic, 2);
    close $fh;
    is($magic, "\x1f\x8b", 'Gzip: body starts with gzip magic bytes');

    # Verify decompressed body is valid JSON with expected structure
    my $p = read_payload($body_file);
    ok(exists $p->{resourceLogs}, 'Gzip: decompressed body is valid OTLP JSON');
}

########################################################################
# 503 Response: Retries And Succeeds On Third Attempt
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'retry.json');
    my ($port, $pid) = start_server(
        codes     => [503, 503, 200],
        body_file => $body_file,
    );

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    my @sleep_calls;
    local *ChangeTrack::Notify::OTLP::_sleep = sub { push @sleep_calls, $_[1] };
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    is_deeply(\@sleep_calls, [1, 2], '503 retry: uses expected exponential backoff delays before eventual success');
    my $p = read_payload($body_file);
    ok(defined $p, '503 retry: payload received on successful third attempt');
    ok(exists $p->{resourceLogs}, '503 retry: OTLP structure intact');
}

########################################################################
# 503 x 3: Warn After Exhausting Retries
########################################################################
{
    my ($port, $pid) = start_server(codes => [503, 503, 503]);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    my @sleep_calls;
    my @w;
    local *ChangeTrack::Notify::OTLP::_sleep = sub { push @sleep_calls, $_[1] };
    local $SIG{__WARN__} = sub { push @w, @_ };
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    is_deeply(\@sleep_calls, [1, 2], '503 x3: retries exhausted after expected backoff delays');
    ok(scalar(grep { /failed|503|attempts/i } @w), 'Warning logged after 503 exhausts retries');
    pass('Does not die after exhausting 503 retries');
}

########################################################################
# 400 Response: No Retry, Warning Logged
########################################################################
{
    my ($port, $pid) = start_server(codes => [400]);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    my @sleep_calls;
    my @w;
    local *ChangeTrack::Notify::OTLP::_sleep = sub { push @sleep_calls, $_[1] };
    local $SIG{__WARN__} = sub { push @w, @_ };
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    is_deeply(\@sleep_calls, [], '400 response: no retry backoff sleep calls');
    ok(scalar(grep { /400|client error/i } @w), '400 response: warning logged, not retried');
    pass('Does not die on 400 response');
}

########################################################################
# Sensitive File: Ct.Diff Omitted With Otlp_Full_Diff=1 + Suppress
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'sens_suppress.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint    => "http://127.0.0.1:$port/v1/logs",
        full_diff   => 1,
        sensitive_notify => 'suppress',
    );
    $n->send(make_report(sensitive => 1));
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    ok($a{'config_change.sensitive'}{boolValue}, 'Sensitive suppress: config_change.sensitive=true');
    ok(!exists $a{'config_change.diff'},         'Sensitive suppress: config_change.diff omitted');
}

########################################################################
# Sensitive_Notify=Allow: Ct.Diff Included
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'sens_allow.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint    => "http://127.0.0.1:$port/v1/logs",
        full_diff   => 1,
        sensitive_notify => 'allow',
    );
    $n->send(make_report(sensitive => 1));
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    ok(exists $a{'config_change.diff'},              'sensitive_notify=allow: config_change.diff present');
    like($a{'config_change.diff'}{stringValue}, qr/old_hash/, 'sensitive_notify=allow: diff content included');
}

########################################################################
# Otlp_Full_Diff=1: Ct.Diff Present For Non-Sensitive Files
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'full_diff.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint  => "http://127.0.0.1:$port/v1/logs",
        full_diff => 1,
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    ok(exists $a{'config_change.diff'},              'Full diff: config_change.diff present');
    like($a{'config_change.diff'}{stringValue}, qr/\+root/, 'Full diff: diff content included');
}

########################################################################
# No Ct.Diff Without Otlp_Full_Diff
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'no_diff.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint  => "http://127.0.0.1:$port/v1/logs",
        full_diff => 0,
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    ok(!exists $a{'config_change.diff'}, 'No config_change.diff attr without full_diff');
}

########################################################################
# Warning Records Emitted As WARN Severity
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'warn_rec.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    $n->send(make_report(with_change => 1, with_warning => 1));
    waitpid($pid, 0);

    my $p       = read_payload($body_file);
    my @records = @{ $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords} };

    my @warn_recs = grep { ($_->{severityNumber} // 0) == 13 } @records;
    is(scalar @warn_recs, 1, 'Warning record emitted with severityNumber=WARN(13)');
    is($warn_recs[0]{severityText}, 'WARN', 'Warning record severityText is WARN');
    like($warn_recs[0]{body}{stringValue}, qr/special file/i, 'Warning record body contains warning text');
}

########################################################################
# File.* Attributes And Config_Change.Type Enum
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'filemeta.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );

    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->add_change(
        path   => '/etc/hosts',
        is_new => 1,
        diff   => ['(new file)'],
        stat   => { mode => '0644', user => 'root', group => 'root',
                    size => 42, mtime => 1_700_000_000, type => 'file' },
    );
    $r->set_end_time(1_000_000_002);
    $n->send($r);
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    is($a{'config_change.type'}{stringValue}, 'created', 'new file => config_change.type=created');
    is($a{'event.name'}{stringValue}, 'changetrack.file.created', 'new file event.name');
    is($a{'file.name'}{stringValue}, 'hosts',     'file.name is basename');
    is($a{'file.directory'}{stringValue}, '/etc', 'file.directory is dirname');
    is($a{'file.mode'}{stringValue}, '0644',      'file.mode propagated');
    is($a{'file.owner.name'}{stringValue}, 'root','file.owner.name propagated');
    is($a{'file.group.name'}{stringValue}, 'root','file.group.name propagated');
    is($a{'file.size'}{intValue}, '42',           'file.size propagated as string intValue');
}

########################################################################
# Config_Change.Notified Is Opt-In (Emit_Recipients)
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};

    my $make = sub {
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/hosts', diff => [],
            recipients => ['ops@example.com', 'sa@example.com']);
        $r->set_end_time(1_000_000_002);
        return $r;
    };

    # default: recipients NOT emitted
    {
        my $bf = File::Spec->catfile($tmpdir, 'norecip.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        ChangeTrack::Notify::OTLP->new(endpoint => "http://127.0.0.1:$port/v1/logs")
            ->send($make->());
        waitpid($pid, 0);
        my $p = read_payload($bf);
        my %a = map { $_->{key} => $_->{value} }
                @{ $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0]{attributes} };
        ok(!exists $a{'config_change.notified'}, 'recipients omitted by default');
    }

    # emit_recipients=1: recipients emitted as arrayValue
    {
        my $bf = File::Spec->catfile($tmpdir, 'recip.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs", emit_recipients => 1)
            ->send($make->());
        waitpid($pid, 0);
        my $p = read_payload($bf);
        my %a = map { $_->{key} => $_->{value} }
                @{ $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0]{attributes} };
        ok(exists $a{'config_change.notified'}, 'recipients emitted when emit_recipients=1');
        my @vals = map { $_->{stringValue} } @{ $a{'config_change.notified'}{arrayValue}{values} };
        is_deeply(\@vals, ['ops@example.com', 'sa@example.com'], 'recipient list correct');
    }
}

########################################################################
# Occurred (mtime) vs Observed (scan) Timestamps
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'ts_split.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(endpoint => "http://127.0.0.1:$port/v1/logs");

    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);   # observed
    $r->add_change(
        path => '/etc/hosts', diff => ['+x'],
        stat => { mtime => 1_700_000_000, mode => '0644', type => 'file' },  # occurred
    );
    $r->set_end_time(1_000_000_002);
    $n->send($r);
    waitpid($pid, 0);

    my $rec = read_payload($body_file)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    is($rec->{timeUnixNano},         '1700000000000000000', 'timeUnixNano = mtime ns (occurred)');
    is($rec->{observedTimeUnixNano}, '1000000000000000000', 'observedTimeUnixNano = scan ns (observed)');
    isnt($rec->{timeUnixNano}, $rec->{observedTimeUnixNano}, 'occurred and observed differ');
}

########################################################################
# Records Without mtime Fall Back To Scan Time
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'ts_fallback.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs", heartbeat => 1);

    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->set_end_time(1_000_000_002);
    $n->send($r);   # heartbeat: no file
    waitpid($pid, 0);

    my $rec = read_payload($body_file)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    is($rec->{timeUnixNano}, $rec->{observedTimeUnixNano},
        'heartbeat occurred == observed (scan time)');
}

########################################################################
# _truncate_diff Helper
########################################################################
{
    my $n = ChangeTrack::Notify::OTLP->new(max_diff_bytes => 0);
    my ($t, $tr) = $n->_truncate_diff('a' x 100);
    is(length($t), 100, 'unlimited (0): text unchanged');
    ok(!$tr,                'unlimited (0): not flagged truncated');

    my $n2 = ChangeTrack::Notify::OTLP->new(max_diff_bytes => 10);
    my ($t2, $tr2) = $n2->_truncate_diff('a' x 100);
    ok($tr2,                          'cap 10: flagged truncated');
    like($t2, qr/^a{10}\n\[diff truncated/, 'cap 10: keeps first 10 chars + marker');

    my ($t3, $tr3) = $n2->_truncate_diff('short');
    is($t3, 'short', 'under cap: unchanged');
    ok(!$tr3,        'under cap: not flagged');
}

########################################################################
# OTLP Diff Truncation
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};

    my $big = join("\n", map { "+line $_ padding padding" } 1..200);

    # default (0): not truncated, no marker
    {
        my $bf = File::Spec->catfile($tmpdir, 'notrunc.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/big.conf', diff => [split /\n/, $big]);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs", full_diff => 1)->send($r);
        waitpid($pid, 0);
        my %a = map { $_->{key} => $_->{value} }
            @{ read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0]{attributes} };
        ok(!exists $a{'config_change.diff_truncated'}, 'default: no truncation marker');
        is(length($a{'config_change.diff'}{stringValue}), length($big), 'default: full diff');
    }

    # cap 50: truncated + marker
    {
        my $bf = File::Spec->catfile($tmpdir, 'trunc.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/big.conf', diff => [split /\n/, $big]);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs", full_diff => 1, max_diff_bytes => 50)->send($r);
        waitpid($pid, 0);
        my %a = map { $_->{key} => $_->{value} }
            @{ read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0]{attributes} };
        ok($a{'config_change.diff_truncated'}{boolValue}, 'cap: truncation marker true');
        like($a{'config_change.diff'}{stringValue}, qr/diff truncated/, 'cap: marker text in diff');
    }
}

########################################################################
# Severity Map + Resolver
########################################################################
{
    my $n = ChangeTrack::Notify::OTLP->new;

    is_deeply([$n->_severity_for('INFO')],  [9,  'INFO'],  'INFO -> 9');
    is_deeply([$n->_severity_for('debug')], [5,  'DEBUG'], 'case-insensitive debug -> 5');
    is_deeply([$n->_severity_for('WARN')],  [13, 'WARN'],  'WARN -> 13');
    is_deeply([$n->_severity_for('bogus')], [0,  'UNSPECIFIED'], 'unknown -> UNSPECIFIED');

    # _severity_cfg: unset key falls back to default name
    is_deeply([$n->_severity_cfg('severity_change', 'INFO')], [9, 'INFO'],
        'unset config -> default INFO');

    my $n2 = ChangeTrack::Notify::OTLP->new(severity_change => 'warn');
    is_deeply([$n2->_severity_cfg('severity_change', 'INFO')], [13, 'WARN'],
        'configured value overrides default (case-insensitive)');

    my $n3 = ChangeTrack::Notify::OTLP->new(severity_change => 'nonsense');
    is_deeply([$n3->_severity_cfg('severity_change', 'INFO')], [9, 'INFO'],
        'invalid config falls back to default');
}

########################################################################
# Per-Class Severity (defaults + overrides)
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};

    # heartbeat default DEBUG (5)
    {
        my $bf = File::Spec->catfile($tmpdir, 'sev_hb.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs", heartbeat => 1)->send($r);
        waitpid($pid, 0);
        my $rec = read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
        is($rec->{severityNumber}, 5,       'heartbeat default severityNumber DEBUG=5');
        is($rec->{severityText},   'DEBUG', 'heartbeat default severityText DEBUG');
    }

    # change default INFO (9)
    {
        my $bf = File::Spec->catfile($tmpdir, 'sev_chg.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/hosts', diff => ['+x']);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(endpoint => "http://127.0.0.1:$port/v1/logs")->send($r);
        waitpid($pid, 0);
        my $rec = read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
        is($rec->{severityNumber}, 9,      'change default severityNumber INFO=9');
        is($rec->{severityText},   'INFO', 'change default severityText INFO');
    }

    # change override WARN (13)
    {
        my $bf = File::Spec->catfile($tmpdir, 'sev_chg_ovr.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/hosts', diff => ['+x']);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs",
            severity_change => 'warn')->send($r);
        waitpid($pid, 0);
        my $rec = read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
        is($rec->{severityNumber}, 13,     'change override severityNumber WARN=13');
        is($rec->{severityText},   'WARN', 'change override severityText WARN');
    }
}

done_testing();

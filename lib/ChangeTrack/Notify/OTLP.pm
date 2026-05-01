package ChangeTrack::Notify::OTLP;

=head1 NAME

ChangeTrack::Notify::OTLP - OpenTelemetry (OTLP/HTTP) notifier for changetrack-ng

=head1 DESCRIPTION

Exports one OTLP log record per changed file to an OTLP/HTTP endpoint via
C<HTTP::Tiny>.  Features: optional gzip compression, environment-variable
endpoint/header precedence (C<OTEL_EXPORTER_OTLP_ENDPOINT>,
C<OTEL_EXPORTER_OTLP_LOGS_ENDPOINT>), 3-attempt exponential retry backoff,
and heartbeat enabled by default.

=cut

use strict;
use warnings;
use parent 'ChangeTrack::Notify::Base';
use JSON::PP ();
use HTTP::Tiny ();

use ChangeTrack::Util qw(hostname);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{otlp_endpoint}            //= '';
    $self->{otlp_headers}             //= '';
    $self->{otlp_compression}         //= '';
    $self->{otlp_full_diff}           //= 0;
    $self->{otlp_heartbeat}           //= 1;
    $self->{otlp_timeout}             //= 10;
    $self->{otlp_insecure}            //= 0;
    $self->{otlp_resource_attributes} //= {};
    $self->{sensitive_notify}         //= 'suppress';
    $self->{_endpoint_warned}         = 0;
    return $self;
}

sub heartbeat_enabled {
    my ($self) = @_;
    return $self->{otlp_heartbeat} ? 1 : 0;
}

sub name { 'otlp' }

sub validate_config {
    my ($self) = @_;
    my $ep = $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT}
          // $ENV{OTEL_EXPORTER_OTLP_ENDPOINT}
          // $self->{otlp_endpoint}
          // '';
    return () if $ep =~ /\S/;
    return ('otlp notifier requires otlp_endpoint or OTEL_EXPORTER_OTLP[_LOGS]_ENDPOINT');
}

sub send_changes {
    my ($self, $report) = @_;
    my $ep = $self->_resolve_endpoint;
    return unless $ep;
    $self->_post_with_retry($ep, $self->_build_payload($report, 0));
}

sub send_heartbeat {
    my ($self, $report) = @_;
    my $ep = $self->_resolve_endpoint;
    return unless $ep;
    $self->_post_with_retry($ep, $self->_build_payload($report, 1));
}

sub _build_payload {
    my ($self, $report, $is_heartbeat) = @_;

    my $ts_nano = sprintf('%d000000000', $report->{start_time} // time());
    my $dur     = $report->duration_ms;
    my $tracked = $report->files_tracked // 0;

    my @common_attrs = (
        { key => 'ct.files_tracked', value => { intValue => "$tracked" } },
    );
    push @common_attrs,
        { key => 'ct.run_duration_ms', value => { intValue => sprintf('%d', $dur) } }
        if defined $dur;

    my @log_records;

    if ($is_heartbeat) {
        push @log_records, {
            timeUnixNano         => $ts_nano,
            observedTimeUnixNano => $ts_nano,
            severityNumber       => 9,
            severityText         => 'INFO',
            body                 => { stringValue => 'changetrack-ng heartbeat (no changes)' },
            attributes           => [
                { key => 'ct.heartbeat', value => { boolValue => JSON::PP::true() } },
                @common_attrs,
            ],
        };
    } else {
        for my $c (@{ $report->changes }) {
            my @attrs = (
                { key => 'ct.path',
                  value => { stringValue => $c->{path} } },
                { key => 'ct.is_new',
                  value => { boolValue => $c->{is_new}       ? JSON::PP::true() : JSON::PP::false() } },
                { key => 'ct.is_removed',
                  value => { boolValue => $c->{is_removed}   ? JSON::PP::true() : JSON::PP::false() } },
                { key => 'ct.is_sensitive',
                  value => { boolValue => $c->{is_sensitive} ? JSON::PP::true() : JSON::PP::false() } },
                { key => 'ct.heartbeat',
                  value => { boolValue => JSON::PP::false() } },
                @common_attrs,
            );

            if ($c->{meta_change}) {
                push @attrs,
                    { key => 'ct.meta_change', value => { stringValue => $c->{meta_change} } };
            }

            if ($self->{otlp_full_diff}) {
                unless ($c->{is_sensitive} && !$self->_sensitive_notify_allowed) {
                    push @attrs, {
                        key   => 'ct.diff',
                        value => { stringValue => join("\n", @{ $c->{diff} // [] }) },
                    };
                }
            }

            my $body_msg = $c->{is_removed} ? "file removed: $c->{path}"
                         : $c->{is_new}     ? "new file: $c->{path}"
                         :                    "file changed: $c->{path}";

            push @log_records, {
                timeUnixNano         => $ts_nano,
                observedTimeUnixNano => $ts_nano,
                severityNumber       => 9,
                severityText         => 'INFO',
                body                 => { stringValue => $body_msg },
                attributes           => \@attrs,
            };
        }

        for my $w (@{ $report->warnings }) {
            push @log_records, {
                timeUnixNano         => $ts_nano,
                observedTimeUnixNano => $ts_nano,
                severityNumber       => 13,
                severityText         => 'WARN',
                body                 => { stringValue => $w },
                attributes           => [
                    { key => 'ct.heartbeat', value => { boolValue => JSON::PP::false() } },
                    @common_attrs,
                ],
            };
        }
    }

    return {
        resourceLogs => [{
            resource  => { attributes => $self->_resource_attrs },
            scopeLogs => [{
                scope      => { name => 'changetrack-ng', version => $VERSION },
                logRecords => \@log_records,
            }],
        }],
    };
}

sub _resource_attrs {
    my ($self) = @_;

    my $machine_id = '';
    if (open(my $fh, '<', '/etc/machine-id')) {
        chomp($machine_id = <$fh> // '');
        close $fh;
    }

    my %attrs = (
        'service.name'        => 'changetrack-ng',
        'service.version'     => $VERSION,
        'service.instance.id' => hostname(),
        'host.name'           => hostname(),
        'host.id'             => $machine_id,
        'os.type'             => $^O,
    );

    my %custom = _parse_kv_config_value($self->{otlp_resource_attributes});
    %attrs = (%attrs, %custom) if %custom;

    return [ map { { key => $_, value => { stringValue => $attrs{$_} } } } sort keys %attrs ];
}

sub _resolve_endpoint {
    my ($self) = @_;

    my $ep = $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT}
          // $ENV{OTEL_EXPORTER_OTLP_ENDPOINT}
          // $self->{otlp_endpoint}
          // '';

    return '' unless $ep =~ /\S/;

    unless ($ep =~ m{/v1/logs$}) {
        unless ($self->{_endpoint_warned}) {
            warn "[changetrack-ng] otlp: endpoint '$ep' does not end in /v1/logs; appending\n";
            $self->{_endpoint_warned} = 1;
        }
        $ep =~ s{/+$}{};
        $ep .= '/v1/logs';
    }

    return $ep;
}

sub _resolve_headers {
    my ($self) = @_;

    my %headers = ('Content-Type' => 'application/json');

    my %cfg_headers = _parse_kv_config_value($self->{otlp_headers});
    %headers = (%headers, %cfg_headers) if %cfg_headers;

    my $env = $ENV{OTEL_EXPORTER_OTLP_HEADERS} // '';
    if ($env =~ /\S/) {
        my %h = _parse_env_headers($env);
        %headers = (%headers, %h);
    }

    return %headers;
}

sub _post_with_retry {
    my ($self, $ep, $payload) = @_;

    my $json = JSON::PP->new->encode($payload);
    my $body = $json;
    my %extra_hdrs;

    if (lc($self->{otlp_compression} // '') eq 'gzip') {
        my $compressed = '';
        my $ok = eval {
            require IO::Compress::Gzip;
            IO::Compress::Gzip::gzip(\$json, \$compressed)
                or die $IO::Compress::Gzip::GzipError;
            1;
        };
        if ($ok) {
            $body = $compressed;
            $extra_hdrs{'Content-Encoding'} = 'gzip';
        } else {
            warn "[changetrack-ng] otlp: gzip compression failed: $@; sending uncompressed\n";
        }
    }

    my %headers = ($self->_resolve_headers, %extra_hdrs);

    my %http_opts = (timeout => $self->{otlp_timeout});
    if ($self->{otlp_insecure}) {
        warn "[changetrack-ng] otlp: TLS verification disabled (otlp_insecure=1)\n";
        $http_opts{verify_SSL} = 0;
    }
    my $http = HTTP::Tiny->new(%http_opts);

    my $max_attempts = 3;
    my $delay        = 1;

    for my $attempt (1 .. $max_attempts) {
        my $resp = $http->request('POST', $ep, {
            headers => \%headers,
            content => $body,
        });

        my $status = $resp->{status};

        if ($status >= 200 && $status < 300) {
            return;
        }

        if ($status >= 400 && $status < 500) {
            warn "[changetrack-ng] otlp: POST to $ep returned $status (client error, not retrying)\n";
            return;
        }

        if ($attempt < $max_attempts) {
            $self->_sleep($delay);
            $delay *= 2;
        } else {
            my $detail = $status == 599 ? $resp->{content} : "HTTP $status";
            warn "[changetrack-ng] otlp: POST to $ep failed after $max_attempts attempts: $detail\n";
        }
    }
}

sub _sleep { sleep($_[1]) }

# Space-separated k=v pairs; backslash escapes spaces in values.
sub _parse_config_headers {
    my ($str) = @_;
    my %h;
    while ($str =~ /(\S+?)=((?:[^\\ \t]|\\.)*)/g) {
        my ($k, $v) = ($1, $2);
        $v =~ s/\\(.)/$1/g;
        $h{$k} = $v;
    }
    return %h;
}

# Comma-separated k=v pairs; values are percent-encoded.
sub _parse_env_headers {
    my ($str) = @_;
    my %h;
    for my $pair (split /,/, $str) {
        next unless $pair =~ /\S/;
        if ($pair =~ /^([^=]+)=(.*)$/) {
            my ($k, $v) = ($1, $2);
            $k =~ s/^\s+|\s+$//g;
            $v =~ s/^\s+|\s+$//g;
            $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $h{$k} = $v;
        }
    }
    return %h;
}

sub _parse_kv_config_value {
    my ($raw) = @_;
    return () unless defined $raw;

    if (ref $raw eq 'HASH') {
        return %$raw;
    }

    if (ref $raw eq 'ARRAY') {
        my %pairs;
        for my $token (@$raw) {
            next unless defined $token && $token =~ /\S/;
            next unless $token =~ /^([^=]+)=(.*)$/;
            my ($k, $v) = ($1, $2);
            $k =~ s/^\s+|\s+$//g;
            $v =~ s/^\s+|\s+$//g;
            $v =~ s/\\(.)/$1/g;
            $pairs{$k} = $v;
        }
        return %pairs;
    }

    return () if ref $raw;
    return () unless $raw =~ /\S/;
    return _parse_config_headers($raw);
}

1;

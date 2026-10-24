# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Notify::OTLP - OTLP/HTTP+JSON logs with gzip, env-var
#   precedence, heartbeat default ON.
#

package ChangeTrack::Notify::OTLP;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Notify::OTLP - OpenTelemetry (OTLP/HTTP) notifier for changetrack-ng

=head1 DESCRIPTION

Exports one OTLP log record per changed file to an OTLP/HTTP endpoint via
C<HTTP::Tiny>.  Features: optional gzip compression, environment-variable
endpoint/header precedence (C<OTEL_EXPORTER_OTLP_ENDPOINT>,
C<OTEL_EXPORTER_OTLP_LOGS_ENDPOINT>), 3-attempt exponential retry backoff,
and heartbeat enabled by default.

=cut

use feature qw(state);
use parent 'ChangeTrack::Notify::Base';
use JSON::PP ();
use HTTP::Tiny ();

use ChangeTrack::Util qw(hostname);
use File::Basename qw(basename dirname);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct the notifier with OTLP config defaults.
sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{endpoint}            //= '';
    $self->{headers}             //= '';
    $self->{compression}         //= '';
    $self->{full_diff}           //= 0;
    $self->{heartbeat}           //= 1;
    $self->{timeout}             //= 10;
    $self->{insecure}            //= 0;
    $self->{resource_attributes} //= {};
    $self->{sensitive_notify}    //= 'suppress';
    $self->{emit_recipients}     //= 0;
    $self->{max_diff_bytes}      //= 0;
    $self->{severity_change}     //= 'INFO';
    $self->{severity_heartbeat}  //= 'DEBUG';
    $self->{severity_warning}    //= 'WARN';
    $self->{_endpoint_warned}    = 0;
    return $self;
}

# heartbeat_enabled -- Return true when heartbeat is set (default on).
sub heartbeat_enabled {
    my ($self) = @_;
    return $self->{heartbeat} ? 1 : 0;
}

sub name { 'otlp' }

# validate_config -- Return an error string when no endpoint is configured.
sub validate_config {
    my ($self) = @_;
    my ($ep) = grep { defined && /\S/ } (
        $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT},
        $ENV{OTEL_EXPORTER_OTLP_ENDPOINT},
        $self->{endpoint},
    );
    $ep //= '';
    return () if $ep =~ /\S/;
    return ('otlp notifier requires endpoint or OTEL_EXPORTER_OTLP[_LOGS]_ENDPOINT');
}

# send_changes -- Build and POST an OTLP change payload.
sub send_changes {
    my ($self, $report) = @_;
    my $ep = $self->_resolve_endpoint;
    return unless $ep;
    $self->_post_with_retry($ep, $self->_build_payload($report, 0));
}

# send_heartbeat -- Build and POST an OTLP heartbeat payload.
sub send_heartbeat {
    my ($self, $report) = @_;
    my $ep = $self->_resolve_endpoint;
    return unless $ep;
    $self->_post_with_retry($ep, $self->_build_payload($report, 1));
}

# _build_payload -- Construct the OTLP LogsData JSON payload for one run.
# Heartbeat runs emit a single log record with event.name=changetrack.run.heartbeat
# at the severity_heartbeat severity (default DEBUG).
# Change runs emit one record per changed file plus records for warnings.
sub _build_payload {
    my ($self, $report, $is_heartbeat) = @_;

    my $observed_nano = sprintf('%d000000000', $report->{start_time} // time());
    my $dur     = $report->duration_ms;
    my $tracked = $report->files_tracked // 0;

    my @common_attrs = (
        { key => 'changetrack.files_tracked', value => { intValue => "$tracked" } },
    );
    push @common_attrs,
        { key => 'changetrack.run_duration_ms', value => { intValue => sprintf('%d', $dur) } }
        if defined $dur;

    my @log_records;

    if ($is_heartbeat) {
        my ($hb_num, $hb_text) = $self->_severity_cfg('severity_heartbeat', 'DEBUG');
        push @log_records, {
            timeUnixNano         => $observed_nano,
            observedTimeUnixNano => $observed_nano,
            severityNumber       => $hb_num,
            severityText         => $hb_text,
            body                 => { stringValue => 'changetrack-ng heartbeat (no changes)' },
            attributes           => [
                { key => 'event.name', value => { stringValue => 'changetrack.run.heartbeat' } },
                @common_attrs,
            ],
        };
    } else {
        my ($chg_num, $chg_text) = $self->_severity_cfg('severity_change', 'INFO');
        for my $c (@{ $report->changes }) {
            my $ev = $self->_build_change_event($c, $report->{start_time} // time());
            my $occurred_nano = sprintf('%d000000000', $ev->{occurred_unix});

            my %ev_attrs = %{ $ev->{attributes} };

            unless ($self->{full_diff}) {
                delete $ev_attrs{'changetrack.file.diff'};
                delete $ev_attrs{'config_change.diff'};
                delete $ev_attrs{'config_change.diff_truncated'};
            }

            my @attrs = (
                { key => 'event.name', value => { stringValue => $ev->{event_name} } },
                @common_attrs,
            );

            for my $k (sort keys %ev_attrs) {
                my $v = $ev_attrs{$k};
                next unless defined $v;

                if ($k eq 'config_change.sensitive' || $k eq 'changetrack.file.sensitive') {
                    push @attrs, { key => $k, value => { boolValue => $v ? JSON::PP::true() : JSON::PP::false() } };
                } elsif ($k eq 'config_change.diff_truncated') {
                    push @attrs, { key => $k, value => { boolValue => JSON::PP::true() } } if $v;
                } elsif ($k eq 'file.size' || $k eq 'changetrack.file.uid' || $k eq 'changetrack.file.gid') {
                    push @attrs, { key => $k, value => { intValue => sprintf('%d', $v) } };
                } elsif ($k eq 'config_change.notified' || $k eq 'changetrack.notify.recipients') {
                    push @attrs, {
                        key   => $k,
                        value => { arrayValue => { values => [
                            map { { stringValue => $_ } } @$v
                        ] } },
                    };
                } else {
                    push @attrs, { key => $k, value => { stringValue => "$v" } };
                }
            }

            push @log_records, {
                timeUnixNano         => $occurred_nano,
                observedTimeUnixNano => $observed_nano,
                severityNumber       => $chg_num,
                severityText         => $chg_text,
                body                 => { stringValue => $ev->{body} },
                attributes           => \@attrs,
            };
        }

        my ($warn_num, $warn_text) = $self->_severity_cfg('severity_warning', 'WARN');
        for my $w (@{ $report->warnings }) {
            push @log_records, {
                timeUnixNano         => $observed_nano,
                observedTimeUnixNano => $observed_nano,
                severityNumber       => $warn_num,
                severityText         => $warn_text,
                body                 => { stringValue => $w },
                attributes           => [
                    { key => 'event.name', value => { stringValue => 'changetrack.run.warning' } },
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

# _resource_attrs -- Build the OTLP resource attributes array.
# Merges fixed host/service attributes with any custom otlp_resource_attributes.
# Reads /etc/machine-id once per process (cached via state).
sub _resource_attrs {
    my ($self) = @_;

    state $machine_id;
    unless (defined $machine_id) {
        $machine_id = '';
        if (open(my $fh, '<', '/etc/machine-id')) {
            chomp($machine_id = <$fh> // '');
            close $fh;
        }
    }

    my %attrs = (
        'service.name'        => 'changetrack-ng',
        'service.version'     => $VERSION,
        'service.instance.id' => hostname(),
        'host.name'           => hostname(),
        'host.id'             => $machine_id,
        'os.type'             => $^O,
    );

    my %custom = _parse_kv_config_value($self->{resource_attributes});
    %attrs = (%attrs, %custom) if %custom;

    return [ map { { key => $_, value => { stringValue => $attrs{$_} } } } sort keys %attrs ];
}

# _resolve_endpoint -- Return the OTLP endpoint URL, checking env vars first.
# Appends /v1/logs if absent (with a one-time warning).
sub _resolve_endpoint {
    my ($self) = @_;

    my ($ep) = grep { defined && /\S/ } (
        $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT},
        $ENV{OTEL_EXPORTER_OTLP_ENDPOINT},
        $self->{endpoint},
    );
    $ep //= '';

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

# _resolve_headers -- Merge Content-Type, config headers, and OTEL_EXPORTER_OTLP_HEADERS.
# Environment headers take precedence over config headers.
sub _resolve_headers {
    my ($self) = @_;

    my %headers = ('Content-Type' => 'application/json');

    my %cfg_headers = _parse_kv_config_value($self->{headers});
    %headers = (%headers, %cfg_headers) if %cfg_headers;

    my $env = $ENV{OTEL_EXPORTER_OTLP_HEADERS} // '';
    if ($env =~ /\S/) {
        my %h = _parse_env_headers($env);
        %headers = (%headers, %h);
    }

    return %headers;
}

# _post_with_retry -- POST the OTLP payload to $ep with up to 3 attempts.
# Applies gzip compression when otlp_compression=gzip is set.
# HTTP dispatch with retry is delegated to Base::_http_post_with_retry.
sub _post_with_retry {
    my ($self, $ep, $payload) = @_;

    my $json = JSON::PP->new->utf8->encode($payload);
    my $body = $json;
    my %extra_hdrs;

    if (lc($self->{compression} // '') eq 'gzip') {
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

    my %http_opts = (timeout => $self->{timeout}, verify_SSL => 1);
    if ($self->{insecure}) {
        warn "[changetrack-ng] otlp: TLS verification disabled (insecure=1)\n";
        $http_opts{verify_SSL} = 0;
    }
    my $http = HTTP::Tiny->new(%http_opts);

    my $safe_url = ChangeTrack::Util::redact_url($ep);
    return $self->_http_post_with_retry($http, $ep, \%headers, $body, 'otlp', $safe_url);
}

# _parse_config_headers -- Parse space-separated key=value pairs from config.
# Backslash-escaped spaces in values are supported.
sub _parse_config_headers {
    my ($str) = @_;
    my %h;
    while ($str =~ /(\S+?)=((?:[^\\ \t]|\\.)*)/g) {
        my ($k, $v) = ($1, $2);
        $v =~ s/\\(.)/$1/g;
        $k =~ s/[\x00\x0D\x0A]//g;
        $v =~ s/[\x00\x0D\x0A]//g;
        $h{$k} = $v;
    }
    return %h;
}

# _parse_env_headers -- Parse comma-separated key=value pairs from an
# OTEL_EXPORTER_OTLP_HEADERS-style environment variable string.
# Values are percent-decoded per the OpenTelemetry spec.
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
            $k =~ s/[\x00\x0D\x0A]//g;
            $v =~ s/[\x00\x0D\x0A]//g;
            $h{$k} = $v;
        }
    }
    return %h;
}

# _parse_kv_config_value -- Normalize a config key=value setting into a plain
# Perl hash.  Accepts a hashref, arrayref of 'k=v' strings, or a raw string.
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

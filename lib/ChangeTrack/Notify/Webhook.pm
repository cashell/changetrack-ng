package ChangeTrack::Notify::Webhook;

=head1 NAME

ChangeTrack::Notify::Webhook - HTTP webhook notifier for changetrack-ng

=head1 DESCRIPTION

POSTs a JSON change report to one or more URLs via C<HTTP::Tiny>.  Payload
is a summary by default; set C<webhook_full_diff = 1> to include the full
unified diff.  Configurable heartbeat (default off).

=cut

use strict;
use warnings;
use parent 'ChangeTrack::Notify::Base';
use POSIX qw(strftime);
use JSON::PP ();
use HTTP::Tiny ();

use ChangeTrack::Util qw(hostname);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{_urls}             = _parse_urls($args{webhook_url} // '');
    $self->{webhook_full_diff} //= 0;
    $self->{webhook_heartbeat} //= 0;
    $self->{webhook_insecure}  //= 0;
    $self->{webhook_timeout}   //= 10;
    $self->{sensitive_notify}  //= 'suppress';
    return $self;
}

sub heartbeat_enabled {
    my ($self) = @_;
    return $self->{webhook_heartbeat} ? 1 : 0;
}

sub name { 'webhook' }

sub validate_config {
    my ($self) = @_;
    return () if @{ $self->{_urls} // [] };
    return ('webhook notifier requires non-empty webhook_url');
}

sub send_changes {
    my ($self, $report) = @_;
    $self->_post_to_all($self->_build_payload($report, 0));
}

sub send_heartbeat {
    my ($self, $report) = @_;
    $self->_post_to_all($self->_build_payload($report, 1));
}

sub _build_payload {
    my ($self, $report, $is_heartbeat) = @_;

    my $ts  = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($report->{start_time} // time()));
    my $dur = $report->duration_ms;

    my @files;
    unless ($is_heartbeat) {
        for my $c (@{ $report->changes }) {
            my $entry = {
                path               => $c->{path},
                is_new             => $c->{is_new}       ? JSON::PP::true() : JSON::PP::false(),
                is_removed         => $c->{is_removed}   ? JSON::PP::true() : JSON::PP::false(),
                is_sensitive       => $c->{is_sensitive} ? JSON::PP::true() : JSON::PP::false(),
                metadata_changed   => ($c->{meta_change} ? JSON::PP::true() : JSON::PP::false()),
                diff_lines_added   => _count_added($c->{diff}),
                diff_lines_removed => _count_removed($c->{diff}),
            };
            if ($self->{webhook_full_diff}) {
                unless ($c->{is_sensitive} && !$self->_sensitive_notify_allowed) {
                    $entry->{diff} = join("\n", @{ $c->{diff} // [] });
                }
            }
            push @files, $entry;
        }
    }

    my %payload = (
        tool          => 'changetrack-ng',
        version       => $VERSION,
        hostname      => hostname(),
        timestamp     => $ts,
        heartbeat     => ($is_heartbeat ? JSON::PP::true() : JSON::PP::false()),
        files_tracked => ($report->files_tracked // 0),
        files         => \@files,
    );
    $payload{run_duration_ms} = int($dur) if defined $dur;
    $payload{vcs}     = $report->{vcs}     if defined $report->{vcs};
    $payload{message} = $is_heartbeat
        ? 'changetrack-ng heartbeat (no changes)'
        : ($report->{message} // '');

    return \%payload;
}

sub _post_to_all {
    my ($self, $payload) = @_;
    return unless @{ $self->{_urls} };

    my $json = JSON::PP->new->encode($payload);

    my %http_opts = (timeout => $self->{webhook_timeout});
    if ($self->{webhook_insecure}) {
        warn "[changetrack-ng] webhook: TLS verification disabled (webhook_insecure=1)\n";
        $http_opts{verify_SSL} = 0;
    }
    my $http = HTTP::Tiny->new(%http_opts);

    for my $url (@{ $self->{_urls} }) {
        $self->_post_with_retry($http, $url, $json);
    }
}

sub _post_with_retry {
    my ($self, $http, $url, $json) = @_;

    my $max_attempts = 3;
    my $delay        = 1;

    for my $attempt (1 .. $max_attempts) {
        my $resp = $http->post($url, {
            headers => { 'Content-Type' => 'application/json' },
            content => $json,
        });

        my $status = $resp->{status};

        if ($status >= 200 && $status < 300) {
            return;
        }

        if ($status >= 400 && $status < 500) {
            warn "[changetrack-ng] webhook POST to $url returned $status (client error, not retrying)\n";
            return;
        }

        # 5xx or 599 (network error): retry with backoff
        if ($attempt < $max_attempts) {
            $self->_sleep($delay);
            $delay *= 2;
        } else {
            my $detail = $status == 599
                ? $resp->{content}
                : "HTTP $status";
            warn "[changetrack-ng] webhook POST to $url failed after $max_attempts attempts: $detail\n";
        }
    }
}

sub _sleep { sleep($_[1]) }

sub _count_added {
    my ($lines) = @_;
    my $n = 0;
    $n++ for grep { /^\+/ } @{ $lines // [] };
    return $n;
}

sub _count_removed {
    my ($lines) = @_;
    my $n = 0;
    $n++ for grep { /^-/ } @{ $lines // [] };
    return $n;
}

sub _parse_urls {
    my ($raw) = @_;

    my @chunks;
    if (!defined $raw) {
        return [];
    } elsif (ref $raw eq 'ARRAY') {
        @chunks = @$raw;
    } elsif (!ref $raw) {
        @chunks = ($raw);
    } else {
        return [];
    }

    my @urls;
    for my $chunk (@chunks) {
        next unless defined $chunk && $chunk =~ /\S/;
        push @urls, grep { /\S/ } split(/\s+/, $chunk);
    }

    return \@urls;
}

1;

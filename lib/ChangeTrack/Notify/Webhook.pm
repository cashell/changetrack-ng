# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Notify::Webhook - HTTP POST JSON with 3-attempt
#   exponential retry, TLS bypass option.
#

package ChangeTrack::Notify::Webhook;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Notify::Webhook - HTTP webhook notifier for changetrack-ng

=head1 DESCRIPTION

POSTs a JSON change report to one or more URLs via C<HTTP::Tiny>.  Payload
is a summary by default; set C<webhook_full_diff = 1> to include the full
unified diff.  Configurable heartbeat (default off).

=cut

use parent 'ChangeTrack::Notify::Base';
use POSIX qw(strftime);
use JSON::PP ();
use HTTP::Tiny ();

use ChangeTrack::Util qw(hostname);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct the notifier, parsing webhook_url into the internal URL list.
sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{_urls}            = _parse_urls($args{url} // '');
    $self->{full_diff}        //= 0;
    $self->{heartbeat}        //= 0;
    $self->{insecure}         //= 0;
    $self->{timeout}          //= 10;
    $self->{max_diff_bytes}   //= 0;
    $self->{sensitive_notify} //= 'suppress';
    return $self;
}

# heartbeat_enabled -- Return true when heartbeat is set.
sub heartbeat_enabled {
    my ($self) = @_;
    return $self->{heartbeat} ? 1 : 0;
}

sub name { 'webhook' }

# config_keys -- The set of constructor args this notifier reads from config.
sub config_keys { qw(url full_diff heartbeat insecure timeout max_diff_bytes) }

# validate_config -- Return an error string when no webhook URLs are configured.
sub validate_config {
    my ($self) = @_;
    return () if @{ $self->{_urls} // [] };
    return ('webhook notifier requires non-empty url');
}

# send_changes -- POST a change payload to all configured URLs.
sub send_changes {
    my ($self, $report) = @_;
    $self->_post_to_all($self->_build_payload($report, 0));
}

# send_heartbeat -- POST a heartbeat payload to all configured URLs.
sub send_heartbeat {
    my ($self, $report) = @_;
    $self->_post_to_all($self->_build_payload($report, 1));
}

# _build_payload -- Construct the JSON payload hashref for one run.
# When $is_heartbeat is true, the files list is empty.
# diff content is only included when webhook_full_diff is set.
sub _build_payload {
    my ($self, $report, $is_heartbeat) = @_;

    my $ts  = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($report->{start_time} // time()));
    my $dur = $report->duration_ms;

    my @files;
    unless ($is_heartbeat) {
        for my $c (@{ $report->changes }) {
            # For a sensitive file with suppression active, withhold both the
            # diff body and its line counts (the counts disclose change
            # magnitude to the endpoint suppression is meant to protect).
            my $suppressed = $c->{is_sensitive} && !$self->_sensitive_notify_allowed;
            my $entry = {
                path               => $c->{path},
                is_new             => $c->{is_new}       ? JSON::PP::true() : JSON::PP::false(),
                is_removed         => $c->{is_removed}   ? JSON::PP::true() : JSON::PP::false(),
                is_sensitive       => $c->{is_sensitive} ? JSON::PP::true() : JSON::PP::false(),
                metadata_changed   => ($c->{meta_change} ? JSON::PP::true() : JSON::PP::false()),
                diff_lines_added   => $suppressed ? 0 : _count_added($c->{diff}),
                diff_lines_removed => $suppressed ? 0 : _count_removed($c->{diff}),
            };
            if ($self->{full_diff} && !$suppressed) {
                my ($text, $truncated)
                    = $self->_truncate_diff(join("\n", @{ $c->{diff} // [] }));
                $entry->{diff}           = $text;
                $entry->{diff_truncated} = $truncated ? JSON::PP::true() : JSON::PP::false();
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

# _post_to_all -- Encode the payload as JSON and POST it to every configured URL.
sub _post_to_all {
    my ($self, $payload) = @_;
    return unless @{ $self->{_urls} };

    my $json = JSON::PP->new->utf8->encode($payload);

    my %http_opts = (timeout => $self->{timeout}, verify_SSL => 1);
    if ($self->{insecure}) {
        warn "[changetrack-ng] webhook: TLS verification disabled (insecure=1)\n";
        $http_opts{verify_SSL} = 0;
    }
    my $http = HTTP::Tiny->new(%http_opts);

    for my $url (@{ $self->{_urls} }) {
        $self->_post_with_retry($http, $url, $json);
    }
}

# _post_with_retry -- POST $json to $url with up to 3 attempts and
# exponential back-off.  Client errors (4xx) are not retried.
sub _post_with_retry {
    my ($self, $http, $url, $json) = @_;

    my $safe_url     = ChangeTrack::Util::redact_url($url);
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
            warn "[changetrack-ng] webhook POST to $safe_url returned $status (client error, not retrying)\n";
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
            warn "[changetrack-ng] webhook POST to $safe_url failed after $max_attempts attempts: $detail\n";
        }
    }
}

# _sleep -- Pause for $secs seconds.  Extracted for test-mocking.
sub _sleep { sleep($_[1]) }

# _count_added -- Count lines added (starting with '+', not '+++') in a diff.
sub _count_added {
    my ($lines) = @_;
    my $n = 0;
    $n++ for grep { /^\+/ && !/^\+\+\+\s/ } @{ $lines // [] };
    return $n;
}

# _count_removed -- Count lines removed (starting with '-', not '---') in a diff.
sub _count_removed {
    my ($lines) = @_;
    my $n = 0;
    $n++ for grep { /^-/ && !/^---\s/ } @{ $lines // [] };
    return $n;
}

# _parse_urls -- Normalize webhook_url config (string, array, or undef)
# into an arrayref of non-empty URL strings.
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

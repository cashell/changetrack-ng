# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Notify::Base - Abstract base class for all notifiers.
#

package ChangeTrack::Notify::Base;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Notify::Base - abstract base class for changetrack-ng notifiers

=head1 DESCRIPTION

Defines the interface implemented by all notification backends.
Subclasses: L<ChangeTrack::Notify::Email>, L<ChangeTrack::Notify::Webhook>,
L<ChangeTrack::Notify::OTLP>, L<ChangeTrack::Notify::File>.

=head1 INTERFACE

=over 4

=item $notifier->send($report)

Send a notification based on the L<ChangeTrack::Report> object.
Dispatches to C<send_changes> or C<send_heartbeat>.  Failures emit a warning
and are rethrown so the runner can record them as warnings.

=item $notifier->send_heartbeat($report)

Send a heartbeat notification (no changes detected).  Only called when the
notifier's heartbeat option is enabled.

=back

=head1 SUBCLASS HELPERS

=over 4

=item $notifier->_http_post_with_retry($http, $url, $headers, $body, $label, $safe_url)

Shared HTTP POST dispatcher with 3-attempt exponential back-off retry loop.
Returns the response hashref on 2xx and 4xx status (emitting a warning on 4xx).
Retries on 5xx and 599 network errors with back-off delay doubling each attempt.
Dies on terminal failure after 3 attempts.

=item $notifier->_build_change_event($change, $observed_unix)

Normalize a single Report change hashref into a canonical OpenTelemetry event
structure shared by File and OTLP notifiers.

=back

=cut

use Carp qw(carp);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct a notifier with the provided config hash.
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

# send -- Dispatcher for changes and heartbeat notifications.
# On failure, emits a carp warning and rethrows so Runner can record the failure.
sub send {
    my ($self, $report) = @_;
    eval {
        if ($report->has_changes) {
            $self->send_changes($report);
        } elsif ($self->heartbeat_enabled && $report->is_heartbeat_eligible) {
            $self->send_heartbeat($report);
        }
        1;
    } or do {
        my $err = $@;
        (my $clean_err = $err) =~ s/\n$//;
        carp sprintf('[changetrack-ng] %s notifier failed: %s', $self->name, $clean_err);
        die $err;
    };
    return;
}

sub send_changes   { die ref(shift) . '::send_changes not implemented' }
sub send_heartbeat { return }   # default: no-op

sub heartbeat_enabled { 0 }     # default: off; subclasses override

# validate_config -- Return a list of user-facing validation errors.
# Called by Runner before a notifier is used.
sub validate_config { return }

# name -- Return a human-readable label for this notifier (defaults to class name).
sub name { ref(shift) }

# _sensitive_notify_allowed -- Return true when the config allows sending
# diffs for sensitive files.  Defaults to 'suppress' (not allowed).
sub _sensitive_notify_allowed {
    my ($self) = @_;
    my $v = $self->{sensitive_notify} // 'suppress';
    return lc($v) eq 'allow';
}

# _diff_text_for -- Return diff lines for a change entry.
# Suppresses the diff content and returns a placeholder when the file is
# sensitive and sensitive_notify is not 'allow'.
sub _diff_text_for {
    my ($self, $change) = @_;
    if ($change->{is_sensitive} && !$self->_sensitive_notify_allowed) {
        return ('[diff suppressed — sensitive file; view via VCS log]');
    }
    return @{ $change->{diff} // [] };
}

# _truncate_diff -- Cap a diff string at max_diff_bytes encoded UTF-8 bytes.
# Returns ($text, $was_truncated).  max_diff_bytes of 0 (or unset) means
# unlimited.  Truncation happens on a UTF-8 byte boundary without splitting a
# multibyte character.
sub _truncate_diff {
    my ($self, $text) = @_;
    my $limit = $self->{max_diff_bytes} // 0;
    return wantarray ? ($text, 0) : $text unless $limit && $limit > 0;

    require Encode;
    my $bytes = Encode::encode('UTF-8', $text);
    return wantarray ? ($text, 0) : $text if length($bytes) <= $limit;

    # FB_QUIET stops decoding at the first incomplete trailing sequence, so the
    # cut never yields a broken multibyte character.
    my $cut = Encode::decode('UTF-8', substr($bytes, 0, $limit), Encode::FB_QUIET());
    my $res = $cut . "\n[diff truncated -- exceeded max_diff_bytes ($limit)]";
    return wantarray ? ($res, 1) : $res;
}

# _build_change_event -- Normalize a single Report change hashref into a
# canonical OpenTelemetry event structure shared by File and OTLP notifiers.
sub _build_change_event {
    my ($self, $change, $observed_unix) = @_;
    $observed_unix //= time();

    my $path = $change->{path};
    my $change_type = ($change->{removed} || $change->{is_removed}) ? 'removed'
                    : ($change->{is_new} ? 'created' : 'modified');
    my $event_name  = ($change_type eq 'modified') ? 'changetrack.file.changed'
                    : "changetrack.file.$change_type";
    my $body        = "File $change_type: $path";

    my $fm = (ref($change->{file_meta}) eq 'HASH') ? $change->{file_meta}
           : (ref($change->{stat}) eq 'HASH')      ? $change->{stat}
           : {};

    my $occurred_unix = $change->{mtime} // $fm->{mtime} // $observed_unix;
    my $is_sensitive  = ($change->{sensitive} || $change->{is_sensitive}) ? 1 : 0;

    require File::Basename;
    my %attrs = (
        'changetrack.file.path'        => $path,
        'changetrack.file.change_type' => $change_type,
        'changetrack.file.sensitive'   => $is_sensitive,
        'file.path'                    => $path,
        'file.name'                    => File::Basename::basename($path),
        'file.directory'               => File::Basename::dirname($path),
        'config_change.type'           => $change_type,
        'config_change.sensitive'      => $is_sensitive,
    );

    if (defined $fm->{mode}) {
        $attrs{'changetrack.file.mode'} = $fm->{mode};
        $attrs{'file.mode'}             = $fm->{mode};
    }
    if (defined $fm->{uid}) {
        $attrs{'changetrack.file.uid'} = $fm->{uid};
    }
    if (defined $fm->{gid}) {
        $attrs{'changetrack.file.gid'} = $fm->{gid};
    }
    my $uname = $fm->{uname} // $fm->{owner} // $fm->{user};
    if (defined $uname) {
        $attrs{'changetrack.file.uname'} = $uname;
        $attrs{'file.owner.name'}        = $uname;
    }
    my $gname = $fm->{gname} // $fm->{group};
    if (defined $gname) {
        $attrs{'changetrack.file.gname'} = $gname;
        $attrs{'file.group.name'}        = $gname;
    }
    if (defined $fm->{size}) {
        $attrs{'file.size'} = $fm->{size} + 0;
    }

    if ($change->{meta_change}) {
        $attrs{'config_change.meta_summary'} = $change->{meta_change};
    }

    if ($self->{emit_recipients} && @{ $change->{recipients} // [] }) {
        $attrs{'changetrack.notify.recipients'} = [ @{ $change->{recipients} } ];
        $attrs{'config_change.notified'}        = [ @{ $change->{recipients} } ];
    }

    my ($diff_text, $diff_truncated);
    if ($is_sensitive && (($self->{sensitive_notify} // 'suppress') eq 'suppress')) {
        $diff_text      = "[diff suppressed \x{2014} sensitive file; view via VCS log]";
        $diff_truncated = 0;
    } elsif (ref($change->{diff}) eq 'ARRAY' && @{ $change->{diff} }) {
        my ($cut, $trunc) = $self->_truncate_diff(join("\n", @{ $change->{diff} }));
        $diff_text      = $cut;
        $diff_truncated = $trunc ? 1 : 0;
    }

    if (defined $diff_text) {
        $attrs{'changetrack.file.diff'} = $diff_text;
        $attrs{'config_change.diff'}    = $diff_text;
        if ($diff_truncated) {
            $attrs{'config_change.diff_truncated'} = 1;
        }
    }

    return {
        change_type    => $change_type,
        event_name     => $event_name,
        body           => $body,
        occurred_unix  => $occurred_unix,
        observed_unix  => $observed_unix,
        diff           => $diff_text,
        diff_truncated => $diff_truncated,
        attributes     => \%attrs,
    };
}

# Severity name -> OTel severityNumber.  Single source of truth for both
# notifiers.  Only the levels changetrack-ng actually emits are listed.
my %SEVERITY = (
    DEBUG => 5,
    INFO  => 9,
    WARN  => 13,
    ERROR => 17,
);

# _severity_for -- Map a severity NAME (case-insensitive) to (number, text).
# Unknown/undef -> (0, 'UNSPECIFIED').
sub _severity_for {
    my ($self, $name) = @_;
    my $key = defined $name ? uc $name : '';
    return ($SEVERITY{$key}, $key) if exists $SEVERITY{$key};
    return (0, 'UNSPECIFIED');
}

# _severity_cfg -- Resolve $self->{$key}; fall back to $default_name when the
# configured value is missing or not a recognised severity name.
sub _severity_cfg {
    my ($self, $key, $default_name) = @_;
    my ($num, $text) = $self->_severity_for($self->{$key});
    return ($num, $text) if $num;             # valid configured value
    return $self->_severity_for($default_name);
}

########################################################################
# HTTP Dispatch With Retry
########################################################################

# _http_post_with_retry -- Shared HTTP POST helper with 3-attempt exponential
# back-off retry loop.  Returns $resp on 2xx or 4xx (after logging warning).
# Retries on 5xx or 599 (network/connection error).  Dies on final failure.
sub _http_post_with_retry {
    my ($self, $http, $url, $headers, $body, $label, $safe_url) = @_;
    $label    //= $self->name;
    $safe_url //= $url;

    my $max_attempts = 3;
    my $delay        = 1;

    for my $attempt (1 .. $max_attempts) {
        my $resp = $http->post($url, {
            headers => $headers,
            content => $body,
        });

        my $status = $resp->{status};

        if ($status >= 200 && $status < 300) {
            return $resp;
        }

        if ($status >= 400 && $status < 500) {
            warn "[changetrack-ng] $label: POST to $safe_url returned $status (client error, not retrying)\n";
            return $resp;
        }

        # 5xx or 599 (network error): retry with backoff
        if ($attempt < $max_attempts) {
            $self->_sleep($delay);
            $delay *= 2;
        } else {
            my $detail = $status == 599
                ? $resp->{content}
                : "HTTP $status";
            die "$label: POST to $safe_url failed after $max_attempts attempts: $detail\n";
        }
    }
}

# _sleep -- Pause for $secs seconds.  Extracted for test-mocking.
sub _sleep { sleep($_[1]) }

1;

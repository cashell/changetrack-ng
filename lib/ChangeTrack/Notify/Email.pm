# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# ChangeTrack::Notify::Email - Sendmail-based notifier, per-recipient
#   digests, heartbeat always off.
#

package ChangeTrack::Notify::Email;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Notify::Email - email notifier for changetrack-ng

=head1 DESCRIPTION

Sends per-file change notifications by piping RFC 2822 messages to
C<sendmail -oi -t>.  Per-file recipient lists are taken from the C<[track]>
section by default.  When C<use_track_recipients> is set to false (0),
per-track recipients are ignored and notifications are delivered only to
the instance's configured C<to> list, preventing duplicate emails when
multiple email notifier instances are defined.  When revision information is
recorded in the report or on individual changes, it is included in the email
message header and file change blocks.  Heartbeat is always disabled (anti-spam).

=cut

use feature qw(say);
use parent 'ChangeTrack::Notify::Base';
use Carp qw(carp);
use Encode qw(encode);
use POSIX qw(strftime);

use ChangeTrack::Util qw(hostname fqdn run_cmd);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

my @SENDMAIL_PATHS = qw(
    /usr/sbin/sendmail
    /usr/lib/sendmail
);

# new -- Construct the notifier with defaults for from, sensitive_notify,
# and use_track_recipients.
sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{from}                 //= 'changetrack-ng@' . fqdn();
    $self->{sensitive_notify}     //= 'suppress';
    $self->{use_track_recipients} //= 1;
    return $self;
}

# heartbeat_enabled -- Always false; email notifier does not send heartbeats.
sub heartbeat_enabled { 0 }

sub name { 'email' }

# send_changes -- Send per-recipient change digest emails.
# Changes are grouped by recipient address. When use_track_recipients is true,
# per-track recipients take precedence over the global email_to list. When
# use_track_recipients is false, per-track recipients are ignored.
sub send_changes {
    my ($self, $report) = @_;

    my $sendmail = $self->_find_sendmail
        or do {
            warn "[changetrack-ng] email notifier: sendmail not found, skipping\n";
            return;
        };

    # Group changes by recipient. When use_track_recipients is true (default),
    # per-track recipients override global; global email_to is the fallback
    # when a track entry has none. When use_track_recipients is false,
    # per-track recipients are ignored and notifications fall back to global.
    my @global_recips = grep { defined $_ && /\S/ } @{ $self->{to} // [] };
    my %by_recipient;
    for my $c (@{ $report->changes }) {
        my @track_recips = $self->{use_track_recipients}
            ? grep { defined $_ && /\S/ } @{ $c->{recipients} // [] }
            : ();
        my @recips = @track_recips ? @track_recips : @global_recips;

        my %seen;
        @recips = grep { !$seen{$_}++ } @recips;

        unless (@recips) {
            warn "[changetrack-ng] email: no recipients for $c->{path}, skipping\n";
            next;
        }

        for my $r (@recips) {
            push @{ $by_recipient{$r} }, $c;
        }
    }

    return unless %by_recipient;

    my $host = hostname();
    my $date = strftime('%Y-%m-%dT%H:%M:%S', localtime($report->{start_time} // time()));

    for my $recipient (sort keys %by_recipient) {
        my $changes = $by_recipient{$recipient};
        my $body    = $self->_format_body($changes, $host, $date, $report);
        $self->_send_one($sendmail, $recipient, $host, $date, $body);
    }
}

# _format_body -- Build the plain-text email body from a list of change entries.
sub _format_body {
    my ($self, $changes, $host, $date, $report_or_rev) = @_;

    my $revision;
    if (ref($report_or_rev) && eval { $report_or_rev->can('revision') }) {
        $revision = $report_or_rev->revision;
    } elsif (ref($report_or_rev) eq 'HASH') {
        $revision = $report_or_rev->{revision};
    } elsif (defined $report_or_rev && !ref($report_or_rev)) {
        $revision = $report_or_rev;
    }

    my @lines;
    push @lines, "changetrack-ng detected changes on $host at $date";
    if (defined $revision && length $revision) {
        push @lines, "Revision: $revision";
    }
    push @lines, '';

    for my $c (@$changes) {
        my $label = $c->{is_removed} ? 'REMOVED'
                  : $c->{is_new}     ? 'NEW'
                  :                    'CHANGED';
        push @lines, "$label: $c->{path}";

        if (defined $c->{revision} && length $c->{revision}
            && (!defined $revision || $c->{revision} ne $revision)) {
            push @lines, "  Revision: $c->{revision}";
        }

        if ($c->{meta_change}) {
            push @lines, "  Metadata: $c->{meta_change}";
        }

        my @diff = $self->_diff_text_for($c);
        if (@diff) {
            push @lines, "  Diff:";
            push @lines, "    $_" for @diff;
        }
        push @lines, '';
    }

    return join("\n", @lines);
}

# _send_one -- Compose and deliver one RFC 2822 email to $recipient via sendmail.
sub _send_one {
    my ($self, $sendmail, $recipient, $host, $date, $body) = @_;

    my $from    = $self->{from};
    my $subject = "[changetrack-ng] Changes on $host \@ $date";
    my $to      = $recipient;

    # Strip CR/LF to prevent mail-header injection via config-sourced values.
    for my $field (\$from, \$to, \$subject) {
        $$field =~ s/[\r\n]//g if defined $$field;
    }

    # '--' terminates option parsing so a recipient or sender beginning with
    # '-' cannot be misinterpreted by sendmail as an option (arg injection).
    my @cmd = ($sendmail, '-oi', '-f', $from, '--', $to);
    if ($^O eq 'MSWin32' && $sendmail !~ /\.(?:exe|bat|cmd|com)$/i) {
        @cmd = ($^X, $sendmail, '-oi', '-f', $from, '--', $to);
    }

    my $msg = "From: $from\n"
        . "To: $to\n"
        . "Subject: $subject\n"
        . "Content-Type: text/plain; charset=UTF-8\n"
        . "\n"
        . $body;

    my $res = run_cmd(cmd => \@cmd, input => encode('UTF-8', $msg));
    if (!$res->{success}) {
        carp "sendmail failed for $recipient (exit $res->{exit_code}): $res->{stderr}";
        return 0;
    }
    return 1;
}

# _find_sendmail -- Return the path to a usable sendmail binary.
# Checks sendmail_path config, then well-known paths, then PATH.
sub _find_sendmail {
    my ($self) = @_;

    if ($self->{sendmail_path}) {
        return $self->{sendmail_path} if -x $self->{sendmail_path};
        return $self->{sendmail_path} if $^O eq 'MSWin32' && -f $self->{sendmail_path};
        return undef;
    }

    for my $path (@SENDMAIL_PATHS) {
        return $path if -x $path;
    }

    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/sbin')) {
        next unless $dir =~ m{^/};    # skip relative PATH entries (untrusted)
        my $p = "$dir/sendmail";
        return $p if -x $p;
    }

    return undef;
}

1;

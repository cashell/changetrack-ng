package ChangeTrack::Notify::Email;

=head1 NAME

ChangeTrack::Notify::Email - email notifier for changetrack-ng

=head1 DESCRIPTION

Sends per-file change notifications by piping RFC 2822 messages to
C<sendmail -oi -t>.  Per-file recipient lists are taken from the C<[track]>
section.  Heartbeat is always disabled (anti-spam).

=cut

use strict;
use warnings;
use feature qw(say);
use parent 'ChangeTrack::Notify::Base';
use POSIX qw(strftime);

use ChangeTrack::Util qw(hostname fqdn);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

my @SENDMAIL_PATHS = qw(
    /usr/sbin/sendmail
    /usr/lib/sendmail
);

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{email_from}       //= 'changetrack-ng@' . fqdn();
    $self->{sensitive_notify} //= 'suppress';
    return $self;
}

# heartbeat_enabled — always 0; email is anti-spam by design.
sub heartbeat_enabled { 0 }

sub name { 'email' }

# config_keys — the set of constructor args this notifier reads from config.
sub config_keys { qw(email_from email_to sendmail_path) }

sub send_changes {
    my ($self, $report) = @_;

    my $sendmail = $self->_find_sendmail
        or do {
            warn "[changetrack-ng] email notifier: sendmail not found, skipping\n";
            return;
        };

    # Group changes by recipient.  Per-track recipients override global;
    # global email_to is the fallback when a track entry has none.
    my @global_recips = grep { defined $_ && /\S/ } @{ $self->{email_to} // [] };
    my %by_recipient;
    for my $c (@{ $report->changes }) {
        my @track_recips = grep { defined $_ && /\S/ } @{ $c->{recipients} // [] };
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
        my $body    = $self->_format_body($changes, $host, $date);
        $self->_send_one($sendmail, $recipient, $host, $date, $body);
    }
}

sub _format_body {
    my ($self, $changes, $host, $date) = @_;
    my @lines;
    push @lines, "changetrack-ng detected changes on $host at $date";
    push @lines, '';

    for my $c (@$changes) {
        my $label = $c->{is_removed} ? 'REMOVED'
                  : $c->{is_new}     ? 'NEW'
                  :                    'CHANGED';
        push @lines, "$label: $c->{path}";

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

sub _send_one {
    my ($self, $sendmail, $to, $host, $date, $body) = @_;

    my $from    = $self->{email_from};
    my $subject = "[changetrack-ng] Changes on $host \@ $date";

    my @cmd = ($sendmail, '-oi', '-f', $from, $to);
    if ($^O eq 'MSWin32' && $sendmail !~ /\.(?:exe|bat|cmd|com)$/i) {
        @cmd = ($^X, $sendmail, '-oi', '-f', $from, $to);
    }

    open(my $pipe, '|-', @cmd)
        or die "Cannot open sendmail pipe: $!";
    binmode($pipe, ':encoding(UTF-8)');

    print $pipe "From: $from\n";
    print $pipe "To: $to\n";
    print $pipe "Subject: $subject\n";
    print $pipe "Content-Type: text/plain; charset=UTF-8\n";
    print $pipe "\n";
    print $pipe $body;

    close($pipe) or warn "[changetrack-ng] sendmail exited with status $?\n";
}

sub _find_sendmail {
    my ($self) = @_;

    if ($self->{sendmail_path}) {
        return $self->{sendmail_path} if -x $self->{sendmail_path};
        return $self->{sendmail_path} if -f $self->{sendmail_path};
    }

    for my $path (@SENDMAIL_PATHS) {
        return $path if -x $path;
    }

    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/sbin')) {
        my $p = "$dir/sendmail";
        return $p if -x $p;
    }

    return undef;
}

1;

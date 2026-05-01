package ChangeTrack::Notify::Base;

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
Wrapped in eval by C<send()>; failures are logged as warnings and do not
abort the run.

=item $notifier->send_heartbeat($report)

Send a heartbeat notification (no changes detected).  Only called when the
notifier's heartbeat option is enabled.

=back

=cut

use strict;
use warnings;
use Carp qw(carp);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

# send() — best-effort dispatcher; never dies.
sub send {
    my ($self, $report) = @_;
    eval {
        if ($report->has_changes) {
            $self->send_changes($report);
        } elsif ($self->heartbeat_enabled && $report->is_heartbeat_eligible) {
            $self->send_heartbeat($report);
        }
    };
    if ($@) {
        (my $err = $@) =~ s/\n$//;
        carp sprintf('[changetrack-ng] %s notifier failed: %s', $self->name, $err);
    }
    return;
}

sub send_changes   { die ref(shift) . '::send_changes not implemented' }
sub send_heartbeat { return }   # default: no-op

sub heartbeat_enabled { 0 }     # default: off; subclasses override

# validate_config() — return list of user-facing validation errors.
# Called by Runner before a notifier is used.
sub validate_config { return }

sub name { ref(shift) }

# _sensitive_notify() — true if config says to allow diffs of sensitive files.
sub _sensitive_notify_allowed {
    my ($self) = @_;
    my $v = $self->{sensitive_notify} // 'suppress';
    return lc($v) eq 'allow';
}

# _diff_text_for() — returns diff lines for a change entry, applying sensitive suppression.
sub _diff_text_for {
    my ($self, $change) = @_;
    if ($change->{is_sensitive} && !$self->_sensitive_notify_allowed) {
        my $mode = $change->{mode} // '????';
        return ("[diff suppressed -- sensitive file (no group/world read)]");
    }
    return @{ $change->{diff} // [] };
}

1;

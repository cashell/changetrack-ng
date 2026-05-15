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
Wrapped in eval by C<send()>; failures are logged as warnings and do not
abort the run.

=item $notifier->send_heartbeat($report)

Send a heartbeat notification (no changes detected).  Only called when the
notifier's heartbeat option is enabled.

=back

=cut

use Carp qw(carp);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct a notifier with the provided config hash.
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

# send -- Best-effort dispatcher; catches errors from send_changes/send_heartbeat.
# On failure, emits a carp warning but never dies.
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
        my $mode = $change->{mode} // '????';
        return ("[diff suppressed -- sensitive file (no group/world read)]");
    }
    return @{ $change->{diff} // [] };
}

1;

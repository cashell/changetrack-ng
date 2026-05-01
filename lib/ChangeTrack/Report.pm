package ChangeTrack::Report;

=head1 NAME

ChangeTrack::Report - accumulates per-file change records during a run

=head1 SYNOPSIS

  my $report = ChangeTrack::Report->new;
  $report->add_change({ path => '/etc/passwd', diff => '...', is_sensitive => 0 });
  $report->add_warning('Could not read /etc/shadow: permission denied');
  $report->finish;

  my @changes = $report->changes;
  my $count   = $report->change_count;

=head1 DESCRIPTION

Collects per-file change records and warnings accumulated during a
C<changetrack-ng run>.  Passed to each enabled notifier after the VCS
commit step.

=head1 INSTANCE METHODS

=over 4

=item $report->add_change(\%record)

Append a change record.  Recognized keys: C<path>, C<diff>,
C<is_sensitive>, C<action> (C<"add">, C<"modify">, C<"delete">).

=item $report->add_warning($msg)

Append a warning string.

=item $report->finish

Record the end time for the run.

=item $report->changes

Return the list of change record hashrefs.

=item $report->warnings

Return the list of warning strings.

=item $report->change_count

Return the number of recorded changes.

=item $report->has_changes

Return true if at least one change was recorded.

=item $report->start_time / $report->end_time

Unix timestamps for the run.

=back

=cut

use strict;
use warnings;

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub new {
    my ($class, %args) = @_;
    return bless {
        start_time    => $args{start_time} // time(),
        end_time      => undef,
        changes       => [],
        warnings      => [],
        files_tracked => 0,
        has_errors    => 0,
    }, $class;
}

sub add_change {
    my ($self, %args) = @_;
    push @{ $self->{changes} }, {
        path         => $args{path},
        is_new       => $args{is_new}       // 0,
        is_removed   => $args{is_removed}   // 0,
        is_sensitive => $args{is_sensitive} // 0,
        diff         => $args{diff}         // [],
        meta_change  => $args{meta_change}  // '',
        recipients   => $args{recipients}   // [],
    };
}

sub add_removed {
    my ($self, %args) = @_;
    push @{ $self->{changes} }, {
        path         => $args{path},
        is_new       => 0,
        is_removed   => 1,
        is_sensitive => 0,
        diff         => [],
        meta_change  => '(file removed from disk)',
        recipients   => $args{recipients} // [],
    };
}

sub add_warning {
    my ($self, $msg) = @_;
    push @{ $self->{warnings} }, $msg;
    $self->{has_errors} = 1;
}

sub increment_tracked {
    my ($self) = @_;
    $self->{files_tracked}++;
}

sub set_end_time {
    my ($self, $t) = @_;
    $self->{end_time} = $t;
}

# has_changes() — true if at least one file changed, was added, or was removed.
sub has_changes {
    my ($self) = @_;
    return scalar @{ $self->{changes} } > 0;
}

# is_heartbeat_eligible() — true if the run completed cleanly (no errors/warnings).
sub is_heartbeat_eligible {
    my ($self) = @_;
    return !$self->{has_errors};
}

sub changes       { $_[0]->{changes}       }
sub warnings      { $_[0]->{warnings}      }
sub files_tracked { $_[0]->{files_tracked} }

sub duration_ms {
    my ($self) = @_;
    return undef unless defined $self->{end_time};
    return ($self->{end_time} - $self->{start_time}) * 1000;
}

# to_text() — human-readable run summary for stdout output.
sub to_text {
    my ($self) = @_;
    my @out;

    if (!$self->has_changes && !@{ $self->{warnings} }) {
        return "No changes detected ($self->{files_tracked} file(s) tracked).\n";
    }

    for my $c (@{ $self->{changes} }) {
        my $label = $c->{is_removed} ? 'REMOVED'
                  : $c->{is_new}     ? 'NEW    '
                  :                    'CHANGED';
        push @out, "  $label  $c->{path}";

        if ($c->{meta_change}) {
            push @out, "           meta: $c->{meta_change}";
        }
        if ($c->{is_sensitive}) {
            push @out, "           [diff suppressed -- sensitive file]";
        } elsif (@{ $c->{diff} }) {
            push @out, "    $_" for @{ $c->{diff} };
        }
    }

    if (@{ $self->{warnings} }) {
        push @out, '', 'Warnings:';
        push @out, "  $_" for @{ $self->{warnings} };
    }

    my $n = scalar @{ $self->{changes} };
    push @out, '', "$n change(s) across $self->{files_tracked} tracked file(s).";

    return join("\n", @out) . "\n";
}

1;

# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Report - Per-run change record accumulator passed to
#   notifiers.
#

package ChangeTrack::Report;

use strict;
use warnings;
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

=item $report->add_change(%fields)

Append a change record.  Accepts a flat key-value list.  Recognized keys:
C<path>, C<is_new>, C<is_sensitive>, C<diff>, C<meta_change>, C<recipients>,
and C<stat> (a metadata hashref normalized into C<file_meta>).

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


our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct a fresh Report for a run starting at time().
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

# add_change -- Append a change record for a modified or new file.
# Recognized keys: path, is_new, is_removed, is_sensitive, diff,
# meta_change, recipients, stat (hashref from Metadata::record_for).
sub add_change {
    my ($self, %args) = @_;
    my $st = $args{stat} // {};
    push @{ $self->{changes} }, {
        path         => $args{path},
        is_new       => $args{is_new}       // 0,
        is_removed   => $args{is_removed}   // 0,
        is_sensitive => $args{is_sensitive} // 0,
        diff         => $args{diff}         // [],
        meta_change  => $args{meta_change}  // '',
        recipients   => $args{recipients}   // [],
        file_meta    => {
            mode  => $st->{mode},
            owner => $st->{user},
            group => $st->{group},
            size  => $st->{size},
            mtime => $st->{mtime},
        },
    };
}

# add_removed -- Append a change record for a file that vanished from disk.
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
        file_meta    => { mode => undef, owner => undef, group => undef,
                          size => undef, mtime => undef },
    };
}

# add_warning -- Record a non-fatal warning encountered during the run.
# Also sets the has_errors flag, suppressing heartbeat eligibility.
sub add_warning {
    my ($self, $msg) = @_;
    push @{ $self->{warnings} }, $msg;
    $self->{has_errors} = 1;
}

# increment_tracked -- Increment the count of files examined this run.
sub increment_tracked {
    my ($self) = @_;
    $self->{files_tracked}++;
}

# set_end_time -- Record the Unix timestamp when the run completed.
sub set_end_time {
    my ($self, $t) = @_;
    $self->{end_time} = $t;
}

# has_changes()  --  true if at least one file changed, was added, or was removed.
sub has_changes {
    my ($self) = @_;
    return scalar @{ $self->{changes} } > 0;
}

# is_heartbeat_eligible()  --  true if the run completed cleanly (no errors/warnings).
sub is_heartbeat_eligible {
    my ($self) = @_;
    return !$self->{has_errors};
}

# Accessors -- Simple read accessors for the report fields.
sub changes       { $_[0]->{changes}       }
sub warnings      { $_[0]->{warnings}      }
sub files_tracked { $_[0]->{files_tracked} }
sub start_time    { $_[0]->{start_time}    }
sub end_time      { $_[0]->{end_time}      }

# duration_ms -- Return run duration in milliseconds, or undef if not finished.
sub duration_ms {
    my ($self) = @_;
    return undef unless defined $self->{end_time};
    return ($self->{end_time} - $self->{start_time}) * 1000;
}

# to_text()  --  human-readable run summary for stdout output.
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

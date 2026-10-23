# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Notify::File - Append-only per-event OTel-shaped NDJSON
#   log notifier with optional heartbeat.
#

package ChangeTrack::Notify::File;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Notify::File - per-event NDJSON log notifier for changetrack-ng

=head1 DESCRIPTION

Appends one OTel-shaped JSON record per event (one per changed file, one
per heartbeat, one per warning) to the file at C<path>.  Each record carries
C<timestamp>, C<event_name>, C<severity_text>, C<severity_number>, C<body>,
C<resource>, and an C<attributes> hash keyed by changetrack-ng's canonical
attribute names.  Heartbeat is configurable (default off).

=cut

use parent 'ChangeTrack::Notify::Base';
use Fcntl qw(:flock);
use POSIX qw(strftime);
use File::Basename qw(basename dirname);
use JSON::PP ();

use ChangeTrack::Util qw(hostname);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct the notifier with defaults for path, heartbeat, diff output.
sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{path}             //= '/var/log/changetrack-ng.log';
    $self->{heartbeat}        //= 0;
    $self->{full_diff}        //= 1;
    $self->{sensitive_notify} //= 'suppress';
    $self->{emit_recipients}  //= 0;
    $self->{max_diff_bytes}   //= 0;
    $self->{severity_change}    //= 'INFO';
    $self->{severity_heartbeat} //= 'DEBUG';
    $self->{severity_warning}   //= 'WARN';
    return $self;
}

# heartbeat_enabled -- Return true when the heartbeat config key is set.
sub heartbeat_enabled {
    my ($self) = @_;
    return $self->{heartbeat} ? 1 : 0;
}

sub name { 'file' }

# validate_config -- Return an error string when path is not set.
sub validate_config {
    my ($self) = @_;
    my $path = $self->{path} // '';
    return () if $path =~ /\S/;
    return ('file notifier requires non-empty path');
}

# send_changes -- Append one record per change (and per warning) for the run.
sub send_changes {
    my ($self, $report) = @_;
    $self->_append_records($self->_build_records($report, 0));
}

# send_heartbeat -- Append a single heartbeat record.
sub send_heartbeat {
    my ($self, $report) = @_;
    $self->_append_records($self->_build_records($report, 1));
}

# _resource -- The resource map common to every record.
sub _resource {
    my ($self) = @_;
    return {
        'service.name'    => 'changetrack-ng',
        'service.version' => $VERSION,
        'host.name'       => hostname(),
    };
}

# _common_attrs -- Per-run attributes attached to every record.
sub _common_attrs {
    my ($self, $report) = @_;
    my %a = ('changetrack.files_tracked' => ($report->files_tracked // 0) + 0);
    my $dur = $report->duration_ms;
    $a{'changetrack.run_duration_ms'} = $dur + 0 if defined $dur;
    return %a;
}

# _build_records -- Build the list of per-event records for one run.
sub _build_records {
    my ($self, $report, $is_heartbeat) = @_;

    my $observed_ts = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($report->{start_time} // time()));
    my %common  = $self->_common_attrs($report);
    my ($chg_num,  $chg_text)  = $self->_severity_cfg('severity_change',    'INFO');
    my ($hb_num,   $hb_text)   = $self->_severity_cfg('severity_heartbeat', 'DEBUG');
    my ($warn_num, $warn_text) = $self->_severity_cfg('severity_warning',   'WARN');
    my @records;

    if ($is_heartbeat) {
        push @records, {
            timestamp          => $observed_ts,
            observed_timestamp => $observed_ts,
            event_name         => 'changetrack.run.heartbeat',
            severity_text      => $hb_text,
            severity_number    => $hb_num,
            body               => 'changetrack-ng heartbeat (no changes)',
            resource           => $self->_resource,
            attributes         => { %common },
        };
        return @records;
    }

    for my $c (@{ $report->changes }) {
        my $ev = $self->_build_change_event($c, $report->{start_time} // time());

        my $occurred_ts = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($ev->{occurred_unix}));
        my %attrs = (
            %{ $ev->{attributes} },
            %common,
        );

        $attrs{'config_change.sensitive'} = $ev->{attributes}{'config_change.sensitive'}
            ? JSON::PP::true() : JSON::PP::false();

        if ($ev->{attributes}{'config_change.diff_truncated'}) {
            $attrs{'config_change.diff_truncated'} = JSON::PP::true();
        }

        unless ($self->{full_diff}) {
            delete $attrs{'changetrack.file.diff'};
            delete $attrs{'config_change.diff'};
            delete $attrs{'config_change.diff_truncated'};
        }

        push @records, {
            timestamp          => $occurred_ts,
            observed_timestamp => $observed_ts,
            event_name         => $ev->{event_name},
            severity_text      => $chg_text,
            severity_number    => $chg_num,
            body               => $ev->{body},
            resource           => $self->_resource,
            attributes         => \%attrs,
        };
    }

    for my $w (@{ $report->warnings }) {
        push @records, {
            timestamp          => $observed_ts,
            observed_timestamp => $observed_ts,
            event_name         => 'changetrack.run.warning',
            severity_text      => $warn_text,
            severity_number    => $warn_num,
            body               => $w,
            resource           => $self->_resource,
            attributes         => { %common },
        };
    }

    return @records;
}

# _append_records -- Serialize each record to one JSON line and append them
# all under a single exclusive lock to prevent interleaved entries.
sub _append_records {
    my ($self, @records) = @_;
    return unless @records;

    my $path = $self->{path};
    my $jp   = JSON::PP->new->utf8->canonical(1);

    open(my $fh, '>>', $path)
        or die "Cannot open log file $path: $!";
    flock($fh, LOCK_EX)
        or die "Cannot lock $path: $!";
    print $fh $jp->encode($_), "\n" for @records;
    flock($fh, LOCK_UN);
    close($fh);
}

1;

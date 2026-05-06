package ChangeTrack::Notify::File;

=head1 NAME

ChangeTrack::Notify::File - append-only JSON log notifier for changetrack-ng

=head1 DESCRIPTION

Appends one JSON object per run to the file at C<notify_log_path>.  Each
record includes a timestamp, hostname, list of changed files, and optional
heartbeat flag.  Configurable heartbeat (default off).

=cut

use strict;
use warnings;
use parent 'ChangeTrack::Notify::Base';
use Fcntl qw(:flock);
use POSIX qw(strftime);
use JSON::PP ();

use ChangeTrack::Util qw(hostname);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{log_path}         //= '/var/log/changetrack-ng.log';
    $self->{file_heartbeat}   //= 0;
    $self->{file_full_diff}   //= 1;
    $self->{sensitive_notify} //= 'suppress';
    return $self;
}

sub heartbeat_enabled {
    my ($self) = @_;
    return $self->{file_heartbeat} ? 1 : 0;
}

sub name { 'file' }

sub validate_config {
    my ($self) = @_;
    my $path = $self->{log_path} // '';
    return () if $path =~ /\S/;
    return ('file notifier requires non-empty notify_log_path');
}

sub send_changes {
    my ($self, $report) = @_;
    $self->_append_record($self->_build_record($report, 0));
}

sub send_heartbeat {
    my ($self, $report) = @_;
    $self->_append_record($self->_build_record($report, 1));
}

sub _build_record {
    my ($self, $report, $is_heartbeat) = @_;

    my $host = hostname();
    my $ts   = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($report->{start_time} // time()));
    my $dur  = $report->duration_ms;

    my @files;
    unless ($is_heartbeat) {
        for my $c (@{ $report->changes }) {
            my $entry = {
                path             => $c->{path},
                is_new           => $c->{is_new}       ? JSON::PP::true() : JSON::PP::false(),
                is_removed       => $c->{is_removed}   ? JSON::PP::true() : JSON::PP::false(),
                is_sensitive     => $c->{is_sensitive} ? JSON::PP::true() : JSON::PP::false(),
                metadata_changed => ($c->{meta_change} ? JSON::PP::true() : JSON::PP::false()),
                meta_change      => $c->{meta_change} // '',
            };
            if ($self->{file_full_diff}) {
                my @diff_lines = $self->_diff_text_for($c);
                $entry->{diff} = \@diff_lines;
            }
            push @files, $entry;
        }
    }

    my %rec = (
        tool          => 'changetrack-ng',
        version       => $VERSION,
        hostname      => $host,
        timestamp     => $ts,
        heartbeat     => ($is_heartbeat ? JSON::PP::true() : JSON::PP::false()),
        files_tracked => $report->files_tracked,
        files         => \@files,
    );
    $rec{run_duration_ms} = $dur if defined $dur;

    return \%rec;
}

sub _append_record {
    my ($self, $record) = @_;
    my $path = $self->{log_path};

    my $json = JSON::PP->new->canonical(1)->encode($record);

    open(my $fh, '>>', $path)
        or die "Cannot open log file $path: $!";
    flock($fh, LOCK_EX)
        or die "Cannot lock $path: $!";
    print $fh $json, "\n";
    flock($fh, LOCK_UN);
    close($fh);
}

1;

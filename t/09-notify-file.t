# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 09-notify-file.t - Tests for the per-event OTel-shaped File notifier.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use JSON::PP ();

use_ok('ChangeTrack::Notify::File');
use_ok('ChangeTrack::Report');

my $dir = tempdir(CLEANUP => 1);

# helper: read all JSONL records from a log file
sub all_records {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @recs;
    while (my $line = <$fh>) {
        next unless $line =~ /\S/;
        chomp $line;
        push @recs, eval { JSON::PP->new->decode($line) };
    }
    close($fh);
    return @recs;
}
sub last_record { my @r = all_records(@_); return $r[-1]; }

########################################################################
# Heartbeat_Enabled Default Off
########################################################################
{
    my $n = ChangeTrack::Notify::File->new(path => "$dir/test.log");
    ok(!$n->heartbeat_enabled, 'heartbeat default off');
    is($n->name, 'file', 'name returns file');
}

########################################################################
# No Append When No Changes And Heartbeat Off
########################################################################
{
    my $log = "$dir/no-hb.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 0);
    $n->send(ChangeTrack::Report->new);
    ok(!-e $log, 'No log file created when no changes and heartbeat off');
}

########################################################################
# Change Run: One OTel Record Per Change
########################################################################
{
    my $log = "$dir/changes.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log);

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(
        path   => '/etc/passwd',
        is_new => 1,
        diff   => ['(new file)'],
        stat   => { mode => '0644', user => 'root', group => 'root',
                    size => 42, mtime => 1_700_000_000, type => 'file' },
    );
    $report->set_end_time(1000000003);
    $n->send($report);

    ok(-e $log, 'Log file created');
    my @recs = all_records($log);
    is(scalar @recs, 1, 'one record for one change');
    my $r = $recs[0];
    is($r->{event_name}, 'changetrack.file.created', 'event_name created');
    is($r->{severity_text}, 'INFO',                  'severity_text INFO');
    is($r->{severity_number}, 9,                     'severity_number 9');
    is($r->{resource}{'service.name'}, 'changetrack-ng', 'resource service.name');
    is($r->{attributes}{'file.path'}, '/etc/passwd',     'attributes file.path');
    is($r->{attributes}{'file.name'}, 'passwd',          'attributes file.name');
    is($r->{attributes}{'config_change.type'}, 'created','attributes config_change.type');
    is($r->{attributes}{'file.mode'}, '0644',            'attributes file.mode');
    is($r->{attributes}{'file.size'}, 42,                'attributes file.size');
    ok(defined $r->{attributes}{'changetrack.run_duration_ms'}, 'run_duration_ms present');
}

########################################################################
# Heartbeat Run: One changetrack.run.heartbeat Record
########################################################################
{
    my $log = "$dir/hb.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 1);

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->set_end_time(time() + 1);
    $n->send($report);

    ok(-e $log, 'Heartbeat: log file created');
    my @recs = all_records($log);
    is(scalar @recs, 1, 'Heartbeat: one record');
    is($recs[0]{event_name}, 'changetrack.run.heartbeat', 'Heartbeat: event_name');
    like($recs[0]{body}, qr/heartbeat/i, 'Heartbeat: body mentions heartbeat');
}

########################################################################
# Heartbeat Off: No Append On Clean Run
########################################################################
{
    my $log = "$dir/hb-off.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 0);
    $n->send(ChangeTrack::Report->new);
    ok(!-e $log, 'Heartbeat off: no log file on clean run');
}

########################################################################
# Multiple Changes In One Run: One Line Each
########################################################################
{
    my $log = "$dir/multi.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log);

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(path => '/etc/a', is_new => 0, diff => ['+x']);
    $report->add_change(path => '/etc/b', is_new => 1, diff => ['(new file)']);
    $report->set_end_time(1000000001);
    $n->send($report);

    my @recs = all_records($log);
    is(scalar @recs, 2, 'two changes => two NDJSON lines');
    is($recs[0]{attributes}{'config_change.type'}, 'modified', 'first is modified');
    is($recs[1]{attributes}{'config_change.type'}, 'created',  'second is created');
}

########################################################################
# Sensitive File: config_change.diff Suppressed
########################################################################
{
    my $log = "$dir/sensitive.log";
    my $n   = ChangeTrack::Notify::File->new(
        path => $log, sensitive_notify => 'suppress');

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old_hash', '+new_hash'],
    );
    $n->send($report);

    my $r = last_record($log);
    my $diff = $r->{attributes}{'config_change.diff'} // '';
    unlike($diff, qr/old_hash|new_hash/, 'Sensitive: raw diff suppressed');
    like($diff,   qr/suppressed/i,        'Sensitive: suppression notice present');
}

########################################################################
# config_change.notified Opt-In
########################################################################
{
    # default: not emitted
    my $log1 = "$dir/norecip.log";
    my $r1 = ChangeTrack::Report->new(start_time => time());
    $r1->add_change(path => '/etc/a', diff => [], recipients => ['ops@x.com']);
    ChangeTrack::Notify::File->new(path => $log1)->send($r1);
    my $rec1 = last_record($log1);
    ok(!exists $rec1->{attributes}{'config_change.notified'},
        'recipients omitted by default');

    # emit_recipients=1: emitted as array
    my $log2 = "$dir/recip.log";
    my $r2 = ChangeTrack::Report->new(start_time => time());
    $r2->add_change(path => '/etc/a', diff => [], recipients => ['ops@x.com', 'sa@x.com']);
    ChangeTrack::Notify::File->new(path => $log2, emit_recipients => 1)->send($r2);
    my $rec2 = last_record($log2);
    is_deeply($rec2->{attributes}{'config_change.notified'},
        ['ops@x.com', 'sa@x.com'], 'recipients emitted when emit_recipients=1');
}

########################################################################
# timestamp (occurred) vs observed_timestamp (scan)
########################################################################
{
    my $log = "$dir/ts_split.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log);

    my $report = ChangeTrack::Report->new(start_time => 1000000000);  # 2001-09-09T01:46:40Z
    $report->add_change(
        path => '/etc/hosts', diff => ['+x'],
        stat => { mtime => 1700000000, mode => '0644', type => 'file' },  # 2023-11-14T22:13:20Z
    );
    $report->set_end_time(1000000001);
    $n->send($report);

    my $r = last_record($log);
    is($r->{timestamp},          '2023-11-14T22:13:20Z', 'timestamp = mtime (occurred)');
    is($r->{observed_timestamp}, '2001-09-09T01:46:40Z', 'observed_timestamp = scan time');
}

########################################################################
# File Diff Truncation
########################################################################
{
    my $big = join("\n", map { "+line $_ padding" } 1..200);

    # default: full diff, no marker
    my $log1 = "$dir/notrunc.log";
    my $r1 = ChangeTrack::Report->new(start_time => 1000000000);
    $r1->add_change(path => '/etc/big.conf', diff => [split /\n/, $big]);
    ChangeTrack::Notify::File->new(path => $log1)->send($r1);
    my $rec1 = last_record($log1);
    ok(!exists $rec1->{attributes}{'config_change.diff_truncated'}, 'default: no marker');
    is(length($rec1->{attributes}{'config_change.diff'}), length($big), 'default: full diff');

    # cap 50: truncated + marker
    my $log2 = "$dir/trunc.log";
    my $r2 = ChangeTrack::Report->new(start_time => 1000000000);
    $r2->add_change(path => '/etc/big.conf', diff => [split /\n/, $big]);
    ChangeTrack::Notify::File->new(path => $log2, max_diff_bytes => 50)->send($r2);
    my $rec2 = last_record($log2);
    ok($rec2->{attributes}{'config_change.diff_truncated'}, 'cap: marker true');
    like($rec2->{attributes}{'config_change.diff'}, qr/diff truncated/, 'cap: marker text in diff');
}

########################################################################
# Sensitive Suppressed With Small max_diff_bytes: No Truncation
########################################################################
{
    # max_diff_bytes=10 is far smaller than the suppression placeholder.
    # The placeholder must be emitted as-is; diff_truncated must NOT be set.
    my $log = "$dir/sens-notrunc.log";
    my $n   = ChangeTrack::Notify::File->new(
        path             => $log,
        sensitive_notify => 'suppress',
        full_diff        => 1,
        max_diff_bytes   => 10,
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old_hash', '+new_hash'],
    );
    $n->send($report);

    my $r    = last_record($log);
    my $diff = $r->{attributes}{'config_change.diff'} // '';

    like($diff, qr/suppressed/i,
        'Sensitive+small cap: suppression placeholder present');
    ok(length($diff) > 10,
        'Sensitive+small cap: placeholder not truncated to cap');
    ok(!exists $r->{attributes}{'config_change.diff_truncated'},
        'Sensitive+small cap: diff_truncated not set');
    unlike($diff, qr/diff truncated/i,
        'Sensitive+small cap: no truncation marker in placeholder');
}

########################################################################
# Per-Class Severity (File notifier)
########################################################################
{
    # heartbeat default DEBUG
    my $log_hb = "$dir/sev_hb.log";
    my $rhb = ChangeTrack::Report->new(start_time => 1000000000);
    $rhb->set_end_time(1000000001);
    ChangeTrack::Notify::File->new(path => $log_hb, heartbeat => 1)->send($rhb);
    my $hb = last_record($log_hb);
    is($hb->{severity_number}, 5,       'file heartbeat severity_number DEBUG=5');
    is($hb->{severity_text},   'DEBUG', 'file heartbeat severity_text DEBUG');

    # change default INFO
    my $log_ch = "$dir/sev_ch.log";
    my $rch = ChangeTrack::Report->new(start_time => 1000000000);
    $rch->add_change(path => '/etc/hosts', diff => ['+x']);
    ChangeTrack::Notify::File->new(path => $log_ch)->send($rch);
    my $ch = last_record($log_ch);
    is($ch->{severity_number}, 9,      'file change severity_number INFO=9');
    is($ch->{severity_text},   'INFO', 'file change severity_text INFO');

    # change override
    my $log_ov = "$dir/sev_ov.log";
    my $rov = ChangeTrack::Report->new(start_time => 1000000000);
    $rov->add_change(path => '/etc/hosts', diff => ['+x']);
    ChangeTrack::Notify::File->new(path => $log_ov, severity_change => 'warn')->send($rov);
    my $ov = last_record($log_ov);
    is($ov->{severity_number}, 13,     'file change override severity_number WARN=13');
    is($ov->{severity_text},   'WARN', 'file change override severity_text WARN');
}

done_testing();

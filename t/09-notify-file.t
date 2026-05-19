# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 09-notify-file.t - Tests for notify file.
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

# helper: read last JSONL record from log file
sub last_record {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    my @lines = <$fh>;
    close($fh);
    return undef unless @lines;
    chomp(my $last = $lines[-1]);
    return eval { JSON::PP->new->decode($last) };
}

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

    my $report = ChangeTrack::Report->new;
    $n->send($report);

    ok(!-e $log, 'No log file created when no changes and heartbeat off');
}

########################################################################
# Appends Record On Changes
########################################################################
{
    my $log = "$dir/changes.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log);

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(
        path         => '/etc/passwd',
        is_new       => 1,
        is_sensitive => 0,
        diff         => ['(new file)'],
        meta_change  => '',
    );
    $report->set_end_time(1000000003);
    $n->send($report);

    ok(-e $log, 'Log file created');

    my $rec = last_record($log);
    ok(defined $rec,                        'Record is valid JSON');
    is($rec->{tool},      'changetrack-ng', 'tool field correct');
    ok(!$rec->{heartbeat},                  'heartbeat false for change run');
    is(scalar @{ $rec->{files} }, 1,        'one file entry');
    is($rec->{files}[0]{path}, '/etc/passwd', 'file path correct');
    ok($rec->{files}[0]{is_new},              'is_new true');
    ok(defined $rec->{run_duration_ms},       'run_duration_ms present');
}

########################################################################
# Heartbeat Appends When File_Heartbeat=1, No Changes
########################################################################
{
    my $log = "$dir/hb.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 1);

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->set_end_time(time() + 1);
    $n->send($report);

    ok(-e $log, 'Heartbeat: log file created');
    my $rec = last_record($log);
    ok(defined $rec,          'Heartbeat: valid JSON');
    ok($rec->{heartbeat},     'Heartbeat: heartbeat true');
    is(scalar @{ $rec->{files} }, 0, 'Heartbeat: empty files array');
}

########################################################################
# Heartbeat Off: No Append On Clean Run
########################################################################
{
    my $log = "$dir/hb-off.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 0);

    my $report = ChangeTrack::Report->new;
    $n->send($report);

    ok(!-e $log, 'Heartbeat off: no log file on clean run');
}

########################################################################
# Multiple Appends: Each Run Adds One Line
########################################################################
{
    my $log = "$dir/multi.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 1);

    for my $i (1..3) {
        my $report = ChangeTrack::Report->new(start_time => time());
        $report->set_end_time(time() + 1);
        $n->send($report);
    }

    open(my $fh, '<', $log) or die $!;
    my @lines = grep { /\S/ } <$fh>;
    close($fh);
    is(scalar @lines, 3, 'Three appends produce three lines');

    # Each line must be valid JSON
    my $all_valid = 1;
    for my $line (@lines) {
        chomp $line;
        eval { JSON::PP->new->decode($line) };
        $all_valid = 0 if $@;
    }
    ok($all_valid, 'All lines are valid JSON');
}

########################################################################
# Sensitive File: Diff Suppressed In Log
########################################################################
{
    my $log = "$dir/sensitive.log";
    my $n   = ChangeTrack::Notify::File->new(
        path         => $log,
        sensitive_notify => 'suppress',
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old_hash', '+new_hash'],
        meta_change  => '',
    );
    $n->send($report);

    my $rec = last_record($log);
    my $diff_str = join("\n", @{ $rec->{files}[0]{diff} // [] });
    unlike($diff_str, qr/old_hash|new_hash/, 'Sensitive: raw diff suppressed in log');
    like($diff_str,   qr/suppressed/i,        'Sensitive: suppression notice present');
}

done_testing();

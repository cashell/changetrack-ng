# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 21-report.t - Tests for report.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use lib File::Spec->catdir($RealBin, '..', 'lib');

use ChangeTrack::Report;

########################################################################
# Construction
########################################################################
{
    my $t0 = time();
    my $r = ChangeTrack::Report->new;
    ok(defined $r, 'new() returns an object');
    isa_ok($r, 'ChangeTrack::Report');
    ok($r->start_time >= $t0, 'start_time set to approximately now');
    is(scalar @{ $r->changes },  0, 'changes empty on construction');
    is(scalar @{ $r->warnings }, 0, 'warnings empty on construction');
    is($r->files_tracked,        0, 'files_tracked zero on construction');
    ok(!$r->has_changes,            'has_changes false on empty report');
    ok($r->is_heartbeat_eligible,   'heartbeat eligible on clean empty report');
}

{
    my $r = ChangeTrack::Report->new(start_time => 1000, vcs => 'git', message => 'initial snapshot');
    is($r->start_time, 1000,               'start_time accepts explicit value');
    is($r->vcs,        'git',              'vcs accessor returns initialized value');
    is($r->message,    'initial snapshot', 'message accessor returns initialized value');
}

########################################################################
# Add_Change / Has_Changes
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_change(path => '/etc/passwd', diff => ['+foo'], is_sensitive => 0);
    ok($r->has_changes, 'has_changes true after add_change');
    is(scalar @{ $r->changes }, 1, 'one change recorded');
    my $c = $r->changes->[0];
    is($c->{path},         '/etc/passwd', 'path stored correctly');
    is($c->{is_sensitive}, 0,             'is_sensitive stored');
    is_deeply($c->{diff},  ['+foo'],      'diff stored correctly');
    is($c->{is_new},       0,             'is_new defaults to 0');
    is($c->{is_removed},   0,             'is_removed defaults to 0');
    is_deeply($c->{recipients}, [],       'recipients defaults to []');
}

{
    my $r = ChangeTrack::Report->new;
    $r->add_change(path => '/etc/new', is_new => 1, diff => ['(new file)'],
                   is_sensitive => 0, recipients => ['admin@example.com']);
    my $c = $r->changes->[0];
    is($c->{is_new},            1,                   'is_new stored');
    is_deeply($c->{recipients}, ['admin@example.com'], 'recipients stored');
}

########################################################################
# Multiple Changes Accumulate In Order
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_change(path => '/etc/a', diff => [], is_sensitive => 0);
    $r->add_change(path => '/etc/b', diff => [], is_sensitive => 0);
    $r->add_change(path => '/etc/c', diff => [], is_sensitive => 0);
    is(scalar @{ $r->changes }, 3, 'three changes accumulated');
    is($r->changes->[0]{path}, '/etc/a', 'first change in order');
    is($r->changes->[2]{path}, '/etc/c', 'last change in order');
}

########################################################################
# Add_Removed
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_removed(path => '/etc/gone');
    ok($r->has_changes, 'has_changes true after add_removed');
    my $c = $r->changes->[0];
    is($c->{path},         '/etc/gone',              'removed path stored');
    is($c->{is_removed},   1,                         'is_removed set');
    is($c->{is_sensitive}, 0,                         'removed never sensitive');
    is($c->{meta_change},  '(file removed from disk)', 'meta_change for removal');
    is_deeply($c->{diff},  [],                         'no diff for removal');
}

########################################################################
# Sensitive Flag Stored Correctly
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_change(path => '/etc/shadow', diff => ['+secrethash'], is_sensitive => 1);
    my $c = $r->changes->[0];
    is($c->{is_sensitive}, 1, 'sensitive flag set to 1');
    is_deeply($c->{diff},  ['+secrethash'], 'diff still stored internally when sensitive');
}

########################################################################
# Add_Warning / Is_Heartbeat_Eligible
########################################################################
{
    my $r = ChangeTrack::Report->new;
    ok($r->is_heartbeat_eligible, 'heartbeat eligible before any warnings');
    $r->add_warning('Something went wrong');
    ok(!$r->is_heartbeat_eligible, 'heartbeat ineligible after add_warning');
    is(scalar @{ $r->warnings }, 1, 'one warning stored');
    is($r->warnings->[0], 'Something went wrong', 'warning text stored correctly');
}

{
    my $r = ChangeTrack::Report->new;
    $r->add_warning('warn1');
    $r->add_warning('warn2');
    is(scalar @{ $r->warnings }, 2, 'multiple warnings accumulate');
}

########################################################################
# Increment_Tracked / Files_Tracked
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->increment_tracked for 1..5;
    is($r->files_tracked, 5, 'files_tracked increments correctly');
}

########################################################################
# Set_End_Time / Duration_Ms
########################################################################
{
    my $r = ChangeTrack::Report->new(start_time => 1000);
    is($r->duration_ms, undef, 'duration_ms undef before end_time set');
    $r->set_end_time(1002);
    is($r->duration_ms, 2000, 'duration_ms correct after set_end_time');
}

########################################################################
# To_Text  --  No Changes
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->increment_tracked for 1..3;
    my $text = $r->to_text;
    like($text, qr/No changes detected/, 'to_text reports no changes');
    like($text, qr/3 file/, 'to_text includes tracked count');
}

########################################################################
# To_Text  --  With Changes
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_change(path => '/etc/hosts', diff => ['+127.0.0.1 myhost'], is_sensitive => 0);
    $r->add_change(path => '/etc/fstab', diff => [], is_new => 1, is_sensitive => 0);
    $r->increment_tracked for 1..10;
    my $text = $r->to_text;
    like($text, qr|/etc/hosts|,    'to_text includes changed path');
    like($text, qr/CHANGED/,       'to_text labels changed file');
    like($text, qr|/etc/fstab|,    'to_text includes new path');
    like($text, qr/NEW/,           'to_text labels new file');
    like($text, qr/2 change\(s\)/, 'to_text includes change count');
}

########################################################################
# To_Text  --  Sensitive File Suppression Label
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_change(path => '/etc/shadow', diff => ['+hash'], is_sensitive => 1);
    my $text = $r->to_text;
    like($text, qr/diff suppressed/, 'to_text notes suppression for sensitive file');
    unlike($text, qr/\+hash/,        'sensitive diff content NOT leaked in to_text');
}

########################################################################
# To_Text  --  Metadata-Only Change
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_change(path => '/etc/passwd', diff => [], is_sensitive => 0,
                   meta_change => 'mode 0644->0600');
    my $text = $r->to_text;
    like($text, qr/meta:.*mode 0644/, 'to_text includes meta_change description');
}

########################################################################
# To_Text  --  Removal
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_removed(path => '/etc/gone');
    my $text = $r->to_text;
    like($text, qr/REMOVED/,     'to_text labels removed file');
    like($text, qr|/etc/gone|,   'to_text includes removed path');
}

########################################################################
# To_Text  --  Warnings Section
########################################################################
{
    my $r = ChangeTrack::Report->new;
    $r->add_change(path => '/etc/a', diff => [], is_sensitive => 0);
    $r->add_warning('Skipping FIFO: /tmp/mypipe');
    my $text = $r->to_text;
    like($text, qr/Warnings:/,           'to_text includes Warnings section when present');
    like($text, qr/Skipping FIFO/,       'to_text includes warning text');
}

########################################################################
# File_Meta Normalization From Stat Record
########################################################################
{
    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->add_change(
        path => '/etc/hosts',
        diff => ['+1.2.3.4 host'],
        stat => {
            path => '/etc/hosts', mode => '0644', uid => 0, gid => 0,
            user => 'root', group => 'root', type => 'file',
            mtime => 1_700_000_000, size => 42,
        },
    );
    my $c = $r->changes->[0];
    is($c->{file_meta}{mode},  '0644',        'file_meta.mode from stat');
    is($c->{file_meta}{owner}, 'root',        'file_meta.owner from stat user');
    is($c->{file_meta}{group}, 'root',        'file_meta.group from stat group');
    is($c->{file_meta}{size},  42,            'file_meta.size from stat');
    is($c->{file_meta}{mtime}, 1_700_000_000, 'file_meta.mtime from stat');
}

########################################################################
# Add_Change Without Stat: File_Meta Present, All Undef
########################################################################
{
    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->add_change(path => '/etc/hosts', diff => []);
    my $c = $r->changes->[0];
    ok(exists $c->{file_meta},          'file_meta present even without stat');
    ok(!defined $c->{file_meta}{mode},  'file_meta.mode undef without stat');
}

done_testing;

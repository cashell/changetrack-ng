# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# 14-vcs-svn.t - Tests for vcs svn.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use File::Basename qw(basename dirname);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use ChangeTrack::Util qw(run_cmd);

my ($SVN, $SVNADMIN);
for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
    $SVN      //= "$dir/svn"      if -x "$dir/svn";
    $SVNADMIN //= "$dir/svnadmin" if -x "$dir/svnadmin";
}
plan skip_all => 'svn or svnadmin not found in PATH'
    unless $SVN && $SVNADMIN;

use_ok('ChangeTrack::VCS::SVN');

my $output_dir  = tempdir(CLEANUP => 1);
my $tracked_dir = tempdir(CLEANUP => 1);

my $vcs = ChangeTrack::VCS::SVN->new(output_dir => $output_dir);
isa_ok($vcs, 'ChangeTrack::VCS::SVN');
isa_ok($vcs, 'ChangeTrack::VCS::Base');

########################################################################
# Model
########################################################################
is($vcs->model, 'whole-repo', 'model returns whole-repo');

########################################################################
# Init / Is_Initialized
########################################################################
ok(!$vcs->is_initialized, 'not initialized before init');
$vcs->init;
ok($vcs->is_initialized, 'initialized after init');
ok(-d "$output_dir/.svn", '.svn directory created in working copy');
ok(-d "$output_dir-svnrepo", 'svn repository created');

########################################################################
# Output_Path
########################################################################
is($vcs->output_path('/etc/passwd'),
    "$output_dir/etc/passwd",
    'output_path: single level');

is($vcs->output_path('/etc/ssl/certs/ca.crt'),
    "$output_dir/etc/ssl/certs/ca.crt",
    'output_path: nested path');

########################################################################
# Checkin (New File)
########################################################################
my $test_file = "$tracked_dir/test.conf";
open(my $fh, '>', $test_file) or die "Cannot create: $!";
print $fh "setting = original\n";
close($fh);

my $err = do { local $@; eval { $vcs->checkin($test_file, 'Initial checkin') }; $@ };
is($err, '', 'checkin new file: no error');

my $mirror = $vcs->output_path($test_file);
ok(-e $mirror, 'checkin: mirror file created');

# Before first commit, diff returns (new file)
my $diff = $vcs->diff($test_file);
is_deeply($diff, ['(new file)'], 'diff: (new file) before first commit');

########################################################################
# Commit
########################################################################
my $commit_res;
$err = do { local $@; eval { $commit_res = $vcs->commit('Initial commit') }; $@ };
is($err, '', 'commit: no error');
is($commit_res->{committed}, 1, 'commit: returns committed => 1');
is($commit_res->{revision}, 'r1', 'commit: returns r1 revision');
is_deeply($commit_res->{warnings}, [], 'commit: warnings empty');

my $log_r = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"]);
like($log_r->{stdout}, qr/Initial commit/, 'commit: appears in svn log');

########################################################################
# Is_Dirty / Diff After Commit
########################################################################
ok(!$vcs->is_dirty($test_file), 'is_dirty: false after commit');

$diff = $vcs->diff($test_file);
is_deeply($diff, [], 'diff: empty for unchanged file after commit');

########################################################################
# Modify File -> Is_Dirty / Diff
########################################################################
open($fh, '>', $test_file) or die $!;
print $fh "setting = modified\n";
close($fh);

ok($vcs->is_dirty($test_file), 'is_dirty: true after modification');

$diff = $vcs->diff($test_file);
ok(@$diff > 0, 'diff: non-empty after modification');
like(join("\n", @$diff), qr/modified/, 'diff: contains modification');
like(join("\n", @$diff), qr/^\+\+\+/m, 'diff: looks like unified diff');
ok($vcs->is_dirty($test_file), 'is_dirty: remains true after non-mutating diff');

########################################################################
# Non-Mutating Diff on Untracked File
########################################################################
my $untracked_file = "$tracked_dir/untracked.conf";
open($fh, '>', $untracked_file) or die $!;
print $fh "untracked = true\n";
close($fh);

my $untracked_diff = $vcs->diff($untracked_file);
is_deeply($untracked_diff, ['(new file)'], 'diff: (new file) for untracked file');
ok(!-e $vcs->output_path($untracked_file), 'diff: does not create mirror path for untracked file');

########################################################################
# Checkin + Commit Modified File
########################################################################
$err = do { local $@; eval { $vcs->checkin($test_file, 'Modification') }; $@ };
is($err, '', 'checkin modified: no error');

$err = do { local $@; eval { $vcs->commit('Modification commit') }; $@ };
is($err, '', 'commit after modification: no error');

ok(!$vcs->is_dirty($test_file), 'is_dirty: false after second commit');

########################################################################
# Multiple Files -> One Atomic Commit
########################################################################
my $file2 = "$tracked_dir/file2.conf";
my $file3 = "$tracked_dir/file3.conf";
for my $f ($file2, $file3) {
    open($fh, '>', $f) or die $!;
    print $fh "key = val\n";
    close($fh);
    $vcs->checkin($f, 'Batch add');
}

my $log_before = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"]);
my @before_revs = ($log_before->{stdout} =~ /^r\d+\s/gm);

$vcs->commit('Atomic batch commit');

my $log_after = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"]);
my @after_revs = ($log_after->{stdout} =~ /^r\d+\s/gm);

is(scalar @after_revs, scalar @before_revs + 1, 'multiple staged files produce one atomic commit');
like($log_after->{stdout}, qr/Atomic batch commit/, 'atomic commit message in log');

########################################################################
# No-Op Commit (Nothing Staged)
########################################################################
my $log_before_noop = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"])->{stdout};

my $noop_res;
$err = do { local $@; eval { $noop_res = $vcs->commit('Should not appear') }; $@ };
is($err, '', 'commit with nothing staged: no error');
is_deeply($noop_res, { committed => 0, revision => undef, warnings => [] },
    'commit with nothing staged: returns committed => 0');

my $log_after_noop = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"])->{stdout};
is($log_before_noop, $log_after_noop, 'commit with nothing staged: no new commit');

########################################################################
# Log_History
########################################################################
my $history = $vcs->log_history($test_file);
ok(@$history > 0, 'log_history: returns lines');
like(join("\n", @$history), qr/Initial commit/,      'log_history: contains first commit msg');
like(join("\n", @$history), qr/Modification commit/, 'log_history: contains second commit msg');

########################################################################
# Revert (with leading 'r' revision string CORR-18)
########################################################################
{
    my $orig_content = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };

    $vcs->revert($test_file, 'r1');

    my $reverted = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };
    like($reverted, qr/original/, 'revert: file content restored to revision r1 (CORR-18)');

    # Restore so subsequent tests (if any) don't see stale state
    open($fh, '>', $test_file) or die $!;
    print $fh $orig_content;
    close($fh);
}

########################################################################
# Remove and Log_History on Deleted File
########################################################################
$vcs->remove($file2);
$vcs->commit('Remove file2');
ok(!-e $vcs->output_path($file2), 'remove: mirror file removed');

my $del_log = $vcs->log_history($file2);
ok(@$del_log > 0, 'log_history on deleted file: returns lines');
isnt($del_log->[0], '(no history yet)', 'log_history on deleted file: not (no history yet)');
like(join("\n", @$del_log), qr/Atomic batch commit/, 'log_history on deleted file: contains prior history');

# Revert deleted file from revision 3
$vcs->revert($file2, 3);
ok(-e $file2, 'revert on deleted file: restores real file');
my $reverted_file2 = do { open(my $f, '<', $file2) or die $!; local $/; <$f> };
like($reverted_file2, qr/key = val/, 'revert on deleted file: content restored');

# Note: SVN has no push_remote concept  --  svn commit IS push.
# The repository URL used at checkout time is the effective remote.

########################################################################
# Revert: Recreate Missing Parent and Clean Mirror at HEAD (CORR-14)
########################################################################
{
    my $sub_dir  = "$tracked_dir/svn_rev_dir";
    mkdir $sub_dir or die $!;
    my $sub_file = "$sub_dir/revert.conf";

    open(my $rfh, '>', $sub_file) or die $!;
    print {$rfh} "svn rev v1\n";
    close($rfh);

    $vcs->checkin($sub_file, 'SVN revert test v1');
    my $c1 = $vcs->commit('SVN revert commit v1');
    my $rev1 = $c1->{revision};

    open($rfh, '>', $sub_file) or die $!;
    print {$rfh} "svn rev v2\n";
    close($rfh);

    $vcs->checkin($sub_file, 'SVN revert test v2');
    my $c2 = $vcs->commit('SVN revert commit v2');
    my $rev2 = $c2->{revision};

    # Delete the live file and its parent directory
    unlink $sub_file or die $!;
    rmdir $sub_dir   or die $!;
    ok(!-d $sub_dir, 'svn revert: parent directory removed before revert');

    # Revert to rev1
    my $rev_err = do { local $@; eval { $vcs->revert($sub_file, $rev1) }; $@ };
    is($rev_err, '', 'revert: succeeded without error with missing parent directory');
    ok(-f $sub_file, 'revert: live file restored');

    open(my $check_fh, '<', $sub_file) or die $!;
    my $reverted_content = do { local $/; <$check_fh> };
    close($check_fh);
    is($reverted_content, "svn rev v1\n", 'revert: restored content matches v1');

    # Subversion mirror working copy must remain clean at HEAD
    my $st = $vcs->_run('svn', 'status', $vcs->output_path($sub_file));
    is($st->{stdout}, '', 'revert: svn working copy remains clean at HEAD');

    # is_dirty must be true because live file (v1) differs from HEAD (v2)
    ok($vcs->is_dirty($sub_file), 'is_dirty: true after revert because live file differs from HEAD');
}

########################################################################
# Metadata At Revision (FEAT-5)
########################################################################
{
    my $meta_file = "$output_dir/.changetrack-metadata";
    open(my $mfh, '>', $meta_file) or die "Cannot write $meta_file: $!";
    print {$mfh} qq|{"path":"/etc/demo.conf","mode":"0644","uid":1000,"gid":1000,"user":"tester","group":"users"}\n|;
    close($mfh);

    $vcs->_run('svn', 'add', $meta_file);
    my $m_c1 = $vcs->commit('Add metadata record 1');
    my $m_rev1 = $m_c1->{revision};

    open($mfh, '>', $meta_file) or die "Cannot write $meta_file: $!";
    print {$mfh} qq|{"path":"/etc/demo.conf","mode":"0600","uid":1000,"gid":1000,"user":"tester","group":"users"}\n|;
    close($mfh);

    my $m_c2 = $vcs->commit('Update metadata record 2');
    my $m_rev2 = $m_c2->{revision};

    my $rec1 = $vcs->metadata_at_revision('/etc/demo.conf', $m_rev1);
    is($rec1->{mode}, '0644', 'metadata_at_revision: retrieves mode from rev1');
    is($rec1->{user}, 'tester', 'metadata_at_revision: retrieves user from rev1');

    my $rec2 = $vcs->metadata_at_revision('/etc/demo.conf', $m_rev2);
    is($rec2->{mode}, '0600', 'metadata_at_revision: retrieves updated mode from rev2');

    is($vcs->metadata_at_revision('/etc/nonexistent', $m_rev1), undef,
        'metadata_at_revision: returns undef for untracked path');
    is($vcs->metadata_at_revision('/etc/demo.conf', '999999'), undef,
        'metadata_at_revision: returns undef for non-existent revision');
    is($vcs->metadata_at_revision('/etc/demo.conf', '-invalid'), undef,
        'metadata_at_revision: rejects revision starting with hyphen');
}

done_testing();

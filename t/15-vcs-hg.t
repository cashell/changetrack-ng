# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# 15-vcs-hg.t - Tests for vcs hg.
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

my $HG = do {
    my $found;
    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
        if (-x "$dir/hg") { $found = "$dir/hg"; last }
    }
    $found;
};
plan skip_all => 'hg not found in PATH' unless $HG;

use_ok('ChangeTrack::VCS::Mercurial');

my $output_dir  = tempdir(CLEANUP => 1);
my $tracked_dir = tempdir(CLEANUP => 1);

my $vcs = ChangeTrack::VCS::Mercurial->new(output_dir => $output_dir);
isa_ok($vcs, 'ChangeTrack::VCS::Mercurial');
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
ok(-d "$output_dir/.hg", '.hg directory created');
ok(-f "$output_dir/.hg/hgrc", 'hgrc written with username');

my $hgrc = do { open(my $f, '<', "$output_dir/.hg/hgrc") or die $!; local $/; <$f> };
like($hgrc, qr/username\s*=\s*changetrack-ng/, 'hgrc contains username');

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
like($commit_res->{revision}, qr/^[0-9a-f]{10,64}$/, 'commit: returns revision hash');
is_deeply($commit_res->{warnings}, [], 'commit: warnings empty');

my $log_r = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '--template', '{desc}\n']);
like($log_r->{stdout}, qr/Initial commit/, 'commit: appears in hg log');

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

my $log_before = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '--template', '{rev}\n']);
my @before_revs = split /\n/, $log_before->{stdout};

$vcs->commit('Atomic batch commit');

my $log_after_r = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '--template', '{rev}\n']);
my @after_revs = split /\n/, $log_after_r->{stdout};

is(scalar @after_revs, scalar @before_revs + 1, 'multiple staged files produce one atomic commit');

my $log_desc = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '--template', '{desc}\n']);
like($log_desc->{stdout}, qr/Atomic batch commit/, 'atomic commit message in log');

########################################################################
# No-Op Commit (Nothing Staged)
########################################################################
my $tip_before = run_cmd(cmd => ['hg', '-R', $output_dir, 'tip', '--template', '{rev}'])->{stdout};

my $noop_res;
$err = do { local $@; eval { $noop_res = $vcs->commit('Should not appear') }; $@ };
is($err, '', 'commit with nothing staged: no error');
is_deeply($noop_res, { committed => 0, revision => undef, warnings => [] },
    'commit with nothing staged: returns committed => 0');

my $tip_after = run_cmd(cmd => ['hg', '-R', $output_dir, 'tip', '--template', '{rev}'])->{stdout};
is($tip_before, $tip_after, 'commit with nothing staged: no new commit');

########################################################################
# Log_History
########################################################################
my $history = $vcs->log_history($test_file);
ok(@$history > 0, 'log_history: returns lines');
like(join("\n", @$history), qr/Initial commit/,      'log_history: contains first commit msg');
like(join("\n", @$history), qr/Modification commit/, 'log_history: contains second commit msg');

########################################################################
# Revert (with 'rev:node' changeset string CORR-18)
########################################################################
{
    my $orig_content = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };

    my $node_r = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '-r', '0', '--template', '{rev}:{node}']);
    my $rev_node = $node_r->{stdout};
    chomp $rev_node;

    $vcs->revert($test_file, $rev_node);

    my $reverted = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };
    like($reverted, qr/original/, 'revert: file content restored using rev:node format (CORR-18)');

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
ok(!-e $vcs->output_path($file2), 'remove: mirror file does not exist after remove');

my $del_log = $vcs->log_history($file2);
ok(@$del_log > 0, 'log_history on deleted file: returns lines');
isnt($del_log->[0], '(no history yet)', 'log_history on deleted file: not (no history yet)');
like(join("\n", @$del_log), qr/Atomic batch commit/, 'log_history on deleted file: contains prior history');

# Revert deleted file from revision 2
$vcs->revert($file2, 2);
ok(-e $file2, 'revert on deleted file: restores real file');
my $reverted_file2 = do { open(my $f, '<', $file2) or die $!; local $/; <$f> };
like($reverted_file2, qr/key = val/, 'revert on deleted file: content restored');

########################################################################
# Push_Remote: Local Clone
########################################################################
{
    my $clone_dir = tempdir(CLEANUP => 1);

    my $clone_r = run_cmd(cmd => ['hg', 'clone', $output_dir, $clone_dir]);
    unless ($clone_r->{success}) {
        diag "hg clone failed (skipping push test): $clone_r->{stderr}";
        goto DONE;
    }

    my $push_vcs = ChangeTrack::VCS::Mercurial->new(
        output_dir => $output_dir,
        options    => { push_remote => $clone_dir },
    );

    my $push_file = "$tracked_dir/push_test.conf";
    open(my $pfh, '>', $push_file) or die $!;
    print $pfh "push test content\n";
    close($pfh);

    $push_vcs->checkin($push_file, 'Push test');
    $err = do { local $@; eval { $push_vcs->commit('Push test commit') }; $@ };
    is($err, '', 'commit with push_remote: no error');

    my $remote_log = run_cmd(cmd => ['hg', '-R', $clone_dir, 'log', '--template', '{desc}\n']);
    like($remote_log->{stdout}, qr/Push test commit/, 'push_remote: commit visible in clone');
}

########################################################################
# Revert: Recreate Missing Parent and Clean Mirror at Tip (CORR-14)
########################################################################
{
    my $sub_dir  = "$tracked_dir/hg_rev_dir";
    mkdir $sub_dir or die $!;
    my $sub_file = "$sub_dir/revert.conf";

    open(my $rfh, '>', $sub_file) or die $!;
    print {$rfh} "hg rev v1\n";
    close($rfh);

    $vcs->checkin($sub_file, 'Mercurial revert test v1');
    my $c1 = $vcs->commit('Mercurial revert commit v1');
    my $rev1 = $c1->{revision};

    open($rfh, '>', $sub_file) or die $!;
    print {$rfh} "hg rev v2\n";
    close($rfh);

    $vcs->checkin($sub_file, 'Mercurial revert test v2');
    my $c2 = $vcs->commit('Mercurial revert commit v2');
    my $rev2 = $c2->{revision};

    # Delete the live file and its parent directory
    unlink $sub_file or die $!;
    rmdir $sub_dir   or die $!;
    ok(!-d $sub_dir, 'hg revert: parent directory removed before revert');

    # Revert to rev1
    my $rev_err = do { local $@; eval { $vcs->revert($sub_file, $rev1) }; $@ };
    is($rev_err, '', 'revert: succeeded without error with missing parent directory');
    ok(-f $sub_file, 'revert: live file restored');

    open(my $check_fh, '<', $sub_file) or die $!;
    my $reverted_content = do { local $/; <$check_fh> };
    close($check_fh);
    is($reverted_content, "hg rev v1\n", 'revert: restored content matches v1');

    # Mercurial mirror working copy for file must remain clean at tip
    my $st = $vcs->_hg('status', $vcs->output_path($sub_file));
    is($st->{stdout}, '', 'revert: hg working copy for file remains clean at tip');

    # is_dirty must be true because live file (v1) differs from tip (v2)
    ok($vcs->is_dirty($sub_file), 'is_dirty: true after revert because live file differs from tip');
}

########################################################################
# Metadata At Revision (FEAT-5)
########################################################################
{
    my $meta_file = "$output_dir/.changetrack-metadata";
    open(my $mfh, '>', $meta_file) or die "Cannot write $meta_file: $!";
    print {$mfh} qq|{"path":"/etc/demo.conf","mode":"0644","uid":1000,"gid":1000,"user":"tester","group":"users"}\n|;
    close($mfh);

    $vcs->_hg('add', $meta_file);
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
    is($vcs->metadata_at_revision('/etc/demo.conf', '000000000000'), undef,
        'metadata_at_revision: returns undef for non-existent revision');
    is($vcs->metadata_at_revision('/etc/demo.conf', '-invalid'), undef,
        'metadata_at_revision: rejects revision starting with hyphen');
}

########################################################################
# Push_Remote: Failure Populates Warnings (NOTIFY-4)
########################################################################
{
    my $bad_remote_vcs = ChangeTrack::VCS::Mercurial->new(
        output_dir => $output_dir,
        options    => { push_remote => '/nonexistent/path/cannot/exist' },
    );

    my $warn_file = "$tracked_dir/warn_test.conf";
    open(my $wfh, '>', $warn_file) or die $!;
    print {$wfh} "warn test content\n";
    close($wfh);

    $bad_remote_vcs->checkin($warn_file, 'Push warn test');
    my $res;
    my $warn_err = do { local $@; eval { $res = $bad_remote_vcs->commit('Push warn commit') }; $@ };
    is($warn_err, '', 'commit succeeds despite push_remote failure');
    is($res->{committed}, 1, 'commit reported committed => 1');
    ok(@{ $res->{warnings} } > 0, 'push warnings captured in returned hashref');
    like($res->{warnings}[0], qr/hg push.*failed/i, 'warning string details push failure');
}

########################################################################
# Show_At_Revision, Historical Diff, and Repo-Wide Log_History (WP 4A)
########################################################################
{
    my $hist_file = "$tracked_dir/hist_hg.conf";
    open(my $hfh, '>', $hist_file) or die $!;
    print {$hfh} "hg line one\n";
    close($hfh);
    $vcs->checkin($hist_file, 'Hist hg v1');
    my $c1 = $vcs->commit('Hist hg commit v1');
    my $hr1 = $c1->{revision};

    open($hfh, '>', $hist_file) or die $!;
    print {$hfh} "hg line two\n";
    close($hfh);
    $vcs->checkin($hist_file, 'Hist hg v2');
    my $c2 = $vcs->commit('Hist hg commit v2');
    my $hr2 = $c2->{revision};

    # Modify live file without committing
    open($hfh, '>', $hist_file) or die $!;
    print {$hfh} "hg line live\n";
    close($hfh);

    # show_at_revision on regular file (also test rev:node normalization)
    my $rn_r = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '-r', $hr1, '--template', '{rev}:{node}']);
    my $rev_node1 = $rn_r->{stdout};
    chomp $rev_node1;

    my $s1 = $vcs->show_at_revision($hist_file, $rev_node1);
    is($s1->{is_symlink}, 0, 'show_at_revision: regular file is_symlink is 0');
    is($s1->{target}, undef, 'show_at_revision: regular file target is undef');
    is($s1->{content}, "hg line one\n", 'show_at_revision: retrieves v1 content with rev:node format');

    my $s2 = $vcs->show_at_revision($hist_file, $hr2);
    is($s2->{content}, "hg line two\n", 'show_at_revision: retrieves v2 content');

    # Mirror remains clean
    my $st = $vcs->_hg('status', $vcs->output_path($hist_file));
    is($st->{stdout}, '', 'show_at_revision: hg working tree remains clean');

    # Symlink show_at_revision
    my $sym_path = "$tracked_dir/hist_hg.link";
    symlink('/etc/passwd', $sym_path) or die "symlink failed: $!";
    $vcs->checkin($sym_path, 'Hg symlink v1');
    my $sc1 = $vcs->commit('Hg symlink commit v1');
    my $sym_res = $vcs->show_at_revision($sym_path, $sc1->{revision});
    is($sym_res->{is_symlink}, 1, 'show_at_revision: symlink is_symlink is 1');
    is($sym_res->{target}, '/etc/passwd', 'show_at_revision: symlink target extracted');

    # Error cases for show_at_revision
    eval { $vcs->show_at_revision($hist_file, '000000000000deadbeef') };
    ok($@, 'show_at_revision: croaks on invalid revision');
    eval { $vcs->show_at_revision("$tracked_dir/missing.conf", $hr1) };
    ok($@, 'show_at_revision: croaks on missing path in revision');
    eval { $vcs->show_at_revision($hist_file, '-tip') };
    like($@, qr/unsafe revision/, 'show_at_revision: rejects leading hyphen');

    # 1-arg diff($path, $rev1): rev1 vs live file
    my $d1 = $vcs->diff($hist_file, $hr1);
    like(join("\n", @$d1), qr/-hg line one/,  'diff(path, rev1): shows old rev1 line');
    like(join("\n", @$d1), qr/\+hg line live/, 'diff(path, rev1): shows live line');
    $st = $vcs->_hg('status', $vcs->output_path($hist_file));
    is($st->{stdout}, '', 'diff(path, rev1): mirror restored clean');

    # 2-arg diff($path, $rev1, $rev2): rev1 vs rev2
    my $d12 = $vcs->diff($hist_file, $hr1, $hr2);
    like(join("\n", @$d12), qr/-hg line one/, 'diff(path, rev1, rev2): shows rev1 line');
    like(join("\n", @$d12), qr/\+hg line two/, 'diff(path, rev1, rev2): shows rev2 line');
    unlike(join("\n", @$d12), qr/hg line live/, 'diff(path, rev1, rev2): ignores live file');

    my $d_same = $vcs->diff($hist_file, $hr1, $hr1);
    is_deeply($d_same, [], 'diff(path, rev1, rev1): empty diff for identical revisions');

    eval { $vcs->diff($hist_file, undef, $hr2) };
    ok($@, 'diff: croaks when rev2 provided without rev1');
    eval { $vcs->diff($hist_file, '-tip') };
    like($@, qr/unsafe revision/, 'diff: rejects leading hyphen');

    # Remove hist_file and commit deletion; verify repo-wide log_history(undef)
    $vcs->remove($hist_file);
    $vcs->commit('Remove hist_hg.conf');

    my $del_show = $vcs->show_at_revision($hist_file, $hr1);
    is($del_show->{content}, "hg line one\n", 'show_at_revision: retrieves deleted file at older rev');

    my $repo_log = $vcs->log_history(undef);
    my $repo_log_str = join("\n", @$repo_log);
    like($repo_log_str, qr/Initial commit/,      'log_history(undef): includes Initial commit');
    like($repo_log_str, qr/Remove hist_hg\.conf/, 'log_history(undef): includes deletion commit');
}

DONE:
done_testing();

# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# 13-vcs-fossil.t - Tests for vcs fossil.
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

my $FOSSIL = do {
    my $found;
    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
        if (-x "$dir/fossil") { $found = "$dir/fossil"; last }
    }
    $found;
};
plan skip_all => 'fossil not found in PATH' unless $FOSSIL;

use_ok('ChangeTrack::VCS::Fossil');

my $output_dir  = tempdir(CLEANUP => 1);
my $tracked_dir = tempdir(CLEANUP => 1);

my $vcs = ChangeTrack::VCS::Fossil->new(output_dir => $output_dir);
isa_ok($vcs, 'ChangeTrack::VCS::Fossil');
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
ok(-f "$output_dir/.fslckout" || -f "$output_dir/_FOSSIL_", 'fossil checkout marker created');
ok(-f "$output_dir.fossil",  'fossil repo file created');

is(
    $vcs->_extract_invalid_utf8_path('Abandoning commit due to invalid UTF-8 in ./etc/epylog/trojans.list'),
    'etc/epylog/trojans.list',
    'extracts invalid UTF-8 path from fossil stderr'
);
is(
    $vcs->_extract_invalid_utf8_path('some other error'),
    undef,
    'returns undef when stderr does not contain invalid UTF-8 path'
);
is(
    $vcs->_merge_glob_list('*.png,*.jpg', '*.jpg'),
    '*.png,*.jpg',
    'merge_glob_list avoids duplicate entries'
);
is(
    $vcs->_merge_glob_list('*.png,*.jpg', 'etc/epylog/trojans.list'),
    '*.png,*.jpg,etc/epylog/trojans.list',
    'merge_glob_list appends new entry'
);

{
    my $partial_dir = tempdir(CLEANUP => 1);
    my $partial_repo = "$partial_dir.fossil";
    my $partial_init = run_cmd(cmd => ['fossil', 'init', $partial_repo]);
    ok($partial_init->{success}, 'manual fossil init for partial repo fixture succeeds');

    my $partial_vcs = ChangeTrack::VCS::Fossil->new(output_dir => $partial_dir);
    my $partial_err = do { local $@; eval { $partial_vcs->init }; $@ };
    is($partial_err, '', 'init reuses an existing repo file without error');
    ok($partial_vcs->is_initialized, 'partial repo becomes initialized after open');
}

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

# Untracked file: diff returns (new file) without creating mirror path
my $untracked_file = "$tracked_dir/untracked.conf";
open(my $ufh, '>', $untracked_file) or die "Cannot create: $!";
print $ufh "setting = untracked\n";
close($ufh);

my $untracked_diff = $vcs->diff($untracked_file);
is_deeply($untracked_diff, ['(new file)'], 'diff: untracked file returns (new file)');
ok(!-e $vcs->output_path($untracked_file), 'diff: untracked file does not create mirror path');

########################################################################
# Commit
########################################################################
my $commit_res;
$err = do { local $@; eval { $commit_res = $vcs->commit('Initial commit') }; $@ };
is($err, '', 'commit: no error');
is($commit_res->{committed}, 1, 'commit: returns committed => 1');
like($commit_res->{revision}, qr/^[0-9a-f]{10,64}$/, 'commit: returns revision hash');
is_deeply($commit_res->{warnings}, [], 'commit: warnings empty');

# Verify commit appears in fossil timeline
my $tl = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '5']);
like($tl->{stdout}, qr/Initial commit/, 'commit: appears in fossil timeline');

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

my $before_tl = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '20']);
my @before_lines = grep { /\S/ } split(/\n/, $before_tl->{stdout});

$vcs->commit('Atomic batch commit');

my $after_tl = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '20']);
my @after_lines = grep { /\S/ } split(/\n/, $after_tl->{stdout});

ok(scalar @after_lines > scalar @before_lines, 'multiple staged files produce one atomic commit');
like($after_tl->{stdout}, qr/Atomic batch commit/, 'atomic commit message in timeline');

########################################################################
# No-Op Commit (Nothing Staged)
########################################################################
my $tl_before_noop = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '20'])->{stdout};

my $noop_res;
$err = do { local $@; eval { $noop_res = $vcs->commit('Should not appear') }; $@ };
is($err, '', 'commit with nothing staged: no error');
is_deeply($noop_res, { committed => 0, revision => undef, warnings => [] },
    'commit with nothing staged: returns committed => 0');

my $tl_after_noop = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '20'])->{stdout};
is($tl_before_noop, $tl_after_noop, 'commit with nothing staged: no new commit');

########################################################################
# Log_History
########################################################################
my $history = $vcs->log_history($test_file);
ok(@$history > 0, 'log_history: returns lines');
like(join("\n", @$history), qr/Initial commit/,      'log_history: contains first commit msg');
like(join("\n", @$history), qr/Modification commit/, 'log_history: contains second commit msg');

########################################################################
# Remove
########################################################################
{
    my $mirror2 = $vcs->output_path($file2);
    ok(-e $mirror2, 'file2 mirror exists before remove');
    $vcs->remove($file2);
    ok(!-e $mirror2, 'remove: file2 mirror deleted');

    $err = do { local $@; eval { $vcs->commit('Remove file2') }; $@ };
    is($err, '', 'commit removal: no error');
    ok(!-e $vcs->output_path($file2), 'output_path($file2) does not exist after commit');

    my $rm_tl = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '5']);
    like($rm_tl->{stdout}, qr/Remove file2/, 'remove: removal commit appears in fossil timeline');

    my $rm_again_err = do { local $@; eval { $vcs->remove($file2) }; $@ };
    is($rm_again_err, '', 'remove: calling remove on already-removed file succeeds');
}

########################################################################
# Revert
########################################################################
{
    my $history = $vcs->log_history($test_file);
    my @revs;
    for my $line (@$history) {
        if ($line =~ /\[([0-9a-f]{10,})\]/) {
            push @revs, $1;
        }
    }
    my $first_rev = $revs[-1];
    ok(defined $first_rev && length $first_rev, 'revert: found earliest commit hash');

    $err = do { local $@; eval { $vcs->revert($test_file, $first_rev) }; $@ };
    is($err, '', 'revert: no error');

    open(my $rfh, '<', $test_file) or die "Cannot read $test_file: $!";
    my $content = do { local $/; <$rfh> };
    close($rfh);

    is($content, "setting = original\n", 'revert: file content restored to original');
}

########################################################################
# Push_Remote: Local Repo Clone
########################################################################
{
    my $remote_dir = tempdir(CLEANUP => 1);
    my $remote_repo = "$remote_dir/remote.fossil";

    # Clone the existing repo to create a remote
    my $clone_r = run_cmd(cmd => ['fossil', 'clone', "$output_dir.fossil", $remote_repo]);
    unless ($clone_r->{success}) {
        diag "fossil clone failed (skipping push test): $clone_r->{stderr}";
        goto DONE;
    }

    my $push_file = "$tracked_dir/push_test.conf";
    open(my $pfh, '>', $push_file) or die $!;
    print $pfh "push test content\n";
    close($pfh);

    # Use a fresh VCS object with push_remote wired to the cloned repo
    my $orig_vcs_push = ChangeTrack::VCS::Fossil->new(
        output_dir => $output_dir,
        options    => { push_remote => $remote_repo },
    );

    $orig_vcs_push->checkin($push_file, 'Push test');
    $err = do { local $@; eval { $orig_vcs_push->commit('Push test commit') }; $@ };
    is($err, '', 'commit with push_remote: no error');

    my $remote_tl = run_cmd(cmd => ['fossil', 'timeline', '-R', $remote_repo, '-n', '5']);
    like($remote_tl->{stdout}, qr/Push test commit/, 'push_remote: commit visible in remote repo');
}


########################################################################
# FOSSIL_HOME / HOME Environment Variable Behavior
########################################################################
{
    # Simulate systemd service environment: HOME and FOSSIL_HOME absent.
    # _run() must set FOSSIL_HOME=output_dir so fossil can find its user db.
    local $ENV{HOME};
    delete $ENV{HOME};
    local $ENV{FOSSIL_HOME};
    delete $ENV{FOSSIL_HOME};

    my $err = do { local $@; eval { $vcs->_run('fossil', 'changes') }; $@ };
    is($err, '', '_run: fossil succeeds with HOME and FOSSIL_HOME absent (systemd env)');
}

{
    # When HOME is set, _run() skips the FOSSIL_HOME override.
    local $ENV{HOME}       = ($ENV{HOME} // $output_dir);
    local $ENV{FOSSIL_HOME};
    delete $ENV{FOSSIL_HOME};

    my $err = do { local $@; eval { $vcs->_run('fossil', 'changes') }; $@ };
    is($err, '', '_run: fossil succeeds when HOME is present');
}

{
    # When FOSSIL_HOME is already set, _run() must not override it.
    my $custom_fossil_home = tempdir(CLEANUP => 1);
    local $ENV{HOME};
    delete $ENV{HOME};
    local $ENV{FOSSIL_HOME} = $custom_fossil_home;

    my $err = do { local $@; eval { $vcs->_run('fossil', 'changes') }; $@ };
    is($err, '', '_run: fossil succeeds with pre-set FOSSIL_HOME');
    is($ENV{FOSSIL_HOME}, $custom_fossil_home, '_run: pre-set FOSSIL_HOME not overridden');
}

########################################################################
# Revert: Recreate Missing Parent and Clean Checkout at Tip (CORR-14)
########################################################################
{
    my $sub_dir  = "$tracked_dir/fossil_rev_dir";
    mkdir $sub_dir or die $!;
    my $sub_file = "$sub_dir/revert.conf";

    open(my $rfh, '>', $sub_file) or die $!;
    print {$rfh} "fossil rev v1\n";
    close($rfh);

    $vcs->checkin($sub_file, 'Fossil revert test v1');
    my $c1 = $vcs->commit('Fossil revert commit v1');
    my $rev1 = $c1->{revision};

    open($rfh, '>', $sub_file) or die $!;
    print {$rfh} "fossil rev v2\n";
    close($rfh);

    $vcs->checkin($sub_file, 'Fossil revert test v2');
    my $c2 = $vcs->commit('Fossil revert commit v2');
    my $rev2 = $c2->{revision};

    # Delete the live file and its parent directory
    unlink $sub_file or die $!;
    rmdir $sub_dir   or die $!;
    ok(!-d $sub_dir, 'fossil revert: parent directory removed before revert');

    # Revert to rev1
    my $rev_err = do { local $@; eval { $vcs->revert($sub_file, $rev1) }; $@ };
    is($rev_err, '', 'revert: succeeded without error with missing parent directory');
    ok(-f $sub_file, 'revert: live file restored');

    open(my $check_fh, '<', $sub_file) or die $!;
    my $reverted_content = do { local $/; <$check_fh> };
    close($check_fh);
    is($reverted_content, "fossil rev v1\n", 'revert: restored content matches v1');

    # Fossil checkout must remain clean at tip
    my $changes = $vcs->_run('fossil', 'changes');
    is($changes->{stdout}, '', 'revert: fossil checkout remains clean at tip');

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

    $vcs->_run('fossil', 'add', '--', '.changetrack-metadata');
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
    my $bad_remote_vcs = ChangeTrack::VCS::Fossil->new(
        output_dir => $output_dir,
        options    => { push_remote => '/nonexistent/path/cannot/exist.fossil' },
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
    like($res->{warnings}[0], qr/fossil push.*failed/i, 'warning string details push failure');
}

########################################################################
# Show_At_Revision, Historical Diff, and Repo-Wide Log_History (WP 4A)
########################################################################
{
    my $hist_file = "$tracked_dir/hist_fossil.conf";
    open(my $hfh, '>', $hist_file) or die $!;
    print {$hfh} "fossil line one\n";
    close($hfh);
    $vcs->checkin($hist_file, 'Hist fossil v1');
    my $c1 = $vcs->commit('Hist fossil commit v1');
    my $hr1 = $c1->{revision};

    open($hfh, '>', $hist_file) or die $!;
    print {$hfh} "fossil line two longer\n";
    close($hfh);
    $vcs->checkin($hist_file, 'Hist fossil v2');
    my $c2 = $vcs->commit('Hist fossil commit v2');
    my $hr2 = $c2->{revision};

    # Modify live file without committing
    open($hfh, '>', $hist_file) or die $!;
    print {$hfh} "fossil line live modified\n";
    close($hfh);

    # show_at_revision on regular file
    my $s1 = $vcs->show_at_revision($hist_file, $hr1);
    is($s1->{is_symlink}, 0, 'show_at_revision: regular file is_symlink is 0');
    is($s1->{target}, undef, 'show_at_revision: regular file target is undef');
    is($s1->{content}, "fossil line one\n", 'show_at_revision: retrieves v1 content');

    my $s2 = $vcs->show_at_revision($hist_file, $hr2);
    is($s2->{content}, "fossil line two longer\n", 'show_at_revision: retrieves v2 content');

    # Checkout remains clean
    my $ch = $vcs->_run('fossil', 'changes');
    is($ch->{stdout}, '', 'show_at_revision: fossil checkout remains clean');

    # Symlink show_at_revision
    my $sym_path = "$tracked_dir/hist_fossil.link";
    symlink('/etc/nsswitch.conf', $sym_path) or die "symlink failed: $!";
    $vcs->checkin($sym_path, 'Fossil symlink v1');
    my $sc1 = $vcs->commit('Fossil symlink commit v1');
    my $sym_res = $vcs->show_at_revision($sym_path, $sc1->{revision});
    is($sym_res->{is_symlink}, 1, 'show_at_revision: symlink is_symlink is 1');
    is($sym_res->{target}, '/etc/nsswitch.conf', 'show_at_revision: symlink target extracted');

    # Error cases for show_at_revision
    eval { $vcs->show_at_revision($hist_file, 'deadbeefdeadbeef') };
    ok($@, 'show_at_revision: croaks on invalid revision');
    eval { $vcs->show_at_revision("$tracked_dir/missing.conf", $hr1) };
    ok($@, 'show_at_revision: croaks on missing path in revision');
    eval { $vcs->show_at_revision($hist_file, '-tip') };
    like($@, qr/unsafe revision/, 'show_at_revision: rejects leading hyphen');

    # 1-arg diff($path, $rev1): rev1 vs live file
    my $d1 = $vcs->diff($hist_file, $hr1);
    like(join("\n", @$d1), qr/-fossil line one/,           'diff(path, rev1): shows old rev1 line');
    like(join("\n", @$d1), qr/\+fossil line live modified/, 'diff(path, rev1): shows live line');
    $ch = $vcs->_run('fossil', 'changes');
    is($ch->{stdout}, '', 'diff(path, rev1): checkout restored clean');

    # 2-arg diff($path, $rev1, $rev2): rev1 vs rev2
    my $d12 = $vcs->diff($hist_file, $hr1, $hr2);
    like(join("\n", @$d12), qr/-fossil line one/,        'diff(path, rev1, rev2): shows rev1 line');
    like(join("\n", @$d12), qr/\+fossil line two longer/, 'diff(path, rev1, rev2): shows rev2 line');
    unlike(join("\n", @$d12), qr/fossil line live/,      'diff(path, rev1, rev2): ignores live file');

    my $d_same = $vcs->diff($hist_file, $hr1, $hr1);
    is_deeply($d_same, [], 'diff(path, rev1, rev1): empty diff for identical revisions');

    eval { $vcs->diff($hist_file, undef, $hr2) };
    ok($@, 'diff: croaks when rev2 provided without rev1');
    eval { $vcs->diff($hist_file, '-tip') };
    like($@, qr/unsafe revision/, 'diff: rejects leading hyphen');

    # Remove hist_file and commit deletion; verify repo-wide log_history(undef) and dir fallback
    $vcs->remove($hist_file);
    $vcs->commit('Remove hist_fossil.conf');

    my $del_show = $vcs->show_at_revision($hist_file, $hr1);
    is($del_show->{content}, "fossil line one\n", 'show_at_revision: retrieves deleted file at older rev');

    my $repo_log = $vcs->log_history(undef);
    my $repo_log_str = join("\n", @$repo_log);
    like($repo_log_str, qr/Initial commit/,          'log_history(undef): includes Initial commit');
    like($repo_log_str, qr/Remove hist_fossil\.conf/, 'log_history(undef): includes deletion commit');

    my $dir_log = $vcs->log_history($tracked_dir);
    like(join("\n", @$dir_log), qr/Initial commit/, 'log_history(dir): falls back to timeline for directory');
}

DONE:
done_testing();

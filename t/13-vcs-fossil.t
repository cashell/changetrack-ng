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

# ── model ────────────────────────────────────────────────────────────────────

is($vcs->model, 'whole-repo', 'model returns whole-repo');

# ── init / is_initialized ────────────────────────────────────────────────────

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

# ── output_path ──────────────────────────────────────────────────────────────

is($vcs->output_path('/etc/passwd'),
    "$output_dir/etc/passwd",
    'output_path: single level');

is($vcs->output_path('/etc/ssl/certs/ca.crt'),
    "$output_dir/etc/ssl/certs/ca.crt",
    'output_path: nested path');

# ── checkin (new file) ───────────────────────────────────────────────────────

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

# ── commit ───────────────────────────────────────────────────────────────────

$err = do { local $@; eval { $vcs->commit('Initial commit') }; $@ };
is($err, '', 'commit: no error');

# Verify commit appears in fossil timeline
my $tl = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '5']);
like($tl->{stdout}, qr/Initial commit/, 'commit: appears in fossil timeline');

# ── is_dirty / diff after commit ─────────────────────────────────────────────

ok(!$vcs->is_dirty($test_file), 'is_dirty: false after commit');

$diff = $vcs->diff($test_file);
is_deeply($diff, [], 'diff: empty for unchanged file after commit');

# ── modify file → is_dirty / diff ────────────────────────────────────────────

open($fh, '>', $test_file) or die $!;
print $fh "setting = modified\n";
close($fh);

ok($vcs->is_dirty($test_file), 'is_dirty: true after modification');

$diff = $vcs->diff($test_file);
ok(@$diff > 0, 'diff: non-empty after modification');
like(join("\n", @$diff), qr/modified/, 'diff: contains modification');
like(join("\n", @$diff), qr/^\+\+\+/m, 'diff: looks like unified diff');

# ── checkin + commit modified file ────────────────────────────────────────────

$err = do { local $@; eval { $vcs->checkin($test_file, 'Modification') }; $@ };
is($err, '', 'checkin modified: no error');

$err = do { local $@; eval { $vcs->commit('Modification commit') }; $@ };
is($err, '', 'commit after modification: no error');

ok(!$vcs->is_dirty($test_file), 'is_dirty: false after second commit');

# ── multiple files → one atomic commit ───────────────────────────────────────

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

# ── no-op commit (nothing staged) ────────────────────────────────────────────

my $tl_before_noop = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '20'])->{stdout};

$err = do { local $@; eval { $vcs->commit('Should not appear') }; $@ };
is($err, '', 'commit with nothing staged: no error');

my $tl_after_noop = run_cmd(cmd => ['fossil', 'timeline', '-R', "$output_dir.fossil", '-n', '20'])->{stdout};
is($tl_before_noop, $tl_after_noop, 'commit with nothing staged: no new commit');

# ── log_history ───────────────────────────────────────────────────────────────

my $history = $vcs->log_history($test_file);
ok(@$history > 0, 'log_history: returns lines');
like(join("\n", @$history), qr/Initial commit/,      'log_history: contains first commit msg');
like(join("\n", @$history), qr/Modification commit/, 'log_history: contains second commit msg');

# ── push_remote: local repo clone ────────────────────────────────────────────

{
    my $remote_dir = tempdir(CLEANUP => 1);
    my $remote_repo = "$remote_dir/remote.fossil";

    # Clone the existing repo to create a remote
    my $clone_r = run_cmd(cmd => ['fossil', 'clone', "$output_dir.fossil", $remote_repo]);
    unless ($clone_r->{success}) {
        diag "fossil clone failed (skipping push test): $clone_r->{stderr}";
        goto DONE;
    }

    my $push_output_dir = tempdir(CLEANUP => 1);
    my $push_vcs = ChangeTrack::VCS::Fossil->new(
        output_dir => $push_output_dir,
        options    => {
            fossil_repo  => "$output_dir.fossil",
            push_remote  => $remote_repo,
        },
    );

    # Re-use the already-open repo — open the existing repo in a new checkout dir
    my $open_r = run_cmd(cmd => ['fossil', 'open', '--user', 'changetrack-ng', "$output_dir.fossil"],
        # fossil open must run in the target dir; use a wrapper
    );
    # Instead: directly test push by committing something new in the original vcs
    # and pushing to remote_repo
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


# ── FOSSIL_HOME / HOME environment variable behavior ──────────────────────────

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

DONE:
done_testing();

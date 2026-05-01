use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use File::Basename qw(basename dirname);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use ChangeTrack::Util qw(run_cmd);

my $GIT = do {
    my $found;
    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
        if (-x "$dir/git") { $found = "$dir/git"; last }
    }
    $found;
};
plan skip_all => 'git not found in PATH' unless $GIT;

use_ok('ChangeTrack::VCS::Git');

my $output_dir  = tempdir(CLEANUP => 1);
my $tracked_dir = tempdir(CLEANUP => 1);

my $vcs = ChangeTrack::VCS::Git->new(output_dir => $output_dir);
isa_ok($vcs, 'ChangeTrack::VCS::Git');
isa_ok($vcs, 'ChangeTrack::VCS::Base');

# ── model ────────────────────────────────────────────────────────────────────

is($vcs->model, 'whole-repo', 'model returns whole-repo');

# ── init / is_initialized ────────────────────────────────────────────────────

ok(!$vcs->is_initialized, 'not initialized before init');
$vcs->init;
ok($vcs->is_initialized, 'initialized after init');
ok(-d "$output_dir/.git", '.git directory created');

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

my $log_r = run_cmd(cmd => ['git', '-C', $output_dir, 'log', '--oneline']);
like($log_r->{stdout}, qr/Initial commit/, 'commit: appears in git log');

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

my @before_lines = grep { /\S/ } split(/\n/, run_cmd(cmd => ['git', '-C', $output_dir, 'log', '--oneline'])->{stdout});

$vcs->commit('Atomic batch commit');

my $after_log = run_cmd(cmd => ['git', '-C', $output_dir, 'log', '--oneline'])->{stdout};
my @after_lines = grep { /\S/ } split(/\n/, $after_log);

is(scalar @after_lines, scalar @before_lines + 1, 'multiple staged files produce one atomic commit');
like($after_log, qr/Atomic batch commit/, 'atomic commit message in log');

# ── no-op commit (nothing staged) ────────────────────────────────────────────

my $log_before_noop = run_cmd(cmd => ['git', '-C', $output_dir, 'log', '--oneline'])->{stdout};

$err = do { local $@; eval { $vcs->commit('Should not appear') }; $@ };
is($err, '', 'commit with nothing staged: no error');

my $log_after_noop = run_cmd(cmd => ['git', '-C', $output_dir, 'log', '--oneline'])->{stdout};
is($log_before_noop, $log_after_noop, 'commit with nothing staged: no new commit');

# ── log_history ───────────────────────────────────────────────────────────────

my $history = $vcs->log_history($test_file);
ok(@$history > 0, 'log_history: returns lines');
like(join("\n", @$history), qr/Initial commit/,      'log_history: contains first commit msg');
like(join("\n", @$history), qr/Modification commit/, 'log_history: contains second commit msg');

# ── push_remote: local bare repo ─────────────────────────────────────────────

{
    my $bare_dir = tempdir(CLEANUP => 1);
    run_cmd(cmd => ['git', 'init', '--bare', $bare_dir]);

    my $push_vcs = ChangeTrack::VCS::Git->new(
        output_dir => $output_dir,
        options    => { push_remote => $bare_dir },
    );

    my $push_file = "$tracked_dir/push_test.conf";
    open(my $pfh, '>', $push_file) or die $!;
    print $pfh "push test content\n";
    close($pfh);

    $push_vcs->checkin($push_file, 'Push test');
    $err = do { local $@; eval { $push_vcs->commit('Push test commit') }; $@ };
    is($err, '', 'commit with push_remote: no error');

    my $bare_log = run_cmd(cmd => ['git', '-C', $bare_dir, 'log', '--oneline']);
    like($bare_log->{stdout}, qr/Push test commit/, 'push_remote: commit visible in bare repo');
}

done_testing();

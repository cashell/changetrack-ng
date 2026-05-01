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

# ── model ────────────────────────────────────────────────────────────────────

is($vcs->model, 'whole-repo', 'model returns whole-repo');

# ── init / is_initialized ────────────────────────────────────────────────────

ok(!$vcs->is_initialized, 'not initialized before init');
$vcs->init;
ok($vcs->is_initialized, 'initialized after init');
ok(-d "$output_dir/.hg", '.hg directory created');
ok(-f "$output_dir/.hg/hgrc", 'hgrc written with username');

my $hgrc = do { open(my $f, '<', "$output_dir/.hg/hgrc") or die $!; local $/; <$f> };
like($hgrc, qr/username\s*=\s*changetrack-ng/, 'hgrc contains username');

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

my $log_r = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '--template', '{desc}\n']);
like($log_r->{stdout}, qr/Initial commit/, 'commit: appears in hg log');

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

my $log_before = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '--template', '{rev}\n']);
my @before_revs = split /\n/, $log_before->{stdout};

$vcs->commit('Atomic batch commit');

my $log_after_r = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '--template', '{rev}\n']);
my @after_revs = split /\n/, $log_after_r->{stdout};

is(scalar @after_revs, scalar @before_revs + 1, 'multiple staged files produce one atomic commit');

my $log_desc = run_cmd(cmd => ['hg', '-R', $output_dir, 'log', '--template', '{desc}\n']);
like($log_desc->{stdout}, qr/Atomic batch commit/, 'atomic commit message in log');

# ── no-op commit (nothing staged) ────────────────────────────────────────────

my $tip_before = run_cmd(cmd => ['hg', '-R', $output_dir, 'tip', '--template', '{rev}'])->{stdout};

$err = do { local $@; eval { $vcs->commit('Should not appear') }; $@ };
is($err, '', 'commit with nothing staged: no error');

my $tip_after = run_cmd(cmd => ['hg', '-R', $output_dir, 'tip', '--template', '{rev}'])->{stdout};
is($tip_before, $tip_after, 'commit with nothing staged: no new commit');

# ── log_history ───────────────────────────────────────────────────────────────

my $history = $vcs->log_history($test_file);
ok(@$history > 0, 'log_history: returns lines');
like(join("\n", @$history), qr/Initial commit/,      'log_history: contains first commit msg');
like(join("\n", @$history), qr/Modification commit/, 'log_history: contains second commit msg');

# ── push_remote: local clone ──────────────────────────────────────────────────

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

DONE:
done_testing();

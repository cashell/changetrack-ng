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

# ── model ────────────────────────────────────────────────────────────────────

is($vcs->model, 'whole-repo', 'model returns whole-repo');

# ── init / is_initialized ────────────────────────────────────────────────────

ok(!$vcs->is_initialized, 'not initialized before init');
$vcs->init;
ok($vcs->is_initialized, 'initialized after init');
ok(-d "$output_dir/.svn", '.svn directory created in working copy');
ok(-d "$output_dir-svnrepo", 'svn repository created');

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

my $log_r = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"]);
like($log_r->{stdout}, qr/Initial commit/, 'commit: appears in svn log');

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

my $log_before = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"]);
my @before_revs = ($log_before->{stdout} =~ /^r\d+\s/gm);

$vcs->commit('Atomic batch commit');

my $log_after = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"]);
my @after_revs = ($log_after->{stdout} =~ /^r\d+\s/gm);

is(scalar @after_revs, scalar @before_revs + 1, 'multiple staged files produce one atomic commit');
like($log_after->{stdout}, qr/Atomic batch commit/, 'atomic commit message in log');

# ── no-op commit (nothing staged) ────────────────────────────────────────────

my $log_before_noop = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"])->{stdout};

$err = do { local $@; eval { $vcs->commit('Should not appear') }; $@ };
is($err, '', 'commit with nothing staged: no error');

my $log_after_noop = run_cmd(cmd => ['svn', 'log', "file://$output_dir-svnrepo"])->{stdout};
is($log_before_noop, $log_after_noop, 'commit with nothing staged: no new commit');

# ── log_history ───────────────────────────────────────────────────────────────

my $history = $vcs->log_history($test_file);
ok(@$history > 0, 'log_history: returns lines');
like(join("\n", @$history), qr/Initial commit/,      'log_history: contains first commit msg');
like(join("\n", @$history), qr/Modification commit/, 'log_history: contains second commit msg');

# ── revert ───────────────────────────────────────────────────────────────────

{
    my $orig_content = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };

    $vcs->revert($test_file, 1);

    my $reverted = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };
    like($reverted, qr/original/, 'revert: file content restored to revision 1');

    # Restore so subsequent tests (if any) don't see stale state
    open($fh, '>', $test_file) or die $!;
    print $fh $orig_content;
    close($fh);
}

# Note: SVN has no push_remote concept — svn commit IS push.
# The repository URL used at checkout time is the effective remote.

done_testing();

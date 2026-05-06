use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
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

use_ok('ChangeTrack::Runner');

my $output_dir  = tempdir(CLEANUP => 1);
my $tracked_dir = tempdir(CLEANUP => 1);
my $bin         = File::Spec->catfile($RealBin, '..', 'bin', 'changetrack-ng');

# ── Config helper ─────────────────────────────────────────────────────────────

sub write_config {
    my (@track_lines) = @_;
    my ($cfh, $cpath) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $output_dir\n\n[track]\n";
    print $cfh "$_\n" for @track_lines;
    close($cfh);
    return $cpath;
}

# ── Setup: tracked file + initial committed state ─────────────────────────────

my $test_file = "$tracked_dir/test.conf";
open(my $fh, '>', $test_file) or die $!;
print $fh "color = blue\n";
close($fh);
chmod(0644, $test_file);

my $cfg = write_config($test_file);

# First run commits the initial state
{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $report = $runner->run;
    ok($report->has_changes, 'setup: initial run detected new file');
}

# Modify and commit a second revision
open($fh, '>', $test_file) or die $!;
print $fh "color = red\n";
close($fh);

{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $report = $runner->run;
    ok($report->has_changes, 'setup: second run detected modification');
}

# File is now clean (both runs committed their state)

# ── status: clean working state ───────────────────────────────────────────────

{
    my $runner  = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $changed = $runner->status;
    is(scalar @$changed, 0, 'status: empty when working copy matches committed state');
}

# Modify the file without running (creates a dirty state)
open($fh, '>', $test_file) or die $!;
print $fh "color = green\n";
close($fh);

{
    my $runner  = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $changed = $runner->status;
    is(scalar @$changed, 1, 'status: one entry when file is modified');
    is($changed->[0]{path}, $test_file, 'status: correct path reported');
    ok(@{ $changed->[0]{diff} } > 0, 'status: diff lines present');
}

# ── diff_path: single file ────────────────────────────────────────────────────

{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $diffs  = $runner->diff_path($test_file);
    ok(exists $diffs->{$test_file}, 'diff_path(file): key present');
    ok(@{ $diffs->{$test_file} } > 0, 'diff_path(file): diff lines returned');
    like(join("\n", @{ $diffs->{$test_file} }), qr/green/, 'diff_path(file): contains new content');
    like(join("\n", @{ $diffs->{$test_file} }), qr/^\+\+\+/m, 'diff_path(file): unified diff format');
}

# ── diff_path: all files (undef path) ────────────────────────────────────────

{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $diffs  = $runner->diff_path(undef);
    ok(exists $diffs->{$test_file}, 'diff_path(undef): dirty file appears in result');
    ok(@{ $diffs->{$test_file} } > 0, 'diff_path(undef): diff lines present');
}

# ── log_path: single file ────────────────────────────────────────────────────

{
    my $runner  = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $logs    = $runner->log_path($test_file);
    ok(exists $logs->{$test_file}, 'log_path(file): key present');
    ok(@{ $logs->{$test_file} } > 0, 'log_path(file): log lines returned');
    # At least two commits should appear in log
    my $joined = join("\n", @{ $logs->{$test_file} });
    like($joined, qr/changetrack-ng run/, 'log_path(file): commit messages in log');
}

# ── log_path: all files (undef path) ─────────────────────────────────────────

{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $logs   = $runner->log_path(undef);
    ok(exists $logs->{$test_file}, 'log_path(undef): tracked file appears in result');
    ok(@{ $logs->{$test_file} } > 0, 'log_path(undef): log lines present');
}

# ── revert_path ───────────────────────────────────────────────────────────────

{
    # Commit the current green state first so revert has a clean base
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    $runner->run;  # commits "color = green"

    chmod(0600, $test_file) or die $!;
    my $before_mode = (stat($test_file))[2] & 07777;
    is($before_mode, 0600, 'revert setup: mode set to 0600 before revert');

    my $current = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };
    like($current, qr/green/, 'revert setup: current content is green');

    # Revert to HEAD~1 (which had "color = red")
    $runner->revert_path($test_file, 'HEAD~1');

    my $reverted = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };
    like($reverted, qr/red/, 'revert_path: file content restored to HEAD~1');

    my $after_mode = (stat($test_file))[2] & 07777;
    is($after_mode, $before_mode, 'revert_path: preserves existing mode on target file');
}

# ── CLI: status exit codes ────────────────────────────────────────────────────

# First commit the reverted state so status starts clean
{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    $runner->run;
}

# CLI status should exit 0 when clean
{
    my $rc = system($^X, $bin, '--config', $cfg, '-q', 'status');
    is($rc >> 8, 0, 'CLI status: exits 0 when clean');
}

# Dirty the file, CLI status should exit 1
open($fh, '>', $test_file) or die $!;
print $fh "color = purple\n";
close($fh);

{
    my $rc = system($^X, $bin, '--config', $cfg, '-q', 'status');
    is($rc >> 8, 1, 'CLI status: exits 1 when dirty');
}

# ── CLI: run --dry-run (no commit, no metadata persistence) ─────────────────

{
    # Capture current committed content (still red from setup history),
    # then make an uncommitted change and dry-run.
    open(my $fh_in, '<', $test_file) or die $!;
    my $before = do { local $/; <$fh_in> };
    close($fh_in);

    open(my $fh_out, '>', $test_file) or die $!;
    print $fh_out "color = cyan\n";
    close($fh_out);

    my $rc = system($^X, $bin, '--config', $cfg, '--dry-run', '-q', 'run');
    is($rc >> 8, 0, 'CLI run --dry-run: exits 0');

    # A subsequent status should still show the file as dirty because dry-run
    # does not commit or persist metadata state.
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $changed = $runner->status;
    ok(@$changed >= 1, 'CLI run --dry-run: leaves working state unchanged');
}

# ── CLI: diff ─────────────────────────────────────────────────────────────────

{
    my $output = `$^X $bin --config $cfg -q diff \Q$test_file\E 2>&1`;
    like($output, qr/purple/, 'CLI diff <path>: shows modification in output');
}

# ── CLI: log ─────────────────────────────────────────────────────────────────

{
    my $output = `$^X $bin --config $cfg -q log \Q$test_file\E 2>&1`;
    like($output, qr/changetrack-ng run/, 'CLI log <path>: shows commit history');
}

# ── CLI: revert --force ───────────────────────────────────────────────────────

{
    # Commit the purple state so we have something to revert from
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    $runner->run;

    # revert HEAD~1 with --force (no prompt)
    my $rc = system($^X, $bin, '--config', $cfg, '--force', 'revert', $test_file, 'HEAD~1');
    is($rc >> 8, 0, 'CLI revert --force: exits 0');

    my $reverted = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };
    unlike($reverted, qr/purple/, 'CLI revert --force: file content changed');
}

# ── CLI: revert confirmation prompt (abort) ───────────────────────────────────

{
    # Answer 'n' to the prompt — file should be unchanged
    my $before = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };

    open(my $proc, '|-',
        $^X, $bin, '--config', $cfg, 'revert', $test_file, 'HEAD')
        or die "cannot open process: $!";
    print $proc "n\n";
    close($proc);
    my $rc = $? >> 8;

    my $after = do { open(my $f, '<', $test_file) or die $!; local $/; <$f> };
    is($before, $after, 'CLI revert: file unchanged when user answers n');
    isnt($rc, 0, 'CLI revert: non-zero exit when aborted');
}

# ── CLI: revert symlink target end-to-end ─────────────────────────────────────

{
    my $target_a = "$tracked_dir/target-a.txt";
    my $target_b = "$tracked_dir/target-b.txt";
    my $link     = "$tracked_dir/link.conf";

    open(my $fha, '>', $target_a) or die $!;
    print $fha "A\n";
    close($fha);
    open(my $fhb, '>', $target_b) or die $!;
    print $fhb "B\n";
    close($fhb);

    unlink $link if -e $link || -l $link;
    symlink($target_a, $link) or die "cannot create symlink: $!";

    my $cfg2 = write_config($link);
    my $runner = ChangeTrack::Runner->new(config => $cfg2, quiet => 1);
    $runner->run; # commit link -> target_a

    unlink $link or die $!;
    symlink($target_b, $link) or die "cannot switch symlink target: $!";
    $runner->run; # commit link -> target_b

    my $cur = readlink($link);
    is($cur, $target_b, 'symlink setup: current target is target_b');

    my $rc = system($^X, $bin, '--config', $cfg2, '--force', 'revert', $link, 'HEAD~1');
    is($rc >> 8, 0, 'CLI revert symlink --force: exits 0');

    my $rev = readlink($link);
    is($rev, $target_a, 'CLI revert symlink: target restored to previous revision');
}

done_testing();

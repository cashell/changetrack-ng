# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# 16-subcommands.t - Tests for subcommands.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use IPC::Open3;
use Symbol qw(gensym);
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

sub run_cli_capture {
    my (@args) = @_;
    my ($in, $out_fh);
    my $err_fh = gensym;
    my $pid = open3($in, $out_fh, $err_fh, $^X, $bin, @args);
    close($in);
    my $stdout = do { local $/; <$out_fh> } // '';
    my $stderr = do { local $/; <$err_fh> } // '';
    waitpid($pid, 0);
    return ($? >> 8, $stdout, $stderr);
}

########################################################################
# Config Helper
########################################################################
sub write_config {
    my (@track_lines) = @_;
    my ($cfh, $cpath) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $output_dir\n\n[track]\n";
    print $cfh "$_\n" for @track_lines;
    close($cfh);
    return $cpath;
}

########################################################################
# Setup: Tracked File + Initial Committed State
########################################################################
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

########################################################################
# Status: Clean Working State
########################################################################
{
    my $runner  = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $changed = $runner->status;
    is(scalar @$changed, 0, 'status: empty when working copy matches committed state');
}

# diff_path on a clean file: fast-path returns empty diff without touching VCS
{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $diffs  = $runner->diff_path($test_file);
    ok(exists $diffs->{$test_file}, 'diff_path(file): key present for clean file');
    is(scalar @{ $diffs->{$test_file} }, 0, 'diff_path(file): empty diff for clean file');
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

########################################################################
# Diff_Path: Single File
########################################################################
{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $diffs  = $runner->diff_path($test_file);
    ok(exists $diffs->{$test_file}, 'diff_path(file): key present');
    ok(@{ $diffs->{$test_file} } > 0, 'diff_path(file): diff lines returned');
    like(join("\n", @{ $diffs->{$test_file} }), qr/green/, 'diff_path(file): contains new content');
    like(join("\n", @{ $diffs->{$test_file} }), qr/^\+\+\+/m, 'diff_path(file): unified diff format');
}

########################################################################
# Diff_Path: All Files (Undef Path)
########################################################################
{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $diffs  = $runner->diff_path(undef);
    ok(exists $diffs->{$test_file}, 'diff_path(undef): dirty file appears in result');
    ok(@{ $diffs->{$test_file} } > 0, 'diff_path(undef): diff lines present');
}

########################################################################
# Log_Path: Single File
########################################################################
{
    my $runner  = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $logs    = $runner->log_path($test_file);
    ok(exists $logs->{$test_file}, 'log_path(file): key present');
    ok(@{ $logs->{$test_file} } > 0, 'log_path(file): log lines returned');
    # At least two commits should appear in log
    my $joined = join("\n", @{ $logs->{$test_file} });
    like($joined, qr/changetrack-ng run/, 'log_path(file): commit messages in log');
}

########################################################################
# Log_Path: All Files (Undef Path)
########################################################################
{
    my $runner = ChangeTrack::Runner->new(config => $cfg, quiet => 1);
    my $logs   = $runner->log_path(undef);
    ok(exists $logs->{'(repository)'}, 'log_path(undef): repository key present');
    ok(@{ $logs->{'(repository)'} } > 0, 'log_path(undef): log lines present');
    like(join("\n", @{ $logs->{'(repository)'} }), qr/changetrack-ng run/,
        'log_path(undef): commit messages in repo-wide log');
}

########################################################################
# Revert_Path
########################################################################
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
    is($after_mode, 0644, 'revert_path: restores historical mode from target revision');
}

########################################################################
# CLI: Status Exit Codes
########################################################################
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

########################################################################
# CLI: Run --Dry-Run (No Commit, No Metadata Persistence)
########################################################################
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

########################################################################
# CLI: Diff
########################################################################
# Reset file to purple and commit so diff test has expected state
open($fh, '>', $test_file) or die $!;
print $fh "color = purple\n";
close($fh);

{
    my $output = `$^X $bin --config $cfg -q diff \Q$test_file\E 2>&1`;
    like($output, qr/purple/, 'CLI diff <path>: shows modification in output');
}

########################################################################
# CLI: Log
########################################################################
{
    my $output = `$^X $bin --config $cfg -q log \Q$test_file\E 2>&1`;
    like($output, qr/changetrack-ng run/, 'CLI log <path>: shows commit history');
}

########################################################################
# CLI: Revert --Force
########################################################################
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

########################################################################
# CLI: Revert Confirmation Prompt (Abort)
########################################################################
{
    # Answer 'n' to the prompt  --  file should be unchanged
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

########################################################################
# CLI: Revert Symlink Target End-To-End
########################################################################
{
    SKIP: {
        my $can_symlink = eval { symlink('', ''); 1 };
        skip 'symlink creation not available on this platform/user', 3 unless $can_symlink;

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
}

########################################################################
# Status Fast-Path: Only Changed File Surfaces When Multiple Are Tracked
########################################################################
{
    my $file_a = "$tracked_dir/alpha.conf";
    my $file_b = "$tracked_dir/beta.conf";
    open(my $fha, '>', $file_a) or die $!; print $fha "a = 1\n"; close($fha);
    open(my $fhb, '>', $file_b) or die $!; print $fhb "b = 1\n"; close($fhb);
    chmod(0644, $_) for ($file_a, $file_b);

    my $cfg2 = write_config($file_a, $file_b);
    { ChangeTrack::Runner->new(config => $cfg2, quiet => 1)->run; }

    # Modify only file_a with different-length content so size change is detectable
    # even if mtime hasn't advanced (same-second write on fast systems).
    open(my $fha2, '>', $file_a) or die $!; print $fha2 "a = 2\na = modified\n"; close($fha2);

    my $runner  = ChangeTrack::Runner->new(config => $cfg2, quiet => 1);
    my $changed = $runner->status;
    is(scalar @$changed, 1, 'status fast-path: only modified file appears (unchanged file skipped)');
    is($changed->[0]{path}, $file_a, 'status fast-path: correct file identified as changed');
}

########################################################################
# Status: Metadata-Only Change (chmod)
########################################################################
{
    my $sub_out = tempdir(CLEANUP => 1);
    my $meta_file = "$tracked_dir/meta_test.conf";
    open(my $mfh, '>', $meta_file) or die $!;
    print $mfh "key = value\n";
    close($mfh);
    chmod(0644, $meta_file);

    my ($cfh, $meta_cfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $sub_out\n\n[track]\n$meta_file\n";
    close($cfh);

    ChangeTrack::Runner->new(config => $meta_cfg, quiet => 1)->run;

    # Change mode only (no content change)
    chmod(0755, $meta_file);

    my $runner  = ChangeTrack::Runner->new(config => $meta_cfg, quiet => 1);
    my $changed = $runner->status;
    is(scalar @$changed, 1, 'status: reports metadata-only change');
    is($changed->[0]{path}, $meta_file, 'status: correct file reported for chmod');
    like(join("\n", @{ $changed->[0]{diff} }), qr/^\(meta: mode /, 'status: diff contains (meta: mode ...)');
}

########################################################################
# Status and Diff_Path: File Truncated to 0 Bytes
########################################################################
{
    my $sub_out = tempdir(CLEANUP => 1);
    my $trunc_file = "$tracked_dir/trunc_test.conf";
    open(my $tfh, '>', $trunc_file) or die $!;
    print $tfh "content to disappear\n";
    close($tfh);

    my ($cfh, $trunc_cfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $sub_out\n\n[track]\n$trunc_file\n";
    close($cfh);

    ChangeTrack::Runner->new(config => $trunc_cfg, quiet => 1)->run;

    # Truncate to 0 bytes
    open($tfh, '>', $trunc_file) or die $!;
    close($tfh);

    my $runner  = ChangeTrack::Runner->new(config => $trunc_cfg, quiet => 1);
    my $changed = $runner->status;
    is(scalar @$changed, 1, 'status: reports file truncated to 0 bytes');
    is($changed->[0]{path}, $trunc_file, 'status: correct path for truncated file');
    like(join("\n", @{ $changed->[0]{diff} }), qr/^-content to disappear/m,
        'status: diff contains removed line for truncated file');

    my $diffs = $runner->diff_path($trunc_file);
    ok(exists $diffs->{$trunc_file}, 'diff_path: key exists for truncated file');
    like(join("\n", @{ $diffs->{$trunc_file} }), qr/^-content to disappear/m,
        'diff_path: returns unified diff of removed lines');
}

########################################################################
# Revert_Path: Refuses While Run Lock Is Held
########################################################################
{
    require ChangeTrack::Lock;
    my $sub_out   = tempdir(CLEANUP => 1);
    my $lock_path = "$sub_out/ct.lock";
    my $rev_file  = "$tracked_dir/revert_lock.conf";

    open(my $rfh, '>', $rev_file) or die $!;
    print $rfh "version 1\n";
    close($rfh);
    chmod(0644, $rev_file);

    my ($cfh, $rev_cfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $sub_out\nlock_path = $lock_path\n\n[track]\n$rev_file\n";
    close($cfh);
    chmod(0600, $rev_cfg);

    ChangeTrack::Runner->new(config => $rev_cfg, quiet => 1)->run;

    my $head = ChangeTrack::Util::run_cmd(cmd => ['git', '-C', $sub_out, 'rev-parse', 'HEAD']);
    chomp(my $sha = $head->{stdout});

    open($rfh, '>', $rev_file) or die $!;
    print $rfh "version 2\n";
    close($rfh);

    my $held = ChangeTrack::Lock->new(path => $lock_path, timeout => 0);
    ok($held->acquire, 'revert lock test: acquired active run lock');

    eval {
        ChangeTrack::Runner->new(config => $rev_cfg, force => 1, quiet => 1)->revert_path($rev_file, $sha);
    };
    like($@, qr/holds the lock/, 'revert_path croaks when lock is held (even with force => 1)');

    open(my $chk, '<', $rev_file) or die $!;
    my $during = do { local $/; <$chk> };
    close($chk);
    is($during, "version 2\n", 'live file is unchanged when revert is blocked by lock');

    $held->release;

    ChangeTrack::Runner->new(config => $rev_cfg, quiet => 1)->revert_path($rev_file, $sha);
    open($chk, '<', $rev_file) or die $!;
    my $after = do { local $/; <$chk> };
    close($chk);
    is($after, "version 1\n", 'revert_path succeeds once lock is released');
}

########################################################################
# Show: Regular File, Symlink, Deleted File, and Error Handling
########################################################################
{
    my $sub_out = tempdir(CLEANUP => 1);
    my $sub_dir = tempdir(CLEANUP => 1);
    my $f_show  = "$sub_dir/show.conf";
    my $f_del   = "$sub_dir/gone.conf";
    my $l_show  = "$sub_dir/link.conf";

    open(my $fh1, '>', $f_show) or die $!;
    print $fh1 "line = one\n";
    close($fh1);
    chmod(0640, $f_show);

    open(my $fh2, '>', $f_del) or die $!;
    print $fh2 "ephemeral = yes\n";
    close($fh2);
    chmod(0644, $f_del);

    my ($cfh, $scfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $sub_out\n\n[track]\nDIRECTORY $sub_dir\n";
    close($cfh);

    ChangeTrack::Runner->new(config => $scfg, quiet => 1)->run;

    open($fh1, '>', $f_show) or die $!;
    print $fh1 "line = two_v2\n";
    close($fh1);
    unlink $f_del or die $!;

    ChangeTrack::Runner->new(config => $scfg, quiet => 1)->run;

    # Show historical revision of regular file
    my ($rc1, $out1, $err1) = run_cli_capture('-c', $scfg, 'show', $f_show, 'HEAD~1');
    is($rc1, 0, 'CLI show regular file at HEAD~1: exits 0');
    like($out1, qr/^# Path: \Q$f_show\E/m, 'CLI show: prints Path header');
    like($out1, qr/^# Revision: HEAD~1/m, 'CLI show: prints Revision header');
    like($out1, qr/^# Type: file  Mode: 0640/m, 'CLI show: prints metadata header');
    like($out1, qr/^line = one$/m, 'CLI show: prints historical file content');

    # Show deleted file at earlier revision
    my ($rc_del, $out_del, $err_del) = run_cli_capture('-c', $scfg, 'show', $f_del, 'HEAD~1');
    is($rc_del, 0, 'CLI show deleted file at HEAD~1: exits 0');
    like($out_del, qr/^ephemeral = yes$/m, 'CLI show deleted file: retrieves content');

    # Show invalid revision exits 2
    my ($rc_bad, $out_bad, $err_bad) = run_cli_capture('-c', $scfg, 'show', $f_show, 'nonexistent_rev_xyz');
    is($rc_bad, 2, 'CLI show invalid revision: exits 2');
    like($err_bad, qr/changetrack-ng:/, 'CLI show invalid revision: prints error');

    # Historical diff: 1 rev (rev vs live) and 2 revs (rev1 vs rev2)
    open($fh1, '>', $f_show) or die $!;
    print $fh1 "line = three_v3\n";
    close($fh1);

    my ($rc_d1, $out_d1, $err_d1) = run_cli_capture('-c', $scfg, 'diff', $f_show, 'HEAD~1');
    is($rc_d1, 0, 'CLI diff <path> <rev1>: exits 0');
    like($out_d1, qr/-line = one/, 'CLI diff <path> <rev1>: shows historical line removed');
    like($out_d1, qr/\+line = three_v3/, 'CLI diff <path> <rev1>: shows live line added');

    my ($rc_d2, $out_d2, $err_d2) = run_cli_capture('-c', $scfg, 'diff', $f_show, 'HEAD~1', 'HEAD');
    is($rc_d2, 0, 'CLI diff <path> <rev1> <rev2>: exits 0');
    like($out_d2, qr/-line = one/, 'CLI diff <path> <rev1> <rev2>: shows rev1 line');
    like($out_d2, qr/\+line = two_v2/, 'CLI diff <path> <rev1> <rev2>: shows rev2 line');

    # Show symlink at historical revision
    SKIP: {
        my $can_symlink = eval { symlink('', ''); 1 };
        skip 'symlink creation not available', 3 unless $can_symlink;
        symlink('/target/first', $l_show) or die $!;
        ChangeTrack::Runner->new(config => $scfg, quiet => 1)->run;
        unlink $l_show or die $!;
        symlink('/target/second', $l_show) or die $!;
        ChangeTrack::Runner->new(config => $scfg, quiet => 1)->run;

        my ($rc_sym, $out_sym, $err_sym) = run_cli_capture('-c', $scfg, 'show', $l_show, 'HEAD~1');
        is($rc_sym, 0, 'CLI show symlink at HEAD~1: exits 0');
        like($out_sym, qr{^# Symlink-Target: /target/first}m, 'CLI show symlink: prints Symlink-Target header');
        like($out_sym, qr{^symlink -> /target/first}m, 'CLI show symlink: prints target');
    }

    # Repo-wide log (no-arg) includes deleted file commit history
    my ($rc_log, $out_log, $err_log) = run_cli_capture('-c', $scfg, 'log');
    is($rc_log, 0, 'CLI log (no-arg): exits 0');
    like($out_log, qr/gone\.conf/, 'CLI log (no-arg): includes deleted file in repo history');
}

########################################################################
# Diff <dir> and Metadata-Only Diff (CORR-16)
########################################################################
{
    my $sub_out = tempdir(CLEANUP => 1);
    my $sub_dir = tempdir(CLEANUP => 1);
    my $fa = "$sub_dir/a.conf";
    my $fb = "$sub_dir/b.conf";

    open(my $fha, '>', $fa) or die $!; print $fha "alpha = 1\n"; close($fha);
    open(my $fhb, '>', $fb) or die $!; print $fhb "beta = 1\n";  close($fhb);
    chmod(0644, $fa, $fb);

    my ($cfh, $dcfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $sub_out\n\n[track]\nDIRECTORY $sub_dir\n";
    close($cfh);

    ChangeTrack::Runner->new(config => $dcfg, quiet => 1)->run;

    # Content change on a.conf (different size for same-second stat), metadata-only on b.conf
    open($fha, '>', $fa) or die $!; print $fha "alpha = 2 (modified)\n"; close($fha);
    chmod(0755, $fb);

    my ($rc_dir, $out_dir, $err_dir) = run_cli_capture('-c', $dcfg, 'diff', $sub_dir);
    is($rc_dir, 0, 'CLI diff <dir>: exits 0 without directory crash');
    like($out_dir, qr/=== \Q$fa\E ===/, 'CLI diff <dir>: includes modified file header');
    like($out_dir, qr/\+alpha = 2 \(modified\)/, 'CLI diff <dir>: includes content diff');
    like($out_dir, qr/=== \Q$fb\E ===/, 'CLI diff <dir>: includes chmod file header');
    like($out_dir, qr/\(metadata changed: mode 0644 -> 0755\)/, 'CLI diff <dir>: reports metadata-only diff');

    my ($rc_single, $out_single, $err_single) = run_cli_capture('-c', $dcfg, 'diff', $fb);
    is($rc_single, 0, 'CLI diff <file> on chmod-only change: exits 0');
    like($out_single, qr/\(metadata changed: mode 0644 -> 0755\)/, 'CLI diff <file>: reports metadata-only change');
}

########################################################################
# Status: File -> Binary Transition and Binary Chmod (CORR-16)
########################################################################
{
    my $sub_out  = tempdir(CLEANUP => 1);
    my $sub_dir  = tempdir(CLEANUP => 1);
    my $bin_file = "$sub_dir/data.dat";

    open(my $fh, '>', $bin_file) or die $!;
    print $fh "plain text initial\n";
    close($fh);
    chmod(0644, $bin_file);

    my ($cfh, $bcfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $sub_out\n\n[track]\n$bin_file\n";
    close($cfh);

    ChangeTrack::Runner->new(config => $bcfg, quiet => 1)->run;

    # Transition text file -> binary file
    open($fh, '>:raw', $bin_file) or die $!;
    print $fh "\x00\x01\x02\x03\x04\x05binarypayload";
    close($fh);

    my $runner1 = ChangeTrack::Runner->new(config => $bcfg, quiet => 1);
    my $st1     = $runner1->status;
    is(scalar @$st1, 1, 'status: detects file -> binary transition');
    is($st1->[0]{path}, $bin_file, 'status: reports correct path for file -> binary');
    like(join("\n", @{ $st1->[0]{diff} }), qr/type file -> binary/,
        'status: diff notes type file -> binary');

    # Commit the binary state, then chmod it
    ChangeTrack::Runner->new(config => $bcfg, quiet => 1)->run;
    chmod(0600, $bin_file);

    my $runner2 = ChangeTrack::Runner->new(config => $bcfg, quiet => 1);
    my $st2     = $runner2->status;
    is(scalar @$st2, 1, 'status: detects chmod on already-tracked binary file');
    like(join("\n", @{ $st2->[0]{diff} }), qr/mode 0644 -> 0600/,
        'status: reports mode change on binary file');
}

########################################################################
# Revert --Dry-Run (Preview Without Disk Mutation)
########################################################################
{
    my $sub_out = tempdir(CLEANUP => 1);
    my $sub_dir = tempdir(CLEANUP => 1);
    my $rfile   = "$sub_dir/app.conf";

    open(my $fh, '>', $rfile) or die $!;
    print $fh "setting = original\n";
    close($fh);
    chmod(0640, $rfile);

    my ($cfh, $rcfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = git\noutput_dir = $sub_out\n\n[track]\n$rfile\n";
    close($cfh);

    ChangeTrack::Runner->new(config => $rcfg, quiet => 1)->run;

    open($fh, '>', $rfile) or die $!;
    print $fh "setting = updated\n";
    close($fh);
    chmod(0644, $rfile);
    ChangeTrack::Runner->new(config => $rcfg, quiet => 1)->run;

    my ($rc, $out, $err) = run_cli_capture('-c', $rcfg, '--dry-run', 'revert', $rfile, 'HEAD~1');
    is($rc, 0, 'CLI revert --dry-run: exits 0 without interactive prompt');
    like($out, qr/Would revert \Q$rfile\E to revision HEAD~1/, 'CLI revert --dry-run: prints preview banner');
    like($out, qr/Target metadata: mode=0640/, 'CLI revert --dry-run: prints target metadata');
    like($out, qr/-setting = original/, 'CLI revert --dry-run: prints diff');

    my $content_after = do { open(my $f, '<', $rfile) or die $!; local $/; <$f> };
    is($content_after, "setting = updated\n", 'CLI revert --dry-run: live file content untouched');
    is((stat($rfile))[2] & 07777, 0644, 'CLI revert --dry-run: live file permissions untouched');

    # Invalid path/revision fails immediately in interactive mode without hanging
    my ($rc_bad, $out_bad, $err_bad) = run_cli_capture('-c', $rcfg, 'revert', $rfile, 'bad_rev_xyz');
    isnt($rc_bad, 0, 'CLI revert invalid rev (interactive): fails immediately');
    unlike($out_bad, qr/\[y\/N\]/, 'CLI revert invalid rev: does not prompt before validating');
}

########################################################################
# RCS Directory Log Including Deleted Files (CORR-18)
########################################################################
SKIP: {
    my $has_rcs = 0;
    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
        if (-x "$dir/ci" && -x "$dir/rlog") { $has_rcs = 1; last }
    }
    skip 'RCS ci/rlog not found in PATH', 3 unless $has_rcs;

    my $rcs_out = tempdir(CLEANUP => 1);
    my $rcs_dir = tempdir(CLEANUP => 1);
    my $rf1     = "$rcs_dir/keep.conf";
    my $rf2     = "$rcs_dir/removed.conf";

    open(my $f1, '>', $rf1) or die $!; print $f1 "keep = 1\n";    close($f1);
    open(my $f2, '>', $rf2) or die $!; print $f2 "removed = 1\n"; close($f2);

    my ($cfh, $rcscfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = rcs\noutput_dir = $rcs_out\n\n[track]\nDIRECTORY $rcs_dir\n";
    close($cfh);

    ChangeTrack::Runner->new(config => $rcscfg, quiet => 1)->run;
    unlink $rf2 or die $!;
    ChangeTrack::Runner->new(config => $rcscfg, quiet => 1)->run;

    my ($rc, $out, $err) = run_cli_capture('-c', $rcscfg, 'log', $rcs_dir);
    is($rc, 0, 'CLI log <dir> (RCS): exits 0');
    like($out, qr/keep\.conf/, 'CLI log <dir> (RCS): includes active file');
    like($out, qr/removed\.conf/, 'CLI log <dir> (RCS): includes deleted file archive');
}

########################################################################
# CLI Validation: Unknown Post-Subcommand Flags, Arity, --lock-timeout, Default VCS
########################################################################
{
    my ($rc1, $o1, $e1) = run_cli_capture('-c', $cfg, 'run', '--bogus-flag');
    is($rc1, 64, 'CLI run --bogus-flag: exits 64');
    like($e1, qr/unknown option '--bogus-flag'/, 'CLI run --bogus-flag: reports unknown option');

    my ($rc2, $o2, $e2) = run_cli_capture('-c', $cfg, 'run', '--dryrun');
    is($rc2, 64, 'CLI run --dryrun: exits 64');

    my ($rc3, $o3, $e3) = run_cli_capture('-c', $cfg, 'status', '/etc/hosts');
    is($rc3, 64, 'CLI status <extra>: exits 64');
    like($e3, qr/unexpected argument/, 'CLI status <extra>: reports unexpected argument');

    my ($rc4, $o4, $e4) = run_cli_capture('-c', $cfg, 'run', 'extra');
    is($rc4, 64, 'CLI run <extra>: exits 64');

    my ($rc5, $o5, $e5) = run_cli_capture('-c', $cfg, 'init', 'extra');
    is($rc5, 64, 'CLI init <extra>: exits 64');

    my ($rc6, $o6, $e6) = run_cli_capture('-c', $cfg, 'log', $test_file, 'extra');
    is($rc6, 64, 'CLI log <p1> <p2>: exits 64');

    my ($rc7, $o7, $e7) = run_cli_capture('-c', $cfg, 'diff', $test_file, 'HEAD~1', 'HEAD', 'extra');
    is($rc7, 64, 'CLI diff >3 args: exits 64');

    my ($rc8, $o8, $e8) = run_cli_capture('-c', $cfg, 'show', $test_file);
    is($rc8, 64, 'CLI show <1 arg>: exits 64');

    my ($rc9, $o9, $e9) = run_cli_capture('-c', $cfg, 'show', $test_file, 'HEAD', 'extra');
    is($rc9, 64, 'CLI show >2 args: exits 64');

    my ($rc10, $o10, $e10) = run_cli_capture('-c', $cfg, 'revert', $test_file);
    is($rc10, 64, 'CLI revert <1 arg>: exits 64');

    my ($rc11, $o11, $e11) = run_cli_capture('-c', $cfg, 'revert', $test_file, 'HEAD', 'extra');
    is($rc11, 64, 'CLI revert >2 args: exits 64');

    my ($rc12, $o12, $e12) = run_cli_capture('-c', $cfg, 'update-ignore');
    is($rc12, 64, 'CLI update-ignore (removed): exits 64');
    like($e12, qr/unknown subcommand 'update-ignore'/, 'CLI update-ignore: reported as unknown subcommand');

    # --lock-timeout valid and invalid
    my ($rc_lt_bad, $o_lt_bad, $e_lt_bad) = run_cli_capture('-c', $cfg, '--lock-timeout', '-1', 'run');
    is($rc_lt_bad, 64, 'CLI --lock-timeout -1: exits 64');
    like($e_lt_bad, qr/non-negative integer/, 'CLI --lock-timeout -1: descriptive error');

    my ($rc_lt_ok, $o_lt_ok, $e_lt_ok) = run_cli_capture('-c', $cfg, 'run', '--lock-timeout', '5', '-n', '-q');
    is($rc_lt_ok, 0, 'CLI run --lock-timeout 5 -n -q: exits 0');

    # Default VCS when vcs is omitted from config is git
    my $def_out = tempdir(CLEANUP => 1);
    my ($dcfh, $def_cfg) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $dcfh "[global]\noutput_dir = $def_out\n\n[track]\n$test_file\n";
    close($dcfh);
    my ($vcs_obj) = ChangeTrack::Runner->new(config => $def_cfg, quiet => 1)->init_vcs;
    isa_ok($vcs_obj, 'ChangeTrack::VCS::Git', 'default VCS when unset in config is Git');
    ok(-d "$def_out/.git", 'default VCS init creates .git directory');
}

done_testing();

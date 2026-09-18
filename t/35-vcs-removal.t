# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 35-vcs-removal.t - Tests for directory deletion reconciliation,
#   status reporting of deleted files, and VCS removal operations.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir tempfile);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use ChangeTrack::Util qw(run_cmd);

# Check git availability
my $GIT = do {
    my $found;
    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
        if (-x "$dir/git") { $found = "$dir/git"; last }
    }
    $found;
};
plan skip_all => 'git not found in PATH' unless $GIT;

use_ok('ChangeTrack::Runner');
use_ok('ChangeTrack::Config');
use_ok('ChangeTrack::Metadata');
use_ok('ChangeTrack::VCS::Git');
use_ok('ChangeTrack::VCS::RCS');

########################################################################
# Test 1: Unit tests for VCS Base remove() and Git remove()
########################################################################
{
    my $out_dir = tempdir(CLEANUP => 1);
    my $git = ChangeTrack::VCS::Git->new(output_dir => $out_dir);
    $git->init;

    my ($tfh, $test_file) = tempfile(UNLINK => 1);
    print {$tfh} "git remove test\n";
    close($tfh);

    $git->checkin($test_file, 'initial checkin');
    $git->commit('initial commit');

    my $mirror = $git->output_path($test_file);
    ok(-e $mirror, 'git: mirror file exists after commit');

    # Calling remove on tracked file
    $git->remove($test_file);
    ok(!-e $mirror, 'git: mirror file unlinked after remove()');

    # Commit the removal
    $git->commit('remove test_file');
    my $rel = $git->_rel_path($mirror);
    my $ls = run_cmd(cmd => ['git', '-C', $out_dir, 'ls-files', '--', $rel]);
    is($ls->{stdout}, '', 'git: file is removed from git index and HEAD');

    # Calling remove on already-removed/untracked file should not die
    my $ok = eval { $git->remove($test_file); 1 };
    ok($ok, 'git: remove() on untracked/missing file succeeds silently');
}

########################################################################
# Test 2: Unit tests for RCS remove()
########################################################################
{
    my $CI = do {
        my $found;
        for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
            if (-x "$dir/ci") { $found = "$dir/ci"; last }
        }
        $found;
    };
    SKIP: {
        skip 'rcs not found in PATH', 3 unless $CI;

        my $out_dir = tempdir(CLEANUP => 1);
        my $rcs = ChangeTrack::VCS::RCS->new(output_dir => $out_dir);
        $rcs->init;

        my ($tf, $test_file) = tempfile(UNLINK => 1);
        print {$tf} "rcs remove test\n";
        close($tf);

        $rcs->checkin($test_file, 'initial checkin');

        my $op = $rcs->output_path($test_file);
        ok(-e $op, 'rcs: mirror working file exists');

        $rcs->remove($test_file);
        ok(!-e $op, 'rcs: mirror working file unlinked after remove()');

        # Verify archive file (,v) is preserved
        my $arch = $rcs->_rcs_file($test_file);
        ok(-e $arch, 'rcs: archive file (,v) preserved after remove()');
    }
}

########################################################################
# Test 3: Directory Deletion Reconciliation with Git Runner
########################################################################
{
    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    my $track_dir  = "$work_dir/configs";
    make_path("$track_dir/subdir");

    my $file_a = "$track_dir/a.conf";
    my $file_b = "$track_dir/b.conf";
    my $file_c = "$track_dir/subdir/c.conf";

    for my $f ($file_a, $file_b, $file_c) {
        open(my $fh, '>', $f) or die $!;
        print {$fh} "content of $f\n";
        close($fh);
    }

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh} "[global]\n";
    print {$cfh} "vcs = git\n";
    print {$cfh} "output_dir = $output_dir\n\n";
    print {$cfh} "[track]\n";
    print {$cfh} "DIRECTORY $track_dir\n";
    close($cfh);

    # Initial run: tracks all 3 files
    my $runner1 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep1 = $runner1->run;
    is(scalar @{ $rep1->changes }, 3, 'initial run: 3 files added');

    my $md = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    ok(defined $md->record_for($file_b), 'metadata has record for b.conf');

    # Delete file_b from disk
    unlink($file_b) or die "unlink $file_b failed: $!";

    # Status check before run should report file_b as deleted
    my $runner_st = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $status_res = $runner_st->status;
    my ($st_b) = grep { $_->{path} eq $file_b } @$status_res;
    ok($st_b, 'status(): deleted file appears in status results');
    is_deeply($st_b->{diff}, ['(deleted)'], 'status(): diff indicates (deleted)');

    # diff_path for specific deleted file
    my $diff_single = $runner_st->diff_path($file_b);
    is_deeply($diff_single->{$file_b}, ['(deleted)'], 'diff_path(file): indicates (deleted)');

    # Second run: file_b should be reconciled as deleted
    my $runner2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep2 = $runner2->run;

    my @removed2 = grep { $_->{is_removed} } @{ $rep2->changes };
    is(scalar @removed2, 1, 'second run: 1 file removed');
    is($removed2[0]{path}, $file_b, 'second run: removed path is b.conf');

    # Check metadata updated
    my $md2 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    ok(!defined $md2->record_for($file_b), 'metadata no longer contains b.conf');
    ok(defined $md2->record_for($file_a), 'metadata still contains a.conf');
    ok(defined $md2->record_for($file_c), 'metadata still contains c.conf');

    # Check git mirror
    my $git = ChangeTrack::VCS::Git->new(output_dir => $output_dir);
    my $mirror_b = $git->output_path($file_b);
    ok(!-e $mirror_b, 'git mirror file for b.conf is unlinked');

    my $rel_b = $git->_rel_path($mirror_b);
    my $ls = run_cmd(cmd => ['git', '-C', $output_dir, 'ls-files', '--', $rel_b]);
    is($ls->{stdout}, '', 'git index no longer tracks b.conf');

    # Whole subdirectory deletion: delete subdir/ containing c.conf
    remove_tree("$track_dir/subdir");
    ok(!-e $file_c, 'subdir and c.conf removed from disk');

    my $runner3 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep3 = $runner3->run;
    my @removed3 = grep { $_->{is_removed} } @{ $rep3->changes };
    is(scalar @removed3, 1, 'third run: c.conf under deleted subdirectory removed');

    my $md3 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    ok(!defined $md3->record_for($file_c), 'metadata no longer contains c.conf');
}

########################################################################
# Test 4: Nested Directory Options Inheritance on Deletion
########################################################################
{
    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    my $base_dir   = "$work_dir/etc";
    my $sub_dir    = "$work_dir/etc/secrets";
    make_path($sub_dir);

    my $secret_file = "$sub_dir/key.pem";
    open(my $fh, '>', $secret_file) or die $!;
    print {$fh} "secret key content\n";
    close($fh);

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh} "[global]\n";
    print {$cfh} "vcs = git\n";
    print {$cfh} "output_dir = $output_dir\n\n";
    print {$cfh} "[track]\n";
    print {$cfh} "DIRECTORY $base_dir : general\@example.com\n";
    print {$cfh} "DIRECTORY $sub_dir : secops\@example.com sensitive=yes\n";
    close($cfh);

    my $runner1 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    $runner1->run;

    # Delete secret_file
    unlink($secret_file) or die $!;

    my $runner2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep = $runner2->run;

    my @removed_entries = grep { $_->{is_removed} } @{ $rep->changes };
    is(scalar @removed_entries, 1, 'nested dir: secret file deletion detected');
    is_deeply(
        $removed_entries[0]{recipients},
        ['secops@example.com'],
        'deleted file inherits options from more specific nested directory',
    );
}

done_testing();

# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 36-type-transitions.t - Tests for bidirectional file type transitions
#   (file <-> symlink, trackable <-> non-trackable) and metadata safety.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use POSIX qw(mkfifo);
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
use_ok('ChangeTrack::Config');
use_ok('ChangeTrack::Metadata');
use_ok('ChangeTrack::VCS::Git');

########################################################################
# Test 1: Metadata Classification and Transition Detection
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $file = "$dir/test.txt";

    # Regular file
    open(my $fh, '>', $file) or die $!;
    print {$fh} "hello world\n";
    close($fh);

    my $meta_file = "$dir/.changetrack-metadata";
    my $md = ChangeTrack::Metadata->load($meta_file);
    $md->update_from_stat($file);
    $md->save($meta_file);

    my $md_loaded = ChangeTrack::Metadata->load($meta_file);
    is($md_loaded->record_for($file)->{type}, 'file', 'classified as file');
    ok($md_loaded->can_skip_content_diff($file), 'can skip diff when unchanged');
    ok(!$md_loaded->changed_since_load($file), 'not changed since load');

    # Truncate to empty file
    open($fh, '>', $file) or die $!;
    close($fh);

    ok(!$md_loaded->can_skip_content_diff($file), 'cannot skip diff after file -> empty transition');
    ok($md_loaded->changed_since_load($file), 'changed_since_load true after type change');
    like($md_loaded->diff_summary($file), qr/type file -> empty/, 'diff_summary reports type transition');

    # Make into binary file
    open($fh, '>', $file) or die $!;
    print {$fh} "hello\0world" x 50;
    close($fh);

    $md->update_from_stat($file);
    is($md->record_for($file)->{type}, 'binary', 'classified as binary');

    # Check symlink transition if platform supports symlinks
    SKIP: {
        my $can_symlink = eval { symlink('', ''); 1 };
        skip 'symlink creation not available on this platform/user', 4 unless $can_symlink;

        unlink($file);
        my $target = "$dir/target.txt";
        open(my $tfh, '>', $target) or die $!;
        print {$tfh} "target content\n";
        close($tfh);

        symlink($target, $file) or die "symlink failed: $!";
        ok(!$md_loaded->can_skip_content_diff($file), 'cannot skip diff after file -> symlink transition');
        ok($md_loaded->changed_since_load($file), 'changed_since_load true on symlink');
        like($md_loaded->diff_summary($file), qr/type \w+ -> symlink/, 'diff_summary reports type change to symlink');
        like($md_loaded->diff_summary($file), qr/target \(none\) -> \S+/, 'diff_summary reports target for new symlink');
    }
}

########################################################################
# Test 2: Runner Bidirectional Transition: Trackable <-> Non-Trackable
########################################################################
{
    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    my $file       = "$work_dir/config.dat";

    # Step 1: Initial state is a text file
    open(my $fh, '>', $file) or die $!;
    print {$fh} "line 1\nline 2\n";
    close($fh);

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh} "[global]\n";
    print {$cfh} "vcs = git\n";
    print {$cfh} "output_dir = $output_dir\n\n";
    print {$cfh} "[track]\n";
    print {$cfh} "$file\n";
    close($cfh);

    my $runner1 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep1 = $runner1->run;
    is(scalar @{ $rep1->changes }, 1, 'run 1: text file checked in');
    is($rep1->changes->[0]{is_new}, 1, 'run 1: change is marked new');

    my $git = ChangeTrack::VCS::Git->new(output_dir => $output_dir);
    my $mirror = $git->output_path($file);
    my $rel = $git->_rel_path($mirror);
    my $ls1 = run_cmd(cmd => ['git', '-C', $output_dir, 'ls-files', '--', $rel]);
    ok($ls1->{stdout} =~ /\S/, 'run 1: file is tracked in git index');

    # Step 2: Reverse transition: file becomes binary (non-trackable)
    open($fh, '>', $file) or die $!;
    binmode($fh);
    print {$fh} "binary\0data\0payload" x 100;
    close($fh);

    my $runner2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep2 = $runner2->run;

    is(scalar @{ $rep2->changes }, 1, 'run 2: transition change recorded');
    my $c2 = $rep2->changes->[0];
    ok($c2->{is_removed}, 'run 2: marked as is_removed for VCS');
    like($c2->{meta_change}, qr/transition from file to binary \(removed from VCS\)/,
        'run 2: transition reason recorded');

    ok(!-e $mirror, 'run 2: mirror file unlinked');
    my $ls2 = run_cmd(cmd => ['git', '-C', $output_dir, 'ls-files', '--', $rel]);
    is($ls2->{stdout}, '', 'run 2: file removed from git index');

    my $md2 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    is($md2->record_for($file)->{type}, 'binary', 'run 2: metadata updated to type binary');

    # Step 3: Run again while still binary -- should be skipped cleanly (no changes)
    my $runner3 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep3 = $runner3->run;
    is(scalar @{ $rep3->changes }, 0, 'run 3: unchanged binary file produces no changes');

    # Step 4: Forward transition: binary becomes text file (trackable again)
    open($fh, '>', $file) or die $!;
    print {$fh} "restored text content\n";
    close($fh);

    my $runner4 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep4 = $runner4->run;

    is(scalar @{ $rep4->changes }, 1, 'run 4: transition to text recorded');
    my $c4 = $rep4->changes->[0];
    ok($c4->{is_new}, 'run 4: marked as is_new in report');
    like($c4->{meta_change}, qr/transition from binary to file/, 'run 4: meta_change describes forward transition');

    my $ls4 = run_cmd(cmd => ['git', '-C', $output_dir, 'ls-files', '--', $rel]);
    ok($ls4->{stdout} =~ /\S/, 'run 4: file re-added to git index');

    my $md4 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    is($md4->record_for($file)->{type}, 'file', 'run 4: metadata updated to type file');
}

########################################################################
# Test 3: Runner Bidirectional Transition: File <-> Symlink
########################################################################
SKIP: {
    my $can_symlink = eval { symlink('', ''); 1 };
    skip 'symlink creation not available on this platform/user', 7 unless $can_symlink;

    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    my $file       = "$work_dir/sym_test.conf";
    my $target1    = "$work_dir/real1.conf";
    my $target2    = "$work_dir/real2.conf";

    open(my $tfh1, '>', $target1) or die $!;
    print {$tfh1} "target 1 content\n";
    close($tfh1);

    open(my $tfh2, '>', $target2) or die $!;
    print {$tfh2} "target 2 content\n";
    close($tfh2);

    # Start as regular file
    open(my $fh, '>', $file) or die $!;
    print {$fh} "regular file content\n";
    close($fh);

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh} "[global]\nvcs = git\noutput_dir = $output_dir\n\n[track]\n$file\n";
    close($cfh);

    my $r1 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    $r1->run;

    # Transition: regular file -> symlink
    unlink($file) or die $!;
    symlink($target1, $file) or die $!;

    my $r2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep2 = $r2->run;
    is(scalar @{ $rep2->changes }, 1, 'file -> symlink change detected');
    like($rep2->changes->[0]{meta_change}, qr/type file -> symlink/, 'report describes type transition to symlink');

    my $md2 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    is($md2->record_for($file)->{type}, 'symlink', 'metadata type updated to symlink');
    is($md2->record_for($file)->{target}, $target1, 'metadata target recorded');

    # Transition: symlink -> regular file
    unlink($file) or die $!;
    open($fh, '>', $file) or die $!;
    print {$fh} "back to regular content\n";
    close($fh);

    my $r3 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep3 = $r3->run;
    is(scalar @{ $rep3->changes }, 1, 'symlink -> file change detected');
    like($rep3->changes->[0]{meta_change}, qr/type symlink -> file/, 'report describes type transition to file');

    my $md3 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    is($md3->record_for($file)->{type}, 'file', 'metadata type updated back to file');
}

########################################################################
# Test 4: File Truncation to 0 Bytes (file -> empty) Captures Deleted Diff
########################################################################
{
    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    my $file       = "$work_dir/truncate_test.txt";

    open(my $fh, '>', $file) or die $!;
    print {$fh} "line to be deleted 1\nline to be deleted 2\n";
    close($fh);

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh} "[global]\nvcs = git\noutput_dir = $output_dir\n\n[track]\n$file\n";
    close($cfh);

    my $r1 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep1 = $r1->run;
    is(scalar @{ $rep1->changes }, 1, 'initial run: tracked non-empty file');

    # Truncate file to 0 bytes
    open($fh, '>', $file) or die $!;
    close($fh);

    my $r2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $rep2 = $r2->run;
    is(scalar @{ $rep2->changes }, 1, 'run 2: truncation change detected');
    my $change = $rep2->changes->[0];
    ok(@{ $change->{diff} } > 0, 'run 2: diff is not empty for file truncation to empty');
    like(join("\n", @{ $change->{diff} }), qr/^-line to be deleted/m,
        'run 2: diff contains deleted line removals');
}

done_testing();

# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 20-util-symlink-mirror.t - Tests for util symlink mirror.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Util', qw(sync_mirror_path restore_mirror_path));

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "open $path: $!";
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

my $tmp = tempdir(CLEANUP => 1);

# Regular file mirror/restore
my $src = "$tmp/source.txt";
open(my $sfh, '>', $src) or die "create $src: $!";
print $sfh "alpha\n";
close($sfh);

my $mirror = "$tmp/mirror.txt";
is(sync_mirror_path($src, $mirror), 'file', 'sync_mirror_path copies regular files');
is(slurp($mirror), "alpha\n", 'mirror content matches source content');

my $dst = "$tmp/restored.txt";
open(my $dfh, '>', $dst) or die "create $dst: $!";
print $dfh "old\n";
close($dfh);

is(restore_mirror_path($mirror, $dst), 'file', 'restore_mirror_path restores regular files');
is(slurp($dst), "alpha\n", 'restored content matches mirrored content');

# Symlink snapshot/restore (skip where symlinks are unavailable)
SKIP: {
    my $probe = "$tmp/.symlink_probe";
    my $can_symlink = eval {
        symlink('probe-target', $probe) or die $!;
        unlink($probe);
        1;
    };
    skip 'symlink creation not available on this platform/user', 4 unless $can_symlink;

    my $target_file = "$tmp/target.txt";
    open(my $tfh, '>', $target_file) or die "create $target_file: $!";
    print $tfh "target\n";
    close($tfh);

    my $target_rel = 'target.txt';
    my $src_link   = "$tmp/source.link";
    symlink($target_rel, $src_link) or die "create symlink $src_link: $!";

    my $link_mirror = "$tmp/link.mirror";
    is(sync_mirror_path($src_link, $link_mirror), 'symlink',
        'sync_mirror_path stores symlink snapshot record');

    my $dst_link = "$tmp/restored.link";
    is(restore_mirror_path($link_mirror, $dst_link), 'symlink',
        'restore_mirror_path recreates symlink from snapshot record');
    ok(-l $dst_link, 'restored path is a symlink');
    is(readlink($dst_link), $target_rel, 'restored symlink target matches original target');
}

########################################################################
# Atomic File Restore & Mode Preservation (CORR-7)
########################################################################
{
    # 1. Mode preservation for existing files
    my $mode_src = "$tmp/mode_src.txt";
    open(my $fh, '>', $mode_src) or die $!;
    print $fh "restored content\n";
    close($fh);

    my $mode_dst = "$tmp/mode_dst.txt";
    open($fh, '>', $mode_dst) or die $!;
    print $fh "initial live content\n";
    close($fh);
    chmod 0750, $mode_dst or die $!;

    my $initial_mode = (stat($mode_dst))[2] & 07777;
    is($initial_mode, 0750, 'initial destination has mode 0750');

    is(restore_mirror_path($mode_src, $mode_dst), 'file', 'restore_mirror_path succeeds');
    is(slurp($mode_dst), "restored content\n", 'restored content matches');
    my $restored_mode = (stat($mode_dst))[2] & 07777;
    is($restored_mode, 0750, 'destination mode 0750 preserved after restore');

    # 2. Destination is not truncated on copy failure & tempfile cleaned up
    my $fail_dir = tempdir(CLEANUP => 1);
    my $protected_dst = "$fail_dir/protected_dst.txt";
    open(my $pfh, '>', $protected_dst) or die $!;
    print $pfh "unmodified live data\n";
    close($pfh);

    my $nonexistent_mirror = "$fail_dir/no_such_file_mirror.txt";
    my $res = eval { restore_mirror_path($nonexistent_mirror, $protected_dst); 1 };
    ok(!$res, 'restore fails when source mirror does not exist');
    like($@, qr/failed/i, 'error reported on missing mirror');
    is(slurp($protected_dst), "unmodified live data\n",
        'live destination was not truncated on copy failure');

    opendir(my $dh, $fail_dir) or die $!;
    my @entries = grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);
    is_deeply([sort @entries], ['protected_dst.txt'],
        'no temporary files left behind on copy failure');

    # 3. Simulate rename failure to verify tempfile cleanup
    my $rename_fail_dir = tempdir(CLEANUP => 1);
    my $rf_src = "$rename_fail_dir/source.txt";
    open(my $rfh, '>', $rf_src) or die $!;
    print $rfh "new data\n";
    close($rfh);

    my $rf_dst = "$rename_fail_dir/dst.txt";
    open($rfh, '>', $rf_dst) or die $!;
    print $rfh "original data\n";
    close($rfh);

    mkdir "$rename_fail_dir/dir_dst" or die $!;
    open($rfh, '>', "$rename_fail_dir/dir_dst/file") or die $!;
    print $rfh "subfile\n";
    close($rfh);

    my $res_rename = eval { restore_mirror_path($rf_src, "$rename_fail_dir/dir_dst"); 1 };
    ok(!$res_rename, 'restore fails when rename destination is a non-empty directory');
    opendir(my $rdh, $rename_fail_dir) or die $!;
    my @rf_entries = grep { !/^\.\.?$/ } readdir($rdh);
    closedir($rdh);
    is_deeply([sort @rf_entries], ['dir_dst', 'dst.txt', 'source.txt'],
        'tempfile is cleaned up when rename fails');
}

done_testing();

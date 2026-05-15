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

done_testing();

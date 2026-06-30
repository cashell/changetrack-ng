# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 33-cleanup.t - Tests for Phase 5 correctness fixes: disabled-notifier name
#   reuse (CTNG-30), revert revision validation (CTNG-31), unknown-option
#   handling (CTNG-29), and the corrected symlink snapshot prefix (CTNG-32).
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');
use_ok('ChangeTrack::Util', qw(sync_mirror_path restore_mirror_path));

my $bin = File::Spec->catfile($RealBin, '..', 'bin', 'changetrack-ng');

########################################################################
# CTNG-30: a disabled notifier must not reserve its name for an enabled one
########################################################################

my $dir = tempdir(CLEANUP => 1);
my $cfg = "$dir/dup.conf";
open(my $f, '>', $cfg) or die $!;
print $f <<'INI';
[global]
vcs = git

[notifier:file:main]
enabled = false
path = /tmp/a.log

[notifier:file:main]
enabled = true
path = /tmp/b.log
INI
close($f);

my $c = eval { ChangeTrack::Config->load($cfg) };
ok($c, 'config loads when a disabled instance shares a name with an enabled one')
    or diag($@);
my $files = $c ? $c->notifiers->{file} : [];
is(scalar(@$files), 1, 'only the enabled instance is registered');
is($files->[0]{path}, '/tmp/b.log', 'the enabled instance is the one kept');

########################################################################
# CTNG-32: symlink snapshot round-trips through the corrected prefix
########################################################################

SKIP: {
    skip 'symlink() not supported here', 2
        unless eval { symlink('', ''); 1 };

    my $src = "$dir/link";
    symlink('/etc/hosts', $src) or skip 'cannot create symlink', 2;
    my $mirror = "$dir/mirror";
    is(sync_mirror_path($src, $mirror), 'symlink', 'symlink mirrored as snapshot');

    my $restored = "$dir/restored";
    is(restore_mirror_path($mirror, $restored), 'symlink',
        'snapshot restored as a symlink via the corrected prefix');
}

########################################################################
# CTNG-31 / CTNG-29: CLI argument validation (run the real script)
########################################################################

SKIP: {
    my $perl = $^X;

    my $out1 = `"$perl" "$bin" revert /etc/hosts -rHEAD 2>&1`;
    my $rc1  = $? >> 8;
    like($out1, qr/invalid revision/, 'revert rejects a revision beginning with "-"');
    is($rc1, 64, 'revert with bad revision exits 64');

    my $out2 = `"$perl" "$bin" --bogus-flag 2>&1`;
    my $rc2  = $? >> 8;
    like($out2, qr/unknown option/, 'unrecognized option is reported as an option');
    is($rc2, 64, 'unknown option exits 64');
}

done_testing();

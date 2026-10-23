# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 31-path-safety.t - Tests for mirror-path traversal containment (CTNG-08)
#   and RCS colon-encoding collision avoidance (CTNG-16).
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');
use_ok('ChangeTrack::VCS::Git');
use_ok('ChangeTrack::VCS::Fossil');
use_ok('ChangeTrack::VCS::SVN');
use_ok('ChangeTrack::VCS::Mercurial');
use_ok('ChangeTrack::VCS::RCS');

my $out = '/var/lib/changetrack-ng';

########################################################################
# Whole-repo output_path rejects '..' segments (containment)
########################################################################

for my $class (qw(Git Fossil SVN Mercurial)) {
    my $full = "ChangeTrack::VCS::$class";
    my $vcs  = $full->new(output_dir => $out);

    is($vcs->output_path('/etc/passwd'), "$out/etc/passwd",
        "$class maps a normal path under output_dir");

    eval { $vcs->output_path('/etc/../../tmp/evil'); 1 };
    like($@, qr/unsafe tracked path/,
        "$class output_path rejects a '..' traversal path");
}

########################################################################
# RCS colon-encoding avoids collisions between distinct paths
########################################################################

my $rcs = ChangeTrack::VCS::RCS->new(output_dir => $out);
my $p1  = $rcs->output_path('/etc/app/config');     # nested dirs
my $p2  = $rcs->output_path('/etc/app:config');     # real file with a colon
isnt($p1, $p2, 'RCS maps /etc/app/config and /etc/app:config to distinct archives');
like($p2, qr/%3A/, 'literal colon is percent-escaped in the RCS flat name');
like($rcs->output_path('/etc/a%b'), qr/%25/, 'literal percent is escaped to %25');
is($rcs->output_path('/etc/app/config'), "$out/etc:app:config",
    'RCS still maps path separators to colons');

########################################################################
# Config rejects '..' in track paths
########################################################################

my $dir = tempdir(CLEANUP => 1);
my $cfg_ok = "$dir/ok.conf";
open(my $f1, '>', $cfg_ok) or die $!;
print $f1 "[global]\nvcs = git\n[track]\n/etc/hosts\n";
close($f1);
my $c1 = eval { ChangeTrack::Config->load($cfg_ok) };
ok($c1, 'config with a normal track path loads');

my $cfg_bad = "$dir/bad.conf";
open(my $f2, '>', $cfg_bad) or die $!;
print $f2 "[global]\nvcs = git\n[track]\n/etc/../tmp/evil\n";
close($f2);
eval { ChangeTrack::Config->load($cfg_bad); 1 };
like($@, qr/may not contain '\.\.'/, "config rejects a '..' track path");

########################################################################
# _internal_exclude_paths includes svn repo, lock_path, and file notifier
########################################################################
{
    require ChangeTrack::Runner;
    my $conf_dir = tempdir(CLEANUP => 1);
    my $cfg_file = "$conf_dir/custom.conf";
    open(my $cfh, '>', $cfg_file) or die $!;
    print $cfh <<'EOF';
[global]
vcs = svn
output_dir = /var/lib/changetrack-test
lock_path = /var/run/custom.lock

[notifier:file:audit]
enabled = 1
path = /var/log/changetrack.json
EOF
    close($cfh);

    my $cfg = ChangeTrack::Config->load($cfg_file);
    my $excludes = ChangeTrack::Runner::_internal_exclude_paths($cfg);
    my %ex_map = map { $_ => 1 } @$excludes;

    ok($ex_map{'/var/lib/changetrack-test-svnrepo'}, '_internal_exclude_paths includes svn repo');
    ok($ex_map{'/var/run/custom.lock'}, '_internal_exclude_paths includes lock_path');
    ok($ex_map{'/var/log/changetrack.json'}, '_internal_exclude_paths includes enabled file notifier path');
}

done_testing();

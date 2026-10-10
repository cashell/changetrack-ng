# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 11-ignore.t - Tests for ignore.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

require ChangeTrack::Runner;

# Access package-internal functions directly
sub should_ignore { ChangeTrack::Runner::_should_ignore(@_) }

########################################################################
# Pattern Matching Via _Should_Ignore
########################################################################
ok( should_ignore('/etc/foo.swp',      'foo.swp',      ['*.swp']),      '*.swp matches foo.swp');
ok(!should_ignore('/etc/foo.swp.bak',  'foo.swp.bak',  ['*.swp']),      '*.swp does not match foo.swp.bak');
ok( should_ignore('/etc/passwd~',      'passwd~',      ['*~']),         '*~ matches passwd~');
ok( should_ignore('/etc/#foo#',        '#foo#',        ['#*#']),        '#*# matches #foo#');
ok(!should_ignore('/etc/foo',          'foo',          ['#*#']),        '#*# does not match plain foo');
ok( should_ignore('/etc/foo.dpkg-old', 'foo.dpkg-old', ['*.dpkg-old']), '*.dpkg-old matches');

########################################################################
# _Should_Ignore: Basename Patterns
########################################################################
{
    my @pats = ('*.swp', '*~');
    ok( should_ignore('/etc/passwd.swp',  'passwd.swp',  \@pats), 'basename *.swp ignored');
    ok( should_ignore('/etc/passwd~',     'passwd~',     \@pats), 'basename *~ ignored');
    ok(!should_ignore('/etc/passwd',      'passwd',      \@pats), '/etc/passwd not ignored');
}

########################################################################
# _Should_Ignore: Path-Containing Patterns Match As Suffix
########################################################################
{
    my @pats = ('udev/hwdb.bin');
    ok( should_ignore('/etc/udev/hwdb.bin', 'hwdb.bin', \@pats),
        'udev/hwdb.bin matches /etc/udev/hwdb.bin');
    ok(!should_ignore('/etc/udev/rules.d/50-udev.rules', 'rules.d', \@pats),
        'udev/hwdb.bin does not match unrelated path');
}

########################################################################
# _Should_Ignore: Glob In Path Pattern
########################################################################
{
    my @pats = ('init.d/.depend.*');
    ok( should_ignore('/etc/init.d/.depend.boot',  '.depend.boot',  \@pats),
        'init.d/.depend.* matches .depend.boot');
    ok( should_ignore('/etc/init.d/.depend.start', '.depend.start', \@pats),
        'init.d/.depend.* matches .depend.start');
    ok(!should_ignore('/etc/init.d/networking',    'networking',    \@pats),
        'init.d/.depend.* does not match networking');
}

########################################################################
# BUILTIN_IGNORE Contains Expected Patterns
########################################################################
{
    my @builtins = ChangeTrack::Runner->builtin_ignore_patterns;
    ok(scalar @builtins > 0, 'BUILTIN_IGNORE is non-empty');
    ok(scalar(grep { $_ eq '*.swp'        } @builtins), 'BUILTIN_IGNORE contains *.swp');
    ok(scalar(grep { $_ eq '*~'           } @builtins), 'BUILTIN_IGNORE contains *~');
    ok(scalar(grep { $_ eq '*.gz'         } @builtins), 'BUILTIN_IGNORE contains *.gz');
    ok(scalar(grep { $_ eq '*.7z'         } @builtins), 'BUILTIN_IGNORE contains *.7z');
    ok(scalar(grep { $_ eq '*.bz2'        } @builtins), 'BUILTIN_IGNORE contains *.bz2');
    ok(scalar(grep { $_ eq '*.zst'        } @builtins), 'BUILTIN_IGNORE contains *.zst');
    ok(scalar(grep { $_ eq '*.xz'         } @builtins), 'BUILTIN_IGNORE contains *.xz');
    ok(scalar(grep { $_ eq '#*#'          } @builtins), 'BUILTIN_IGNORE contains #*#');
    ok(scalar(grep { $_ eq 'udev/hwdb.bin'} @builtins), 'BUILTIN_IGNORE contains udev/hwdb.bin');
    ok(scalar(grep { $_ eq 'lvm/cache'    } @builtins), 'BUILTIN_IGNORE contains lvm/cache');
}

########################################################################
# Internal Exclusions Prevent Self-Tracking Of Output Repo Artifacts
########################################################################
{
    my $root = tempdir(CLEANUP => 1);
    my $track_dir = "$root/tracked";
    my $output_dir = "$track_dir/state/changetrack-ng";

    mkdir $track_dir or die "mkdir $track_dir: $!";
    mkdir "$track_dir/state" or die "mkdir $track_dir/state: $!";
    mkdir $output_dir or die "mkdir $output_dir: $!";

    open(my $fh, '>', "$track_dir/real.txt") or die $!;
    print {$fh} "real\n";
    close($fh);

    open($fh, '>', "$output_dir/.changetrack-metadata") or die $!;
    print {$fh} "meta\n";
    close($fh);

    open($fh, '>', "$track_dir/state/changetrack-ng.fossil") or die $!;
    print {$fh} "repo\n";
    close($fh);

    my $cfg = ChangeTrack::Config->new(
        version => 2,
        global  => {
            vcs        => 'fossil',
            output_dir => $output_dir,
            ignore     => [],
        },
        tracks => [
            { kind => 'directory', path => $track_dir, emails => [], options => {} },
        ],
    );

    my $runner = ChangeTrack::Runner->new();
    my $entries = $runner->_tracked_entries($cfg);
    my @paths = map { File::Spec->canonpath($_->{path}) } @$entries;

    ok((grep { $_ eq File::Spec->canonpath("$track_dir/real.txt") } @paths), 'real tracked file remains included');
    ok(!(grep { $_ eq File::Spec->canonpath("$output_dir/.changetrack-metadata") } @paths), 'metadata sidecar is excluded');
    ok(!(grep { $_ eq File::Spec->canonpath("$track_dir/state/changetrack-ng.fossil") } @paths), 'fossil repo database is excluded');
}

done_testing();

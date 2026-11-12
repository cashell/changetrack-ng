# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
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
        },
        ignore => [],
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

########################################################################
# Character Classes In Ignore Patterns (DEBT-5)
########################################################################
{
    ok( should_ignore('/src/main.c', 'main.c', ['*.[ch]']), '*.[ch] matches main.c');
    ok( should_ignore('/src/main.h', 'main.h', ['*.[ch]']), '*.[ch] matches main.h');
    ok(!should_ignore('/src/main.o', 'main.o', ['*.[ch]']), '*.[ch] does not match main.o');
    ok( should_ignore('/etc/1.conf', '1.conf', ['[!a-z].conf']), '[!a-z].conf matches 1.conf');
    ok(!should_ignore('/etc/a.conf', 'a.conf', ['[!a-z].conf']), '[!a-z].conf does not match a.conf');
    ok( should_ignore('/etc/Z.conf', 'Z.conf', ['[^a-z].conf']), '[^a-z].conf matches Z.conf');
    ok( should_ignore('/etc/[literal', '[literal', ['[literal']), 'unclosed [ treated literally');
    ok( should_ignore('/etc/[a/b]', '[a/b]', ['[a/b]']), 'class with slash treated literally');
}

########################################################################
# Glob Wildcard ** Matches Across Directory Separators
########################################################################
{
    my @pats = ('**/cache/**');
    ok( should_ignore('/var/cache/app/data.txt', 'data.txt', \@pats), '**/cache/** matches /var/cache/app/data.txt');
    ok( should_ignore('/var/app/cache/data.txt', 'data.txt', \@pats), '**/cache/** matches /var/app/cache/data.txt');
    ok(!should_ignore('/var/app/data.txt',       'data.txt', \@pats), '**/cache/** does not match /var/app/data.txt');

    my @pats2 = ('/a/**/e.txt');
    ok( should_ignore('/a/b/c/d/e.txt', 'e.txt', \@pats2), '/a/**/e.txt matches multi-level descendant');
    ok( should_ignore('/a/e.txt',       'e.txt', \@pats2), '/a/**/e.txt matches immediate child');
    ok(!should_ignore('/b/e.txt',       'e.txt', \@pats2), '/a/**/e.txt does not match outside /a');
}

########################################################################
# Directory And Subtree Ignore Patterns
########################################################################
{
    my @pats = ('lvm/cache');
    ok( should_ignore('/etc/lvm/cache',          'cache',      \@pats), 'lvm/cache matches directory itself');
    ok( should_ignore('/etc/lvm/cache/data.bin', 'data.bin',   \@pats), 'lvm/cache matches descendant file');
    ok(!should_ignore('/etc/lvm/cache_file',     'cache_file', \@pats), 'lvm/cache does not match cache_file');

    my @pats_root = ('/etc/letsencrypt');
    ok( should_ignore('/etc/letsencrypt',                          'letsencrypt', \@pats_root), '/etc/letsencrypt matches dir');
    ok( should_ignore('/etc/letsencrypt/archive/domain/cert1.pem', 'cert1.pem',   \@pats_root), '/etc/letsencrypt matches deep descendant');
    ok(!should_ignore('/var/etc/letsencrypt',                      'letsencrypt', \@pats_root), '/etc/letsencrypt does not match /var/etc/letsencrypt');
}

########################################################################
# Ignore Overrides Explicit Track File Entries
########################################################################
{
    my $root = tempdir(CLEANUP => 1);
    my $explicit_file = "$root/explicit.conf";
    open(my $fh, '>', $explicit_file) or die $!;
    print {$fh} "conf\n";
    close($fh);

    my $cfg = ChangeTrack::Config->new(
        version => 2,
        global  => { vcs => 'rcs', output_dir => "$root/output" },
        ignore  => ['*.conf'],
        tracks  => [
            { kind => 'file', path => $explicit_file, emails => [], options => {} },
        ],
    );

    my $runner = ChangeTrack::Runner->new();
    my $entries = $runner->_tracked_entries($cfg);
    is(scalar @$entries, 0, 'explicit track file entry is overridden by [ignore]');
}

########################################################################
# File::Find Directory Pruning Verified Via Trace
########################################################################
{
    my $root = tempdir(CLEANUP => 1);
    my $track_dir = "$root/tree";
    File::Path::make_path("$track_dir/keep");
    File::Path::make_path("$track_dir/pruned_dir/sub");

    open(my $fh1, '>', "$track_dir/keep/file1.txt") or die $!;
    print {$fh1} "file1\n";
    close($fh1);

    open(my $fh2, '>', "$track_dir/pruned_dir/secret.txt") or die $!;
    print {$fh2} "secret\n";
    close($fh2);

    open(my $fh3, '>', "$track_dir/pruned_dir/sub/nested.txt") or die $!;
    print {$fh3} "nested\n";
    close($fh3);

    my $cfg = ChangeTrack::Config->new(
        version => 2,
        global  => { vcs => 'rcs', output_dir => "$root/output" },
        ignore  => ['pruned_dir'],
        tracks  => [
            { kind => 'directory', path => $track_dir, emails => [], options => {} },
        ],
    );

    my @trace_lines;
    my $runner = ChangeTrack::Runner->new(trace => 1, quiet => 1);
    {
        local $SIG{__WARN__} = sub { push @trace_lines, $_[0] };
        my $entries = $runner->_tracked_entries($cfg);
        is(scalar @$entries, 1, 'only keep/file1.txt is tracked');
        is($entries->[0]{path}, "$track_dir/keep/file1.txt", 'resolved path is keep/file1.txt');
    }

    my $trace_text = join('', @trace_lines);
    like($trace_text, qr/pruned \(ignored directory\)/, 'pruned directory logged in trace');
    unlike($trace_text, qr/secret\.txt/, 'files in pruned directory are never visited');
    unlike($trace_text, qr/nested\.txt/, 'descendant files in pruned directory are never visited');
}

########################################################################
# Reconciliation Silently Purges Newly Ignored Paths From Metadata
########################################################################
{
    my $root = tempdir(CLEANUP => 1);
    my $track_dir  = "$root/configs";
    my $output_dir = "$root/output";
    File::Path::make_path($track_dir);
    File::Path::make_path($output_dir);

    my $file_active = "$track_dir/active.txt";
    my $file_ignore = "$track_dir/ignore_later.txt";
    for my $f ($file_active, $file_ignore) {
        open(my $fh, '>', $f) or die $!;
        print {$fh} "content of $f\n";
        close($fh);
    }

    my ($cfh1, $cfg1_path) = File::Temp::tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh1} "[global]\nvcs = git\noutput_dir = $output_dir\n\n[track]\nDIRECTORY $track_dir\n";
    close($cfh1);

    # First run tracks both files
    my $rep1 = ChangeTrack::Runner->new(config => $cfg1_path, quiet => 1)->run;
    is(scalar @{ $rep1->changes }, 2, 'run 1: tracks both files');
    my $md1 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    ok(defined $md1->record_for($file_ignore), 'metadata initially has ignore_later.txt');

    # Now add ignore_later.txt to [ignore]
    my ($cfh2, $cfg2_path) = File::Temp::tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh2} "[global]\nvcs = git\noutput_dir = $output_dir\n\n[ignore]\nignore_later.txt\n\n[track]\nDIRECTORY $track_dir\n";
    close($cfh2);

    # Second run should silently purge ignore_later.txt from metadata with no removal change
    my $rep2 = ChangeTrack::Runner->new(config => $cfg2_path, quiet => 1)->run;
    is(scalar @{ $rep2->changes }, 0, 'run 2: no changes emitted (newly ignored file is not reported as removed)');

    my $md2 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    ok(!defined $md2->record_for($file_ignore), 'metadata silently purged ignore_later.txt');
    ok(defined $md2->record_for($file_active), 'metadata still retains active.txt');
}

done_testing();

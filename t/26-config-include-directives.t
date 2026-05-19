# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 26-config-include-directives.t - Tests for @include, @include-track,
#   and @include-notifier directives: file form, directory form,
#   section restriction, and recursion guard.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');

sub write_file {
    my ($dir, $name, $content) = @_;
    my $path = "$dir/$name";
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $content;
    close($fh);
    return $path;
}

########################################################################
# @include File Form: Includes Content from a Second File
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $inc = write_file($dir, 'extra.conf', "[track]\n/etc/extra\n");
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n\@include $inc\n");

    my $cfg   = ChangeTrack::Config->load("$dir/main.conf");
    my @paths = map { $_->{path} } @{ $cfg->tracks };
    ok(grep { $_ eq '/etc/extra' } @paths, '@include file form adds track entries');
}

########################################################################
# @include Directory Form: Includes All *.conf in Sorted Order
########################################################################
{
    my $dir    = tempdir(CLEANUP => 1);
    my $incdir = "$dir/extras";
    mkdir $incdir or die $!;
    write_file($incdir, 'b.conf', "[track]\n/etc/second\n");
    write_file($incdir, 'a.conf', "[track]\n/etc/first\n");
    write_file($dir,    'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n\@include $incdir\n");

    my $cfg   = ChangeTrack::Config->load("$dir/main.conf");
    my @paths = map { $_->{path} } @{ $cfg->tracks };
    my ($ia)  = grep { $paths[$_] eq '/etc/first'  } 0 .. $#paths;
    my ($ib)  = grep { $paths[$_] eq '/etc/second' } 0 .. $#paths;
    ok(defined($ia) && defined($ib) && $ia < $ib,
        '@include dir: files processed in sorted order');
}

########################################################################
# @include-track: Restricts Included File to [track] Sections
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $inc = write_file($dir, 'tracks.conf', "[track]\n/etc/tracked\n");
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n\@include-track $inc\n");

    my $cfg   = ChangeTrack::Config->load("$dir/main.conf");
    my @paths = map { $_->{path} } @{ $cfg->tracks };
    ok(grep { $_ eq '/etc/tracked' } @paths,
        '@include-track: track entries from included file');
}

########################################################################
# @include-track: Rejects [global] in Included File (fatal)
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $inc = write_file($dir, 'bad.conf', "[global]\nvcs = git\n");
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n\@include-track $inc\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, '@include-track: [global] section in included file is fatal');
    like($@, qr/not allowed/i, 'Error mentions restriction');
}

########################################################################
# @include-notifier: Restricts Included File to [notifier:*] Sections
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $inc = write_file($dir, 'notifiers.conf',
        "[notifier:file:default]\nenabled = true\npath = /tmp/ct.log\n");
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n"
            . "\@include-notifier $inc\n");

    my $cfg   = ChangeTrack::Config->load("$dir/main.conf");
    my $insts = $cfg->notifiers->{file};
    is(scalar @$insts, 1, '@include-notifier: notifier instance from included file');
}

########################################################################
# @include-notifier: Rejects [track] in Included File (fatal)
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $inc = write_file($dir, 'bad.conf', "[track]\n/etc/passwd\n");
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n"
            . "\@include-notifier $inc\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, '@include-notifier: [track] section in included file is fatal');
    like($@, qr/not allowed/i, 'Error mentions restriction');
}

########################################################################
# Recursion Guard: Re-Including an Already-Visited File Is Silently Skipped
########################################################################
{
    my $dir    = tempdir(CLEANUP => 1);
    my $extra  = write_file($dir, 'extra.conf', "[track]\n/etc/extra\n");
    my $main   = "$dir/main.conf";
    open(my $fh, '>', $main) or die $!;
    print {$fh} "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n";
    print {$fh} "\@include $extra\n";
    print {$fh} "\@include $extra\n";
    close($fh);

    my $cfg   = ChangeTrack::Config->load($main);
    my @paths = map { $_->{path} } @{ $cfg->tracks };
    my $count = grep { $_ eq '/etc/extra' } @paths;
    is($count, 1, 'Recursion guard: same file included twice adds entry only once');
}

########################################################################
# Missing @include Path Is Fatal
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n"
            . "\@include $dir/nonexistent.conf\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, 'Missing @include path is a fatal parse error');
    like($@, qr/not found/i, 'Error message mentions path not found');
}

done_testing();

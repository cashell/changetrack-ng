# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 27-config-cross-file-errors.t - Tests for cross-file error detection:
#   duplicate notifier instances, scalar [global] key conflicts, and
#   section-in-wrong-directory errors.
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
# Duplicate Notifier Instance Across Main + notifier.d Is Fatal
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n"
            . "\n[notifier:email:default]\nenabled = true\nto = a\@example.com\n");
    mkdir "$dir/notifier.d" or die $!;
    write_file("$dir/notifier.d", 'extra.conf',
        "[notifier:email:default]\nenabled = true\nto = b\@example.com\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, 'Duplicate notifier instance across main + notifier.d is fatal');
    like($@, qr/duplicate notifier instance/i, 'Error message mentions duplicate');
}

########################################################################
# Scalar Global Key Conflict Across Main + conf.d Is Fatal
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n");
    mkdir "$dir/conf.d" or die $!;
    write_file("$dir/conf.d", 'extra.conf',
        "[global]\noutput_dir = /var/lib/changetrack-ng\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, 'Scalar global key set in two files is a fatal parse error');
    like($@, qr/output_dir.*already set|already set.*output_dir/i,
        'Error message names the conflicting key');
}

########################################################################
# Duplicate Notifier Instance Across Two @include-d Files Is Fatal
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $a   = write_file($dir, 'a.conf',
        "[notifier:file:default]\nenabled = true\npath = /tmp/a.log\n");
    my $b = write_file($dir, 'b.conf',
        "[notifier:file:default]\nenabled = true\npath = /tmp/b.log\n");
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n"
            . "\@include-notifier $a\n\@include-notifier $b\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, 'Duplicate notifier instance across @include files is fatal');
    like($@, qr/duplicate notifier instance/i, 'Error message mentions duplicate');
}

########################################################################
# [track] in notifier.d/ File Is Fatal
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n");
    mkdir "$dir/notifier.d" or die $!;
    write_file("$dir/notifier.d", 'bad.conf', "[track]\n/etc/shadow\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, '[track] in notifier.d/ is a fatal parse error');
    like($@, qr/not allowed/i, 'Error message mentions restriction');
}

########################################################################
# [notifier:*] in track.d/ File Is Fatal
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n");
    mkdir "$dir/track.d" or die $!;
    write_file("$dir/track.d", 'bad.conf',
        "[notifier:email]\nenabled = true\nto = x\@example.com\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, '[notifier:*] in track.d/ is a fatal parse error');
    like($@, qr/not allowed/i, 'Error message mentions restriction');
}

########################################################################
# [global] in conf.d/ (Array Keys Only) Is Valid
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n");
    mkdir "$dir/conf.d" or die $!;
    write_file("$dir/conf.d", 'ok.conf', "[global]\nignore = *.swp\n");

    my $cfg = eval { ChangeTrack::Config->load("$dir/main.conf") };
    ok(defined $cfg, '[global] (array key only) in conf.d/ is valid');
    my $ign = $cfg->global('ignore') // [];
    ok(grep { $_ eq '*.swp' } @$ign, 'ignore extended from conf.d drop-in');
}

done_testing();

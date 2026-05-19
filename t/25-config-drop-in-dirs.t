# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 25-config-drop-in-dirs.t - Tests for conf.d/, track.d/, notifier.d/
#   drop-in directory discovery, sorted-order processing, and per-dir
#   section restrictions.
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

sub base_dir {
    my $dir = tempdir(CLEANUP => 1);
    write_file($dir, 'main.conf',
        "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n");
    return $dir;
}

########################################################################
# Non-Existent Drop-in Dirs Silently Skipped
########################################################################
{
    my $dir = base_dir();
    my $cfg = eval { ChangeTrack::Config->load("$dir/main.conf") };
    ok(defined $cfg, 'Config loads fine when no drop-in dirs exist');
}

########################################################################
# notifier.d/ Processed and Adds Notifier Instances
########################################################################
{
    my $dir = base_dir();
    mkdir "$dir/notifier.d" or die $!;
    write_file("$dir/notifier.d", 'email.conf',
        "[notifier:email:default]\nenabled = true\nto = admin\@example.com\n");

    my $cfg   = ChangeTrack::Config->load("$dir/main.conf");
    my $insts = $cfg->notifiers->{email};
    is(scalar @$insts, 1, 'notifier.d/email.conf contributes one instance');
    is($insts->[0]{to}[0], 'admin@example.com', 'to field from notifier.d drop-in');
}

########################################################################
# track.d/ Processed and Adds Tracks
########################################################################
{
    my $dir = base_dir();
    mkdir "$dir/track.d" or die $!;
    write_file("$dir/track.d", 'app.conf', "[track]\n/var/log/app.log\n");

    my $cfg   = ChangeTrack::Config->load("$dir/main.conf");
    my @paths = map { $_->{path} } @{ $cfg->tracks };
    ok(grep { $_ eq '/var/log/app.log' } @paths, 'track.d/app.conf adds track entry');
}

########################################################################
# conf.d/ Processed and Extends Global Array Keys
########################################################################
{
    my $dir = base_dir();
    mkdir "$dir/conf.d" or die $!;
    write_file("$dir/conf.d", 'extra.conf', "[global]\nignore = *.swp\n");

    my $cfg = ChangeTrack::Config->load("$dir/main.conf");
    my $ign = $cfg->global('ignore') // [];
    ok(grep { $_ eq '*.swp' } @$ign, 'conf.d/extra.conf extends global ignore list');
}

########################################################################
# Files Processed in Sorted Order (track.d/)
########################################################################
{
    my $dir = base_dir();
    mkdir "$dir/track.d" or die $!;
    write_file("$dir/track.d", 'b-second.conf', "[track]\n/etc/second\n");
    write_file("$dir/track.d", 'a-first.conf',  "[track]\n/etc/first\n");

    my $cfg   = ChangeTrack::Config->load("$dir/main.conf");
    my @paths = map { $_->{path} } @{ $cfg->tracks };
    my ($ia)  = grep { $paths[$_] eq '/etc/first'  } 0 .. $#paths;
    my ($ib)  = grep { $paths[$_] eq '/etc/second' } 0 .. $#paths;
    ok(defined($ia) && defined($ib) && $ia < $ib,
        'a-first.conf processed before b-second.conf (sorted order)');
}

########################################################################
# Only *.conf Files Picked Up (not *.ini, *.bak, no-ext)
########################################################################
{
    my $dir = base_dir();
    mkdir "$dir/notifier.d" or die $!;
    write_file("$dir/notifier.d", 'valid.conf',
        "[notifier:file:default]\nenabled = true\npath = /tmp/ct.log\n");
    write_file("$dir/notifier.d", 'ignored.ini',
        "[notifier:file:extra]\nenabled = true\npath = /tmp/ct2.log\n");

    my $cfg   = ChangeTrack::Config->load("$dir/main.conf");
    my $insts = $cfg->notifiers->{file};
    is(scalar @$insts, 1, 'Only .conf files from notifier.d are processed');
}

########################################################################
# notifier.d/ May Not Contain [global] Section (fatal)
########################################################################
{
    my $dir = base_dir();
    mkdir "$dir/notifier.d" or die $!;
    write_file("$dir/notifier.d", 'bad.conf', "[global]\nvcs = git\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, 'notifier.d/ file with [global] section is a fatal parse error');
    like($@, qr/not allowed/i, 'Error message mentions restriction');
}

########################################################################
# track.d/ May Not Contain [notifier:*] Section (fatal)
########################################################################
{
    my $dir = base_dir();
    mkdir "$dir/track.d" or die $!;
    write_file("$dir/track.d", 'bad.conf',
        "[notifier:email]\nenabled = true\nto = x\@example.com\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, 'track.d/ file with [notifier:*] section is a fatal parse error');
    like($@, qr/not allowed/i, 'Error message mentions restriction');
}

########################################################################
# conf.d/ May Not Contain [track] Section (fatal)
########################################################################
{
    my $dir = base_dir();
    mkdir "$dir/conf.d" or die $!;
    write_file("$dir/conf.d", 'bad.conf', "[track]\n/etc/passwd\n");

    my $ok = eval { ChangeTrack::Config->load("$dir/main.conf"); 1 };
    ok(!$ok, 'conf.d/ file with [track] section is a fatal parse error');
    like($@, qr/not allowed/i, 'Error message mentions restriction');
}

done_testing();

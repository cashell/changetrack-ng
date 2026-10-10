# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 24-config-sections.t - Tests for [notifier:<type>:<name>] section
#   syntax, required 'enabled' field, and duplicate-instance detection.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');

sub write_main {
    my ($dir, $extra) = @_;
    my $path = "$dir/main.conf";
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} "[global]\nvcs = git\noutput_dir = /tmp\n\n[track]\n/etc/hosts\n";
    print {$fh} $extra // '';
    close($fh);
    return $path;
}

########################################################################
# Default Instance Name
########################################################################
{
    my $dir   = tempdir(CLEANUP => 1);
    my $path  = write_main($dir, "\n[notifier:email]\nenabled = true\nto = admin\@example.com\n");
    my $cfg   = ChangeTrack::Config->load($path);
    my $insts = $cfg->notifiers->{email};
    is(scalar @$insts, 1, 'One email instance parsed');
    is($insts->[0]{instance_name}, 'default', 'Blank name normalises to default');
    is($insts->[0]{to}[0], 'admin@example.com', 'to field parsed');
}

########################################################################
# Explicit Instance Name
########################################################################
{
    my $dir   = tempdir(CLEANUP => 1);
    my $path  = write_main($dir, "\n[notifier:email:ops]\nenabled = true\nto = ops\@example.com\n");
    my $cfg   = ChangeTrack::Config->load($path);
    my $insts = $cfg->notifiers->{email};
    is($insts->[0]{instance_name}, 'ops', 'Explicit instance name stored');
}

########################################################################
# Multiple Instances of Same Type
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_main($dir,
        "\n[notifier:email:ops]\nenabled = true\nto = ops\@example.com\n"
            . "\n[notifier:email:sec]\nenabled = true\nto = sec\@example.com\n"
    );
    my $cfg   = ChangeTrack::Config->load($path);
    my $insts = $cfg->notifiers->{email};
    is(scalar @$insts, 2, 'Two email instances parsed');
    my %by_name = map { $_->{instance_name} => $_ } @$insts;
    ok(exists $by_name{ops}, 'ops instance present');
    ok(exists $by_name{sec}, 'sec instance present');
}

########################################################################
# Disabled Instance Discarded
########################################################################
{
    my $dir   = tempdir(CLEANUP => 1);
    my $path  = write_main($dir, "\n[notifier:email]\nenabled = false\nto = admin\@example.com\n");
    my $cfg   = ChangeTrack::Config->load($path);
    my $insts = $cfg->notifiers->{email};
    is(scalar @$insts, 0, 'Disabled instance not returned by notifiers()');
}

########################################################################
# Missing 'enabled' Is Fatal
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_main($dir, "\n[notifier:email]\nto = admin\@example.com\n");
    my $ok   = eval { ChangeTrack::Config->load($path); 1 };
    ok(!$ok, 'Missing enabled key is a fatal parse error');
    like($@, qr/missing required.*enabled/i, 'Error message mentions enabled');
}

########################################################################
# Unknown Notifier Type Is Fatal
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_main($dir, "\n[notifier:slack]\nenabled = true\n");
    my $ok   = eval { ChangeTrack::Config->load($path); 1 };
    ok(!$ok, 'Unknown notifier type is a fatal parse error');
    like($@, qr/unknown notifier type.*slack/i, 'Error message names the bad type');
}

########################################################################
# Unknown Key in Notifier Section Is Fatal
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_main($dir, "\n[notifier:email]\nenabled = true\nbadkey = x\n");
    my $ok   = eval { ChangeTrack::Config->load($path); 1 };
    ok(!$ok, 'Unknown notifier key is a fatal parse error');
    like($@, qr/unknown key.*badkey/i, 'Error message names the bad key');
}

########################################################################
# Duplicate Instance Name In Same File Is Fatal
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_main($dir,
        "\n[notifier:email:default]\nenabled = true\nto = a\@example.com\n"
            . "\n[notifier:email:default]\nenabled = true\nto = b\@example.com\n"
    );
    my $ok = eval { ChangeTrack::Config->load($path); 1 };
    ok(!$ok, 'Duplicate instance name in same file is fatal');
    like($@, qr/duplicate notifier instance/i, 'Error message mentions duplicate');
}

########################################################################
# Boolean Coercion: enabled Accepts yes/no/true/false/1/0
########################################################################
{
    for my $val (qw(true yes 1)) {
        my $dir  = tempdir(CLEANUP => 1);
        my $path = write_main($dir, "\n[notifier:file]\nenabled = $val\npath = /tmp/ct.log\n");
        my $cfg  = eval { ChangeTrack::Config->load($path) };
        ok(defined($cfg) && scalar(@{ $cfg->notifiers->{file} }) == 1,
            "enabled=$val accepted as true");
    }
    for my $val (qw(false no 0)) {
        my $dir  = tempdir(CLEANUP => 1);
        my $path = write_main($dir, "\n[notifier:file]\nenabled = $val\npath = /tmp/ct.log\n");
        my $cfg  = eval { ChangeTrack::Config->load($path) };
        ok(defined($cfg) && scalar(@{ $cfg->notifiers->{file} }) == 0,
            "enabled=$val accepted as false");
    }
}

########################################################################
# Lazy HOSTNAME Expansion (PERF-3) & Deprecated Keys (DEBT-8)
########################################################################
{
    require ChangeTrack::Util;
    my $fqdn_calls = 0;
    no warnings qw(redefine once);
    local *ChangeTrack::Util::fqdn = sub {
        $fqdn_calls++;
        return 'mock-node.internal.net';
    };

    # 1. Config without HOSTNAME: fqdn() must NOT be called
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $path = write_main($dir, "\n[notifier:file]\nenabled = true\npath = /tmp/ct.log\n");
        my $cfg  = ChangeTrack::Config->load($path);
        is($fqdn_calls, 0, 'fqdn() is not called when config lacks HOSTNAME');
    }

    # 2. Config with HOSTNAME in notifier: fqdn() is called and value interpolated
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $path = write_main($dir, "\n[notifier:email]\nenabled = true\nto = admin\@HOSTNAME\n");
        my $cfg  = ChangeTrack::Config->load($path);
        ok($fqdn_calls > 0, 'fqdn() is invoked when config contains HOSTNAME');
        my $insts = $cfg->notifiers->{email};
        is($insts->[0]{to}[0], 'admin@mock-node.internal.net', 'HOSTNAME interpolated in notifier');
    }

    # 3. Config with HOSTNAME in global section: interpolated correctly
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $path = "$dir/global_host.conf";
        open(my $fh, '>', $path) or die $!;
        print {$fh} "[global]\nvcs = git\noutput_dir = /var/ct-HOSTNAME\n\n[track]\n/etc/hosts\n";
        close($fh);
        my $cfg = ChangeTrack::Config->load($path);
        is($cfg->global('output_dir'), '/var/ct-mock-node.internal.net', 'HOSTNAME interpolated in global section');
    }

    # 4. Deprecated interval key is parsed without error (DEBT-8)
    {
        my $dir  = tempdir(CLEANUP => 1);
        my $path = "$dir/interval.conf";
        open(my $fh, '>', $path) or die $!;
        print {$fh} "[global]\nvcs = git\noutput_dir = /tmp\ninterval = 1800\n\n[track]\n/etc/hosts\n";
        close($fh);
        my $cfg = eval { ChangeTrack::Config->load($path) };
        ok(defined $cfg, 'Deprecated interval key accepted without parse error');
        is($cfg->global('interval'), 1800, 'interval value preserved for backward compatibility');
    }
}

done_testing();

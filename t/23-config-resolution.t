# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 23-config-resolution.t - Tests for config resolution.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
use lib File::Spec->catdir($RealBin, '..', 'lib');

my $bin = File::Spec->catfile($RealBin, '..', 'bin', 'changetrack-ng');
plan skip_all => 'bin/changetrack-ng not found' unless -f $bin;

###############################################################################
# helpers
###############################################################################

# Write a minimal config whose VCS name acts as a unique sentinel.
# When this config is loaded and the lock-free status path runs, Runner
# will croak "Unknown VCS '<sentinel>'", proving the correct config file
# was opened.
sub make_config {
    my ($sentinel) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} "[global]\nvcs = $sentinel\noutput_dir = /tmp\n\n[track]\n";
    close($fh);
    return $path;
}

# Run the CLI with the given args (list form, no shell) and return
# (exit_code, combined_stdout+stderr).  %ENV modifications made before
# this call are inherited by the child process.
sub run_cli {
    my (@args) = @_;
    my ($in, $combined);
    my $err = gensym;
    my $pid = open3($in, $combined, $err, $^X, $bin, @args);
    close($in);
    my $stdout = do { local $/; <$combined> };
    my $stderr = do { local $/; <$err> };
    waitpid($pid, 0);
    return ($? >> 8, $stdout . $stderr);
}

###############################################################################
# -c / --config explicit path
###############################################################################

{
    my $cfg = make_config('sentinel_explicit');
    my ($rc, $out) = run_cli('-c', $cfg, 'status');
    like($out, qr/sentinel_explicit/, '-c: loads the named config file');
}

###############################################################################
# $CHANGETRACK_CONFIG env var
###############################################################################

{
    my $cfg = make_config('sentinel_envvar');
    local $ENV{CHANGETRACK_CONFIG} = $cfg;
    delete $ENV{HOME};
    my ($rc, $out) = run_cli('status');
    like($out, qr/sentinel_envvar/, 'CHANGETRACK_CONFIG env var: loaded when -c not given');
}

###############################################################################
# -c beats $CHANGETRACK_CONFIG
###############################################################################

{
    my $cfg_c   = make_config('sentinel_dashc');
    my $cfg_env = make_config('sentinel_envvar2');
    local $ENV{CHANGETRACK_CONFIG} = $cfg_env;
    my ($rc, $out) = run_cli('-c', $cfg_c, 'status');
    like($out,   qr/sentinel_dashc/,   '-c beats CHANGETRACK_CONFIG: correct config used');
    unlike($out, qr/sentinel_envvar2/, '-c beats CHANGETRACK_CONFIG: env var config not used');
}

###############################################################################
# --user flag
###############################################################################

{
    my $fake_home = tempdir(CLEANUP => 1);
    my $cfg_dir   = "$fake_home/.config/changetrack-ng";
    make_path($cfg_dir);
    open(my $fh, '>', "$cfg_dir/changetrack-ng.conf") or die $!;
    print {$fh} "[global]\nvcs = sentinel_user\noutput_dir = /tmp\n\n[track]\n";
    close($fh);

    local $ENV{HOME} = $fake_home;
    delete $ENV{CHANGETRACK_CONFIG};
    my ($rc, $out) = run_cli('--user', 'status');
    like($out, qr/sentinel_user/, '--user: loads ~/.config/changetrack-ng/changetrack-ng.conf');
}

###############################################################################
# $CHANGETRACK_CONFIG beats --user
###############################################################################

{
    my $fake_home = tempdir(CLEANUP => 1);
    my $cfg_dir   = "$fake_home/.config/changetrack-ng";
    make_path($cfg_dir);
    open(my $fh, '>', "$cfg_dir/changetrack-ng.conf") or die $!;
    print {$fh} "[global]\nvcs = sentinel_user2\noutput_dir = /tmp\n\n[track]\n";
    close($fh);

    my $cfg_env = make_config('sentinel_envvar3');
    local $ENV{HOME}               = $fake_home;
    local $ENV{CHANGETRACK_CONFIG} = $cfg_env;
    my ($rc, $out) = run_cli('--user', 'status');
    like($out,   qr/sentinel_envvar3/, 'CHANGETRACK_CONFIG beats --user: env var config used');
    unlike($out, qr/sentinel_user2/,   'CHANGETRACK_CONFIG beats --user: user config not used');
}

###############################################################################
# default uses system config path (no flags, no env var)
###############################################################################

{
    local $ENV{HOME};
    delete $ENV{HOME};
    delete $ENV{CHANGETRACK_CONFIG};
    my ($rc, $out) = run_cli('status');
    like($out,   qr{/etc/changetrack-ng}, 'default: uses system config path');
    unlike($out, qr{\.config/changetrack-ng}, 'default: does not use user config path');
    is($rc, 2, 'default: exits 2 when system config is missing (not a usage error)');
}

###############################################################################
# --system + --user are mutually exclusive
###############################################################################

{
    my ($rc, $out) = run_cli('--system', '--user', 'status');
    is($rc, 64, '--system --user: exits 64');
    like($out, qr/mutually exclusive/, '--system --user: error message is descriptive');
}

###############################################################################
# --user without HOME set
###############################################################################

{
    local $ENV{HOME};
    delete $ENV{HOME};
    delete $ENV{CHANGETRACK_CONFIG};
    my ($rc, $out) = run_cli('--user', 'status');
    is($rc, 64, '--user without HOME: exits 64');
    like($out, qr/HOME/, '--user without HOME: error message mentions HOME');
}

done_testing();

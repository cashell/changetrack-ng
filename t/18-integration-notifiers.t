# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 18-integration-notifiers.t - Config->Runner->Notifier integration;
#   validates required settings, startup validation, and SEC-2 warning.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');
use_ok('ChangeTrack::Runner');

########################################################################
# Helper: write a temp config with [global]+[track] plus extra sections
########################################################################

sub write_cfg {
    my (@notifier_sections) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} "[global]\n";
    print {$fh} "vcs = git\n";
    print {$fh} "output_dir = /tmp/changetrack-ng-test\n";
    print {$fh} "\n[track]\n";
    print {$fh} "/etc/hosts\n";
    for my $sect (@notifier_sections) {
        print {$fh} "\n$sect";
    }
    close($fh);
    return $path;
}

########################################################################
# Happy Path: Full Fixture Validates Through Config -> Runner -> Notifier
########################################################################
{
    my $fixture = File::Spec->catfile($RealBin, 'fixtures', 'config-v2-full.ini');
    my $cfg = ChangeTrack::Config->load($fixture);
    my $runner = ChangeTrack::Runner->new(config => $fixture, quiet => 1);

    my @notifiers = $runner->_build_notifiers($cfg);
    my $ok = eval { $runner->_validate_notifiers(\@notifiers); 1 };
    ok($ok, 'fixture config passes notifier startup validation');
}

########################################################################
# Webhook Required Setting Enforced
########################################################################
{
    my $path = write_cfg("[notifier:webhook:default]\nenabled = true\nurl =\n");
    my $cfg  = ChangeTrack::Config->load($path);
    my $runner = ChangeTrack::Runner->new(config => $path, quiet => 1);

    my @notifiers = $runner->_build_notifiers($cfg);
    my $ok = eval { $runner->_validate_notifiers(\@notifiers); 1 };

    ok(!$ok, 'empty webhook url fails startup validation');
    like($@, qr/webhook notifier requires/i, 'webhook error is actionable');
}

########################################################################
# OTLP Required Setting Enforced
########################################################################
{
    my $path = write_cfg("[notifier:otlp:default]\nenabled = true\nendpoint =\n");
    my $cfg  = ChangeTrack::Config->load($path);
    my $runner = ChangeTrack::Runner->new(config => $path, quiet => 1);

    my @notifiers = $runner->_build_notifiers($cfg);
    my $ok = eval {
        local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
        local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
        $runner->_validate_notifiers(\@notifiers);
        1;
    };

    ok(!$ok, 'missing OTLP endpoint fails startup validation');
    like($@, qr/otlp notifier requires/i, 'otlp error is actionable');
}

########################################################################
# File Required Setting Enforced
########################################################################
{
    my $path = write_cfg("[notifier:file:default]\nenabled = true\npath =\n");
    my $cfg  = ChangeTrack::Config->load($path);
    my $runner = ChangeTrack::Runner->new(config => $path, quiet => 1);

    my @notifiers = $runner->_build_notifiers($cfg);
    my $ok = eval { $runner->_validate_notifiers(\@notifiers); 1 };

    ok(!$ok, 'empty file path fails startup validation');
    like($@, qr/file notifier requires non-empty path/i, 'file notifier error is actionable');
}

########################################################################
# SEC-2: World-Readable Secret-Bearing Config Warns
########################################################################
if ($^O eq 'MSWin32' || $^O eq 'cygwin') {
    # chmod() does not propagate to stat() mode bits on Windows/Cygwin
    pass('SEC-2 world-readable warning test skipped on Windows/Cygwin');
} else {
    my $path = write_cfg(
        "[notifier:otlp:default]\nenabled = true\n"
            . "endpoint = https://otel.example.com/v1/logs\n"
            . "headers = Authorization=Bearer-secret\n"
    );
    chmod 0644, $path or die "chmod $path: $!";

    my $cfg    = ChangeTrack::Config->load($path);
    my $runner = ChangeTrack::Runner->new(config => $path, quiet => 1);

    my @warn;
    local $SIG{__WARN__} = sub { push @warn, @_ };
    $runner->_warn_insecure_config_permissions($cfg, $path);

    ok(grep(/world-readable/i, @warn), 'world-readable config with secrets emits warning');
}

########################################################################
# C1 Regression: New per-notifier keys parse without croak and propagate
########################################################################
# File notifier: max_diff_bytes, emit_recipients, severity_change
{
    my $path = write_cfg(
        "[notifier:file:default]\n"
            . "enabled = true\n"
            . "path = /tmp/ct-test.log\n"
            . "max_diff_bytes = 4096\n"
            . "emit_recipients = 1\n"
            . "severity_change = WARNING\n"
    );
    my $cfg;
    my $ok = eval { $cfg = ChangeTrack::Config->load($path); 1 };
    ok($ok, 'file notifier: new keys parse without croak (C1 regression)');
    diag $@ if !$ok;

    if ($ok) {
        my $runner    = ChangeTrack::Runner->new(config => $path, quiet => 1);
        my @notifiers = $runner->_build_notifiers($cfg);
        my $n         = $notifiers[0];
        is($n->{max_diff_bytes}, 4096,     'file notifier: max_diff_bytes propagates from config');
        ok($n->{emit_recipients},          'file notifier: emit_recipients propagates as true from config');
        is($n->{severity_change}, 'WARNING', 'file notifier: severity_change propagates from config');
    }
}

# OTLP notifier: same keys parse without croak and propagate
{
    my $path = write_cfg(
        "[notifier:otlp:default]\n"
            . "enabled = true\n"
            . "endpoint = https://otel.example.com/v1/logs\n"
            . "max_diff_bytes = 8192\n"
            . "emit_recipients = 1\n"
            . "severity_change = WARNING\n"
    );
    my $cfg;
    my $ok = eval { $cfg = ChangeTrack::Config->load($path); 1 };
    ok($ok, 'otlp notifier: new keys parse without croak (C1 regression)');
    diag $@ if !$ok;

    if ($ok) {
        my $runner    = ChangeTrack::Runner->new(config => $path, quiet => 1);
        my @notifiers = $runner->_build_notifiers($cfg);
        my $n         = $notifiers[0];
        is($n->{max_diff_bytes}, 8192,     'otlp notifier: max_diff_bytes propagates from config');
        ok($n->{emit_recipients},          'otlp notifier: emit_recipients propagates as true from config');
        is($n->{severity_change}, 'WARNING', 'otlp notifier: severity_change propagates from config');
    }
}

done_testing();

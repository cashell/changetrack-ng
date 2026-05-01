use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');
use_ok('ChangeTrack::Runner');

sub write_cfg {
    my ($global_block) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} "[global]\n";
    print {$fh} "vcs = git\n";
    print {$fh} "output_dir = /tmp/changetrack-ng-test\n";
    print {$fh} $global_block;
    print {$fh} "\n[track]\n";
    print {$fh} "/etc/hosts\n";
    close($fh);
    return $path;
}

# ── happy path: full fixture validates through Config -> Runner -> Notifier ──
{
    my $cfg = ChangeTrack::Config->load(File::Spec->catfile($RealBin, 'fixtures', 'config-v2-full.ini'));
    my $runner = ChangeTrack::Runner->new(config => '/nonexistent', quiet => 1);

    my @notify = @{ $cfg->global('notify') // [] };
    my $ok = eval {
        $runner->_validate_notifier_startup($cfg, \@notify);
        1;
    };
    ok($ok, 'fixture config passes notifier startup validation');
}

# ── webhook required setting enforced ─────────────────────────────────────────
{
    my $path = write_cfg("notify = webhook\nwebhook_url =\n");
    my $cfg = ChangeTrack::Config->load($path);
    my $runner = ChangeTrack::Runner->new(config => $path, quiet => 1);

    my @notify = @{ $cfg->global('notify') // [] };
    my $ok = eval {
        $runner->_validate_notifier_startup($cfg, \@notify);
        1;
    };

    ok(!$ok, 'empty webhook_url fails startup validation');
    like($@, qr/webhook notifier requires non-empty webhook_url/i, 'webhook error is actionable');
}

# ── otlp required setting enforced ────────────────────────────────────────────
{
    my $path = write_cfg("notify = otlp\notlp_endpoint =\n");
    my $cfg = ChangeTrack::Config->load($path);
    my $runner = ChangeTrack::Runner->new(config => $path, quiet => 1);

    my @notify = @{ $cfg->global('notify') // [] };
    my $ok = eval {
        local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
        local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
        $runner->_validate_notifier_startup($cfg, \@notify);
        1;
    };

    ok(!$ok, 'missing OTLP endpoint fails startup validation');
    like($@, qr/otlp notifier requires otlp_endpoint/i, 'otlp error is actionable');
}

# ── file required setting enforced ────────────────────────────────────────────
{
    my $path = write_cfg("notify = file\nnotify_log_path =\n");
    my $cfg = ChangeTrack::Config->load($path);
    my $runner = ChangeTrack::Runner->new(config => $path, quiet => 1);

    my @notify = @{ $cfg->global('notify') // [] };
    my $ok = eval {
        $runner->_validate_notifier_startup($cfg, \@notify);
        1;
    };

    ok(!$ok, 'empty notify_log_path fails startup validation');
    like($@, qr/file notifier requires non-empty notify_log_path/i, 'file notifier error is actionable');
}

# ── SEC-2: world-readable secret-bearing config warns ────────────────────────
{
    my $path = write_cfg("notify = otlp\notlp_headers = Authorization=Bearer\\ token\n");
    chmod 0644, $path or die "chmod $path: $!";

    my $cfg = ChangeTrack::Config->load($path);
    my $runner = ChangeTrack::Runner->new(config => $path, quiet => 1);

    my @warn;
    local $SIG{__WARN__} = sub { push @warn, @_ };
    $runner->_warn_insecure_config_permissions($cfg, $path);

    ok(grep(/world-readable/i, @warn), 'world-readable config with secrets emits warning');
}

done_testing();

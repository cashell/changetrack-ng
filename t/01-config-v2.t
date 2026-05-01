use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');

sub fixture { File::Spec->catfile($RealBin, 'fixtures', @_) }

# ── basic config ──────────────────────────────────────────────────────────────

{
    my $cfg = ChangeTrack::Config->load(fixture('config-v2-basic.ini'));

    is($cfg->version, 2, 'basic: version detected as 2');
    is($cfg->global('vcs'), 'git', 'basic: vcs = git');
    is($cfg->global('output_dir'), '/var/lib/changetrack-ng', 'basic: output_dir');

    my $tracks = $cfg->tracks;
    is(scalar @$tracks, 2, 'basic: two track entries');

    is($tracks->[0]{kind},  'file',       'basic: first entry is file');
    is($tracks->[0]{path},  '/etc/passwd', 'basic: first path');
    is_deeply($tracks->[0]{emails}, ['root@localhost'], 'basic: first emails');

    is($tracks->[1]{kind},  'file',       'basic: second entry is file');
    is($tracks->[1]{path},  '/etc/hosts', 'basic: second path');
    is_deeply($tracks->[1]{emails}, [], 'basic: second has no emails');
}

# ── full config ───────────────────────────────────────────────────────────────

{
    my $cfg = ChangeTrack::Config->load(fixture('config-v2-full.ini'));

    is($cfg->version, 2, 'full: version 2');
    is_deeply($cfg->global('notify'),  ['email', 'webhook'], 'full: notify arrayref');
    is_deeply($cfg->global('ignore'),  ['*.swp', '*~', '*.bak'], 'full: ignore arrayref');
    is($cfg->global('otlp_heartbeat'), '1', 'full: otlp_heartbeat = 1');
    is($cfg->global('webhook_heartbeat'), '0', 'full: webhook_heartbeat = 0');

    my $tracks = $cfg->tracks;
    is(scalar @$tracks, 4, 'full: four track entries');

    my ($nginx) = grep { $_->{path} eq '/etc/nginx' } @$tracks;
    ok(defined $nginx, 'full: DIRECTORY /etc/nginx found');
    is($nginx->{kind}, 'directory', 'full: nginx entry is directory');
    is_deeply($nginx->{emails}, ['admin@example.com'], 'full: nginx emails');

    my ($ssl) = grep { $_->{path} eq '/etc/ssl/private' } @$tracks;
    ok(defined $ssl, 'full: DIRECTORY /etc/ssl/private found');
    is($ssl->{options}{sensitive}, 'yes', 'full: sensitive option preserved');
}

# ── known global keys are preserved ──────────────────────────────────────────

{
    my $cfg = ChangeTrack::Config->load(fixture('config-v2-full.ini'));
    is($cfg->global('lock_timeout'), '0', 'global: lock_timeout preserved');
    is($cfg->global('interval'), 'hourly', 'global: interval preserved');
    ok(!defined $cfg->global('no_such_key'), 'global: missing key returns undef');
}

# ── unknown global keys are rejected ─────────────────────────────────────────

{
    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = git
no_such_key = 1

[track]
/etc/hosts
INI
    close($fh);

    my $ok = eval { ChangeTrack::Config->load($tmp); 1 };
    ok(!$ok, 'unknown global key causes parse failure');
    like($@, qr/unsupported global key 'no_such_key'/i,
        'error message includes unsupported key name');
}

# ── round-trip: parse → dump → parse → compare ───────────────────────────────

{
    my $cfg1 = ChangeTrack::Config->load(fixture('config-v2-full.ini'));

    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    close($fh);
    $cfg1->dump_v2($tmp);

    my $cfg2 = ChangeTrack::Config->load($tmp);

    is($cfg2->version, 2, 'round-trip: version');
    is($cfg2->global('vcs'), $cfg1->global('vcs'), 'round-trip: vcs');
    is_deeply($cfg2->global('notify'), $cfg1->global('notify'), 'round-trip: notify');
    is_deeply($cfg2->global('ignore'), $cfg1->global('ignore'), 'round-trip: ignore');
    is(scalar @{ $cfg2->tracks }, scalar @{ $cfg1->tracks }, 'round-trip: track count');

    for my $i (0 .. $#{ $cfg1->tracks }) {
        my ($e1, $e2) = ($cfg1->tracks->[$i], $cfg2->tracks->[$i]);
        is($e2->{kind}, $e1->{kind}, "round-trip: track[$i] kind");
        is($e2->{path}, $e1->{path}, "round-trip: track[$i] path");
        is_deeply($e2->{emails}, $e1->{emails}, "round-trip: track[$i] emails");
    }
}

# ── case-insensitive key lookup ───────────────────────────────────────────────

{
    my $cfg = ChangeTrack::Config->load(fixture('config-v2-basic.ini'));
    is($cfg->global('VCS'), $cfg->global('vcs'), 'global: case-insensitive key lookup');
}

# ── value validation (booleans/ints/enums) ──────────────────────────────────

{
    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = git
webhook_heartbeat = maybe

[track]
/etc/hosts
INI
    close($fh);

    my $ok = eval { ChangeTrack::Config->load($tmp); 1 };
    ok(!$ok, 'invalid boolean causes parse failure');
    like($@, qr/must be boolean/i, 'boolean validation message');
}

{
    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = git
lock_timeout = never

[track]
/etc/hosts
INI
    close($fh);

    my $ok = eval { ChangeTrack::Config->load($tmp); 1 };
    ok(!$ok, 'invalid integer causes parse failure');
    like($@, qr/non-negative integer/i, 'integer validation message');
}

{
    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = cvs

[track]
/etc/hosts
INI
    close($fh);

    my $ok = eval { ChangeTrack::Config->load($tmp); 1 };
    ok(!$ok, 'invalid enum causes parse failure');
    like($@, qr/invalid value/i, 'enum validation message');
}

# ── env expansion in scalar + array globals ─────────────────────────────────

{
    local $ENV{CT_TEST_TOKEN} = 's3cr3t';
    local $ENV{CT_TEST_HOST}  = 'hooks.example.test';

    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = git
otlp_headers = Authorization=Bearer\ ${CT_TEST_TOKEN}
webhook_url = https://${CT_TEST_HOST}/one https://${CT_TEST_HOST}/two

[track]
/etc/hosts
INI
    close($fh);

    my $cfg = ChangeTrack::Config->load($tmp);
    is($cfg->global('otlp_headers'), 'Authorization=Bearer\\ s3cr3t', 'scalar env expansion works');
    is_deeply(
        $cfg->global('webhook_url'),
        ['https://hooks.example.test/one', 'https://hooks.example.test/two'],
        'array env expansion works',
    );
}

{
    delete local $ENV{CT_MISSING_ENV};

    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = git
otlp_headers = Authorization=Bearer\ ${CT_MISSING_ENV}

[track]
/etc/hosts
INI
    close($fh);

    my $ok = eval { ChangeTrack::Config->load($tmp); 1 };
    ok(!$ok, 'undefined env reference causes parse failure');
    like($@, qr/undefined environment variable/i, 'missing env message');
}

# ── track path expansion (~/ and env vars) ─────────────────────────────────

{
    local $ENV{HOME} = '/tmp/ct-home';
    local $ENV{CT_TEST_DOTDIR} = '.config/demo';

    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = git

[track]
~/.bashrc
DIRECTORY ~/${CT_TEST_DOTDIR}
INI
    close($fh);

    my $cfg = ChangeTrack::Config->load($tmp);
    my $tracks = $cfg->tracks;
    is($tracks->[0]{path}, '/tmp/ct-home/.bashrc', 'track file path expands ~');
    is($tracks->[1]{path}, '/tmp/ct-home/.config/demo', 'track directory path expands ~ and env vars');
}

{
    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = git

[track]
relative/path.txt
INI
    close($fh);

    my $ok = eval { ChangeTrack::Config->load($tmp); 1 };
    ok(!$ok, 'relative v2 track path is rejected');
    like($@, qr/track path must be absolute/i, 'relative path rejection message');
}

{
    local $ENV{HOME} = '/tmp/ct-home-global';

    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = fossil
output_dir = ~/.local/state/changetrack-ng
lock_path = ~/.cache/changetrack-ng.lock

[track]
/etc/hosts
INI
    close($fh);

    my $cfg = ChangeTrack::Config->load($tmp);
    is($cfg->global('output_dir'), '/tmp/ct-home-global/.local/state/changetrack-ng', 'output_dir expands ~');
    is($cfg->global('lock_path'), '/tmp/ct-home-global/.cache/changetrack-ng.lock', 'lock_path expands ~');
}

{
    my ($fh, $tmp) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$fh} <<'INI';
[global]
vcs = git
output_dir = relative/output

[track]
/etc/hosts
INI
    close($fh);

    my $ok = eval { ChangeTrack::Config->load($tmp); 1 };
    ok(!$ok, 'relative output_dir is rejected');
    like($@, qr/key 'output_dir' must be an absolute path/i, 'relative output_dir rejection message');
}

done_testing();

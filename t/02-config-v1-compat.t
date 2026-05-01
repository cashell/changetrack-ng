use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');

sub fixture { File::Spec->catfile($RealBin, 'fixtures', @_) }

sub _canon_track {
    my ($t) = @_;
    return {
        kind    => $t->{kind},
        path    => $t->{path},
        recurse => $t->{recurse} ? 1 : 0,
        emails  => [ sort @{ $t->{emails} // [] } ],
    };
}

# ── v1 detection ──────────────────────────────────────────────────────────────

{
    my $cfg = ChangeTrack::Config->load(fixture('config-v1-legacy.conf'));
    is($cfg->version, 1, 'v1: detected as version 1');

    my $tracks = $cfg->tracks;
    ok(scalar @$tracks >= 3, 'v1: at least three track entries');

    my ($passwd) = grep { defined $_->{path} && $_->{path} eq '/etc/passwd' } @$tracks;
    ok(defined $passwd, 'v1: /etc/passwd found');
    is($passwd->{kind}, 'file', 'v1: /etc/passwd is file kind');
    is_deeply($passwd->{emails}, ['root@localhost'], 'v1: /etc/passwd email preserved');

    my ($fstab) = grep { defined $_->{path} && $_->{path} eq '/etc/fstab' } @$tracks;
    ok(defined $fstab, 'v1: /etc/fstab found');
    is_deeply($fstab->{emails}, ['sysadmin@example.com', 'root@localhost'],
        'v1: multiple emails preserved');

    my ($find_entry) = grep { $_->{options}{_v1_find_expr} } @$tracks;
    ok(defined $find_entry, 'v1: @ find expression parsed');
    is($find_entry->{kind}, 'directory', 'v1: find entry has directory kind');
    like($find_entry->{path}, qr{/etc}, 'v1: find path contains /etc');
}

# ── v2 files are not misdetected as v1 ───────────────────────────────────────

{
    my $cfg = ChangeTrack::Config->load(fixture('config-v2-basic.ini'));
    is($cfg->version, 2, 'not misdetected: v2 config stays v2');
}

# ── migration: v1 → v2 ───────────────────────────────────────────────────────

{
    my $orig = ChangeTrack::Config->load(fixture('config-v1-legacy.conf'));

    my ($fh, $tmp) = tempfile(SUFFIX => '.conf', UNLINK => 1);
    close($fh);

    ChangeTrack::Config->migrate_v1_to_v2(fixture('config-v1-legacy.conf'), $tmp);

    my $migrated = ChangeTrack::Config->load($tmp);
    is($migrated->version, 2, 'migrated: output is v2');
    is($migrated->global('vcs'), 'rcs', 'migrated: vcs defaults to rcs');

    my $tracks = $migrated->tracks;
    ok(scalar @$tracks >= 2, 'migrated: at least two track entries');

    my ($passwd) = grep { defined $_->{path} && $_->{path} eq '/etc/passwd' } @$tracks;
    ok(defined $passwd, 'migrated: /etc/passwd preserved');
    is_deeply($passwd->{emails}, ['root@localhost'], 'migrated: email preserved');

    # The @ find entry should NOT appear as a real track (it becomes a comment)
    my ($find_live) = grep {
        !$_->{options}{_v1_find_expr}
        && defined $_->{path}
        && $_->{path} =~ m{/etc.*-name}
    } @$tracks;
    ok(!defined $find_live, 'migrated: @ find expression not carried over as live track');

    my @orig_effective = map  { _canon_track($_) }
                         grep { !($_->{options}{_v1_find_expr}) }
                         @{ $orig->tracks };
    my @new_effective  = map  { _canon_track($_) }
                         @{ $migrated->tracks };

    my %orig_by_path = map { $_->{path} => $_ } @orig_effective;
    my %new_by_path  = map { $_->{path} => $_ } @new_effective;

    is_deeply(\%new_by_path, \%orig_by_path,
        'migrated: effective tracked entries match v1 semantics (excluding v1 @ find expression)');
}

# ── migration preserves multiple emails ──────────────────────────────────────

{
    my ($fh, $tmp) = tempfile(SUFFIX => '.conf', UNLINK => 1);
    close($fh);

    ChangeTrack::Config->migrate_v1_to_v2(fixture('config-v1-legacy.conf'), $tmp);

    my $migrated = ChangeTrack::Config->load($tmp);
    my ($fstab) = grep { defined $_->{path} && $_->{path} eq '/etc/fstab' } @{ $migrated->tracks };
    ok(defined $fstab, 'migrate-emails: /etc/fstab present');
    is_deeply($fstab->{emails}, ['sysadmin@example.com', 'root@localhost'],
        'migrate-emails: multiple emails preserved');
}

done_testing();

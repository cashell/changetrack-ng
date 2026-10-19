# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
########################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
########################################################################
# 38-test-dirty.t - Tests for tools/test-dirty fast-feedback test selector.
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;

my $repo_dir = File::Spec->catdir($RealBin, '..');
my $tool     = File::Spec->catfile($repo_dir, 'tools', 'test-dirty');

ok(-f $tool, 'tools/test-dirty exists');
ok(-x $tool, 'tools/test-dirty is executable');

# 1. Test --help flag
{
    my $out = `$^X $tool --help`;
    is($? >> 8, 0, '--help exits 0');
    like($out, qr/Usage: tools\/test-dirty/, '--help output contains usage instructions');
    like($out, qr/--dry-run/, '--help lists --dry-run option');
}

# 2. Test explicit file arguments with --dry-run for single modules
{
    my $out = `$^X $tool --dry-run lib/ChangeTrack/Config.pm`;
    is($? >> 8, 0, 'Mapping Config.pm exits 0');
    like($out, qr/t\/23-config-resolution\.t/, 'Config.pm maps to 23-config-resolution.t');
    like($out, qr/t\/24-config-sections\.t/,   'Config.pm maps to 24-config-sections.t');
}

{
    my $out = `$^X $tool --dry-run lib/ChangeTrack/Runner.pm`;
    is($? >> 8, 0, 'Mapping Runner.pm exits 0');
    like($out, qr/t\/04-runner-rcs\.t/,        'Runner.pm maps to 04-runner-rcs.t');
    like($out, qr/t\/10-sensitive\.t/,         'Runner.pm maps to 10-sensitive.t');
    like($out, qr/t\/36-type-transitions\.t/,  'Runner.pm maps to 36-type-transitions.t');
}

{
    my $out = `$^X $tool --dry-run lib/ChangeTrack/Metadata.pm`;
    is($? >> 8, 0, 'Mapping Metadata.pm exits 0');
    like($out, qr/t\/03-metadata\.t/, 'Metadata.pm maps to 03-metadata.t');
}

{
    my $out = `$^X $tool --dry-run lib/ChangeTrack/Lock.pm`;
    is($? >> 8, 0, 'Mapping Lock.pm exits 0');
    like($out, qr/t\/12-locking\.t/, 'Lock.pm maps to 12-locking.t');
}

{
    my $out = `$^X $tool --dry-run lib/ChangeTrack/VCS/Git.pm`;
    is($? >> 8, 0, 'Mapping VCS/Git.pm exits 0');
    like($out, qr/t\/06-vcs-git\.t/, 'VCS/Git.pm maps to 06-vcs-git.t');
}

# 3. Test direct test file mapping
{
    my $out = `$^X $tool --dry-run t/06-vcs-git.t`;
    is($? >> 8, 0, 'Direct test modification exits 0');
    chomp $out;
    is($out, 't/06-vcs-git.t', 'Direct test file maps exactly to itself');
}

# 4. Test multiple files and deduplication
{
    my $out = `$^X $tool --dry-run lib/ChangeTrack/Metadata.pm t/03-metadata.t`;
    is($? >> 8, 0, 'Mapping Metadata.pm and t/03-metadata.t exits 0');
    my @lines = split /\n/, $out;
    my @matches = grep { $_ eq 't/03-metadata.t' } @lines;
    is(scalar(@matches), 1, 'Duplicate test entries are deduplicated');
}

# 5. Test documentation-only dry-run handling
{
    my $out = `$^X $tool --dry-run README.md`;
    is($? >> 8, 0, 'Documentation file dry-run exits 0');
    like($out, qr/Documentation\/configuration only modified/, 'Identifies doc-only modification');
}

done_testing();

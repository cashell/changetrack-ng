# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
########################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
########################################################################
# 39-bump-version.t - Tests for tools/bump-version atomic version orchestrator.
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $repo_dir = File::Spec->catdir($RealBin, '..');
my $tool     = File::Spec->catfile($repo_dir, 'tools', 'bump-version');

ok(-f $tool, 'tools/bump-version exists');
ok(-x $tool, 'tools/bump-version is executable');

# 1. Test --help flag
{
    my $out = `$^X $tool --help`;
    is($? >> 8, 0, '--help exits 0');
    like($out, qr/Usage: tools\/bump-version/, '--help output contains usage instructions');
    like($out, qr/Target Files:/, '--help lists Target Files');
    like($out, qr/--dry-run/, '--help lists --dry-run option');
    like($out, qr/--show/, '--help lists --show option');
}

# 2. Test --show flag against current repository
{
    my $out = `$^X $tool --show`;
    is($? >> 8, 0, '--show exits 0');
    like($out, qr/Version\.pm\s+0\.\d+\.\d+/, '--show displays Version.pm version');
    like($out, qr/Makefile\s+0\.\d+\.\d+/,   '--show displays Makefile version');
    like($out, qr/CHANGELOG\.md\s+0\.\d+\.\d+/, '--show displays CHANGELOG.md version');
}

# 3. Test input validation and error cases
{
    my $out = `$^X $tool 2>&1`;
    isnt($? >> 8, 0, 'Missing version exits non-zero');
    like($out, qr/Missing new version argument/, 'Reports missing version');

    $out = `$^X $tool invalid-version 2>&1`;
    isnt($? >> 8, 0, 'Invalid SemVer format exits non-zero');
    like($out, qr/Invalid version format/, 'Reports invalid version format');

    # Attempting to bump to an older version without --force
    $out = `$^X $tool 0.1.0 2>&1`;
    isnt($? >> 8, 0, 'Downgrade without --force exits non-zero');
    like($out, qr/must be greater than current version/, 'Enforces version monotonicity');
}

# 4. Test --dry-run on a higher version
{
    my $out = `$^X $tool --dry-run 0.9.0`;
    is($? >> 8, 0, '--dry-run exits 0');
    like($out, qr/DRY RUN: Planned version synchronization/, 'Dry run header present');
    like($out, qr/Target: .*Version\.pm/, 'Mentions Version.pm target');
    like($out, qr/\+ our \$VERSION = '0\.9\.0';/, 'Shows diff for Version.pm');
    like($out, qr/\+ VERSION    := 0\.9\.0/,      'Shows diff for Makefile');
}

# 5. Full isolated atomic transformation test in temp directory
{
    my $tmp_dir = tempdir(CLEANUP => 1);

    # Create directory tree
    make_path(
        File::Spec->catdir($tmp_dir, 'lib', 'ChangeTrack'),
        File::Spec->catdir($tmp_dir, 'packaging', 'debian'),
        File::Spec->catdir($tmp_dir, 'packaging', 'rpm'),
    );

    # Populate mock files
    my %mock_files = (
        File::Spec->catfile($tmp_dir, 'lib', 'ChangeTrack', 'Version.pm') => <<'EOF',
package ChangeTrack::Version;
use strict;
use warnings;
our $VERSION = '0.7.3';
1;
EOF
        File::Spec->catfile($tmp_dir, 'Makefile') => <<'EOF',
NAME    := changetrack-ng
VERSION := 0.7.3
EOF
        File::Spec->catfile($tmp_dir, 'CHANGELOG.md') => <<'EOF',
# Changelog
## [Unreleased]

## [0.7.3] - 2026-10-12
* Previous release
EOF
        File::Spec->catfile($tmp_dir, 'packaging', 'debian', 'changelog') => <<'EOF',
changetrack-ng (0.7.3-1) unstable; urgency=medium

  * Previous release.

 -- Christopher Cashell <topher@zyp.org>  Mon, 12 Oct 2026 00:00:00 +0000
EOF
        File::Spec->catfile($tmp_dir, 'packaging', 'rpm', 'changetrack-ng.spec') => <<'EOF',
Name: changetrack-ng
Version: 0.7.3
Release: 1%{?dist}

%changelog
* Mon Oct 12 2026 Christopher Cashell <topher@zyp.org> - 0.7.3-1
- Previous release
EOF
        File::Spec->catfile($tmp_dir, 'PRODUCT.md') => <<'EOF',
# changetrack-ng
Version: 0.7.3
EOF
        File::Spec->catfile($tmp_dir, 'MANIFEST.toml') => <<'EOF',
[meta]
version = "0.7.3"
updated = "2026-10-12"
EOF
        File::Spec->catfile($tmp_dir, 'README.md') => <<'EOF',
# changetrack-ng
Download changetrack-ng-0.7.3.tar.gz
EOF
    );

    for my $p (keys %mock_files) {
        open my $fh, '>', $p or die "Cannot create mock file $p: $!\n";
        print $fh $mock_files{$p};
        close $fh;
    }

    # Copy bump-version into mock directory or call it with repo dir pointing to $tmp_dir
    # Since bump-version computes $repo_dir relative to itself, copy tool to $tmp_dir/tools/
    make_path(File::Spec->catdir($tmp_dir, 'tools'));
    my $mock_tool = File::Spec->catfile($tmp_dir, 'tools', 'bump-version');
    open my $in, '<', $tool or die "Cannot read $tool: $!\n";
    open my $out, '>', $mock_tool or die "Cannot write $mock_tool: $!\n";
    while (<$in>) { print $out $_; }
    close $in;
    close $out;
    chmod 0755, $mock_tool;

    # Run mock bump
    my $cmd = "$^X $mock_tool --date 2026-11-01 --revision 2 0.8.0";
    my $res = `$cmd`;
    is($? >> 8, 0, 'Isolated mock bump-version succeeds');
    like($res, qr/Successfully updated version from 0\.7\.3 to 0\.8\.0/, 'Success message emitted');

    # Validate each target
    my $v_pm = read_test_file(File::Spec->catfile($tmp_dir, 'lib', 'ChangeTrack', 'Version.pm'));
    like($v_pm, qr/our \$VERSION = '0\.8\.0';/, 'Version.pm updated to 0.8.0');

    my $mk = read_test_file(File::Spec->catfile($tmp_dir, 'Makefile'));
    like($mk, qr/VERSION\s*:=\s*0\.8\.0/, 'Makefile updated to 0.8.0');

    my $cl = read_test_file(File::Spec->catfile($tmp_dir, 'CHANGELOG.md'));
    like($cl, qr/## \[Unreleased\]\n\n## \[0\.8\.0\] - 2026-11-01/, 'CHANGELOG.md has new 0.8.0 section and empty [Unreleased]');

    my $deb = read_test_file(File::Spec->catfile($tmp_dir, 'packaging', 'debian', 'changelog'));
    like($deb, qr/^changetrack-ng \(0\.8\.0-2\) unstable; urgency=medium/, 'Debian changelog prepended 0.8.0-2');

    my $rpm = read_test_file(File::Spec->catfile($tmp_dir, 'packaging', 'rpm', 'changetrack-ng.spec'));
    like($rpm, qr/Version:\s*0\.8\.0/, 'RPM spec Version set to 0.8.0');
    like($rpm, qr/Release:\s*2%\{\?dist\}/, 'RPM spec Release set to 2%{?dist}');
    like($rpm, qr/\* Sun Nov 01 2026 Christopher Cashell <topher\@zyp\.org> - 0\.8\.0-2/, 'RPM %changelog prepended correctly');

    my $prod = read_test_file(File::Spec->catfile($tmp_dir, 'PRODUCT.md'));
    like($prod, qr/Version: 0\.8\.0/, 'PRODUCT.md Version updated to 0.8.0');

    my $mf = read_test_file(File::Spec->catfile($tmp_dir, 'MANIFEST.toml'));
    like($mf, qr/version = "0\.8\.0"/, 'MANIFEST.toml version updated to 0.8.0');
    like($mf, qr/updated = "2026-11-01"/, 'MANIFEST.toml updated date set to 2026-11-01');

    my $rm = read_test_file(File::Spec->catfile($tmp_dir, 'README.md'));
    like($rm, qr/changetrack-ng-0\.8\.0\.tar\.gz/, 'README.md inline version references updated');
}

sub read_test_file {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open $file: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

done_testing();

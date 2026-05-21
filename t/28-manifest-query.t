# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
########################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
########################################################################
# 28-manifest-query.t - Tests for tools/manifest-query: --validate,
#   --dist, --category, --field, --deps-deb, --build-deps-deb.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use Cwd qw(abs_path getcwd);

eval { require TOML::Tiny };
plan skip_all => 'TOML::Tiny not installed' if $@;

my $repo_root = abs_path(File::Spec->catdir(__FILE__, '..', '..'));
my $query     = File::Spec->catfile($repo_root, 'tools', 'manifest-query');
my $fixture   = File::Spec->catfile($repo_root, 't', 'fixtures', 'manifest-test.toml');

plan tests => 23;

ok(-f $query,   'tools/manifest-query exists');
ok(-f $fixture, 't/fixtures/manifest-test.toml fixture exists');

# run_query: invoke manifest-query with --manifest pointing at $fixture.
# Returns ($exit_code, \@stdout_lines).
sub run_query {
    my (@args) = @_;
    my @cmd = ($^X, $query, '--manifest', $fixture, @args);
    my $out = '';
    open my $fh, '-|', @cmd
        or die "Cannot run manifest-query: $!\n";
    $out .= $_ while <$fh>;
    close $fh;
    return ($? >> 8, [grep { length $_ } split /\n/, $out]);
}

# run_query_dir: like run_query but from a given directory (for --validate).
sub run_query_dir {
    my ($dir, $manifest, @args) = @_;
    my @cmd = ($^X, $query, '--manifest', $manifest, @args);
    my $old = getcwd();
    chdir $dir;
    my $out = '';
    open my $fh, '-|', @cmd
        or do { chdir $old; die "Cannot run manifest-query: $!\n" };
    $out .= $_ while <$fh>;
    close $fh;
    my $exit = $? >> 8;
    chdir $old;
    return ($exit, [grep { length $_ } split /\n/, $out]);
}

########################################################################
# --dist filtering
########################################################################

{
    my ($exit, $lines) = run_query('--dist', 'full');
    is($exit, 0, '--dist full exits 0');
    my %f = map { $_ => 1 } @$lines;
    ok($f{'bin/test-tool'},              '--dist full includes bin/test-tool');
    ok($f{'lib/Test/Foo.pm'},            '--dist full includes lib/Test/Foo.pm');
    ok($f{'lib/Test/Bar.pm'},            '--dist full includes lib/Test/Bar.pm');
    ok(!$f{'packaging/debian/control'},  '--dist full excludes deb-only file');
}

{
    my ($exit, $lines) = run_query('--dist', 'deb');
    my %f = map { $_ => 1 } @$lines;
    ok($f{'packaging/debian/control'},  '--dist deb includes debian/control');
    ok(!$f{'bin/test-tool'},            '--dist deb excludes program files');
}

########################################################################
# --category filtering
########################################################################

{
    my ($exit, $lines) = run_query('--category', 'library');
    my %f = map { $_ => 1 } @$lines;
    ok($f{'lib/Test/Foo.pm'},   '--category library includes Foo.pm');
    ok($f{'lib/Test/Bar.pm'},   '--category library includes Bar.pm');
    ok(!$f{'bin/test-tool'},    '--category library excludes program files');
}

########################################################################
# --field extraction
########################################################################

{
    my ($exit, $lines) = run_query('--category', 'program', '--field', 'install_path');
    is(scalar @$lines, 1,                 '--field returns one line for one match');
    is($lines->[0], '/usr/bin/test-tool', '--field install_path returns correct value');
}

########################################################################
# --validate
########################################################################

{
    # Fixture references non-existent paths -> should fail
    my $tmpdir = tempdir(CLEANUP => 1);
    my ($exit) = run_query_dir($tmpdir, $fixture, '--validate');
    ok($exit != 0, '--validate exits non-zero when listed files are missing');
}

{
    # Create real files in a temp dir and write a matching manifest
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path(File::Spec->catfile($tmpdir, 'bin'));
    _touch(File::Spec->catfile($tmpdir, 'bin', 'real-tool'));
    my $mf = File::Spec->catfile($tmpdir, 'MANIFEST.toml');
    _write($mf, "[program.\"bin/real-tool\"]\ndescription = \"real\"\n");
    my ($exit) = run_query_dir($tmpdir, $mf, '--validate');
    is($exit, 0, '--validate exits 0 when all listed files exist');
}

########################################################################
# --deps-deb
########################################################################

{
    my ($exit, $lines) = run_query('--deps-deb');
    is($exit, 0, '--deps-deb exits 0');
    my ($dep_line)  = grep { /^Depends:/     } @$lines;
    my ($rec_line)  = grep { /^Recommends:/  } @$lines;
    ok(defined $dep_line,                     '--deps-deb emits Depends: line');
    like($dep_line, qr/perl/,                 'Depends: includes perl');
    like($dep_line, qr/git \| rcs/,           'Depends: includes OR vcs group');
    ok(defined $rec_line,                     '--deps-deb emits Recommends: line');
}

########################################################################
# --build-deps-deb
########################################################################

{
    my ($exit, $lines) = run_query('--build-deps-deb');
    my ($bdep_line) = grep { /^Build-Depends:/ } @$lines;
    ok(defined $bdep_line,             '--build-deps-deb emits Build-Depends: line');
    like($bdep_line, qr/libtoml-tiny/, 'Build-Depends: includes libtoml-tiny-perl');
}

########################################################################
# Helpers
########################################################################

sub _touch {
    my ($path) = @_;
    open my $fh, '>', $path or die "Cannot create $path: $!\n";
}

sub _write {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!\n";
    print $fh $content;
}

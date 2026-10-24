# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 17-precommit-checks.t - Tests for precommit checks.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use lib File::Spec->catdir($RealBin, '..', 'lib');

if ($^O eq 'MSWin32') {
    plan skip_all => 'Special-file and hard-link tests require Unix';
}

use_ok('ChangeTrack::Runner');
use_ok('ChangeTrack::Metadata');
use_ok('ChangeTrack::Report');

my $tmpdir   = tempdir(CLEANUP => 1);
my $have_fifo = eval { require POSIX; defined &POSIX::mkfifo };

########################################################################
# Minimal VCS Stub
########################################################################
package MockVCS;
sub new      { bless {}, shift }
sub model    { 'per-file' }
sub diff     { [] }
sub checkin  {}
sub add      {}

package main;

sub make_runner {
    my (%args) = @_;
    return ChangeTrack::Runner->new(
        config             => '/dev/null',
        quiet              => 1,
        warn_special_files => exists $args{warn_special_files} ? $args{warn_special_files} : 1,
    );
}

sub make_ctx {
    my $md     = ChangeTrack::Metadata->load('/nonexistent/path/for/test');
    my $report = ChangeTrack::Report->new(start_time => time());
    return ($md, $report);
}

########################################################################
# FIFO: Special File Warning Emitted
########################################################################
SKIP: {
    skip 'POSIX::mkfifo not available', 2 unless $have_fifo;

    my $fifo = File::Spec->catfile($tmpdir, 'test.fifo');
    POSIX::mkfifo($fifo, 0600) or skip "mkfifo failed: $!", 2;

    my $runner = make_runner();
    my ($md, $report) = make_ctx();
    my $vcs = MockVCS->new;

    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    $runner->_process_file({ path => $fifo, sensitive => undef }, $vcs, $md, $report, 'test');

    ok(scalar(grep { /special file|FIFO|socket/i } @w), 'FIFO triggers special-file warning');
    if ($report->can('warnings')) {
        my $warnings = $report->warnings;
        ok(scalar(grep { /Skipping special file/i } @{ $warnings // [] }), 'FIFO adds report warning');
    }
    pass('FIFO test completed') unless $report->can('warnings');

    unlink $fifo;
}

########################################################################
# Warn_Special_Files=0: No Warning On Special File
########################################################################
SKIP: {
    skip 'POSIX::mkfifo not available', 1 unless $have_fifo;

    my $fifo = File::Spec->catfile($tmpdir, 'test2.fifo');
    POSIX::mkfifo($fifo, 0600) or skip "mkfifo failed: $!", 1;

    my $runner = make_runner(warn_special_files => 0);
    my ($md, $report) = make_ctx();
    my $vcs = MockVCS->new;

    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    $runner->_process_file({ path => $fifo, sensitive => undef }, $vcs, $md, $report, 'test');

    ok(!grep { /WARNING.*special/i } @w, 'warn_special_files=0 suppresses special-file warning');
    unlink $fifo;
}

########################################################################
# Hardlinked File: Warning Emitted
########################################################################
{
    my ($fh, $src) = tempfile(DIR => $tmpdir, SUFFIX => '.txt');
    print $fh "data\n";
    close $fh;

    my $link = File::Spec->catfile($tmpdir, 'hardlink.txt');
    if (!link($src, $link)) {
        SKIP: { skip "hard links not supported: $!", 1 }
    } else {
        my $runner = make_runner();
        my ($md, $report) = make_ctx();
        my $vcs = MockVCS->new;

        my @w;
        local $SIG{__WARN__} = sub { push @w, @_ };
        $runner->_process_file({ path => $src, sensitive => undef }, $vcs, $md, $report, 'test');

        ok(scalar(grep { /hard link/i } @w), 'hardlinked file triggers hardlink warning');
        unlink $link;
    }
    unlink $src;
}

########################################################################
# Regular File (Nlink=1): No Hardlink Warning
########################################################################
{
    my ($fh, $src) = tempfile(DIR => $tmpdir, SUFFIX => '.txt');
    print $fh "data\n";
    close $fh;

    my $runner = make_runner();
    my ($md, $report) = make_ctx();
    my $vcs = MockVCS->new;

    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    $runner->_process_file({ path => $src, sensitive => undef }, $vcs, $md, $report, 'test');

    ok(!grep { /hard link/i } @w, 'regular file (nlink=1) produces no hardlink warning');
    unlink $src;
}

########################################################################
# Makefile: install-user-systemd Recipe Checks
########################################################################
{
    my $makefile = File::Spec->catfile($RealBin, '..', 'Makefile');
    open my $fh, '<', $makefile or die "Cannot open $makefile: $!";
    my $in_target = 0;
    my $recipe = '';
    while (my $line = <$fh>) {
        if ($line =~ /^install-user-systemd:/) {
            $in_target = 1;
            next;
        }
        if ($in_target) {
            last if $line =~ /^[a-zA-Z0-9_\-]+:/;
            $recipe .= $line;
        }
    }
    close $fh;

    ok($recipe =~ m{/\@DEFAULTSDIR\@/d}, 'install-user-systemd recipe strips @DEFAULTSDIR@');
    ok($recipe =~ m{s\|--system\|--user\|g}, 'install-user-systemd recipe transforms --system to --user');
    ok($recipe =~ m{s\|\@BINDIR\@\|\$\(HOME\)/\.local/bin\|g}, 'install-user-systemd recipe sets user BINDIR');
}

########################################################################
# VCS Base: _with_temp_mirror_sync Helper
########################################################################
{
    require ChangeTrack::VCS::Base;
    can_ok('ChangeTrack::VCS::Base', '_with_temp_mirror_sync');

    my $dummy = bless { output_dir => $tmpdir }, 'ChangeTrack::VCS::Base';
    my $real   = File::Spec->catfile($tmpdir, 'real.txt');
    my $mirror = File::Spec->catfile($tmpdir, 'mirror.txt');

    # Write real file
    open my $rfh, '>', $real or die "Cannot write $real: $!";
    print $rfh "real content\n";
    close $rfh;

    # Case 1: Mirror does not exist initially
    unlink $mirror if -e $mirror;
    my $called = 0;
    $dummy->_with_temp_mirror_sync($real, $mirror, sub {
        $called = 1;
        ok(-f $mirror, 'mirror file exists during callback (initially absent)');
    });
    ok($called, 'callback was executed');
    ok(!-e $mirror, 'mirror file removed after callback when initially absent');

    # Case 2: Mirror exists initially
    open my $mfh, '>', $mirror or die "Cannot write $mirror: $!";
    print $mfh "original mirror\n";
    close $mfh;
    my @orig_st = stat($mirror);

    my $inside_ok = 0;
    $dummy->_with_temp_mirror_sync($real, $mirror, sub {
        open my $check_fh, '<', $mirror or return;
        my $content = do { local $/; <$check_fh> };
        close $check_fh;
        $inside_ok = ($content eq "real content\n");
    });
    ok($inside_ok, 'mirror had synced real content during callback');

    open my $check_fh, '<', $mirror or die "Cannot read $mirror: $!";
    my $restored_content = do { local $/; <$check_fh> };
    close $check_fh;
    is($restored_content, "original mirror\n", 'mirror content restored after callback');
    my @restored_st = stat($mirror);
    is($restored_st[9], $orig_st[9], 'mirror mtime restored after callback');

    # Cleanup
    unlink $real, $mirror;
}

########################################################################
# Release Tarball Simulation: tools/doc-lint Without dev_doc Files
########################################################################
{
    my $sim_dir  = tempdir(CLEANUP => 1);
    my $repo_dir = File::Spec->catdir($RealBin, '..');

    # Mirror the release tarball layout (excluding dev_doc files like AGENTS.md and TODO.md)
    for my $subdir (qw(bin lib man docs tools)) {
        my $src = File::Spec->catdir($repo_dir, $subdir);
        my $dst = File::Spec->catdir($sim_dir, $subdir);
        symlink($src, $dst) or die "Cannot symlink $src -> $dst: $!";
    }
    for my $doc (qw(README.md CHANGELOG.md INSTALL.md CONTRIBUTING.md ARCHITECTURE.md PRODUCT.md SECURITY.md)) {
        my $src = File::Spec->catfile($repo_dir, $doc);
        my $dst = File::Spec->catfile($sim_dir, $doc);
        symlink($src, $dst) or die "Cannot symlink $src -> $dst: $!";
    }

    ok(!-e File::Spec->catfile($sim_dir, 'AGENTS.md'), 'tarball simulation excludes AGENTS.md');
    my $doc_lint = File::Spec->catfile($sim_dir, 'tools', 'doc-lint');
    my $out = '';
    open(my $lfh, '-|', $^X, $doc_lint) or die "Cannot run doc-lint: $!";
    $out .= $_ while <$lfh>;
    close($lfh);
    is($? >> 8, 0, 'tools/doc-lint succeeds when AGENTS.md is absent (release tarball mode)');
}

########################################################################
# tools/build-packages: Versioned Subdirectory & SHA256SUMS Filtering
########################################################################
{
    my $bp_file = File::Spec->catfile($RealBin, '..', 'tools', 'build-packages');
    open(my $bfh, '<', $bp_file) or die "Cannot open $bp_file: $!";
    my $bp_src = do { local $/; <$bfh> };
    close($bfh);

    like($bp_src, qr/my \$ver_subdir\s*=\s*"v\$version"/, 'build-packages uses v<version> subdirectory');
    like($bp_src, qr/catdir\(\$opt_release_dir,\s*\$ver_subdir\)/, 'build-packages stages releases under RELEASE_DIR/v<version>');
    like($bp_src, qr/buildinfo\|changes/, 'build-packages excludes .buildinfo and .changes from SHA256SUMS');
}

done_testing();

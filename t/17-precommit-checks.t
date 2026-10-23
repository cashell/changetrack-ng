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

done_testing();

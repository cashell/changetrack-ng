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

done_testing();

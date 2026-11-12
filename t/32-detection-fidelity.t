# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# 32-detection-fidelity.t - Tests for the ctime content fast-path (CTNG-19)
#   and webhook sensitive-count suppression + diff cap (CTNG-21, CTNG-22).
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Metadata');
use_ok('ChangeTrack::Report');
use_ok('ChangeTrack::Notify::Webhook');
use_ok('ChangeTrack::Runner');
use_ok('ChangeTrack::Config');

########################################################################
# ctime fast-path (CTNG-19): same mtime+size but different ctime -> not skipped
########################################################################

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/tracked.txt";
open(my $fh, '>', $file) or die $!;
print $fh "hello world";
close($fh);

my @st = lstat($file);
my ($size, $mtime, $ctime) = ($st[7] + 0, $st[9] + 0, $st[10] + 0);

my $md = ChangeTrack::Metadata->load("$dir/.changetrack-metadata");   # empty

# Matching mtime+size+ctime -> content can be skipped.
$md->{original}{$file}
    = { type => 'file', size => $size, mtime => $mtime, ctime => $ctime };
is($md->can_skip_content_diff($file), 1, 'skip when mtime+size+ctime all match');

# Same mtime+size but different ctime -> must NOT skip (catches restored mtime).
$md->{original}{$file}
    = { type => 'file', size => $size, mtime => $mtime, ctime => $ctime - 100 };
is($md->can_skip_content_diff($file), 0, 'do not skip when ctime differs');

# Back-compat: a record with no ctime falls back to mtime+size.
$md->{original}{$file} = { type => 'file', size => $size, mtime => $mtime };
is($md->can_skip_content_diff($file), 1, 'ctime-less record falls back to mtime+size');

# Size change is still detected.
$md->{original}{$file}
    = { type => 'file', size => $size + 1, mtime => $mtime, ctime => $ctime };
is($md->can_skip_content_diff($file), 0, 'size change is detected');

# A fresh stat records ctime.
$md->update_from_stat($file);
ok(defined $md->{records}{$file}{ctime}, 'update_from_stat records ctime');

########################################################################
# Webhook: suppress sensitive line counts (CTNG-21) + diff cap (CTNG-22)
########################################################################

# Sensitive file with suppression: no diff body and zeroed line counts.
{
    my $n = ChangeTrack::Notify::Webhook->new(url => '', full_diff => 1);
    my $r = ChangeTrack::Report->new(start_time => 1000000000);
    $r->add_change(
        path => '/etc/shadow', is_new => 0, is_sensitive => 1,
        diff => ['-old', '+new', '+extra'], meta_change => '', recipients => [],
    );
    my $p = $n->_build_payload($r, 0);
    my $f = $p->{files}[0];
    ok(!exists $f->{diff},          'sensitive diff body suppressed');
    is($f->{diff_lines_added},   0, 'sensitive added-count suppressed to 0');
    is($f->{diff_lines_removed}, 0, 'sensitive removed-count suppressed to 0');
}

# Non-sensitive large diff with a byte cap: body present and truncated flag set.
{
    my $n = ChangeTrack::Notify::Webhook->new(
        url => '', full_diff => 1, max_diff_bytes => 10);
    my $r = ChangeTrack::Report->new(start_time => 1000000000);
    $r->add_change(
        path => '/etc/hosts', is_new => 0, is_sensitive => 0,
        diff => ['+' . ('x' x 100)], meta_change => '', recipients => [],
    );
    my $p = $n->_build_payload($r, 0);
    my $f = $p->{files}[0];
    ok(exists $f->{diff},                'diff present for non-sensitive change');
    ok(length($f->{diff}) < 100,         'diff truncated to the byte cap');
    ok($f->{diff_truncated},             'diff_truncated flag set when capped');
}

########################################################################
# CTNG-35: _truncate_diff caps by encoded UTF-8 bytes, not characters
########################################################################

{
    my $n = ChangeTrack::Notify::Webhook->new(url => '', max_diff_bytes => 8);
    # 6 multibyte chars (each 2 bytes in UTF-8 = 12 bytes) exceeds the 8-byte cap.
    my ($text, $trunc) = $n->_truncate_diff("\x{00e9}" x 6);
    ok($trunc, 'multibyte diff exceeding the byte cap is truncated');
    require Encode;
    cmp_ok(length(Encode::encode('UTF-8', $text)), '>', 8,
        'truncated text includes the notice marker');
    my ($t2, $tr2) = $n->_truncate_diff('abc');
    ok(!$tr2, 'short diff is not truncated');
    is($t2, 'abc', 'short diff returned unchanged');
}

########################################################################
# max_file_size Handling: Oversize Skip, One-Time Warning & Transition
########################################################################
{
    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    chmod 0700, $output_dir;
    my $track_dir  = "$work_dir/files";
    make_path($track_dir);

    my $large_file = "$track_dir/large.bin";
    open(my $fh1, '>', $large_file) or die $!;
    print {$fh1} "X" x 100;
    close($fh1);

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh} "[global]\nvcs = git\noutput_dir = $output_dir\nmax_file_size = 50\n\n[track]\nDIRECTORY $track_dir\n";
    close($cfh);
    chmod 0600, $cfg_path;

    # Run 1: initial detection of oversize file
    my $rep1 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    ok(scalar(grep { /skipping oversize file \(100 bytes > max_file_size 50\)/ } @{ $rep1->warnings }),
        'oversize file emits warning on initial detection');
    is(scalar @{ $rep1->changes }, 0, 'oversize file not included in change report');

    my $md1 = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    ok(defined $md1->record_for($large_file), 'oversize file recorded in metadata');
    is($md1->record_for($large_file)->{type}, 'oversize', 'metadata record has type oversize');

    # Run 2: second run with unchanged oversize file suppresses duplicate warning
    my $rep2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    ok(!scalar(grep { /skipping oversize file/ } @{ $rep2->warnings }),
        'oversize warning is one-time (not repeated when unchanged)');

    # Add a normal file that subsequently grows past max_file_size
    my $grow_file = "$track_dir/grow.txt";
    open(my $fh2, '>', $grow_file) or die $!;
    print {$fh2} "small content\n";
    close($fh2);

    my $rep3 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    my @new_changes = grep { $_->{path} eq $grow_file && $_->{is_new} } @{ $rep3->changes };
    is(scalar @new_changes, 1, 'grow.txt tracked initially while small');

    # Grow file beyond max_file_size
    open(my $fh3, '>>', $grow_file) or die $!;
    print {$fh3} "Y" x 100;
    close($fh3);

    # Run 4: file -> oversize transition
    my $rep4 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    ok(scalar(grep { /skipping oversize file/ } @{ $rep4->warnings }),
        'file -> oversize transition emits warning');

    my @rem = grep { $_->{path} eq $grow_file && $_->{is_removed} } @{ $rep4->changes };
    is(scalar @rem, 1, 'file -> oversize transition records removal change');
    like("@{ $rem[0]{diff} }", qr/file became oversize/,
        'diff describes removal from VCS tracking due to oversize');
    is($rem[0]{meta_change}, 'transition from file to oversize (removed from VCS)',
        'meta_change records transition description');
}

########################################################################
# Directory Listed Without DIRECTORY Keyword Auto-Promotes With Warning
########################################################################
{
    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    chmod 0700, $output_dir;
    my $sub_dir    = "$work_dir/configs";
    make_path($sub_dir);

    my $conf_file = "$sub_dir/app.conf";
    open(my $fh, '>', $conf_file) or die $!;
    print {$fh} "setting=on\n";
    close($fh);

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    # Note: path listed without 'DIRECTORY' prefix
    print {$cfh} "[global]\nvcs = git\noutput_dir = $output_dir\n\n[track]\n$sub_dir\n";
    close($cfh);
    chmod 0600, $cfg_path;

    my $rep = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    ok(scalar(grep { /\[track\] entry '.*configs' is a directory; treating as 'DIRECTORY / } @{ $rep->warnings }),
        'directory entry without DIRECTORY keyword emits auto-promotion warning');
    ok(scalar(grep { $_->{path} eq $conf_file && $_->{is_new} } @{ $rep->changes }),
        'files inside auto-promoted directory are tracked successfully');
}

########################################################################
# Non-Trackable Files Report Metadata Changes (CORR-17)
########################################################################
{
    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    chmod 0700, $output_dir;
    my $track_dir  = "$work_dir/non_trackable";
    make_path($track_dir);

    # 1. Binary file
    my $bin_file = "$track_dir/data.bin";
    open(my $fh1, '>', $bin_file) or die $!;
    binmode($fh1);
    print {$fh1} "text\0binary\0data";
    close($fh1);
    chmod 0644, $bin_file;

    # 2. Oversize file
    my $big_file = "$track_dir/big.dat";
    open(my $fh2, '>', $big_file) or die $!;
    print {$fh2} "Z" x 80;
    close($fh2);
    chmod 0644, $big_file;

    # 3. Unreadable file
    my $unreadable_file = "$track_dir/unreadable.txt";
    open(my $fh3, '>', $unreadable_file) or die $!;
    print {$fh3} "secret text\n";
    close($fh3);
    chmod 0000, $unreadable_file;

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh} "[global]\nvcs = git\noutput_dir = $output_dir\nmax_file_size = 50\n\n[track]\nDIRECTORY $track_dir\n";
    close($cfh);
    chmod 0600, $cfg_path;

    # Initial run: all 3 recorded in metadata
    ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;

    # Modify metadata of all three without making them VCS-eligible text files
    chmod 0600, $bin_file;
    chmod 0640, $big_file;
    chmod 0200, $unreadable_file; # write-only, still not readable (mode change 0000 -> 0200)

    # Second run: metadata changes should be reported (CORR-17)
    my $rep = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    my %by_path = map { $_->{path} => $_ } @{ $rep->changes };

    ok(exists $by_path{$bin_file}, 'binary file metadata change is reported');
    like("@{ $by_path{$bin_file}{diff} }", qr/metadata changed: mode/,
        'binary file diff describes metadata change');
    is($by_path{$bin_file}{is_new}, 0, 'binary file is not marked as new');

    ok(exists $by_path{$big_file}, 'oversize file metadata change is reported');
    like("@{ $by_path{$big_file}{diff} }", qr/metadata changed: mode/,
        'oversize file diff describes metadata change');

    ok(exists $by_path{$unreadable_file}, 'unreadable file metadata change is reported');
    like("@{ $by_path{$unreadable_file}{diff} }", qr/metadata changed: mode/,
        'unreadable file diff describes metadata change');

    # Clean up unreadable file permissions so tempdir removal succeeds
    chmod 0644, $unreadable_file;
}

########################################################################
# Dirty-Only Metadata Save Avoids Unnecessary Writes (PERF-6)
########################################################################
{
    my $work_dir   = tempdir(CLEANUP => 1);
    my $output_dir = tempdir(CLEANUP => 1);
    chmod 0700, $output_dir;
    my $track_dir  = "$work_dir/perf";
    make_path($track_dir);

    my $file = "$track_dir/clean.txt";
    open(my $fh, '>', $file) or die $!;
    print {$fh} "steady state content\n";
    close($fh);

    my ($cfh, $cfg_path) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print {$cfh} "[global]\nvcs = git\noutput_dir = $output_dir\n\n[track]\nDIRECTORY $track_dir\n";
    close($cfh);
    chmod 0600, $cfg_path;

    # Run 1 creates the sidecar
    ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    my $meta_path = "$output_dir/.changetrack-metadata";
    ok(-f $meta_path, 'metadata sidecar created after initial run');

    my @st_orig = stat($meta_path);
    my $orig_inode = $st_orig[1];
    my $orig_mtime = $st_orig[9];

    # Run 2 is a no-op run: no files changed, added, or deleted
    my $rep2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    is(scalar @{ $rep2->changes }, 0, 'no changes in second run');

    my @st_after = stat($meta_path);
    is($st_after[1], $orig_inode, 'metadata sidecar inode unchanged on no-op run (PERF-6)');
    is($st_after[9], $orig_mtime, 'metadata sidecar mtime unchanged on no-op run');
}

done_testing();

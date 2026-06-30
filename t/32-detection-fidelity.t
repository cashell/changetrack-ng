# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 32-detection-fidelity.t - Tests for the ctime content fast-path (CTNG-19)
#   and webhook sensitive-count suppression + diff cap (CTNG-21, CTNG-22).
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Metadata');
use_ok('ChangeTrack::Report');
use_ok('ChangeTrack::Notify::Webhook');

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

done_testing();

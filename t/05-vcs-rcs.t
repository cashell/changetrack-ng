# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# 05-vcs-rcs.t - Tests for vcs rcs.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use File::Basename qw(basename dirname);
use lib File::Spec->catdir($RealBin, '..', 'lib');

# Skip if rcs tooling not available
my $CI_BIN = do {
    my $found;
    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
        if (-x "$dir/ci") { $found = "$dir/ci"; last }
    }
    $found;
};
plan skip_all => 'rcs tools (ci/rcsdiff) not found in PATH' unless $CI_BIN;

use_ok('ChangeTrack::VCS::RCS');

my $output_dir  = tempdir(CLEANUP => 1);
my $tracked_dir = tempdir(CLEANUP => 1);

my $vcs = ChangeTrack::VCS::RCS->new(output_dir => $output_dir);
isa_ok($vcs, 'ChangeTrack::VCS::RCS');
isa_ok($vcs, 'ChangeTrack::VCS::Base');

########################################################################
# Model
########################################################################
is($vcs->model, 'per-file', 'model returns per-file');

########################################################################
# Init / Is_Initialized
########################################################################
ok(!$vcs->is_initialized, 'not initialized before init');
$vcs->init;
ok($vcs->is_initialized,   'initialized after init');
ok(-d "$output_dir/RCS",   'RCS subdirectory created');

########################################################################
# Output_Path
########################################################################
is($vcs->output_path('/etc/passwd'),
    "$output_dir/etc:passwd",
    'output_path: single level');

is($vcs->output_path('/etc/ssl/certs/ca.crt'),
    "$output_dir/etc:ssl:certs:ca.crt",
    'output_path: nested path');

eval { $vcs->output_path('/etc/../shadow') };
like($@, qr/unsafe tracked path/, 'output_path rejects .. traversal');

########################################################################
# Checkin (New File)
########################################################################
my $test_file = "$tracked_dir/test.conf";
open(my $fh, '>', $test_file) or die "Cannot create: $!";
print $fh "setting = original\n";
close($fh);

my $rev1;
my $err = do { local $@; eval { $rev1 = $vcs->checkin($test_file, 'Initial checkin') }; $@ };
is($err, '', 'checkin new file: no error');
is($rev1, '1.1', 'checkin: returns revision 1.1');

# Verify ,v file was created
my $op       = $vcs->output_path($test_file);
my $rcs_file = dirname($op) . '/RCS/' . basename($op) . ',v';
ok(-e $rcs_file, 'checkin: ,v file created');

########################################################################
# Is_Dirty (After Checkin, Should Be Clean)
########################################################################
ok(!$vcs->is_dirty($test_file), 'is_dirty: false after initial checkin');

########################################################################
# Diff On Unchanged File
########################################################################
my $diff = $vcs->diff($test_file);
is_deeply($diff, [], 'diff: empty for unchanged file');

########################################################################
# Modify File -> Is_Dirty / Diff
########################################################################
open($fh, '>', $test_file) or die $!;
print $fh "setting = modified\n";
close($fh);

ok($vcs->is_dirty($test_file), 'is_dirty: true after modification');

$diff = $vcs->diff($test_file);
ok(@$diff > 0, 'diff: non-empty after modification');
like(join("\n", @$diff), qr/modified/, 'diff: contains modification');
like(join("\n", @$diff), qr/^\+\+\+/m, 'diff: looks like unified diff');
ok($vcs->is_dirty($test_file), 'is_dirty: remains true after non-mutating diff');

########################################################################
# Checkin Modified File
########################################################################
my $rev2;
$err = do { local $@; eval { $rev2 = $vcs->checkin($test_file, 'Modification') }; $@ };
is($err, '', 'checkin modified file: no error');
is($rev2, '1.2', 'checkin: returns revision 1.2');
ok(!$vcs->is_dirty($test_file), 'is_dirty: false after second checkin');

########################################################################
# Log_History
########################################################################
my $log = $vcs->log_history($test_file);
ok(@$log > 0, 'log_history: returns lines');
like(join("\n", @$log), qr/Initial checkin/, 'log_history: contains first commit msg');
like(join("\n", @$log), qr/Modification/,    'log_history: contains second commit msg');

########################################################################
# Add And Commit Are No-Ops For RCS
########################################################################
my $add_err    = do { local $@; eval { $vcs->add($test_file) };    $@ };
my $commit_err = do { local $@; eval { $vcs->commit('batch msg') }; $@ };
is($add_err,    '', 'add: no-op, no error');
is($commit_err, '', 'commit: no-op, no error');

########################################################################
# Revert And Subsequent Checkin
########################################################################
eval { $vcs->revert($test_file, '1.1') };
is($@, '', 'revert: succeeds without error');

my $restored_content = do {
    open(my $rfh, '<', $test_file) or die "Cannot read $test_file: $!";
    local $/;
    <$rfh>;
};
is($restored_content, "setting = original\n", 'revert: content restored to 1.1');

open($fh, '>', $test_file) or die "Cannot write $test_file: $!";
print $fh "setting = third\n";
close($fh);

eval { $vcs->checkin($test_file, 'Third checkin') };
is($@, '', 'checkin after revert: no error (lock not corrupted)');

########################################################################
# Metadata-Only Checkin Forces New Revision via -f (FEAT-5)
########################################################################
{
    # File content unchanged, but chmod changes mode
    chmod 0600, $test_file or die "chmod failed: $!";
    my $rev_meta = $vcs->checkin($test_file, 'Metadata chmod only');
    ok(defined $rev_meta && length $rev_meta, 'checkin with only metadata change produces new revision');
    isnt($rev_meta, '1.3', 'new revision created for metadata-only change');

    # Verify metadata_at_revision
    my $meta_rec = $vcs->metadata_at_revision($test_file, $rev_meta);
    ok(defined $meta_rec, 'metadata_at_revision: returns record');
    is($meta_rec->{mode}, '0600', 'metadata_at_revision: recorded mode 0600');
    is($meta_rec->{path}, $test_file, 'metadata_at_revision: records path');

    is($vcs->metadata_at_revision($test_file, '99.99'), undef,
        'metadata_at_revision: returns undef for non-existent revision');
    is($vcs->metadata_at_revision($test_file, '-invalid'), undef,
        'metadata_at_revision: rejects revision starting with hyphen');
}

########################################################################
# Revert: Recreate Missing Parent and Leave Mirror Clean at HEAD (CORR-14)
########################################################################
{
    my $sub_dir   = "$tracked_dir/rcs_revert_sub";
    mkdir $sub_dir or die $!;
    my $sub_file  = "$sub_dir/revert.conf";

    open(my $sfh, '>', $sub_file) or die $!;
    print {$sfh} "rcs revert v1\n";
    close($sfh);

    my $r1 = $vcs->checkin($sub_file, 'Subfile v1');
    is($r1, '1.1', 'subfile checkin v1');

    open($sfh, '>', $sub_file) or die $!;
    print {$sfh} "rcs revert v2\n";
    close($sfh);

    my $r2 = $vcs->checkin($sub_file, 'Subfile v2');
    is($r2, '1.2', 'subfile checkin v2');

    # Delete live file and parent directory
    unlink $sub_file or die $!;
    rmdir $sub_dir   or die $!;
    ok(!-d $sub_dir, 'rcs revert: parent directory removed before revert');

    # Revert to r1
    eval { $vcs->revert($sub_file, $r1) };
    is($@, '', 'rcs revert: succeeds with missing parent directory');
    ok(-f $sub_file, 'rcs revert: live file restored');

    open(my $check_fh, '<', $sub_file) or die $!;
    my $content = do { local $/; <$check_fh> };
    close($check_fh);
    is($content, "rcs revert v1\n", 'rcs revert: content restored to v1');

    # VCS mirror remains at HEAD, so is_dirty must be true
    ok($vcs->is_dirty($sub_file), 'is_dirty: true after revert because live file differs from RCS HEAD');
}

########################################################################
# Show_At_Revision, Historical Diff, and Repo-Wide Log_History (WP 4A)
########################################################################
{
    # Base class stub
    my $base = ChangeTrack::VCS::Base->new(output_dir => $output_dir);
    eval { $base->show_at_revision($test_file, '1.1') };
    like($@, qr/not implemented/, 'VCS::Base::show_at_revision croaks with not implemented');

    my $hist_file = "$tracked_dir/hist_rcs.conf";
    open(my $hfh, '>', $hist_file) or die $!;
    print {$hfh} "line one\n";
    close($hfh);
    my $hr1 = $vcs->checkin($hist_file, 'Hist RCS v1');

    open($hfh, '>', $hist_file) or die $!;
    print {$hfh} "line two\n";
    close($hfh);
    my $hr2 = $vcs->checkin($hist_file, 'Hist RCS v2');

    # Modify live file without checking in
    open($hfh, '>', $hist_file) or die $!;
    print {$hfh} "line live\n";
    close($hfh);

    # show_at_revision on regular file
    my $s1 = $vcs->show_at_revision($hist_file, $hr1);
    is($s1->{is_symlink}, 0, 'show_at_revision: regular file is_symlink is 0');
    is($s1->{target}, undef, 'show_at_revision: regular file target is undef');
    is($s1->{content}, "line one\n", 'show_at_revision: retrieves rev 1.1 content');

    my $s2 = $vcs->show_at_revision($hist_file, $hr2);
    is($s2->{content}, "line two\n", 'show_at_revision: retrieves rev 1.2 content');

    # Live file untouched by show_at_revision
    open(my $lfh, '<', $hist_file) or die $!;
    my $live_now = do { local $/; <$lfh> };
    close($lfh);
    is($live_now, "line live\n", 'show_at_revision: does not mutate live file');

    # Symlink show_at_revision
    my $sym_path = "$tracked_dir/hist_rcs.link";
    symlink('/etc/hosts', $sym_path) or die "symlink failed: $!";
    my $sr1 = $vcs->checkin($sym_path, 'RCS symlink v1');
    my $sym_res = $vcs->show_at_revision($sym_path, $sr1);
    is($sym_res->{is_symlink}, 1, 'show_at_revision: symlink is_symlink is 1');
    is($sym_res->{target}, '/etc/hosts', 'show_at_revision: symlink target extracted');

    # Error cases for show_at_revision
    eval { $vcs->show_at_revision($hist_file, '99.99') };
    ok($@, 'show_at_revision: croaks on invalid revision');
    eval { $vcs->show_at_revision("$tracked_dir/does_not_exist.conf", '1.1') };
    ok($@, 'show_at_revision: croaks on missing archive');
    eval { $vcs->show_at_revision($hist_file, '-1.1') };
    like($@, qr/unsafe revision/, 'show_at_revision: rejects leading hyphen');
    eval { $vcs->show_at_revision('', '1.1') };
    ok($@, 'show_at_revision: croaks on empty path');

    # 1-arg diff($path, $rev1): rev1 vs live file
    my $d1 = $vcs->diff($hist_file, $hr1);
    like(join("\n", @$d1), qr/-line one/, 'diff(path, rev1): shows old rev1 line');
    like(join("\n", @$d1), qr/\+line live/, 'diff(path, rev1): shows live line');
    ok($vcs->is_dirty($hist_file), 'diff(path, rev1): preserves dirty state');

    # 2-arg diff($path, $rev1, $rev2): rev1 vs rev2
    my $d12 = $vcs->diff($hist_file, $hr1, $hr2);
    like(join("\n", @$d12), qr/-line one/, 'diff(path, rev1, rev2): shows rev1 line');
    like(join("\n", @$d12), qr/\+line two/, 'diff(path, rev1, rev2): shows rev2 line');
    unlike(join("\n", @$d12), qr/line live/, 'diff(path, rev1, rev2): ignores live file');

    my $d_same = $vcs->diff($hist_file, $hr1, $hr1);
    is_deeply($d_same, [], 'diff(path, rev1, rev1): empty diff for identical revisions');

    eval { $vcs->diff($hist_file, undef, $hr2) };
    ok($@, 'diff: croaks when rev2 provided without rev1');
    eval { $vcs->diff($hist_file, '-1.1') };
    like($@, qr/unsafe revision/, 'diff: rejects leading hyphen in rev1');

    # Remove working mirror of hist_file and verify repo-wide log_history(undef)
    $vcs->remove($hist_file);
    my $repo_log = $vcs->log_history(undef);
    my $repo_log_str = join("\n", @$repo_log);
    like($repo_log_str, qr/Initial checkin/, 'log_history(undef): includes test.conf history');
    like($repo_log_str, qr/Hist RCS v2/,     'log_history(undef): includes removed file history');
}

done_testing();

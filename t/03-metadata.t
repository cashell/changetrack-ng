# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 03-metadata.t - Tests for metadata.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Metadata');

########################################################################
# Empty Load (No File)
########################################################################
{
    my $md = ChangeTrack::Metadata->load('/nonexistent/path/to/metadata.jsonl');
    ok(defined $md, 'load: returns object even if file missing');
    is($md->record_for('/etc/passwd'), undef, 'load: empty metadata returns undef for any path');
    ok(!$md->changed_since_load('/etc/passwd'), 'changed_since_load: false for untracked file');
}

########################################################################
# Update_From_Stat And Record_For
########################################################################
{
    my ($fh, $test_file) = tempfile(UNLINK => 1, SUFFIX => '.conf');
    print $fh "key = value\n";
    close($fh);
    chmod(0644, $test_file);

    my $md = ChangeTrack::Metadata->load('/nonexistent');
    $md->update_from_stat($test_file);

    my $rec = $md->record_for($test_file);
    ok(defined $rec, 'record_for: returns record after update_from_stat');
    is($rec->{path}, $test_file, 'record: path correct');
    is($rec->{type}, 'file',     'record: type is file');
    like($rec->{mode}, qr/^\d{4}$/, 'record: mode is 4-digit octal string');
    ok(defined $rec->{uid},   'record: uid present');
    ok(defined $rec->{gid},   'record: gid present');
    ok(defined $rec->{user},  'record: user present');
    ok(defined $rec->{group}, 'record: group present');
    ok(defined $rec->{mtime}, 'record: mtime present for regular file');
    ok(defined $rec->{size},  'record: size present for regular file');
}

########################################################################
# Changed_Since_Load
########################################################################
{
    my ($fh, $test_file) = tempfile(UNLINK => 1, SUFFIX => '.conf');
    print $fh "key = value\n";
    close($fh);
    chmod(0644, $test_file);

    # Create a fake "loaded" state at 0600
    my @s     = stat($test_file);
    my %orig_rec = (
        path  => $test_file,
        mode  => '0600',          # deliberately different from actual 0644
        uid   => $s[4],
        gid   => $s[5],
        user  => ($^O eq 'MSWin32' ? $s[4] : (getpwuid($s[4]))[0] // $s[4]),
        group => ($^O eq 'MSWin32' ? $s[5] : (getgrgid($s[5]))[0] // $s[5]),
        type  => 'file',
    );

    # Simulate a "loaded" metadata object with that stale record
    my $md = bless {
        records  => { $test_file => { %orig_rec } },
        original => { $test_file => { %orig_rec } },
    }, 'ChangeTrack::Metadata';

    ok($md->changed_since_load($test_file), 'changed_since_load: true when mode differs');

    # diff_summary should mention mode
    my $summary = $md->diff_summary($test_file);
    like($summary, qr/mode/, 'diff_summary: mentions mode');
    like($summary, qr/0600/, 'diff_summary: shows old mode');
}

########################################################################
# No Change Detected When Metadata Matches
########################################################################
{
    my ($fh, $test_file) = tempfile(UNLINK => 1, SUFFIX => '.conf');
    print $fh "key = value\n";
    close($fh);

    my $md = ChangeTrack::Metadata->load('/nonexistent');
    $md->update_from_stat($test_file);

    # Simulate load by copying records to original
    $md->{original} = { map { $_ => { %{ $md->{records}{$_} } } } keys %{ $md->{records} } };

    ok(!$md->changed_since_load($test_file), 'changed_since_load: false when nothing changed');
    is($md->diff_summary($test_file), '', 'diff_summary: empty when nothing changed');

    ok($md->can_skip_content_diff($test_file), 'can_skip_content_diff: true when mtime+size unchanged');

    # content + mtime change should invalidate the skip fast-path
    sleep 1;
    open(my $fh2, '>>', $test_file) or die $!;
    print $fh2 "extra\n";
    close($fh2);
    ok(!$md->can_skip_content_diff($test_file), 'can_skip_content_diff: false when content fingerprint changed');
}

########################################################################
# Can_Skip_Content_Diff True For Zero-Byte -> Zero-Byte
########################################################################
{
    my ($fh, $test_file) = tempfile(UNLINK => 1, SUFFIX => '.log');
    close($fh);   # leave it empty (0 bytes)

    my $md = ChangeTrack::Metadata->load('/nonexistent/path/that/will/never/exist');
    $md->update_from_stat($test_file);
    # Freeze current state as the "loaded" snapshot
    $md->{original} = { map { $_ => { %{ $md->{records}{$_} } } } keys %{ $md->{records} } };

    ok($md->can_skip_content_diff($test_file), 'can_skip_content_diff: true for zero-byte file with unchanged size=0');

    # Even if mtime advances (e.g. touch), content still cannot have changed
    sleep 1;
    utime(time(), time(), $test_file);
    ok($md->can_skip_content_diff($test_file), 'can_skip_content_diff: true for zero-byte file after mtime bump');
}

########################################################################
# Can_Skip_Content_Diff False For Legacy Records Without Mtime/Size
########################################################################
{
    my ($fh, $test_file) = tempfile(UNLINK => 1, SUFFIX => '.conf');
    print $fh "legacy\n";
    close($fh);

    my @s = stat($test_file);
    my $md = bless {
        records  => { $test_file => {
            path  => $test_file,
            type  => 'file',
            mode  => sprintf('%04o', $s[2] & 07777),
            uid   => $s[4],
            gid   => $s[5],
            user  => ($^O eq 'MSWin32' ? $s[4] : (getpwuid($s[4]))[0] // $s[4]),
            group => ($^O eq 'MSWin32' ? $s[5] : (getgrgid($s[5]))[0] // $s[5]),
        } },
        original => { $test_file => {
            path  => $test_file,
            type  => 'file',
            mode  => sprintf('%04o', $s[2] & 07777),
            uid   => $s[4],
            gid   => $s[5],
            user  => ($^O eq 'MSWin32' ? $s[4] : (getpwuid($s[4]))[0] // $s[4]),
            group => ($^O eq 'MSWin32' ? $s[5] : (getgrgid($s[5]))[0] // $s[5]),
        } },
    }, 'ChangeTrack::Metadata';

    ok(!$md->can_skip_content_diff($test_file), 'legacy records without mtime/size do not use diff fast-path');
}

########################################################################
# Save And Reload
########################################################################
{
    my $dir      = tempdir(CLEANUP => 1);
    my $meta_path = "$dir/.changetrack-metadata";
    my ($fh, $test_file) = tempfile(UNLINK => 1, SUFFIX => '.conf', DIR => $dir);
    print $fh "hello\n";
    close($fh);

    my $md = ChangeTrack::Metadata->load($meta_path);  # doesn't exist yet
    $md->update_from_stat($test_file);
    $md->save($meta_path);

    ok(-e $meta_path, 'save: file was created');

    # Reload
    my $md2 = ChangeTrack::Metadata->load($meta_path);
    my $rec  = $md2->record_for($test_file);
    ok(defined $rec, 'reload: record present after save+load');
    is($rec->{path}, $test_file, 'reload: path matches');
    is($rec->{type}, 'file',     'reload: type preserved');
    is($rec->{mode}, $md->record_for($test_file)->{mode}, 'reload: mode preserved');
}

########################################################################
# Symlink Metadata Lifecycle
########################################################################
{
    SKIP: {
        my $can_symlink = eval { symlink('', ''); 1 };
        skip 'symlink creation not available on this platform/user', 6 unless $can_symlink;

        my $dir = tempdir(CLEANUP => 1);
        my $target_a = "$dir/target-a.txt";
        my $target_b = "$dir/target-b.txt";
        my $link     = "$dir/link.conf";

        open(my $fa, '>', $target_a) or die $!;
        print $fa "A\n";
        close($fa);

        open(my $fb, '>', $target_b) or die $!;
        print $fb "B\n";
        close($fb);

        symlink($target_a, $link) or die "cannot create symlink: $!";

        my $md = ChangeTrack::Metadata->load('/nonexistent/symlink-metadata');
        $md->update_from_stat($link);

        my $rec = $md->record_for($link);
        is($rec->{type}, 'symlink', 'symlink: type recorded');
        is(File::Spec->canonpath($rec->{target}), File::Spec->canonpath($target_a),
            'symlink: target captured');

        $md->{original} = { map { $_ => { %{ $md->{records}{$_} } } } keys %{ $md->{records} } };

        SKIP: {
            skip 'symlink target normalization differs on Windows', 1 if $^O eq 'MSWin32';
            ok($md->can_skip_content_diff($link), 'symlink: can skip when target unchanged');
        }

        unlink($link) or die $!;
        symlink($target_b, $link) or die "cannot switch symlink target: $!";

        ok($md->changed_since_load($link), 'symlink: target change detected');
        my $summary = $md->diff_summary($link);
        like($summary, qr/target/, 'symlink: diff summary mentions target');
        ok(!$md->can_skip_content_diff($link), 'symlink: cannot skip when target changed');
    }
}

########################################################################
# Mark_Removed
########################################################################
{
    my $md = bless {
        records  => { '/etc/passwd' => { path => '/etc/passwd', type => 'file' } },
        original => { '/etc/passwd' => { path => '/etc/passwd', type => 'file' } },
    }, 'ChangeTrack::Metadata';

    ok(defined $md->record_for('/etc/passwd'), 'mark_removed: before removal');
    $md->mark_removed('/etc/passwd');
    is($md->record_for('/etc/passwd'), undef, 'mark_removed: record gone after removal');
}

########################################################################
# Rollback
########################################################################
{
    my $md = bless {
        records  => {
            '/etc/existing' => { path => '/etc/existing', type => 'file', size => 100 },
        },
        original => {
            '/etc/existing' => { path => '/etc/existing', type => 'file', size => 50 },
        },
    }, 'ChangeTrack::Metadata';

    # Existing file rolled back to original
    $md->rollback('/etc/existing');
    is($md->record_for('/etc/existing')->{size}, 50, 'rollback: existing record restored to original');

    # New file (not in original) deleted on rollback
    $md->{records}{'/etc/new'} = { path => '/etc/new', type => 'file', size => 200 };
    $md->rollback('/etc/new');
    is($md->record_for('/etc/new'), undef, 'rollback: new record deleted when not in original');
}

done_testing();

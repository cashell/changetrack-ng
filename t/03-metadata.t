# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
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

########################################################################
# Dirty Tracking State Transitions
########################################################################
{
    # 1. new: dirty starts at 0
    my $md_new = ChangeTrack::Metadata->new;
    is($md_new->is_dirty, 0, 'new: is_dirty is 0 initially');

    # 2. load on non-existent file sets dirty to 1 (new sidecar file on first run)
    my $dir = tempdir(CLEANUP => 1);
    my $meta_path = "$dir/.changetrack-metadata";
    my $md_missing = ChangeTrack::Metadata->load($meta_path);
    is($md_missing->is_dirty, 1, 'load: is_dirty is 1 when sidecar file does not exist');

    # 3. Create a file, update metadata, and save
    my $test_file = "$dir/sample.conf";
    open(my $fh, '>', $test_file) or die "Cannot create $test_file: $!";
    print {$fh} "setting = alpha\n";
    close($fh);
    chmod 0644, $test_file;

    $md_missing->update_from_stat($test_file);
    is($md_missing->is_dirty, 1, 'is_dirty is 1 after adding new file record');
    $md_missing->save($meta_path);
    is($md_missing->is_dirty, 0, 'save: resets is_dirty to 0');

    # 4. load on existing file sets dirty to 0
    my $md_loaded = ChangeTrack::Metadata->load($meta_path);
    is($md_loaded->is_dirty, 0, 'load: is_dirty is 0 when loaded from existing sidecar');

    # 5. unchanged update_from_stat leaves dirty as 0
    $md_loaded->update_from_stat($test_file);
    is($md_loaded->is_dirty, 0, 'update_from_stat: unchanged attributes leave is_dirty as 0');

    # 6. changed update_from_stat sets dirty to 1
    chmod 0600, $test_file;
    $md_loaded->update_from_stat($test_file);
    is($md_loaded->is_dirty, 1, 'update_from_stat: modified attributes set is_dirty to 1');
    is($md_loaded->record_for($test_file)->{mode}, '0600', 'mode updated to 0600');

    # 7. rollback_path restores prior dirty state and record
    $md_loaded->rollback_path($test_file);
    is($md_loaded->is_dirty, 0, 'rollback_path: restores is_dirty to 0');
    is($md_loaded->record_for($test_file)->{mode}, '0644', 'rollback_path: restores mode to 0644');

    # 8. mark_removed sets dirty to 1 for tracked file
    $md_loaded->mark_removed($test_file);
    is($md_loaded->is_dirty, 1, 'mark_removed: sets is_dirty to 1');
    is($md_loaded->record_for($test_file), undef, 'mark_removed: record removed');

    # 9. rollback_path after mark_removed restores record and dirty state
    $md_loaded->rollback_path($test_file);
    is($md_loaded->is_dirty, 0, 'rollback_path after mark_removed: restores is_dirty to 0');
    is($md_loaded->record_for($test_file)->{mode}, '0644', 'rollback_path: record restored');

    # 10. save resets dirty to 0 after modification
    chmod 0600, $test_file;
    $md_loaded->update_from_stat($test_file);
    is($md_loaded->is_dirty, 1, 'is_dirty is 1 before save');
    $md_loaded->save($meta_path);
    is($md_loaded->is_dirty, 0, 'save: resets is_dirty to 0');
}

########################################################################
# Oversize File Classification And Transitions
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $meta_path = "$dir/.changetrack-metadata";
    my $test_file = "$dir/oversize.bin";

    # Write 500 bytes of non-empty content
    open(my $fh, '>', $test_file) or die "Cannot create $test_file: $!";
    print {$fh} "X" x 500;
    close($fh);
    chmod 0644, $test_file;

    my $md = ChangeTrack::Metadata->load($meta_path);

    # When max_file_size is larger than file size: classified as file
    $md->update_from_stat($test_file, undef, 1000);
    my $rec = $md->record_for($test_file);
    is($rec->{type}, 'file', 'classified as file when size <= max_file_size');
    is($rec->{size}, 500, 'size recorded as 500');

    # When max_file_size is smaller than file size: classified as oversize
    $md->update_from_stat($test_file, undef, 300);
    $rec = $md->record_for($test_file);
    is($rec->{type}, 'oversize', 'classified as oversize when size > max_file_size');
    is($rec->{size}, 500, 'oversize record has size recorded');
    ok(defined $rec->{mtime}, 'oversize record has mtime recorded');

    # Save and reload metadata with oversize record
    $md->save($meta_path);
    my $md_loaded = ChangeTrack::Metadata->load($meta_path, max_file_size => 300);
    is($md_loaded->record_for($test_file)->{type}, 'oversize', 'reloaded record has type oversize');

    # Unchanged oversize file can skip content diff and is not changed
    ok($md_loaded->can_skip_content_diff($test_file, undef, 300),
        'can_skip_content_diff: true for unchanged oversize file');
    ok(!$md_loaded->changed_since_load($test_file, undef, 300),
        'changed_since_load: false for unchanged oversize file');
    is($md_loaded->diff_summary($test_file, undef, 300), '',
        'diff_summary: empty for unchanged oversize file');

    # Mode change on oversize file
    chmod 0600, $test_file;
    ok($md_loaded->changed_since_load($test_file, undef, 300),
        'changed_since_load: true on oversize mode change');
    like($md_loaded->diff_summary($test_file, undef, 300), qr/mode 0644 -> 0600/,
        'diff_summary: reports mode change on oversize file');
    chmod 0644, $test_file;

    # Size and mtime change on oversize file
    sleep 1;
    open(my $fh_app, '>>', $test_file) or die "Cannot append to $test_file: $!";
    print {$fh_app} "Y" x 200;
    close($fh_app);

    ok(!$md_loaded->can_skip_content_diff($test_file, undef, 300),
        'can_skip_content_diff: false when oversize size/mtime change');
    ok($md_loaded->changed_since_load($test_file, undef, 300),
        'changed_since_load: true when oversize size/mtime change');
    my $summary = $md_loaded->diff_summary($test_file, undef, 300);
    like($summary, qr/size 500 -> 700/, 'diff_summary: reports size change on oversize file');
    like($summary, qr/mtime/, 'diff_summary: reports mtime change on oversize file');
}

########################################################################
# Bidirectional File <-> Oversize and Empty <-> Oversize Transitions
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $meta_path = "$dir/.changetrack-metadata";
    my $test_file = "$dir/transition.txt";

    # Create file with 600 bytes
    open(my $fh, '>', $test_file) or die "Cannot create $test_file: $!";
    print {$fh} "Z" x 600;
    close($fh);
    chmod 0644, $test_file;

    # 1. Start classified as 'file' with max_file_size 1000
    my $md = ChangeTrack::Metadata->load($meta_path);
    $md->update_from_stat($test_file, undef, 1000);
    $md->save($meta_path);

    my $md_file = ChangeTrack::Metadata->load($meta_path);
    is($md_file->record_for($test_file)->{type}, 'file', 'initially classified as file');

    # Transition file -> oversize (by lowering max_file_size to 400)
    ok(!$md_file->can_skip_content_diff($test_file, undef, 400),
        'can_skip_content_diff: false on file -> oversize transition');
    ok($md_file->changed_since_load($test_file, undef, 400),
        'changed_since_load: true on file -> oversize transition');
    like($md_file->diff_summary($test_file, undef, 400), qr/type file -> oversize/,
        'diff_summary: reports type file -> oversize');

    # Update record as oversize and save
    $md_file->update_from_stat($test_file, undef, 400);
    $md_file->save($meta_path);

    # 2. Transition oversize -> file (by raising max_file_size to 2000)
    my $md_over = ChangeTrack::Metadata->load($meta_path);
    is($md_over->record_for($test_file)->{type}, 'oversize', 'reloaded as oversize');

    ok(!$md_over->can_skip_content_diff($test_file, undef, 2000),
        'can_skip_content_diff: false on oversize -> file transition');
    ok($md_over->changed_since_load($test_file, undef, 2000),
        'changed_since_load: true on oversize -> file transition');
    like($md_over->diff_summary($test_file, undef, 2000), qr/type oversize -> file/,
        'diff_summary: reports type oversize -> file');

    # 3. Transition oversize -> empty (truncate file to 0 bytes)
    open(my $fh_trunc, '>', $test_file) or die "Cannot truncate $test_file: $!";
    close($fh_trunc);

    ok(!$md_over->can_skip_content_diff($test_file, undef, 400),
        'can_skip_content_diff: false on oversize -> empty transition');
    ok($md_over->changed_since_load($test_file, undef, 400),
        'changed_since_load: true on oversize -> empty transition');
    like($md_over->diff_summary($test_file, undef, 400), qr/type oversize -> empty/,
        'diff_summary: reports type oversize -> empty');

    # 4. Transition empty -> oversize
    $md_over->update_from_stat($test_file, undef, 400);
    $md_over->save($meta_path);

    my $md_empty = ChangeTrack::Metadata->load($meta_path);
    is($md_empty->record_for($test_file)->{type}, 'empty', 'reloaded as empty');

    # Grow file to 800 bytes (exceeds max_file_size 400)
    open(my $fh_grow, '>', $test_file) or die "Cannot grow $test_file: $!";
    print {$fh_grow} "W" x 800;
    close($fh_grow);

    ok(!$md_empty->can_skip_content_diff($test_file, undef, 400),
        'can_skip_content_diff: false on empty -> oversize transition');
    ok($md_empty->changed_since_load($test_file, undef, 400),
        'changed_since_load: true on empty -> oversize transition');
    like($md_empty->diff_summary($test_file, undef, 400), qr/type empty -> oversize/,
        'diff_summary: reports type empty -> oversize');
}

done_testing();

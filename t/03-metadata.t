use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Metadata');

# ── empty load (no file) ──────────────────────────────────────────────────────

{
    my $md = ChangeTrack::Metadata->load('/nonexistent/path/to/metadata.jsonl');
    ok(defined $md, 'load: returns object even if file missing');
    is($md->record_for('/etc/passwd'), undef, 'load: empty metadata returns undef for any path');
    ok(!$md->changed_since_load('/etc/passwd'), 'changed_since_load: false for untracked file');
}

# ── update_from_stat and record_for ──────────────────────────────────────────

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

# ── changed_since_load ───────────────────────────────────────────────────────

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

# ── no change detected when metadata matches ─────────────────────────────────

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

# ── can_skip_content_diff true for zero-byte → zero-byte ─────────────────────

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

# ── can_skip_content_diff false for legacy records without mtime/size ───────

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

# ── save and reload ───────────────────────────────────────────────────────────

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

# ── mark_removed ─────────────────────────────────────────────────────────────

{
    my $md = bless {
        records  => { '/etc/passwd' => { path => '/etc/passwd', type => 'file' } },
        original => { '/etc/passwd' => { path => '/etc/passwd', type => 'file' } },
    }, 'ChangeTrack::Metadata';

    ok(defined $md->record_for('/etc/passwd'), 'mark_removed: before removal');
    $md->mark_removed('/etc/passwd');
    is($md->record_for('/etc/passwd'), undef, 'mark_removed: record gone after removal');
}

done_testing();

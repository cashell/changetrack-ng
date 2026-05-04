use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
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

use_ok('ChangeTrack::Runner');

my $output_dir  = tempdir(CLEANUP => 1);
my $tracked_dir = tempdir(CLEANUP => 1);

# Helper: write a config file pointing at our temp dirs
sub write_config {
    my ($extra_tracks) = @_;
    my ($cfh, $cpath) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = rcs\noutput_dir = $output_dir\n\n[track]\n";
    print $cfh "$_\n" for @{ $extra_tracks // [] };
    close($cfh);
    return $cpath;
}

# ── setup: create a test file ────────────────────────────────────────────────

my $file1 = "$tracked_dir/app.conf";
open(my $fh, '>', $file1) or die $!;
print $fh "color = blue\nsize = 10\n";
close($fh);
chmod(0644, $file1);

my $cfg_path = write_config([$file1]);

# ── first run: new file detected ─────────────────────────────────────────────

{
    my $runner = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $report = $runner->run;

    ok($report->has_changes, 'first run: has changes');
    is(scalar @{ $report->changes }, 1, 'first run: one change entry');
    is($report->changes->[0]{path}, $file1, 'first run: correct file path');
    ok($report->changes->[0]{is_new}, 'first run: marked as new');
    ok(-d "$output_dir/RCS", 'first run: RCS dir exists');
}

# ── second run: no changes ────────────────────────────────────────────────────

{
    my $runner = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $report = $runner->run;

    ok(!$report->has_changes, 'second run: no changes');
    is($report->files_tracked, 1, 'second run: one file tracked');
}

# ── modify content → change detected ─────────────────────────────────────────

{
    open(my $fh, '>', $file1) or die $!;
    print $fh "color = red\nsize = 10\n";
    close($fh);

    my $runner = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $report = $runner->run;

    ok($report->has_changes, 'content change: detected');
    my $c = $report->changes->[0];
    ok(!$c->{is_new},     'content change: not marked new');
    ok(@{ $c->{diff} } > 0, 'content change: diff lines present');
    like(join("\n", @{ $c->{diff} }), qr/red/, 'content change: diff contains new value');
}

# ── no changes on repeat run after content change ────────────────────────────

{
    my $runner = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $report = $runner->run;
    ok(!$report->has_changes, 'after content change: second run is clean');
}

# ── metadata-only change (permission) ────────────────────────────────────────

{
    chmod(0600, $file1);

    my $runner = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $report = $runner->run;

    ok($report->has_changes, 'perm change: detected');
    my $c = $report->changes->[0];
    ok($c->{meta_change}, 'perm change: meta_change populated');
    like($c->{meta_change}, qr/mode/, 'perm change: meta mentions mode');
}

# ── no changes after metadata already updated ────────────────────────────────

{
    my $runner = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $report = $runner->run;
    ok(!$report->has_changes, 'after perm update: second run is clean');
}

# ── removed file ─────────────────────────────────────────────────────────────

{
    unlink $file1 or die "Cannot remove test file: $!";

    my $runner = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1);
    my $report = $runner->run;

    ok($report->has_changes, 'removed: detected');
    my $c = $report->changes->[0];
    ok($c->{is_removed}, 'removed: is_removed flag set');
    is($c->{path}, $file1, 'removed: correct path');
}

# ── DIRECTORY tracking ────────────────────────────────────────────────────────

{
    my $dir2     = tempdir(CLEANUP => 1, DIR => $tracked_dir);
    my $output2  = tempdir(CLEANUP => 1);
    my $dirfile1 = "$dir2/a.conf";
    my $dirfile2 = "$dir2/b.conf";

    open(my $fh, '>', $dirfile1) or die $!;
    print $fh "a=1\n"; close($fh);
    open($fh, '>', $dirfile2) or die $!;
    print $fh "b=2\n"; close($fh);

    my ($cfh, $cpath) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = rcs\noutput_dir = $output2\n\n[track]\nDIRECTORY $dir2\n";
    close($cfh);

    my $runner = ChangeTrack::Runner->new(config => $cpath, quiet => 1);
    my $report = $runner->run;

    ok($report->has_changes,           'DIRECTORY: changes detected');
    is($report->files_tracked, 2,      'DIRECTORY: two files tracked');
    is(scalar @{$report->changes}, 2,  'DIRECTORY: two change entries');

    my @paths = map { $_->{path} } @{ $report->changes };
    is_deeply(\@paths, [sort @paths], 'DIRECTORY: change entries are emitted in deterministic sorted order');
}

# ── Track recipients are propagated into report changes ───────────────────────

{
    my $output4 = tempdir(CLEANUP => 1);
    my $file4   = "$tracked_dir/notify-test.conf";

    open(my $fh, '>', $file4) or die $!;
    print $fh "x=1\n";
    close($fh);

    my ($cfh, $cpath) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = rcs\noutput_dir = $output4\n\n[track]\n$file4 : default\@example.com\n";
    close($cfh);

    my $runner = ChangeTrack::Runner->new(config => $cpath, quiet => 1);
    my $report = $runner->run;

    ok($report->has_changes, 'RECIPIENTS: initial change detected');
    is_deeply($report->changes->[0]{recipients}, ['default@example.com'],
        'RECIPIENTS: track recipients propagated to report change');
}

# ── BINARY file handling ──────────────────────────────────────────────────────

{
    my $dir3    = tempdir(CLEANUP => 1, DIR => $tracked_dir);
    my $output3 = tempdir(CLEANUP => 1);
    my $textf   = "$dir3/plain.txt";
    my $binf    = "$dir3/archive.blob";

    open(my $fh, '>', $textf) or die $!;
    print $fh "hello\n";
    close($fh);

    open($fh, '>:raw', $binf) or die $!;
    print $fh "\x00\x01\x02\x03BINARY";
    close($fh);

    my ($cfh, $cpath) = tempfile(SUFFIX => '.ini', UNLINK => 1);
    print $cfh "[global]\nvcs = rcs\noutput_dir = $output3\n\n[track]\nDIRECTORY $dir3\n";
    close($cfh);

    my $runner = ChangeTrack::Runner->new(config => $cpath, quiet => 1);
    my $report = $runner->run;

    ok($report->has_changes, 'BINARY: text file still tracked');
    is(scalar @{ $report->changes }, 1, 'BINARY: only text file recorded as change');
    is($report->changes->[0]{path}, $textf, 'BINARY: recorded change is text file path');
    ok(grep { /Skipping binary file: \Q$binf\E/ } @{ $report->warnings },
        'BINARY: binary file is skipped with warning');

    my $runner2 = ChangeTrack::Runner->new(config => $cpath, quiet => 1);
    my $report2 = $runner2->run;
    ok(!$report2->has_changes, 'BINARY: second run has no content changes');
    ok(!grep { /Skipping binary file: \Q$binf\E/ } @{ $report2->warnings },
        'BINARY: unchanged binary file is not warned repeatedly');
}

done_testing();

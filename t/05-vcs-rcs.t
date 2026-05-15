# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
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

########################################################################
# Checkin (New File)
########################################################################
my $test_file = "$tracked_dir/test.conf";
open(my $fh, '>', $test_file) or die "Cannot create: $!";
print $fh "setting = original\n";
close($fh);

my $err = do { local $@; eval { $vcs->checkin($test_file, 'Initial checkin') }; $@ };
is($err, '', 'checkin new file: no error');

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

########################################################################
# Checkin Modified File
########################################################################
$err = do { local $@; eval { $vcs->checkin($test_file, 'Modification') }; $@ };
is($err, '', 'checkin modified file: no error');
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

done_testing();

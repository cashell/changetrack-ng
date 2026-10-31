# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 40-mirror-isolation.t - Tests for mirror isolation across foreign VCS
#   directories, tracked ignore/attributes files, excluded-dir pruning,
#   and nested-repository startup warnings.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use ChangeTrack::Util qw(run_cmd);
use ChangeTrack::Runner;
use ChangeTrack::Metadata;

# Locate external VCS binaries if present
my $GIT = do {
    my $found;
    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
        if (-x "$dir/git") { $found = "$dir/git"; last }
    }
    $found;
};
plan skip_all => 'git not found in PATH' unless $GIT;

my ($SVN, $SVNADMIN);
for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
    $SVN      //= "$dir/svn"      if -x "$dir/svn";
    $SVNADMIN //= "$dir/svnadmin" if -x "$dir/svnadmin";
}

my $HG = do {
    my $found;
    for my $dir (split /:/, ($ENV{PATH} // '/usr/bin:/usr/local/bin')) {
        if (-x "$dir/hg") { $found = "$dir/hg"; last }
    }
    $found;
};

# _write_file -- Write raw text to a file path.
sub _write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $content;
    close($fh) or die "Cannot close $path: $!";
}

# _write_cfg -- Write an INI config and enforce 0600 mode to avoid warnings.
sub _write_cfg {
    my ($cfg_path, $vcs, $output_dir, $lock_path, $track_dir) = @_;
    my $content = "[global]\nvcs = $vcs\noutput_dir = $output_dir\n";
    $content .= "lock_path = $lock_path\n" if defined $lock_path && length $lock_path;
    $content .= "\n[track]\nDIRECTORY $track_dir\n";
    _write_file($cfg_path, $content);
    chmod 0600, $cfg_path;
}

########################################################################
# Test 1: Nested Git repo, .fslckout skip, stale metadata purge
########################################################################
{
    my $work       = tempdir(CLEANUP => 1);
    my $output_dir = "$work/out";
    my $track_dir  = "$work/tracked";
    my $lock_path  = "$work/ct.lock";
    my $cfg_path   = "$work/ct.ini";

    make_path($output_dir, "$track_dir/sub");
    chmod 0700, $output_dir;

    my $r_init = run_cmd(cmd => [$GIT, 'init', '-q', "$track_dir/sub"]);
    ok($r_init->{success}, 'git init nested repo succeeded');

    _write_file("$track_dir/sub/conf", "alpha=1\n");
    _write_file("$track_dir/sub/.fslckout", "sqlite-stub\n");

    _write_cfg($cfg_path, 'git', $output_dir, $lock_path, $track_dir);

    ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->init_vcs;

    my $seed_md = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    $seed_md->update_from_stat("$track_dir/sub/.git/HEAD");
    $seed_md->save("$output_dir/.changetrack-metadata");

    my $rep = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;

    my $ls = run_cmd(cmd => [$GIT, '-C', $output_dir, 'ls-files']);
    ok($ls->{success}, 'git ls-files succeeded');
    like($ls->{stdout}, qr{sub/conf$}m, 'ls-files contains sub/conf');
    unlike($ls->{stdout}, qr{\.git/}, 'ls-files does not contain .git/');
    unlike($ls->{stdout}, qr{\.fslckout}, 'ls-files does not contain .fslckout');

    ok(!scalar(grep { $_->{is_removed} } @{ $rep->changes }),
        'stale foreign VCS metadata did not trigger a removed change alert');

    my $reloaded_md = ChangeTrack::Metadata->load("$output_dir/.changetrack-metadata");
    ok(defined $reloaded_md->record_for("$track_dir/sub/conf"),
        'metadata records sub/conf');
    ok(!defined $reloaded_md->record_for("$track_dir/sub/.git/HEAD"),
        'stale foreign VCS record purged from metadata');
}

########################################################################
# Test 2: Tracked .gitignore force-add and .gitattributes neutralization
########################################################################
{
    my $work       = tempdir(CLEANUP => 1);
    my $output_dir = "$work/out";
    my $track_dir  = "$work/tracked";
    my $lock_path  = "$work/ct.lock";
    my $cfg_path   = "$work/ct.ini";

    make_path($output_dir, $track_dir);
    chmod 0700, $output_dir;

    _write_file("$track_dir/.gitignore", "secret.local\n");
    _write_file("$track_dir/.gitattributes", "*.conf -diff eol=lf\n");
    _write_file("$track_dir/secret.local", "top-secret=1\n");
    chmod 0644, "$track_dir/secret.local";
    _write_file("$track_dir/app.conf", "key=v1\n");
    chmod 0644, "$track_dir/app.conf";

    _write_cfg($cfg_path, 'git', $output_dir, $lock_path, $track_dir);

    my $rep1 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    is(scalar @{ $rep1->warnings }, 0, 'no warnings on ignored file run');

    my $tree = run_cmd(cmd => [$GIT, '-C', $output_dir, 'ls-tree', '-r', '--name-only', 'HEAD']);
    ok($tree->{success}, 'git ls-tree succeeded');
    like($tree->{stdout}, qr{secret\.local$}m, 'ls-tree contains secret.local');
    like($tree->{stdout}, qr{app\.conf$}m, 'ls-tree contains app.conf');

    ok(-f "$output_dir/.git/info/attributes", '.git/info/attributes exists');

    _write_file("$track_dir/app.conf", "key=v1\nkey2=v2\n");
    utime(time() + 5, time() + 5, "$track_dir/app.conf");

    my $rep2 = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    my ($conf_change) = grep { $_->{path} eq "$track_dir/app.conf" } @{ $rep2->changes };
    ok($conf_change, 'change record found for app.conf');
    my $diff_text = join("\n", @{ $conf_change->{diff} // [] });
    like($diff_text, qr/\+key2=v2/, 'diff contains +key2=v2 (gitattributes -diff neutralized)');
}

########################################################################
# Test 3: output_dir inside tracked directory is pruned
########################################################################
{
    my $work       = tempdir(CLEANUP => 1);
    my $track_dir  = "$work/tracked";
    my $output_dir = "$track_dir/mirror_store";
    my $lock_path  = "$work/ct.lock";
    my $cfg_path   = "$work/ct.ini";

    make_path($output_dir, $track_dir);
    chmod 0700, $output_dir;

    _write_file("$track_dir/etc.conf", "x=1\n");
    _write_cfg($cfg_path, 'git', $output_dir, $lock_path, $track_dir);

    ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;

    my @stderr;
    {
        local $SIG{__WARN__} = sub { push @stderr, $_[0] };
        ChangeTrack::Runner->new(config => $cfg_path, trace => 1, quiet => 1)->run;
    }

    ok(scalar(grep { /\[TRACE\].*\Q$output_dir\E: pruned/ } @stderr),
        'output_dir was pruned during traversal');
    ok(!scalar(grep { /\[TRACE\].*\Q$output_dir\/.git\/\E/ } @stderr),
        'no file inside output_dir/.git/ was visited');
}

########################################################################
# Test 4: Pre-existing nested .git inside mirror emits startup warning
########################################################################
{
    my $work       = tempdir(CLEANUP => 1);
    my $output_dir = "$work/out";
    my $track_dir  = "$work/tracked";
    my $lock_path  = "$work/ct.lock";
    my $cfg_path   = "$work/ct.ini";

    make_path($output_dir, $track_dir);
    chmod 0700, $output_dir;

    _write_file("$track_dir/live.conf", "ok=1\n");
    _write_cfg($cfg_path, 'git', $output_dir, $lock_path, $track_dir);

    ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->init_vcs;

    make_path("$output_dir/etc/.git");

    my @stderr;
    my $rep;
    {
        local $SIG{__WARN__} = sub { push @stderr, $_[0] };
        $rep = ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;
    }

    my $nested_re = qr{Nested repository at .*\Q$output_dir/etc/.git\E inside the mirror};
    ok(scalar(grep { $_ =~ $nested_re } @stderr),
        'STDERR warning emitted for nested repository');
    ok(scalar(grep { $_ =~ $nested_re } @{ $rep->warnings }),
        'Report warning recorded for nested repository');
    ok(-d "$output_dir/etc/.git",
        'nested repository dir was not auto-deleted');
}

########################################################################
# Test 5: SVN nested .svn and --no-ignore
########################################################################
SKIP: {
    skip 'svn/svnadmin not available', 3 unless $SVN && $SVNADMIN;

    my $work       = tempdir(CLEANUP => 1);
    my $output_dir = "$work/out";
    my $track_dir  = "$work/tracked";
    my $lock_path  = "$work/ct.lock";
    my $cfg_path   = "$work/ct.ini";

    make_path("$track_dir/sub");

    run_cmd(cmd => [$SVNADMIN, 'create', "$work/foreign-svn"]);
    run_cmd(cmd => [$SVN, 'checkout', "file://$work/foreign-svn", "$track_dir/sub"]);

    _write_file("$track_dir/sub/conf", "svn=1\n");
    _write_file("$track_dir/plugin.so", "text-so\n");

    _write_cfg($cfg_path, 'svn', $output_dir, $lock_path, $track_dir);

    ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;

    my $ls = run_cmd(cmd => [$SVN, 'list', '-R', "file://$output_dir-svnrepo"]);
    ok($ls->{success}, 'svn list succeeded');
    ok(
        $ls->{stdout} =~ qr{sub/conf$}m && $ls->{stdout} =~ qr{plugin\.so$}m,
        'svn repo contains sub/conf and plugin.so (--no-ignore)'
    );
    unlike($ls->{stdout}, qr{\.svn}, 'svn repo does not contain foreign .svn');
}

########################################################################
# Test 6: Mercurial nested .hg and .hgignore isolation
########################################################################
SKIP: {
    skip 'hg not available', 3 unless $HG;

    my $work       = tempdir(CLEANUP => 1);
    my $output_dir = "$work/out";
    my $track_dir  = "$work/tracked";
    my $lock_path  = "$work/ct.lock";
    my $cfg_path   = "$work/ct.ini";

    make_path($output_dir, "$track_dir/sub");
    chmod 0700, $output_dir;

    run_cmd(cmd => [$HG, 'init', "$track_dir/sub"]);

    _write_file("$track_dir/sub/conf", "hg=1\n");
    _write_file("$track_dir/secret.local", "hgsec=1\n");

    _write_cfg($cfg_path, 'hg', $output_dir, $lock_path, $track_dir);

    ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->init_vcs;
    _write_file("$output_dir/.hgignore", "syntax: glob\nsecret.local\n");

    ChangeTrack::Runner->new(config => $cfg_path, quiet => 1)->run;

    my $mf = run_cmd(cmd => [$HG, '-R', $output_dir, 'manifest']);
    ok($mf->{success}, 'hg manifest succeeded');
    ok(
        $mf->{stdout} =~ qr{sub/conf$}m && $mf->{stdout} =~ qr{secret\.local$}m,
        'hg manifest contains sub/conf and secret.local'
    );
    unlike($mf->{stdout}, qr{\.hg/}, 'hg manifest does not contain foreign .hg/');
}

done_testing();

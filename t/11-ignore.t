use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

require ChangeTrack::Runner;

# Access package-internal functions directly
sub should_ignore { ChangeTrack::Runner::_should_ignore(@_) }
sub glob_match    { ChangeTrack::Runner::_glob_match(@_) }

# ── _glob_match ───────────────────────────────────────────────────────────────

ok( glob_match('*.swp',  'foo.swp'),      '*.swp matches foo.swp');
ok(!glob_match('*.swp',  'foo.swp.bak'),  '*.swp does not match foo.swp.bak');
ok( glob_match('*~',     'passwd~'),      '*~ matches passwd~');
ok( glob_match('#*#',    '#foo#'),        '#*# matches #foo#');
ok(!glob_match('#*#',    'foo'),          '#*# does not match plain foo');
ok( glob_match('*.dpkg-old', 'foo.dpkg-old'), '*.dpkg-old matches');

# ── _should_ignore: basename patterns ────────────────────────────────────────

{
    my @pats = ('*.swp', '*~');
    ok( should_ignore('/etc/passwd.swp',  'passwd.swp',  \@pats), 'basename *.swp ignored');
    ok( should_ignore('/etc/passwd~',     'passwd~',     \@pats), 'basename *~ ignored');
    ok(!should_ignore('/etc/passwd',      'passwd',      \@pats), '/etc/passwd not ignored');
}

# ── _should_ignore: path-containing patterns match as suffix ─────────────────

{
    my @pats = ('udev/hwdb.bin');
    ok( should_ignore('/etc/udev/hwdb.bin', 'hwdb.bin', \@pats),
        'udev/hwdb.bin matches /etc/udev/hwdb.bin');
    ok(!should_ignore('/etc/udev/rules.d/50-udev.rules', 'rules.d', \@pats),
        'udev/hwdb.bin does not match unrelated path');
}

# ── _should_ignore: glob in path pattern ─────────────────────────────────────

{
    my @pats = ('init.d/.depend.*');
    ok( should_ignore('/etc/init.d/.depend.boot',  '.depend.boot',  \@pats),
        'init.d/.depend.* matches .depend.boot');
    ok( should_ignore('/etc/init.d/.depend.start', '.depend.start', \@pats),
        'init.d/.depend.* matches .depend.start');
    ok(!should_ignore('/etc/init.d/networking',    'networking',    \@pats),
        'init.d/.depend.* does not match networking');
}

# ── BUILTIN_IGNORE contains expected patterns ────────────────────────────────

{
    my @builtins = ChangeTrack::Runner->builtin_ignore_patterns;
    ok(scalar @builtins > 0, 'BUILTIN_IGNORE is non-empty');
    ok(scalar(grep { $_ eq '*.swp'        } @builtins), 'BUILTIN_IGNORE contains *.swp');
    ok(scalar(grep { $_ eq '*~'           } @builtins), 'BUILTIN_IGNORE contains *~');
    ok(scalar(grep { $_ eq '*.gz'         } @builtins), 'BUILTIN_IGNORE contains *.gz');
    ok(scalar(grep { $_ eq '*.7z'         } @builtins), 'BUILTIN_IGNORE contains *.7z');
    ok(scalar(grep { $_ eq '*.bz2'        } @builtins), 'BUILTIN_IGNORE contains *.bz2');
    ok(scalar(grep { $_ eq '*.zst'        } @builtins), 'BUILTIN_IGNORE contains *.zst');
    ok(scalar(grep { $_ eq '*.xz'         } @builtins), 'BUILTIN_IGNORE contains *.xz');
    ok(scalar(grep { $_ eq '#*#'          } @builtins), 'BUILTIN_IGNORE contains #*#');
    ok(scalar(grep { $_ eq 'udev/hwdb.bin'} @builtins), 'BUILTIN_IGNORE contains udev/hwdb.bin');
    ok(scalar(grep { $_ eq 'lvm/cache'    } @builtins), 'BUILTIN_IGNORE contains lvm/cache');
}

# ── internal exclusions prevent self-tracking of output repo artifacts ──────

{
    my $root = tempdir(CLEANUP => 1);
    my $track_dir = "$root/tracked";
    my $output_dir = "$track_dir/state/changetrack-ng";

    mkdir $track_dir or die "mkdir $track_dir: $!";
    mkdir "$track_dir/state" or die "mkdir $track_dir/state: $!";
    mkdir $output_dir or die "mkdir $output_dir: $!";

    open(my $fh, '>', "$track_dir/real.txt") or die $!;
    print {$fh} "real\n";
    close($fh);

    open($fh, '>', "$output_dir/.changetrack-metadata") or die $!;
    print {$fh} "meta\n";
    close($fh);

    open($fh, '>', "$track_dir/state/changetrack-ng.fossil") or die $!;
    print {$fh} "repo\n";
    close($fh);

    my $cfg = ChangeTrack::Config->new(
        version => 2,
        global  => {
            vcs        => 'fossil',
            output_dir => $output_dir,
            ignore     => [],
        },
        tracks => [
            { kind => 'directory', path => $track_dir, emails => [], options => {} },
        ],
    );

    my $runner = ChangeTrack::Runner->new();
    my $entries = $runner->_tracked_entries($cfg);
    my @paths = map { $_->{path} } @$entries;

    ok((grep { $_ eq "$track_dir/real.txt" } @paths), 'real tracked file remains included');
    ok(!(grep { $_ eq "$output_dir/.changetrack-metadata" } @paths), 'metadata sidecar is excluded');
    ok(!(grep { $_ eq "$track_dir/state/changetrack-ng.fossil" } @paths), 'fossil repo database is excluded');
}

done_testing();

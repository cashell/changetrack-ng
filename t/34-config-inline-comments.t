# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 34-config-inline-comments.t - Tests for inline comment stripping
#   in the config parser.  Both '#' and ';' are supported as inline
#   comment characters when preceded by whitespace.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');

# Helper: write a config file and return its path.
sub write_conf {
    my ($dir, $content) = @_;
    my $path = "$dir/test.conf";
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $content;
    close($fh);
    return $path;
}

########################################################################
# Inline '#' comment on a global key=value line
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]
vcs = git
output_dir = /tmp
lock_timeout = 30    # seconds to wait

[track]
/etc/hosts
EOF
    my $cfg = ChangeTrack::Config->load($path);
    is($cfg->global('lock_timeout'), 30,
        'Inline # comment stripped from integer value');
}

########################################################################
# Inline ';' comment on a global key=value line
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]
vcs = git
output_dir = /tmp
lock_timeout = 60    ; one minute

[track]
/etc/hosts
EOF
    my $cfg = ChangeTrack::Config->load($path);
    is($cfg->global('lock_timeout'), 60,
        'Inline ; comment stripped from integer value');
}

########################################################################
# Inline comment on a string value
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]
vcs = git    # default backend
output_dir = /tmp

[track]
/etc/hosts
EOF
    my $cfg = ChangeTrack::Config->load($path);
    is($cfg->global('vcs'), 'git',
        'Inline # comment stripped from string/enum value');
}

########################################################################
# Inline comment on a boolean value
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]
vcs = git
output_dir = /tmp
sensitive_auto = 0    # disable auto-detection

[track]
/etc/hosts
EOF
    my $cfg = ChangeTrack::Config->load($path);
    is($cfg->global('sensitive_auto'), 0,
        'Inline # comment stripped from boolean value');
}

########################################################################
# Inline comment on a notifier key=value line
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]
vcs = git
output_dir = /tmp

[notifier:webhook:default]
enabled      = true
url          = https://hooks.example.com/ct
max_diff_bytes = 0    # unlimited
insecure     = 0      ; verified by default

[track]
/etc/hosts
EOF
    my $cfg   = ChangeTrack::Config->load($path);
    my $insts = $cfg->notifiers->{webhook};
    is(scalar @$insts, 1, 'Webhook instance parsed with inline comments');
    is($insts->[0]{max_diff_bytes}, 0,
        'Notifier # inline comment stripped from integer');
    is($insts->[0]{insecure}, 0,
        'Notifier ; inline comment stripped from boolean');
}

########################################################################
# Full-line ';' comment is skipped (not just '#')
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]
vcs = git
output_dir = /tmp
; This is a full-line semicolon comment
lock_timeout = 5

[track]
/etc/hosts
EOF
    my $cfg = ChangeTrack::Config->load($path);
    is($cfg->global('lock_timeout'), 5,
        'Full-line ; comment skipped, subsequent key parsed');
}

########################################################################
# '#' embedded without leading whitespace is NOT stripped
# (e.g., a '#' that is part of the value itself)
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]
vcs = git
output_dir = /tmp

[notifier:otlp:default]
enabled  = true
endpoint = https://otel.example.com/v1/logs
headers  = X-Custom=val#1

[track]
/etc/hosts
EOF
    my $cfg   = ChangeTrack::Config->load($path);
    my $insts = $cfg->notifiers->{otlp};
    is($insts->[0]{headers}, 'X-Custom=val#1',
        '# without leading whitespace is kept as part of the value');
}

########################################################################
# Inline comment after section header
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]   # global settings
vcs = git
output_dir = /tmp

[track]    ; tracked files
/etc/hosts
EOF
    my $cfg = ChangeTrack::Config->load($path);
    is($cfg->global('vcs'), 'git',
        'Inline comment after [global] header does not break parsing');
    ok(scalar @{ $cfg->tracks } >= 1,
        'Inline comment after [track] header does not break parsing');
}

########################################################################
# Value that is entirely a comment after stripping becomes empty string
########################################################################
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = write_conf($dir, <<'EOF');
[global]
vcs = git
output_dir = /tmp
push_remote =    # no remote configured

[track]
/etc/hosts
EOF
    my $cfg = ChangeTrack::Config->load($path);
    my $pr  = $cfg->global('push_remote');
    # push_remote is an array key; empty value should yield empty arrayref
    is_deeply($pr, [], 'Empty value with inline comment yields empty array for array key');
}

done_testing();

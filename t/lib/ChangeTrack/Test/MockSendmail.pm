package ChangeTrack::Test::MockSendmail;
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;
use File::Temp qw(tempfile);
use File::Basename qw(dirname);
use File::Path qw(make_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# create() — write a mock sendmail script that captures its invocation.
# Returns the path to the script and the path to the capture file.
sub create {
    my ($class, %args) = @_;

    my ($cfh, $capture_path) = tempfile(SUFFIX => '.capture', UNLINK => 0);
    close($cfh);

    my ($sfh, $script_path) = tempfile(SUFFIX => '.sendmail', UNLINK => 0);

    print $sfh <<"END_SCRIPT";
#!/usr/bin/env perl
use strict;
use warnings;

my \$capture = '$capture_path';
open(my \$fh, '>', \$capture) or die "Cannot write capture: \$!";
print \$fh "ARGS:\\n";
print \$fh "  \$_\\n" for \@ARGV;
print \$fh "STDIN:\\n";
while (my \$line = <STDIN>) {
    print \$fh \$line;
}
close(\$fh);
exit 0;
END_SCRIPT

    close($sfh);
    chmod(0755, $script_path);

    return ($script_path, $capture_path);
}

# read_capture($path) — returns a hashref with keys: args (arrayref), headers (hashref), body (string).
sub read_capture {
    my ($class, $capture_path) = @_;

    open(my $fh, '<', $capture_path) or return undef;
    my @lines = <$fh>;
    close($fh);
    chomp @lines;

    my (@args, %headers, @body_lines);
    my $section = '';

    for my $line (@lines) {
        if ($line eq 'ARGS:') { $section = 'args'; next }
        if ($line eq 'STDIN:') { $section = 'stdin'; next }

        if ($section eq 'args') {
            (my $arg = $line) =~ s/^\s+//;
            push @args, $arg;
        } elsif ($section eq 'stdin') {
            push @body_lines, $line;
        }
    }

    # Parse headers from body_lines (up to first blank line)
    my $in_headers = 1;
    my @body;
    for my $line (@body_lines) {
        if ($in_headers) {
            if ($line eq '') {
                $in_headers = 0;
                next;
            }
            if ($line =~ /^([^:]+):\s*(.*)$/) {
                $headers{$1} = $2;
            }
        } else {
            push @body, $line;
        }
    }

    return {
        args    => \@args,
        headers => \%headers,
        body    => join("\n", @body),
    };
}

1;

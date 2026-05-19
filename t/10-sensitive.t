# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 10-sensitive.t - Tests for sensitive.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use lib File::Spec->catdir($RealBin, 'lib');

# Skip on Windows/Cygwin: chmod() does not propagate to stat() mode bits
if ($^O eq 'MSWin32' || $^O eq 'cygwin') {
    plan skip_all => 'Sensitive file mode tests require Unix stat() semantics (skip on Windows/Cygwin)';
}

use_ok('ChangeTrack::Runner');
use_ok('ChangeTrack::Notify::Email');
use_ok('ChangeTrack::Notify::File');
use_ok('ChangeTrack::Report');
use_ok('ChangeTrack::Test::MockSendmail');

########################################################################
# _Resolve_Sensitive() Unit Tests (Via Runner Internals)
########################################################################
# We call the private function directly by importing it.
# It's a package sub so we can call it as ChangeTrack::Runner::_resolve_sensitive().

{
    my ($fh, $file) = tempfile(UNLINK => 1, SUFFIX => '.conf');
    print $fh "data\n";
    close($fh);

    chmod(0644, $file);
    ok(!ChangeTrack::Runner::_resolve_sensitive($file, undef),
        '_resolve_sensitive: 0644 -> not sensitive (world-readable)');

    chmod(0640, $file);
    ok(ChangeTrack::Runner::_resolve_sensitive($file, undef),
        '_resolve_sensitive: 0640 -> sensitive (no world read)');

    chmod(0600, $file);
    ok(ChangeTrack::Runner::_resolve_sensitive($file, undef),
        '_resolve_sensitive: 0600 -> sensitive (no world read)');

    chmod(0604, $file);
    ok(!ChangeTrack::Runner::_resolve_sensitive($file, undef),
        '_resolve_sensitive: 0604 -> not sensitive (world-readable)');
}

########################################################################
# Sensitive Override: Yes/No/1/0
########################################################################
{
    my ($fh, $file) = tempfile(UNLINK => 1, SUFFIX => '.conf');
    print $fh "data\n"; close($fh);
    chmod(0644, $file);   # would be not-sensitive by mode

    ok(ChangeTrack::Runner::_resolve_sensitive($file, 'yes'),
        'override yes: forces sensitive regardless of mode');
    ok(ChangeTrack::Runner::_resolve_sensitive($file, '1'),
        'override 1: forces sensitive');

    chmod(0600, $file);   # would be sensitive by mode
    ok(!ChangeTrack::Runner::_resolve_sensitive($file, 'no'),
        'override no: forces not-sensitive regardless of mode');
    ok(!ChangeTrack::Runner::_resolve_sensitive($file, '0'),
        'override 0: forces not-sensitive');
}

########################################################################
# VCS Still Gets Full Diff; Notification Suppresses
########################################################################
{
    # Build a report where a file is sensitive
    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old_hash', '+new_hash'],
        meta_change  => '',
    );

    # The report object itself holds the full diff
    my $c = $report->changes->[0];
    is(scalar @{ $c->{diff} }, 2, 'Report stores full diff regardless of sensitive flag');
    like(join("\n", @{ $c->{diff} }), qr/old_hash/, 'Full diff content in report');

    # File notifier with suppress should NOT include raw diff
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/sens.log";
    my $n   = ChangeTrack::Notify::File->new(
        path         => $log,
        sensitive_notify => 'suppress',
    );
    $n->send($report);

    open(my $fh, '<', $log) or die $!;
    my $line = <$fh>; close($fh);
    chomp $line;
    require JSON::PP;
    my $rec = JSON::PP->new->decode($line);
    my $diff_str = join("\n", @{ $rec->{files}[0]{diff} // [] });
    unlike($diff_str, qr/old_hash/, 'Notification: raw diff suppressed');
    like($diff_str,   qr/suppressed/i, 'Notification: suppression placeholder present');
}

########################################################################
# Sensitive_Notify=Allow: Full Diff In Notification
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/allow.log";
    my $n   = ChangeTrack::Notify::File->new(
        path         => $log,
        sensitive_notify => 'allow',
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old_hash', '+new_hash'],
        meta_change  => '',
    );
    $n->send($report);

    open(my $fh, '<', $log) or die $!;
    my $line = <$fh>; close($fh);
    chomp $line;
    require JSON::PP;
    my $rec = JSON::PP->new->decode($line);
    my $diff_str = join("\n", @{ $rec->{files}[0]{diff} // [] });
    like($diff_str, qr/old_hash/, 'sensitive_notify=allow: full diff in notification');
}

########################################################################
# Metadata Loosening Is Always Reported
########################################################################
{
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/perm-loosen.log";
    my $n   = ChangeTrack::Notify::File->new(
        path         => $log,
        sensitive_notify => 'suppress',
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => [],
        meta_change  => 'mode 0600 -> 0644',
    );
    $n->send($report);

    open(my $fh, '<', $log) or die $!;
    my $line = <$fh>; close($fh);
    chomp $line;
    require JSON::PP;
    my $rec = JSON::PP->new->decode($line);
    is($rec->{files}[0]{meta_change}, 'mode 0600 -> 0644',
        'Permission loosening: meta_change always present in notification');
}

########################################################################
# Sensitive_Auto x Sensitive_Notify Interaction Matrix
########################################################################
{
    my ($fh, $file) = tempfile(UNLINK => 1, SUFFIX => '.secret');
    print $fh "token=abcd\n";
    close($fh);
    chmod(0600, $file); # no world read => sensitive when auto=1

    my @cases = (
        { auto => 1, notify => 'suppress', expect_secret => 0, label => 'auto=1 suppress' },
        { auto => 1, notify => 'allow',    expect_secret => 1, label => 'auto=1 allow' },
        { auto => 0, notify => 'suppress', expect_secret => 1, label => 'auto=0 suppress' },
        { auto => 0, notify => 'allow',    expect_secret => 1, label => 'auto=0 allow' },
    );

    for my $c (@cases) {
        my $is_sensitive = ChangeTrack::Runner::_resolve_sensitive($file, undef, $c->{auto});

        my $dir = tempdir(CLEANUP => 1);
        my $log = "$dir/matrix.log";
        my $n   = ChangeTrack::Notify::File->new(
            path         => $log,
            sensitive_notify => $c->{notify},
        );

        my $report = ChangeTrack::Report->new(start_time => time());
        $report->add_change(
            path         => $file,
            is_new       => 0,
            is_sensitive => $is_sensitive,
            diff         => ['-token=old', '+token=new'],
            meta_change  => '',
        );
        $n->send($report);

        open(my $rfh, '<', $log) or die $!;
        my $line = <$rfh>;
        close($rfh);
        chomp $line;

        require JSON::PP;
        my $rec = JSON::PP->new->decode($line);
        my $diff_str = join("\n", @{ $rec->{files}[0]{diff} // [] });
        if ($c->{expect_secret}) {
            like($diff_str, qr/token=/, "$c->{label}: full diff present");
        } else {
            unlike($diff_str, qr/token=/, "$c->{label}: secret suppressed");
            like($diff_str, qr/suppressed/i, "$c->{label}: suppression placeholder");
        }
    }
}

########################################################################
# Email Notifier: Sensitive Suppression
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path    => $script,
        to         => ['sec@example.com'],
        sensitive_notify => 'suppress',
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/ssh/ssh_host_rsa_key',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old_key_data', '+new_key_data'],
        meta_change  => '',
    );
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    unlike($cap->{body}, qr/old_key_data|new_key_data/,
        'Email: sensitive diff suppressed in body');
    like($cap->{body}, qr/suppressed/i,
        'Email: suppression notice in body');
    like($cap->{body}, qr{/etc/ssh/ssh_host_rsa_key},
        'Email: file path still present in body');

    unlink $script, $capture;
}

done_testing();

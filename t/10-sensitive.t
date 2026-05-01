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

# ── _resolve_sensitive() unit tests (via Runner internals) ───────────────────

# We call the private function directly by importing it.
# It's a package sub so we can call it as ChangeTrack::Runner::_resolve_sensitive().

{
    my ($fh, $file) = tempfile(UNLINK => 1, SUFFIX => '.conf');
    print $fh "data\n";
    close($fh);

    chmod(0644, $file);
    ok(!ChangeTrack::Runner::_resolve_sensitive($file, undef),
        '_resolve_sensitive: 0644 → not sensitive (world-readable)');

    chmod(0640, $file);
    ok(ChangeTrack::Runner::_resolve_sensitive($file, undef),
        '_resolve_sensitive: 0640 → sensitive (no world read)');

    chmod(0600, $file);
    ok(ChangeTrack::Runner::_resolve_sensitive($file, undef),
        '_resolve_sensitive: 0600 → sensitive (no world read)');

    chmod(0604, $file);
    ok(!ChangeTrack::Runner::_resolve_sensitive($file, undef),
        '_resolve_sensitive: 0604 → not sensitive (world-readable)');
}

# ── sensitive override: yes/no/1/0 ───────────────────────────────────────────

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

# ── VCS still gets full diff; notification suppresses ────────────────────────

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
        log_path         => $log,
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

# ── sensitive_notify=allow: full diff in notification ────────────────────────

{
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/allow.log";
    my $n   = ChangeTrack::Notify::File->new(
        log_path         => $log,
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

# ── metadata loosening is always reported ─────────────────────────────────────

{
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/perm-loosen.log";
    my $n   = ChangeTrack::Notify::File->new(
        log_path         => $log,
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

# ── email notifier: sensitive suppression ────────────────────────────────────

{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path    => $script,
        email_to         => ['sec@example.com'],
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

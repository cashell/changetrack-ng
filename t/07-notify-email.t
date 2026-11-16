# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# 07-notify-email.t - Tests for notify email.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use lib File::Spec->catdir($RealBin, 'lib');

use_ok('ChangeTrack::Notify::Email');
use_ok('ChangeTrack::Report');
use_ok('ChangeTrack::Test::MockSendmail');

########################################################################
# Heartbeat Contract
########################################################################
{
    my $n = ChangeTrack::Notify::Email->new;
    ok(!$n->heartbeat_enabled, 'Email heartbeat_enabled always false');
    is($n->name, 'email', 'name returns email');
}

########################################################################
# No Mail Sent When No Changes
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => $script,
        to      => ['nobody@example.invalid'],
    );

    my $report = ChangeTrack::Report->new;   # no changes
    $n->send($report);

    # capture file should be empty (sendmail never called)
    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    ok(!defined $cap || !@{ $cap->{args} // [] },
        'No mail sent when no changes');

    unlink $script, $capture;
}

########################################################################
# Mail Sent For Single Change
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => $script,
        from    => 'ct@testhost',
        to      => ['admin@example.com'],
    );

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(
        path         => '/etc/passwd',
        is_new       => 0,
        is_sensitive => 0,
        diff         => ['-old line', '+new line'],
        meta_change  => '',
    );
    $report->set_end_time(1000000005);
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    ok(defined $cap, 'capture file readable');
    like($cap->{headers}{'Subject'}, qr/changetrack-ng.*Changes/i, 'Subject header present');
    is($cap->{headers}{'From'}, 'ct@testhost', 'From header matches from');
    like($cap->{body}, qr{/etc/passwd}, 'body contains file path');
    like($cap->{body}, qr/new line/,    'body contains diff content');

    # Verify recipient was passed as arg to sendmail
    ok(scalar(grep { $_ eq 'admin@example.com' } @{ $cap->{args} }),
        'recipient passed as sendmail arg');

    unlink $script, $capture;
}

########################################################################
# Per-File Recipients
########################################################################
{
    my ($script1, $capture1) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => $script1,
        from    => 'ct@host',
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/nginx/nginx.conf',
        is_new       => 1,
        is_sensitive => 0,
        diff         => ['(new file)'],
        meta_change  => '',
        recipients   => ['webmaster@example.com'],
    );
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture1);
    ok(defined $cap, 'per-file recipient: capture readable');
    ok(scalar(grep { $_ eq 'webmaster@example.com' } @{ $cap->{args} }),
        'per-file recipient used as sendmail arg');

    unlink $script1, $capture1;
}

########################################################################
# Sensitive File: Diff Suppressed
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => $script,
        to      => ['sec@example.com'],
        sensitive_notify => 'suppress',
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old hash', '+new hash'],
        meta_change  => '',
    );
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    ok(defined $cap, 'sensitive suppress: capture readable');
    unlike($cap->{body}, qr/old hash|new hash/, 'raw diff not in body');
    like($cap->{body},   qr/suppressed/i,        'suppression notice in body');
    like($cap->{body},   qr{/etc/shadow},         'file path still in body');

    unlink $script, $capture;
}

########################################################################
# Sensitive_Notify = Allow: Full Diff Sent
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path    => $script,
        to         => ['sec@example.com'],
        sensitive_notify => 'allow',
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old hash', '+new hash'],
        meta_change  => '',
    );
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    like($cap->{body}, qr/new hash/, 'sensitive_notify=allow: diff included');

    unlink $script, $capture;
}

########################################################################
# Default Email_To Fallback When Per-File Recipients Missing
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => $script,
        to      => ['default@example.com'],
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/hosts',
        is_new       => 0,
        is_sensitive => 0,
        diff         => ['-a', '+b'],
        meta_change  => '',
        recipients   => [],
    );
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    ok(defined $cap, 'default recipient: capture readable');
    ok(scalar(grep { $_ eq 'default@example.com' } @{ $cap->{args} }),
        'default recipient used when per-file recipients are absent');

    unlink $script, $capture;
}

########################################################################
# Per-File Recipients Override Global Default
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => $script,
        to      => ['default@example.com'],
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/nginx/nginx.conf',
        is_new       => 0,
        is_sensitive => 0,
        diff         => ['-worker_processes 1', '+worker_processes auto'],
        meta_change  => '',
        recipients   => ['webmaster@example.com'],
    );
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    ok(defined $cap, 'override recipient: capture readable');
    ok(scalar(grep { $_ eq 'webmaster@example.com' } @{ $cap->{args} }),
        'per-file recipient is used');
    ok(!scalar(grep { $_ eq 'default@example.com' } @{ $cap->{args} }),
        'global default not added when per-file recipient exists');

    unlink $script, $capture;
}

########################################################################
# No Sendmail Found: Graceful Warning
########################################################################
{
    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => '/nonexistent/sendmail',
        to      => ['nobody@example.invalid'],
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path => '/etc/hosts', is_new => 0, is_sensitive => 0,
        diff => [], meta_change => '',
    );

    # send() must not die  --  just warn
    my $died = 0;
    eval { $n->send($report) };
    $died = 1 if $@;
    ok(!$died, 'No sendmail found: send does not die');
}

########################################################################
# Explicit Bad Sendmail Path Must Not Fall Back To PATH sendmail
########################################################################
{
    my $tmp = tempdir(CLEANUP => 1);
    my $cap = File::Spec->catfile($tmp, 'fallback.capture');
    my $bin = File::Spec->catfile($tmp, 'sendmail');

    open(my $fh, '>', $bin) or die "Cannot write fake sendmail: $!";
    print {$fh} "#!/usr/bin/env perl\n";
    print {$fh} "use strict; use warnings;\n";
    print {$fh} "open(my \\\$cfh, '>', '$cap') or die \\\$!;\n";
    print {$fh} "print {\\\$cfh} \\\"called\\n\\\";\n";
    print {$fh} "close(\\\$cfh);\n";
    print {$fh} "exit 0;\n";
    close($fh);
    chmod(0755, $bin);

    local $ENV{PATH} = $tmp . ':' . ($ENV{PATH} // '');

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => '/nonexistent/sendmail',
        to            => ['nobody@example.invalid'],
    );

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path => '/etc/hosts', is_new => 0, is_sensitive => 0,
        diff => ['-a', '+b'], meta_change => '',
    );

    my @warn;
    local $SIG{__WARN__} = sub { push @warn, @_ };
    $n->send($report);

    ok(!-e $cap, 'bad explicit sendmail_path does not invoke PATH sendmail');
    ok(grep(/sendmail not found/i, @warn), 'bad explicit sendmail_path emits skip warning');
}

########################################################################
# Use_Track_Recipients Flag Behavior
########################################################################
{
    # 1. Default (use_track_recipients => 1): per-track recipients take precedence
    {
        my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

        my $n = ChangeTrack::Notify::Email->new(
            sendmail_path => $script,
            to            => ['instance-default@example.com'],
            # use_track_recipients defaults to 1
        );

        my $report = ChangeTrack::Report->new(start_time => time());
        $report->add_change(
            path         => '/etc/custom.conf',
            is_new       => 0,
            is_sensitive => 0,
            diff         => ['-one', '+two'],
            meta_change  => '',
            recipients   => ['pertrack@example.com'],
        );
        $n->send($report);

        my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
        ok(defined $cap, 'use_track_recipients=1: capture readable');
        ok(scalar(grep { $_ eq 'pertrack@example.com' } @{ $cap->{args} }),
            'use_track_recipients=1: per-track recipient receives notification');
        ok(!scalar(grep { $_ eq 'instance-default@example.com' } @{ $cap->{args} }),
            'use_track_recipients=1: instance to recipient overridden');

        unlink $script, $capture;
    }

    # 2. use_track_recipients => 0: ignores per-track recipients, sends to instance to list
    {
        my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

        my $n = ChangeTrack::Notify::Email->new(
            sendmail_path        => $script,
            to                   => ['admin-digest@example.com'],
            use_track_recipients => 0,
        );

        my $report = ChangeTrack::Report->new(start_time => time());
        $report->add_change(
            path         => '/etc/custom.conf',
            is_new       => 0,
            is_sensitive => 0,
            diff         => ['-one', '+two'],
            meta_change  => '',
            recipients   => ['pertrack@example.com'],
        );
        $n->send($report);

        my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
        ok(defined $cap, 'use_track_recipients=0: capture readable');
        ok(scalar(grep { $_ eq 'admin-digest@example.com' } @{ $cap->{args} }),
            'use_track_recipients=0: instance to recipient receives notification');
        ok(!scalar(grep { $_ eq 'pertrack@example.com' } @{ $cap->{args} }),
            'use_track_recipients=0: per-track recipient ignored');

        unlink $script, $capture;
    }

    # 3. use_track_recipients => 0 with empty instance to list skips and warns
    {
        my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

        my $n = ChangeTrack::Notify::Email->new(
            sendmail_path        => $script,
            to                   => [],
            use_track_recipients => 0,
        );

        my $report = ChangeTrack::Report->new(start_time => time());
        $report->add_change(
            path         => '/etc/custom.conf',
            is_new       => 0,
            is_sensitive => 0,
            diff         => ['-one', '+two'],
            meta_change  => '',
            recipients   => ['pertrack@example.com'],
        );

        my @warn;
        local $SIG{__WARN__} = sub { push @warn, @_ };
        $n->send($report);

        my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
        ok(!defined $cap || !@{ $cap->{args} // [] },
            'use_track_recipients=0 with no to: sendmail not called');
        ok(grep(/no recipients for \/etc\/custom\.conf/i, @warn),
            'use_track_recipients=0 with no to: warning emitted');

        unlink $script, $capture;
    }
}

########################################################################
# Revision Surfacing: Report Revision In Email Header
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => $script,
        from          => 'ct@testhost',
        to            => ['admin@example.com'],
    );

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(
        path         => '/etc/hosts',
        is_new       => 0,
        is_sensitive => 0,
        diff         => ['+192.168.1.1 server'],
    );
    $report->set_revision('deadbeef1234');
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    ok(defined $cap, 'email capture readable with report revision');
    like($cap->{body}, qr/^Revision:\s*deadbeef1234$/m, 'email body header contains Revision: deadbeef1234');
    unlike($cap->{body}, qr/CHANGED:.*deadbeef/,        'per-file line does not redundantly repeat revision');

    unlink $script, $capture;
}

########################################################################
# Revision Surfacing: Per-File Revision In Email Block
########################################################################
{
    my ($script, $capture) = ChangeTrack::Test::MockSendmail->create;

    my $n = ChangeTrack::Notify::Email->new(
        sendmail_path => $script,
        from          => 'ct@testhost',
        to            => ['admin@example.com'],
    );

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(
        path         => '/etc/rcs-file',
        is_new       => 0,
        is_sensitive => 0,
        diff         => ['+change line'],
        revision     => '1.2',
    );
    $n->send($report);

    my $cap = ChangeTrack::Test::MockSendmail->read_capture($capture);
    ok(defined $cap, 'email capture readable with per-file revision');
    unlike($cap->{body}, qr/^changetrack-ng detected.*\nRevision:/s, 'email body has no top-level revision header');
    like($cap->{body},   qr/^\s*Revision:\s*1\.2$/m,                'email body per-file block contains Revision: 1.2');

    unlink $script, $capture;
}

########################################################################
# Direct _format_body Backward Compatibility
########################################################################
{
    my $n = ChangeTrack::Notify::Email->new;
    my $changes = [
        { path => '/etc/test', is_new => 0, is_removed => 0, is_sensitive => 0, diff => [] },
    ];

    # 3-arg call (legacy test compatibility)
    my $body3 = $n->_format_body($changes, 'myhost', '2026-11-12T00:00:00');
    unlike($body3, qr/Revision:/, '3-arg _format_body omits Revision line');

    # 4-arg call with scalar revision
    my $body4 = $n->_format_body($changes, 'myhost', '2026-11-12T00:00:00', 'git-sha-789');
    like($body4, qr/^Revision:\s*git-sha-789$/m, '4-arg _format_body includes Revision: git-sha-789');
}

done_testing();

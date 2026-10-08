# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
########################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
########################################################################
# 37-review-findings.t - Tests covering fixes for review primary findings:
#   1. Output directory & storage permission tightening and alerting
#   2. Metadata rollback on file error & commit-before-save sequencing
#   3. Notifier failure bubbling and warning recording in Report
#   4. Debian rules and RPM spec placeholder substitutions
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use lib File::Spec->catdir($RealBin, '..', 'lib');

use ChangeTrack::Config;
use ChangeTrack::Runner;
use ChangeTrack::Metadata;
use ChangeTrack::Report;

########################################################################
# Finding 1: Output Dir & Sibling Permissions Tightened and Alerted
########################################################################
SKIP: {
    skip 'POSIX file permissions differ on Windows', 6 if $^O eq 'MSWin32';

    my $tmpdir = tempdir(CLEANUP => 1);
    my $outdir = File::Spec->catdir($tmpdir, 'outdir');
    mkdir($outdir, 0755) or die "mkdir: $!";
    chmod(0755, $outdir) or die "chmod: $!";

    my $fossil_repo = "$outdir.fossil";
    open(my $fh, '>', $fossil_repo) or die "open: $!";
    print {$fh} "fossil dummy\n";
    close($fh);
    chmod(0644, $fossil_repo) or die "chmod: $!";

    my $tracked_file = File::Spec->catfile($tmpdir, 'tracked.conf');
    open(my $tfh, '>', $tracked_file) or die "open: $!";
    print {$tfh} "content\n";
    close($tfh);

    my $cfg_file = File::Spec->catfile($tmpdir, 'ct.conf');
    open(my $cfh, '>', $cfg_file) or die "open: $!";
    print {$cfh} "[global]\nvcs = rcs\noutput_dir = $outdir\n\n[track]\n$tracked_file\n";
    close($cfh);

    my $runner = ChangeTrack::Runner->new(config => $cfg_file, quiet => 1);
    my $report = $runner->run;

    my $out_mode = (stat($outdir))[2] & 07777;
    my $fsl_mode = (stat($fossil_repo))[2] & 07777;

    is($out_mode, 0700, 'output_dir tightened from 0755 to 0700');
    is($fsl_mode, 0600, 'sibling fossil repo tightened from 0644 to 0600');

    my @warns = @{ $report->warnings };
    ok(
        scalar(grep { /Tightened insecure permissions on .*outdir from 0755 to 0700/ } @warns),
        'warning recorded in report for output_dir permission tightening'
    );
    ok(
        scalar(grep { /Tightened insecure permissions on .*outdir\.fossil from 0644 to 0600/ } @warns),
        'warning recorded in report for sibling repo permission tightening'
    );

    # Clean run with secure permissions emits no permission warnings
    my $report2 = $runner->run;
    my @warns2  = @{ $report2->warnings };
    ok(
        !grep { /Tightened insecure permissions/ } @warns2,
        'second run with secure permissions produces no permission tightening warnings'
    );
    is((stat($outdir))[2] & 07777, 0700, 'output_dir remains 0700');
}

########################################################################
# Finding 2: Metadata Rollback on _process_file Error
########################################################################
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $outdir = File::Spec->catdir($tmpdir, 'outdir');
    my $tracked = File::Spec->catfile($tmpdir, 'file.conf');
    open(my $tfh, '>', $tracked) or die "open: $!";
    print {$tfh} "version 1\n";
    close($tfh);

    my $cfg_file = File::Spec->catfile($tmpdir, 'ct.conf');
    open(my $cfh, '>', $cfg_file) or die "open: $!";
    print {$cfh} "[global]\nvcs = rcs\noutput_dir = $outdir\n\n[track]\n$tracked\n";
    close($cfh);

    my $runner = ChangeTrack::Runner->new(config => $cfg_file, quiet => 1);
    $runner->run;

    # Load metadata after initial run
    my $meta_path = "$outdir/.changetrack-metadata";
    my $md = ChangeTrack::Metadata->load($meta_path);
    my $orig_rec = $md->record_for($tracked);
    ok(defined $orig_rec, 'file record exists in metadata after initial run');
    my $orig_mtime = $orig_rec->{mtime};
    my $orig_size  = $orig_rec->{size};

    # Update file on disk
    sleep 1;
    open(my $tfh2, '>>', $tracked) or die "open: $!";
    print {$tfh2} "version 2 with more content\n";
    close($tfh2);

    # Now mock _process_file to die
    {
        no warnings 'redefine';
        local *ChangeTrack::Runner::_process_file = sub {
            my ($self, $entry, $vcs, $md_ref, $report, $msg) = @_;
            # simulate partial processing updating metadata before dying
            $md_ref->update_from_stat($entry->{path});
            die "simulated disk error during processing\n";
        };

        my $r = ChangeTrack::Runner->new(config => $cfg_file, quiet => 1);
        my $fail_report = eval { $r->run };
        ok(!$@, 'runner completes even if _process_file dies');
        ok(grep { /simulated disk error/ } @{ $fail_report->warnings }, 'warning recorded for processing error');

        # Verify on-disk metadata was NOT updated to the failed state
        my $md_disk = ChangeTrack::Metadata->load($meta_path);
        my $disk_rec = $md_disk->record_for($tracked);
        is($disk_rec->{size}, $orig_size, 'on-disk metadata preserves original size after failed processing');
        is($disk_rec->{mtime}, $orig_mtime, 'on-disk metadata preserves original mtime after failed processing');
    }
}

########################################################################
# Finding 2: Metadata Save After VCS Commit (Sequencing)
########################################################################
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $outdir = File::Spec->catdir($tmpdir, 'outdir');
    my $tracked = File::Spec->catfile($tmpdir, 'commit-test.conf');
    open(my $tfh, '>', $tracked) or die "open: $!";
    print {$tfh} "initial commit\n";
    close($tfh);

    my $cfg_file = File::Spec->catfile($tmpdir, 'ct.conf');
    open(my $cfh, '>', $cfg_file) or die "open: $!";
    print {$cfh} "[global]\nvcs = git\noutput_dir = $outdir\n\n[track]\n$tracked\n";
    close($cfh);

    my $runner = ChangeTrack::Runner->new(config => $cfg_file, quiet => 1);
    $runner->run;

    # Modify file
    sleep 1;
    open(my $tfh2, '>>', $tracked) or die "open: $!";
    print {$tfh2} "new content\n";
    close($tfh2);

    my $meta_path = "$outdir/.changetrack-metadata";
    my $md_before = ChangeTrack::Metadata->load($meta_path);
    my $before_size = $md_before->record_for($tracked)->{size};

    # Mock VCS commit to fail
    {
        no warnings qw(redefine once);
        local *ChangeTrack::VCS::Git::commit = sub {
            die "simulated git commit failure\n";
        };

        my $r = ChangeTrack::Runner->new(config => $cfg_file, quiet => 1);
        eval { $r->run };
        like($@, qr/VCS commit failed/i, 'run dies when whole-repo commit fails');

        # Verify on-disk metadata was not saved
        my $md_after = ChangeTrack::Metadata->load($meta_path);
        my $after_size = $md_after->record_for($tracked)->{size};
        is($after_size, $before_size, 'on-disk metadata was not advanced when VCS commit failed');
    }
}

########################################################################
# Finding 5: Notifier Failure Recorded in Report Warnings
########################################################################
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $outdir = File::Spec->catdir($tmpdir, 'outdir');
    my $tracked = File::Spec->catfile($tmpdir, 'notify-test.conf');
    open(my $tfh, '>', $tracked) or die "open: $!";
    print {$tfh} "hello\n";
    close($tfh);

    my $cfg_file = File::Spec->catfile($tmpdir, 'ct.conf');
    open(my $cfh, '>', $cfg_file) or die "open: $!";
    print {$cfh} "[global]\nvcs = rcs\noutput_dir = $outdir\n\n[track]\n$tracked\n";
    print {$cfh} "\n[notifier:webhook:failing_hook]\nenabled = true\nurl = http://127.0.0.1:19753/\n";
    close($cfh);

    # Initial run to commit
    my $runner = ChangeTrack::Runner->new(config => $cfg_file, quiet => 1);
    my $rep1 = $runner->run;

    # Modify file to trigger notification
    open(my $tfh2, '>>', $tracked) or die "open: $!";
    print {$tfh2} "changes\n";
    close($tfh2);

    my $rep2 = $runner->run;
    my @w = @{ $rep2->warnings };
    ok(
        scalar(grep { /Notifier ChangeTrack::Notify::Webhook:failing_hook failed:/ } @w),
        'notifier failure was recorded in report warnings'
    );
    is($rep2->vcs, 'rcs', 'report preserves vcs name');
    ok(defined $rep2->message && length($rep2->message), 'report preserves message string');
}

########################################################################
# Finding 3 & 4: Packaging Substitutions and DNF Hook Non-Blocking
########################################################################
{
    # Check packaging/debian/rules
    my $rules_path = File::Spec->catfile($RealBin, '..', 'packaging', 'debian', 'rules');
    open(my $rfh, '<', $rules_path) or die "Cannot open $rules_path: $!";
    my $rules_content = do { local $/; <$rfh> };
    close($rfh);

    ok(
        index($rules_content, 'sed -e "s|@BINDIR@|/usr/bin|g" -e "s|@DEFAULTSDIR@|/etc/default|g" packaging/hooks/apt-pre') != -1,
        'debian/rules substitutes @BINDIR@ and @DEFAULTSDIR@ in apt-pre'
    );
    ok(
        index($rules_content, 'sed -e "s|@BINDIR@|/usr/bin|g" -e "s|@DEFAULTSDIR@|/etc/default|g" packaging/hooks/apt-post') != -1,
        'debian/rules substitutes @BINDIR@ and @DEFAULTSDIR@ in apt-post'
    );
    ok(
        index($rules_content, 'sed -e "s|@BINDIR@|/usr/bin|g" -e "s|@DEFAULTSDIR@|/etc/default|g" packaging/cron/changetrack-ng') != -1,
        'debian/rules substitutes @BINDIR@ and @DEFAULTSDIR@ in cron job'
    );

    # Check packaging/debian/changetrack-ng.service
    my $svc_path = File::Spec->catfile($RealBin, '..', 'packaging', 'debian', 'changetrack-ng.service');
    open(my $sfh, '<', $svc_path) or die "Cannot open $svc_path: $!";
    my $svc_content = do { local $/; <$sfh> };
    close($sfh);

    ok(index($svc_content, 'EnvironmentFile=-/etc/default/changetrack-ng') != -1, 'debian service sets EnvironmentFile');
    ok(index($svc_content, 'ExecStart=/usr/bin/changetrack-ng run --system --quiet $CHANGETRACK_EXTRA_ARGS') != -1, 'debian service matches systemd template');

    # Check packaging/rpm/changetrack-ng.spec
    my $spec_path = File::Spec->catfile($RealBin, '..', 'packaging', 'rpm', 'changetrack-ng.spec');
    open(my $spfh, '<', $spec_path) or die "Cannot open $spec_path: $!";
    my $spec_content = do { local $/; <$spfh> };
    close($spfh);

    ok(index($spec_content, 's|@DEFAULTSDIR@|%{_sysconfdir}/sysconfig|g') != -1, 'rpm spec substitutes @DEFAULTSDIR@');
    ok(index($spec_content, '%dir %attr(0700,root,root) %{_localstatedir}/lib/%{name}') != -1, 'rpm spec sets 0700 on lib dir');

    # Check packaging/hooks/dnf/changetrack_ng.py
    my $dnf_path = File::Spec->catfile($RealBin, '..', 'packaging', 'hooks', 'dnf', 'changetrack_ng.py');
    open(my $dfh, '<', $dnf_path) or die "Cannot open $dnf_path: $!";
    my $dnf_content = do { local $/; <$dfh> };
    close($dfh);

    like($dnf_content, qr/self\._run\("pre-install", required=False\)/, 'dnf plugin pre-install is not required');
    unlike($dnf_content, qr/raise dnf\.exceptions\.Error/, 'dnf plugin does not raise dnf Error to block transactions');
    like($dnf_content, qr/sys\.stderr\.write.*WARNING/, 'dnf plugin outputs warning to stderr on failure');
}

done_testing();

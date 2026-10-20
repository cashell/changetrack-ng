# File Notifier OTel Reshape Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the File notifier from one per-run JSON object (with a nested `files[]` array) into per-event NDJSON — one OTel-shaped JSON record per change, heartbeat, or warning — using the same canonical attribute names as the OTLP notifier.

**Architecture:** `File.pm` gains `_build_records` (returns a list of flat OTel-style records) replacing `_build_record` (single per-run object). Each record has `timestamp`, `event_name`, `severity_text`, `severity_number`, `body`, `resource`, and an `attributes` hash keyed by the canonical names. `_append_records` writes all records for a run under one exclusive lock.

**Tech Stack:** Perl 5.20+, `JSON::PP`, `POSIX::strftime`, `File::Basename`, `Fcntl` flock (all core). Tests: `Test::More` + `prove`.

**Dependency:** This plan depends on `2026-06-23-otel-attribute-model.md` (Task 1) — it consumes `$change->{file_meta}` and the canonical attribute names that plan establishes on `ChangeTrack::Report`.

## Global Constraints

- **Perl 5.20+, zero non-core dependencies.** Only core modules: `JSON::PP`, `HTTP::Tiny`, `IO::Compress::Gzip`, `POSIX`, `Fcntl`, `Carp`, `File::Basename`, `Time::HiRes`. No CPAN.
- **changetrack-ng is a SysAdmin config-change tracking tool, NOT a security/HIDS tool.** Do not frame output as security telemetry. Do NOT add content hashes. Do NOT add actor/detection-provenance fields.
- **OTel output is not yet deployed** — format reshape is NOT a breaking change. Reshape freely; rewrite the affected tests in the *same* task so the tree is never left red.
- **Preserve sensitive-file diff suppression.** `sensitive_notify` (suppress|allow) gates diff emission via `_diff_text_for`/`_sensitive_notify_allowed` in `Notify/Base.pm`. Never emit a suppressed diff.
- **Never expose sensitive data** in logs (recipient PII, suppressed diffs). Recipient emission is opt-in, default OFF.
- **File headers** on any new file: vim modeline + perltidy line + SPDX block exactly as in existing `lib/ChangeTrack/Notify/*.pm`.
- **Test runner:** `prove -lv t/NN-name.t` from the changetrack-ng project root. `Test::More` + `done_testing()`.

### Canonical attribute naming (authoritative — identical across this plan series)

| Current (`ct.*`) | New key | JSON type in File NDJSON | Notes |
|---|---|---|---|
| `ct.path` | `file.path` | string | absolute path |
| — | `file.name` | string | basename |
| — | `file.directory` | string | dirname |
| `ct.is_new` + `ct.is_removed` | `config_change.type` | string enum | `created` \| `modified` \| `removed` |
| `ct.is_sensitive` | `config_change.sensitive` | bool | |
| `ct.meta_change` | `config_change.meta_summary` | string | omit when empty |
| `ct.diff` | `config_change.diff` | string | omit when not full_diff; suppressed text when sensitive |
| — | `config_change.diff_truncated` | bool | Plan 4 (otel-diff-truncation) only |
| — | `config_change.notified` | array&lt;string&gt; | F7, behind `emit_recipients` (default off) |
| — | `file.mode` | string | e.g. `0644` |
| — | `file.owner.name` | string | |
| — | `file.group.name` | string | |
| — | `file.size` | number | bytes |
| `ct.files_tracked` | `changetrack.files_tracked` | number | common attr |
| `ct.run_duration_ms` | `changetrack.run_duration_ms` | number | common attr |
| `ct.heartbeat` | *(removed)* | — | discriminate via `event_name` |

### Canonical `event_name` values

| Record | `event_name` |
|---|---|
| created file | `changetrack.file.created` |
| modified file | `changetrack.file.changed` |
| removed file | `changetrack.file.removed` |
| heartbeat | `changetrack.run.heartbeat` |
| warning | `changetrack.run.warning` |

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify (rewrite) | `lib/ChangeTrack/Notify/File.pm` | Per-event OTel-shaped NDJSON records |
| Modify (rewrite) | `t/09-notify-file.t` | Assert per-event NDJSON shape |

---

## Task 1: Rewrite `t/09-notify-file.t` for per-event NDJSON

TDD: rewrite the tests first to the new shape. They fail against the current per-run-object `File.pm`. Task 2 implements the reshape.

**Files:**
- Modify (rewrite): `t/09-notify-file.t`

**Interfaces:**
- Consumes: canonical names + `event_name` tables above; `ChangeTrack::Report` with `file_meta` (from the attribute-model plan).
- Produces: assertions that each appended line is one OTel record with `event_name`, `severity_text`, `severity_number`, `body`, `resource`, `attributes`.

- [ ] **Step 1: Replace the whole test file**

Replace the entire contents of `t/09-notify-file.t` with:

```perl
# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 09-notify-file.t - Tests for the per-event OTel-shaped File notifier.
#

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->catdir($RealBin, '..', 'lib');
use JSON::PP ();

use_ok('ChangeTrack::Notify::File');
use_ok('ChangeTrack::Report');

my $dir = tempdir(CLEANUP => 1);

# helper: read all JSONL records from a log file
sub all_records {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @recs;
    while (my $line = <$fh>) {
        next unless $line =~ /\S/;
        chomp $line;
        push @recs, eval { JSON::PP->new->decode($line) };
    }
    close($fh);
    return @recs;
}
sub last_record { my @r = all_records(@_); return $r[-1]; }

########################################################################
# Heartbeat_Enabled Default Off
########################################################################
{
    my $n = ChangeTrack::Notify::File->new(path => "$dir/test.log");
    ok(!$n->heartbeat_enabled, 'heartbeat default off');
    is($n->name, 'file', 'name returns file');
}

########################################################################
# No Append When No Changes And Heartbeat Off
########################################################################
{
    my $log = "$dir/no-hb.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 0);
    $n->send(ChangeTrack::Report->new);
    ok(!-e $log, 'No log file created when no changes and heartbeat off');
}

########################################################################
# Change Run: One OTel Record Per Change
########################################################################
{
    my $log = "$dir/changes.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log);

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(
        path   => '/etc/passwd',
        is_new => 1,
        diff   => ['(new file)'],
        stat   => { mode => '0644', user => 'root', group => 'root',
                    size => 42, mtime => 1_700_000_000, type => 'file' },
    );
    $report->set_end_time(1000000003);
    $n->send($report);

    ok(-e $log, 'Log file created');
    my @recs = all_records($log);
    is(scalar @recs, 1, 'one record for one change');
    my $r = $recs[0];
    is($r->{event_name}, 'changetrack.file.created', 'event_name created');
    is($r->{severity_text}, 'INFO',                  'severity_text INFO');
    is($r->{severity_number}, 9,                     'severity_number 9');
    is($r->{resource}{'service.name'}, 'changetrack-ng', 'resource service.name');
    is($r->{attributes}{'file.path'}, '/etc/passwd',     'attributes file.path');
    is($r->{attributes}{'file.name'}, 'passwd',          'attributes file.name');
    is($r->{attributes}{'config_change.type'}, 'created','attributes config_change.type');
    is($r->{attributes}{'file.mode'}, '0644',            'attributes file.mode');
    is($r->{attributes}{'file.size'}, 42,                'attributes file.size');
    ok(defined $r->{attributes}{'changetrack.run_duration_ms'}, 'run_duration_ms present');
}

########################################################################
# Heartbeat Run: One changetrack.run.heartbeat Record
########################################################################
{
    my $log = "$dir/hb.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 1);

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->set_end_time(time() + 1);
    $n->send($report);

    ok(-e $log, 'Heartbeat: log file created');
    my @recs = all_records($log);
    is(scalar @recs, 1, 'Heartbeat: one record');
    is($recs[0]{event_name}, 'changetrack.run.heartbeat', 'Heartbeat: event_name');
    like($recs[0]{body}, qr/heartbeat/i, 'Heartbeat: body mentions heartbeat');
}

########################################################################
# Heartbeat Off: No Append On Clean Run
########################################################################
{
    my $log = "$dir/hb-off.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log, heartbeat => 0);
    $n->send(ChangeTrack::Report->new);
    ok(!-e $log, 'Heartbeat off: no log file on clean run');
}

########################################################################
# Multiple Changes In One Run: One Line Each
########################################################################
{
    my $log = "$dir/multi.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log);

    my $report = ChangeTrack::Report->new(start_time => 1000000000);
    $report->add_change(path => '/etc/a', is_new => 0, diff => ['+x']);
    $report->add_change(path => '/etc/b', is_new => 1, diff => ['(new file)']);
    $report->set_end_time(1000000001);
    $n->send($report);

    my @recs = all_records($log);
    is(scalar @recs, 2, 'two changes => two NDJSON lines');
    is($recs[0]{attributes}{'config_change.type'}, 'modified', 'first is modified');
    is($recs[1]{attributes}{'config_change.type'}, 'created',  'second is created');
}

########################################################################
# Sensitive File: config_change.diff Suppressed
########################################################################
{
    my $log = "$dir/sensitive.log";
    my $n   = ChangeTrack::Notify::File->new(
        path => $log, sensitive_notify => 'suppress');

    my $report = ChangeTrack::Report->new(start_time => time());
    $report->add_change(
        path         => '/etc/shadow',
        is_new       => 0,
        is_sensitive => 1,
        diff         => ['-old_hash', '+new_hash'],
    );
    $n->send($report);

    my $r = last_record($log);
    my $diff = $r->{attributes}{'config_change.diff'} // '';
    unlike($diff, qr/old_hash|new_hash/, 'Sensitive: raw diff suppressed');
    like($diff,   qr/suppressed/i,        'Sensitive: suppression notice present');
}

########################################################################
# config_change.notified Opt-In
########################################################################
{
    # default: not emitted
    my $log1 = "$dir/norecip.log";
    my $r1 = ChangeTrack::Report->new(start_time => time());
    $r1->add_change(path => '/etc/a', diff => [], recipients => ['ops@x.com']);
    ChangeTrack::Notify::File->new(path => $log1)->send($r1);
    my $rec1 = last_record($log1);
    ok(!exists $rec1->{attributes}{'config_change.notified'},
        'recipients omitted by default');

    # emit_recipients=1: emitted as array
    my $log2 = "$dir/recip.log";
    my $r2 = ChangeTrack::Report->new(start_time => time());
    $r2->add_change(path => '/etc/a', diff => [], recipients => ['ops@x.com', 'sa@x.com']);
    ChangeTrack::Notify::File->new(path => $log2, emit_recipients => 1)->send($r2);
    my $rec2 = last_record($log2);
    is_deeply($rec2->{attributes}{'config_change.notified'},
        ['ops@x.com', 'sa@x.com'], 'recipients emitted when emit_recipients=1');
}

done_testing();
```

- [ ] **Step 2: Run to verify it fails against the current File.pm**

Run: `prove -lv t/09-notify-file.t`
Expected: FAIL — current `File.pm` emits a per-run object (`$rec->{files}`, `$rec->{heartbeat}`), so `event_name`/`attributes` assertions fail.

- [ ] **Step 3: Commit the tests**

```bash
git add t/09-notify-file.t
git commit -m "test(file): assert per-event OTel-shaped NDJSON records"
```

---

## Task 2: Reshape `File.pm` to per-event records

**Files:**
- Modify (rewrite): `lib/ChangeTrack/Notify/File.pm`
- Test: `t/09-notify-file.t` (made to pass)

**Interfaces:**
- Consumes: `$report->changes` (each with `path/is_new/is_removed/is_sensitive/diff/meta_change/recipients/file_meta`), `$report->warnings`, `$report->files_tracked`, `$report->duration_ms`, `$report->{start_time}`.
- Produces: `_build_records($report, $is_heartbeat)` → list of record hashrefs; `_append_records(@records)` writes one JSON line each under a single `LOCK_EX`. New config key `emit_recipients` (default 0).

- [ ] **Step 1: Replace the whole module**

Replace the entire contents of `lib/ChangeTrack/Notify/File.pm` with:

```perl
# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Notify::File - Append-only per-event OTel-shaped NDJSON
#   log notifier with optional heartbeat.
#

package ChangeTrack::Notify::File;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Notify::File - per-event NDJSON log notifier for changetrack-ng

=head1 DESCRIPTION

Appends one OTel-shaped JSON record per event (one per changed file, one
per heartbeat, one per warning) to the file at C<path>.  Each record carries
C<timestamp>, C<event_name>, C<severity_text>, C<severity_number>, C<body>,
C<resource>, and an C<attributes> hash keyed by changetrack-ng's canonical
attribute names.  Heartbeat is configurable (default off).

=cut

use parent 'ChangeTrack::Notify::Base';
use Fcntl qw(:flock);
use POSIX qw(strftime);
use File::Basename qw(basename dirname);
use JSON::PP ();

use ChangeTrack::Util qw(hostname);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# new -- Construct the notifier with defaults for path, heartbeat, diff output.
sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{path}             //= '/var/log/changetrack-ng.log';
    $self->{heartbeat}        //= 0;
    $self->{full_diff}        //= 1;
    $self->{sensitive_notify} //= 'suppress';
    $self->{emit_recipients}  //= 0;
    return $self;
}

# heartbeat_enabled -- Return true when the heartbeat config key is set.
sub heartbeat_enabled {
    my ($self) = @_;
    return $self->{heartbeat} ? 1 : 0;
}

sub name { 'file' }

# config_keys -- The set of constructor args this notifier reads from config.
sub config_keys { qw(path heartbeat full_diff emit_recipients) }

# validate_config -- Return an error string when path is not set.
sub validate_config {
    my ($self) = @_;
    my $path = $self->{path} // '';
    return () if $path =~ /\S/;
    return ('file notifier requires non-empty path');
}

# send_changes -- Append one record per change (and per warning) for the run.
sub send_changes {
    my ($self, $report) = @_;
    $self->_append_records($self->_build_records($report, 0));
}

# send_heartbeat -- Append a single heartbeat record.
sub send_heartbeat {
    my ($self, $report) = @_;
    $self->_append_records($self->_build_records($report, 1));
}

# _resource -- The resource map common to every record.
sub _resource {
    my ($self) = @_;
    return {
        'service.name'    => 'changetrack-ng',
        'service.version' => $VERSION,
        'host.name'       => hostname(),
    };
}

# _common_attrs -- Per-run attributes attached to every record.
sub _common_attrs {
    my ($self, $report) = @_;
    my %a = ('changetrack.files_tracked' => ($report->files_tracked // 0) + 0);
    my $dur = $report->duration_ms;
    $a{'changetrack.run_duration_ms'} = $dur + 0 if defined $dur;
    return %a;
}

# _build_records -- Build the list of per-event records for one run.
sub _build_records {
    my ($self, $report, $is_heartbeat) = @_;

    my $ts      = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($report->{start_time} // time()));
    my %common  = $self->_common_attrs($report);
    my @records;

    if ($is_heartbeat) {
        push @records, {
            timestamp       => $ts,
            event_name      => 'changetrack.run.heartbeat',
            severity_text   => 'INFO',
            severity_number => 9,
            body            => 'changetrack-ng heartbeat (no changes)',
            resource        => $self->_resource,
            attributes      => { %common },
        };
        return @records;
    }

    for my $c (@{ $report->changes }) {
        my ($type, $event_name, $body);
        if ($c->{is_removed}) {
            $type = 'removed';
            $event_name = 'changetrack.file.removed';
            $body = "config file removed: $c->{path}";
        } elsif ($c->{is_new}) {
            $type = 'created';
            $event_name = 'changetrack.file.created';
            $body = "new config file: $c->{path}";
        } else {
            $type = 'modified';
            $event_name = 'changetrack.file.changed';
            $body = "config file changed: $c->{path}";
        }

        my %attrs = (
            'file.path'               => $c->{path},
            'file.name'               => basename($c->{path}),
            'file.directory'          => dirname($c->{path}),
            'config_change.type'      => $type,
            'config_change.sensitive' => ($c->{is_sensitive} ? JSON::PP::true() : JSON::PP::false()),
            %common,
        );

        my $fm = $c->{file_meta} // {};
        $attrs{'file.mode'}       = $fm->{mode}     if defined $fm->{mode};
        $attrs{'file.owner.name'} = $fm->{owner}    if defined $fm->{owner};
        $attrs{'file.group.name'} = $fm->{group}    if defined $fm->{group};
        $attrs{'file.size'}       = $fm->{size} + 0 if defined $fm->{size};

        $attrs{'config_change.meta_summary'} = $c->{meta_change} if $c->{meta_change};

        if ($self->{emit_recipients} && @{ $c->{recipients} // [] }) {
            $attrs{'config_change.notified'} = [ @{ $c->{recipients} } ];
        }

        if ($self->{full_diff}) {
            $attrs{'config_change.diff'} = join("\n", $self->_diff_text_for($c));
        }

        push @records, {
            timestamp       => $ts,
            event_name      => $event_name,
            severity_text   => 'INFO',
            severity_number => 9,
            body            => $body,
            resource        => $self->_resource,
            attributes      => \%attrs,
        };
    }

    for my $w (@{ $report->warnings }) {
        push @records, {
            timestamp       => $ts,
            event_name      => 'changetrack.run.warning',
            severity_text   => 'WARN',
            severity_number => 13,
            body            => $w,
            resource        => $self->_resource,
            attributes      => { %common },
        };
    }

    return @records;
}

# _append_records -- Serialize each record to one JSON line and append them
# all under a single exclusive lock to prevent interleaved entries.
sub _append_records {
    my ($self, @records) = @_;
    return unless @records;

    my $path = $self->{path};
    my $jp   = JSON::PP->new->canonical(1);

    open(my $fh, '>>', $path)
        or die "Cannot open log file $path: $!";
    flock($fh, LOCK_EX)
        or die "Cannot lock $path: $!";
    print $fh $jp->encode($_), "\n" for @records;
    flock($fh, LOCK_UN);
    close($fh);
}

1;
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `prove -lv t/09-notify-file.t`
Expected: PASS (all blocks).

- [ ] **Step 3: Run the broader notifier integration test**

Run: `prove -lv t/18-integration-notifiers.t`
Expected: PASS. If it asserts the old File per-run shape, update those assertions to the per-event shape in this same commit (same reshape, same rationale).

- [ ] **Step 4: Commit**

```bash
git add lib/ChangeTrack/Notify/File.pm t/09-notify-file.t t/18-integration-notifiers.t
git commit -m "feat(file): emit per-event OTel-shaped NDJSON records"
```

---

## Self-Review

- **Spec coverage:** F1 (File notifier → per-event OTel NDJSON) — Tasks 1-2. Reuses canonical names + recipients opt-in from the attribute-model plan. ✔
- **Placeholder scan:** Full module and full test file are concrete. Task 2 Step 3 is conditional on what `t/18` actually asserts — the action (match the new shape) is explicit.
- **Type consistency:** `event_name`/`severity_text`/`severity_number`/`attributes.*` keys are identical between the test (Task 1) and the implementation (Task 2). `config_change.notified` is a plain array in both. `file_meta` keys match the attribute-model plan.
- **Constraint check:** Sensitive diff suppression goes through `_diff_text_for` unchanged. Recipients opt-in, default OFF. No hashes, no actor fields.

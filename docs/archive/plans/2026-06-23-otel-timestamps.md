# OTel Occurred-vs-Observed Timestamps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Distinguish *when the change occurred* (the file's mtime) from *when changetrack-ng observed it* (the scan time) in both notifiers — OTLP `timeUnixNano`/`observedTimeUnixNano` and the File notifier's `timestamp`/`observed_timestamp`.

**Architecture:** The scan time (`$report->{start_time}`) is the observed time for every record. For change records, the occurred time is the file's mtime (already plumbed as `file_meta.mtime` by the attribute-model plan); records without a file mtime (heartbeats, warnings, removed files) fall back to the observed time. Timestamps are encoded at nanosecond resolution; sub-second precision (Time::HiRes) is explicitly out of scope (see Decisions).

**Tech Stack:** Perl 5.20+, `POSIX::strftime` (already used). No new dependencies.

**Dependencies:** `2026-06-23-otel-attribute-model.md` (plumbs `file_meta.mtime`, rewrites the OTLP builder) AND `2026-06-23-file-notifier-otel-reshape.md` (establishes the File notifier record shape with `timestamp`). Apply this plan *after* both.

## Decisions

- **Occurred = file mtime, Observed = scan time.** This is the OTLP-recommended split (`observedTimeUnixNano` is when the collector/agent saw the record; `timeUnixNano` is when the event happened).
- **Whole-second values, nanosecond encoding.** mtime and scan time are whole seconds (`stat`/`time()`), multiplied to nanoseconds for the wire format. Real sub-second observed time would require `ChangeTrack::Report` to capture a `Time::HiRes` start; that is **out of scope** — the occurred-vs-observed *distinction* is the value here, not sub-second resolution. Note it as a future option only.
- **Fallback.** Heartbeats, warnings, and removed files have no usable mtime → occurred == observed (scan time).

## Global Constraints

- **Perl 5.20+, zero non-core dependencies.** Only core modules. No CPAN.
- **changetrack-ng is a SysAdmin config-change tracking tool, NOT a security/HIDS tool.** No hashes, no actor/detection fields.
- **OTel output is not yet deployed** — format changes are NOT breaking. Update affected tests in the same task.
- **Preserve sensitive-file diff suppression** (`sensitive_notify`, `_diff_text_for`). Unchanged by this plan.
- **Test runner:** `prove -lv t/NN-name.t` from project root. `Test::More` + `done_testing()`.

### Canonical field names used here

| Notifier | Occurred (event time) | Observed (scan time) | Source of occurred |
|---|---|---|---|
| OTLP | `timeUnixNano` (string int64 ns) | `observedTimeUnixNano` (string int64 ns) | `file_meta.mtime × 1e9`, else observed |
| File | `timestamp` (ISO8601 Z) | `observed_timestamp` (ISO8601 Z) | `gmtime(file_meta.mtime)`, else observed |

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `lib/ChangeTrack/Notify/OTLP.pm` (`_build_payload`) | Per-record occurred vs observed nanos |
| Modify | `lib/ChangeTrack/Notify/File.pm` (`_build_records`) | Per-record `timestamp` vs `observed_timestamp` |
| Test | `t/19-notify-otlp.t` | occurred≠observed when mtime present |
| Test | `t/09-notify-file.t` | `timestamp`/`observed_timestamp` split |

---

## Task 1: OTLP occurred-vs-observed nanos

**Files:**
- Modify: `lib/ChangeTrack/Notify/OTLP.pm` (`_build_payload`)
- Test: `t/19-notify-otlp.t`

**Interfaces:**
- Consumes: `$change->{file_meta}{mtime}` (epoch seconds or undef), `$report->{start_time}`.
- Produces: each change record's `timeUnixNano` = mtime×1e9 when defined else observed; `observedTimeUnixNano` = scan time always. Heartbeat/warning records: both = scan time.

- [ ] **Step 1: Write the failing test**

Append to `t/19-notify-otlp.t` before `done_testing()`:

```perl
########################################################################
# Occurred (mtime) vs Observed (scan) Timestamps
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'ts_split.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(endpoint => "http://127.0.0.1:$port/v1/logs");

    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);   # observed
    $r->add_change(
        path => '/etc/hosts', diff => ['+x'],
        stat => { mtime => 1_700_000_000, mode => '0644', type => 'file' },  # occurred
    );
    $r->set_end_time(1_000_000_002);
    $n->send($r);
    waitpid($pid, 0);

    my $rec = read_payload($body_file)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    is($rec->{timeUnixNano},         '1700000000000000000', 'timeUnixNano = mtime ns (occurred)');
    is($rec->{observedTimeUnixNano}, '1000000000000000000', 'observedTimeUnixNano = scan ns (observed)');
    isnt($rec->{timeUnixNano}, $rec->{observedTimeUnixNano}, 'occurred and observed differ');
}

########################################################################
# Records Without mtime Fall Back To Scan Time
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'ts_fallback.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs", heartbeat => 1);

    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->set_end_time(1_000_000_002);
    $n->send($r);   # heartbeat: no file
    waitpid($pid, 0);

    my $rec = read_payload($body_file)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    is($rec->{timeUnixNano}, $rec->{observedTimeUnixNano},
        'heartbeat occurred == observed (scan time)');
}
```

- [ ] **Step 2: Run to verify failure**

Run: `prove -lv t/19-notify-otlp.t`
Expected: FAIL — current builder sets `timeUnixNano == observedTimeUnixNano == scan` for change records, so `timeUnixNano = mtime` assertion fails.

- [ ] **Step 3: Implement per-record occurred/observed in `_build_payload`**

In `lib/ChangeTrack/Notify/OTLP.pm`, rename the run-level timestamp variable. Replace:

```perl
    my $observed_nano = sprintf('%d000000000', $report->{start_time} // time());
```

(this is the line introduced by the attribute-model plan; if that plan still has it named `$ts_nano`, rename here) — and update the **heartbeat** record to use `$observed_nano` for both `timeUnixNano` and `observedTimeUnixNano`.

In the change-record loop, immediately after `for my $c (@{ $report->changes }) {`, add:

```perl
            my $mtime = ($c->{file_meta} // {})->{mtime};
            my $occurred_nano = defined $mtime
                ? sprintf('%d000000000', $mtime)
                : $observed_nano;
```

Change that record's timestamp fields to:

```perl
                timeUnixNano         => $occurred_nano,
                observedTimeUnixNano => $observed_nano,
```

Ensure the **warning** record uses `$observed_nano` for both fields.

- [ ] **Step 4: Run to verify pass**

Run: `prove -lv t/19-notify-otlp.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Notify/OTLP.pm t/19-notify-otlp.t
git commit -m "feat(otlp): split occurred (mtime) from observed (scan) timestamps"
```

---

## Task 2: File notifier `timestamp` vs `observed_timestamp`

**Files:**
- Modify: `lib/ChangeTrack/Notify/File.pm` (`_build_records`)
- Test: `t/09-notify-file.t`

**Interfaces:**
- Consumes: `$change->{file_meta}{mtime}`, `$report->{start_time}`.
- Produces: each record gains `observed_timestamp` (scan time, ISO8601 Z). `timestamp` becomes the occurred time: `gmtime(mtime)` for changes with an mtime, else the observed time.

- [ ] **Step 1: Write the failing test**

Append to `t/09-notify-file.t` before `done_testing()`:

```perl
########################################################################
# timestamp (occurred) vs observed_timestamp (scan)
########################################################################
{
    my $log = "$dir/ts_split.log";
    my $n   = ChangeTrack::Notify::File->new(path => $log);

    my $report = ChangeTrack::Report->new(start_time => 1000000000);  # 2001-09-09T01:46:40Z
    $report->add_change(
        path => '/etc/hosts', diff => ['+x'],
        stat => { mtime => 1700000000, mode => '0644', type => 'file' },  # 2023-11-14T22:13:20Z
    );
    $report->set_end_time(1000000001);
    $n->send($report);

    my $r = last_record($log);
    is($r->{timestamp},          '2023-11-14T22:13:20Z', 'timestamp = mtime (occurred)');
    is($r->{observed_timestamp}, '2001-09-09T01:46:40Z', 'observed_timestamp = scan time');
}
```

- [ ] **Step 2: Run to verify failure**

Run: `prove -lv t/09-notify-file.t`
Expected: FAIL — no `observed_timestamp`; `timestamp` currently equals scan time, not mtime.

- [ ] **Step 3: Implement in `_build_records`**

In `lib/ChangeTrack/Notify/File.pm`, in `_build_records`, replace the single `$ts` line:

```perl
    my $ts      = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($report->{start_time} // time()));
```

with:

```perl
    my $observed_ts = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($report->{start_time} // time()));
```

In the heartbeat record, set:

```perl
            timestamp          => $observed_ts,
            observed_timestamp => $observed_ts,
```

In the change-record loop, compute the occurred timestamp right after the `if/elsif/else` that sets `$type`/`$event_name`/`$body`:

```perl
        my $mtime = ($c->{file_meta} // {})->{mtime};
        my $occurred_ts = defined $mtime
            ? strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($mtime))
            : $observed_ts;
```

and set the change record's timestamp fields to:

```perl
            timestamp          => $occurred_ts,
            observed_timestamp => $observed_ts,
```

In the warning record, set both `timestamp` and `observed_timestamp` to `$observed_ts`.

- [ ] **Step 4: Run to verify pass**

Run: `prove -lv t/09-notify-file.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Notify/File.pm t/09-notify-file.t
git commit -m "feat(file): add observed_timestamp; timestamp reflects file mtime"
```

---

## Self-Review

- **Spec coverage:** F5 (occurred=mtime, observed=scan, nanosecond encoding, fallback when no file) — Tasks 1 (OTLP) and 2 (File). Sub-second Time::HiRes explicitly deferred (Decisions). ✔
- **Placeholder scan:** Both tasks give exact old→new lines and concrete expected ISO/ns values. No TBDs.
- **Type consistency:** OTLP nanos are string-encoded int64 (`sprintf '%d000000000'`) consistent with the existing wire format and the `timeUnixNano encoded as JSON string` test. File timestamps are ISO8601 Z strings consistent with the reshape plan.
- **Constraint check:** No new dependencies. Sensitive handling untouched.

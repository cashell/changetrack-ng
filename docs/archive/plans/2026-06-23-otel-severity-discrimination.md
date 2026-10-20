# OTel Severity Discrimination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the OTLP and File notifiers configurable, semantically meaningful log severities per record class — change events default to INFO, heartbeats to DEBUG, warnings to WARN — instead of emitting everything at the same level.

**Architecture:** A small text→number severity map lives on `Notify/Base.pm` (`_severity_for($name)` → `(number, text)`). Three config keys (`severity_change`, `severity_heartbeat`, `severity_warning`) hold severity *names* with sensible defaults; each notifier resolves them through the shared map when building a record. The OTLP notifier emits `severityNumber`+`severityText`; the File notifier emits `severity_number`+`severity_text`.

**Tech Stack:** Perl 5.20+, core only. No new dependencies.

**Dependencies:** `2026-06-23-otel-attribute-model.md` (OTLP record classes + event.name) AND `2026-06-23-file-notifier-otel-reshape.md` (File per-event records with `severity_text`/`severity_number`). Apply after both. Independent of the diff-truncation and timestamp plans (any order among those three).

## Decisions

- **Defaults:** change=`INFO` (9), heartbeat=`DEBUG` (5), warning=`WARN` (13). A routine config change is informational; a heartbeat ("nothing changed, still alive") is diagnostic noise most of the time; a scan warning is the one thing an operator should be alerted to. This matches the OTel severity model and the reference recommendation.
- **Configurable by name.** Operators set `severity_change`, `severity_heartbeat`, `severity_warning` to one of `DEBUG|INFO|WARN|ERROR` (case-insensitive). Unknown/blank → the record class's default. We expose only the four levels we actually use; the map can grow later.
- **Single source of truth.** The name→number table lives once on Base; both notifiers and both wire formats derive from it. No duplicated literals.

## Global Constraints

- **Perl 5.20+, zero non-core dependencies.** Core only. No CPAN.
- **changetrack-ng is a SysAdmin config-change tracking tool, NOT a security/HIDS tool.** No hashes, no actor/detection fields.
- **OTel output is not yet deployed** — format changes are NOT breaking. Update affected tests in the same task.
- **Preserve sensitive-file diff suppression.** Unchanged by this plan.
- **Validate external input.** Severity config values are validated through the map; invalid values fall back to the default rather than producing an out-of-range severityNumber.
- **Test runner:** `prove -lv t/NN-name.t` from project root. `Test::More` + `done_testing()`.

### Severity map (single source of truth)

| Name (config) | OTLP severityNumber | OTLP/File severityText | Default for |
|---|---|---|---|
| `DEBUG` | 5 | `DEBUG` | heartbeat |
| `INFO` | 9 | `INFO` | change events |
| `WARN` | 13 | `WARN` | warnings |
| `ERROR` | 17 | `ERROR` | (available, not a default) |

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `lib/ChangeTrack/Notify/Base.pm` | `_severity_for` map + `_severity_cfg` resolver |
| Modify | `lib/ChangeTrack/Notify/OTLP.pm` (`new`, `config_keys`, `_build_payload`) | Per-class severityNumber/severityText from config |
| Modify | `lib/ChangeTrack/Notify/File.pm` (`new`, `config_keys`, `_build_records`) | Per-class severity_number/severity_text from config |
| Test | `t/19-notify-otlp.t` | Default + overridden severities; heartbeat default DEBUG |
| Test | `t/09-notify-file.t` | Default + overridden severities |

---

## Task 1: Shared severity map + resolver on Base

**Files:**
- Modify: `lib/ChangeTrack/Notify/Base.pm`
- Test: `t/19-notify-otlp.t` (direct unit check of the resolver)

**Interfaces:**
- Produces:
  - `($number, $text) = $self->_severity_for($name)` — maps a severity name (case-insensitive) to its OTel number and canonical text. Unknown/undef name → returns `(0, 'UNSPECIFIED')` so callers can detect "not a valid name".
  - `($number, $text) = $self->_severity_cfg($config_key, $default_name)` — reads `$self->{$config_key}`, resolves it via `_severity_for`; if the configured value is missing or unknown, resolves `$default_name` instead.

- [ ] **Step 1: Write the failing test**

Append to `t/19-notify-otlp.t` before `done_testing()`:

```perl
########################################################################
# Severity Map + Resolver
########################################################################
{
    my $n = ChangeTrack::Notify::OTLP->new;

    is_deeply([$n->_severity_for('INFO')],  [9,  'INFO'],  'INFO -> 9');
    is_deeply([$n->_severity_for('debug')], [5,  'DEBUG'], 'case-insensitive debug -> 5');
    is_deeply([$n->_severity_for('WARN')],  [13, 'WARN'],  'WARN -> 13');
    is_deeply([$n->_severity_for('bogus')], [0,  'UNSPECIFIED'], 'unknown -> UNSPECIFIED');

    # _severity_cfg: unset key falls back to default name
    is_deeply([$n->_severity_cfg('severity_change', 'INFO')], [9, 'INFO'],
        'unset config -> default INFO');

    my $n2 = ChangeTrack::Notify::OTLP->new(severity_change => 'warn');
    is_deeply([$n2->_severity_cfg('severity_change', 'INFO')], [13, 'WARN'],
        'configured value overrides default (case-insensitive)');

    my $n3 = ChangeTrack::Notify::OTLP->new(severity_change => 'nonsense');
    is_deeply([$n3->_severity_cfg('severity_change', 'INFO')], [9, 'INFO'],
        'invalid config falls back to default');
}
```

- [ ] **Step 2: Run to verify failure**

Run: `prove -lv t/19-notify-otlp.t`
Expected: FAIL — `Can't locate object method "_severity_for"`.

- [ ] **Step 3: Implement on Base.pm**

In `lib/ChangeTrack/Notify/Base.pm`, add before the final `1;`:

```perl
# Severity name -> OTel severityNumber.  Single source of truth for both
# notifiers.  Only the levels changetrack-ng actually emits are listed.
my %SEVERITY = (
    DEBUG => 5,
    INFO  => 9,
    WARN  => 13,
    ERROR => 17,
);

# _severity_for -- Map a severity NAME (case-insensitive) to (number, text).
# Unknown/undef -> (0, 'UNSPECIFIED').
sub _severity_for {
    my ($self, $name) = @_;
    my $key = defined $name ? uc $name : '';
    return ($SEVERITY{$key}, $key) if exists $SEVERITY{$key};
    return (0, 'UNSPECIFIED');
}

# _severity_cfg -- Resolve $self->{$key}; fall back to $default_name when the
# configured value is missing or not a recognised severity name.
sub _severity_cfg {
    my ($self, $key, $default_name) = @_;
    my ($num, $text) = $self->_severity_for($self->{$key});
    return ($num, $text) if $num;             # valid configured value
    return $self->_severity_for($default_name);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `prove -lv t/19-notify-otlp.t`
Expected: PASS (severity block).

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Notify/Base.pm t/19-notify-otlp.t
git commit -m "feat(notify): add shared severity name->number map + resolver"
```

---

## Task 2: Per-class severity in the OTLP notifier

**Files:**
- Modify: `lib/ChangeTrack/Notify/OTLP.pm` (`new`, `config_keys`, `_build_payload`)
- Test: `t/19-notify-otlp.t`

**Interfaces:**
- Consumes: `_severity_cfg` from Task 1.
- Produces: change records use `severity_change` (default INFO=9); heartbeat records use `severity_heartbeat` (default DEBUG=5); warning records use `severity_warning` (default WARN=13). Each record sets both `severityNumber` and `severityText`. New config keys: `severity_change`, `severity_heartbeat`, `severity_warning`.

- [ ] **Step 1: Write the failing test**

Append to `t/19-notify-otlp.t` before `done_testing()`:

```perl
########################################################################
# Per-Class Severity (defaults + overrides)
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};

    # heartbeat default DEBUG (5)
    {
        my $bf = File::Spec->catfile($tmpdir, 'sev_hb.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs", heartbeat => 1)->send($r);
        waitpid($pid, 0);
        my $rec = read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
        is($rec->{severityNumber}, 5,       'heartbeat default severityNumber DEBUG=5');
        is($rec->{severityText},   'DEBUG', 'heartbeat default severityText DEBUG');
    }

    # change default INFO (9)
    {
        my $bf = File::Spec->catfile($tmpdir, 'sev_chg.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/hosts', diff => ['+x']);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(endpoint => "http://127.0.0.1:$port/v1/logs")->send($r);
        waitpid($pid, 0);
        my $rec = read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
        is($rec->{severityNumber}, 9,      'change default severityNumber INFO=9');
        is($rec->{severityText},   'INFO', 'change default severityText INFO');
    }

    # change override WARN (13)
    {
        my $bf = File::Spec->catfile($tmpdir, 'sev_chg_ovr.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/hosts', diff => ['+x']);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs",
            severity_change => 'warn')->send($r);
        waitpid($pid, 0);
        my $rec = read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
        is($rec->{severityNumber}, 13,     'change override severityNumber WARN=13');
        is($rec->{severityText},   'WARN', 'change override severityText WARN');
    }
}
```

> Note: the existing heartbeat test (carried in from the attribute-model plan) that asserts `severityNumber == 9` for a heartbeat must be updated to `5`/`DEBUG` as part of this step, since the default changes here.

- [ ] **Step 2: Run to verify failure**

Run: `prove -lv t/19-notify-otlp.t`
Expected: FAIL — heartbeat currently INFO(9); change records use a fixed severity; overrides ignored.

- [ ] **Step 3: Implement in OTLP.pm**

In `new`, add defaults next to the others:

```perl
    $self->{severity_change}    //= 'INFO';
    $self->{severity_heartbeat} //= 'DEBUG';
    $self->{severity_warning}   //= 'WARN';
```

Replace `config_keys` with (adding the three keys):

```perl
sub config_keys { qw(endpoint headers compression full_diff heartbeat timeout insecure resource_attributes emit_recipients max_diff_bytes severity_change severity_heartbeat severity_warning) }
```

In `_build_payload`:

- For the **heartbeat** record, replace its fixed `severityNumber => 9` / `severityText => 'INFO'` with:

```perl
    my ($hb_num, $hb_text) = $self->_severity_cfg('severity_heartbeat', 'DEBUG');
    # ...
                severityNumber => $hb_num,
                severityText   => $hb_text,
```

- In the **change-record loop**, resolve once before the loop and use per record:

```perl
    my ($chg_num, $chg_text) = $self->_severity_cfg('severity_change', 'INFO');
```
```perl
                severityNumber => $chg_num,
                severityText   => $chg_text,
```

- For the **warning** record, replace the fixed WARN literals with:

```perl
    my ($warn_num, $warn_text) = $self->_severity_cfg('severity_warning', 'WARN');
    # ...
                severityNumber => $warn_num,
                severityText   => $warn_text,
```

- [ ] **Step 4: Run to verify pass**

Run: `prove -lv t/19-notify-otlp.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Notify/OTLP.pm t/19-notify-otlp.t
git commit -m "feat(otlp): configurable per-class severity (change/heartbeat/warning)"
```

---

## Task 3: Per-class severity in the File notifier

**Files:**
- Modify: `lib/ChangeTrack/Notify/File.pm` (`new`, `config_keys`, `_build_records`)
- Test: `t/09-notify-file.t`

**Interfaces:**
- Consumes: `_severity_cfg` from Task 1.
- Produces: each File record's `severity_number`/`severity_text` come from `severity_change`/`severity_heartbeat`/`severity_warning` (same defaults as OTLP). New config keys mirror the OTLP notifier.

- [ ] **Step 1: Write the failing test**

Append to `t/09-notify-file.t` before `done_testing()`:

```perl
########################################################################
# Per-Class Severity (File notifier)
########################################################################
{
    # heartbeat default DEBUG
    my $log_hb = "$dir/sev_hb.log";
    my $rhb = ChangeTrack::Report->new(start_time => 1000000000);
    $rhb->set_end_time(1000000001);
    ChangeTrack::Notify::File->new(path => $log_hb, heartbeat => 1)->send($rhb);
    my $hb = last_record($log_hb);
    is($hb->{severity_number}, 5,       'file heartbeat severity_number DEBUG=5');
    is($hb->{severity_text},   'DEBUG', 'file heartbeat severity_text DEBUG');

    # change default INFO
    my $log_ch = "$dir/sev_ch.log";
    my $rch = ChangeTrack::Report->new(start_time => 1000000000);
    $rch->add_change(path => '/etc/hosts', diff => ['+x']);
    ChangeTrack::Notify::File->new(path => $log_ch)->send($rch);
    my $ch = last_record($log_ch);
    is($ch->{severity_number}, 9,      'file change severity_number INFO=9');
    is($ch->{severity_text},   'INFO', 'file change severity_text INFO');

    # change override
    my $log_ov = "$dir/sev_ov.log";
    my $rov = ChangeTrack::Report->new(start_time => 1000000000);
    $rov->add_change(path => '/etc/hosts', diff => ['+x']);
    ChangeTrack::Notify::File->new(path => $log_ov, severity_change => 'warn')->send($rov);
    my $ov = last_record($log_ov);
    is($ov->{severity_number}, 13,     'file change override severity_number WARN=13');
    is($ov->{severity_text},   'WARN', 'file change override severity_text WARN');
}
```

> Note: any existing File-notifier severity assertion carried in from the reshape plan that expects change=INFO is consistent; update any heartbeat assertion that expected INFO to DEBUG here.

- [ ] **Step 2: Run to verify failure**

Run: `prove -lv t/09-notify-file.t`
Expected: FAIL — severities fixed / heartbeat not DEBUG / override ignored.

- [ ] **Step 3: Implement in File.pm**

In `new`, add:

```perl
    $self->{severity_change}    //= 'INFO';
    $self->{severity_heartbeat} //= 'DEBUG';
    $self->{severity_warning}   //= 'WARN';
```

Replace `config_keys` with:

```perl
sub config_keys { qw(path heartbeat full_diff emit_recipients max_diff_bytes severity_change severity_heartbeat severity_warning) }
```

In `_build_records`, resolve the three severities near the top:

```perl
    my ($chg_num,  $chg_text)  = $self->_severity_cfg('severity_change',    'INFO');
    my ($hb_num,   $hb_text)   = $self->_severity_cfg('severity_heartbeat', 'DEBUG');
    my ($warn_num, $warn_text) = $self->_severity_cfg('severity_warning',   'WARN');
```

Then set, in the respective records:

- heartbeat record:
```perl
        severity_number => $hb_num,
        severity_text   => $hb_text,
```
- change record (inside the loop):
```perl
        severity_number => $chg_num,
        severity_text   => $chg_text,
```
- warning record:
```perl
        severity_number => $warn_num,
        severity_text   => $warn_text,
```

- [ ] **Step 4: Run to verify pass**

Run: `prove -lv t/09-notify-file.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Notify/File.pm t/09-notify-file.t
git commit -m "feat(file): configurable per-class severity (change/heartbeat/warning)"
```

---

## Self-Review

- **Spec coverage:** F8 (semantically meaningful, configurable per-class severity; heartbeat DEBUG / change INFO / warning WARN defaults; both notifiers; both wire formats) — Tasks 1-3. ✔
- **Placeholder scan:** Map, resolver, both notifier edits, and tests are concrete with exact numbers (5/9/13/17) and names. No TBDs.
- **Type consistency:** `_severity_for`/`_severity_cfg` return `($number, $text)` in Task 1 and are consumed identically in Tasks 2-3. OTLP fields are `severityNumber`/`severityText`; File fields are `severity_number`/`severity_text` — consistent with the attribute-model and reshape plans respectively.
- **Constraint check:** Invalid config values fall back to defaults (no out-of-range severityNumber) — satisfies input-validation guardrail. Single source of truth on Base; no duplicated literals. The heartbeat default moves from INFO(9) to DEBUG(5), so the pre-existing heartbeat severity assertion is updated within Tasks 2 and 3 (noted explicitly) — the tree never goes red across the commit boundary.
- **Cross-plan note:** This plan changes the heartbeat severity default that the attribute-model plan's heartbeat test asserts (9→5). Whichever plan runs second owns updating that assertion; both Task 2 and Task 3 call this out.

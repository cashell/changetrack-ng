# OTel Attribute Model & Data Plumbing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ad-hoc `ct.*` OTLP attributes with OpenTelemetry semantic-convention-aligned names, add an `event.name` discriminator, propagate file stat metadata (`file.mode/owner/group/size`) into change records, and emit recipient lists as an opt-in attribute.

**Architecture:** A small data-plumbing spine carries stat metadata from the place it is already collected (`Metadata.pm`) through `Report::add_change` into the OTLP notifier. The OTLP payload builder is rewritten to emit the canonical attribute set below. This is the foundational plan — Plans 2–5 (File-notifier reshape, timestamps, diff truncation, severity) build on the names and `file_meta` structure established here.

**Tech Stack:** Perl 5.20+, `JSON::PP`, `File::Basename` (all core). Tests: `Test::More` + `prove`, with a forking mock OTLP/HTTP receiver (already present in `t/19-notify-otlp.t`).

## Global Constraints

- **Perl 5.20+, zero non-core dependencies.** Only core modules: `JSON::PP`, `HTTP::Tiny`, `IO::Compress::Gzip`, `POSIX`, `Fcntl`, `Carp`, `File::Basename`, `Time::HiRes`. No CPAN.
- **changetrack-ng is a SysAdmin config-change tracking tool, NOT a security/HIDS tool.** Do not frame output as security telemetry. Do NOT add content hashes (the VCS backend is the integrity record). Do NOT add actor/detection-provenance fields.
- **OTel output is not yet deployed** — attribute/format renames are NOT breaking changes. Rename freely; update the affected tests in the *same* task so the tree is never left red.
- **Preserve sensitive-file diff suppression.** `sensitive_notify` (suppress|allow) gates diff emission via `_diff_text_for`/`_sensitive_notify_allowed` in `Notify/Base.pm`. Never emit a suppressed diff.
- **Never expose sensitive data** in logs/notifications/errors (recipient PII, suppressed diffs). Recipient emission is opt-in and defaults OFF.
- **File headers** on any new file: the vim modeline + perltidy line + SPDX block exactly as in existing `lib/ChangeTrack/Notify/*.pm`.
- **Test runner:** `prove -lv t/NN-name.t` from the changetrack-ng project root. All tests use `Test::More` + `done_testing()`.

### Canonical attribute naming (authoritative — every plan in this series uses these exact keys)

| Current (`ct.*`) | New key | OTLP value type | Notes |
|---|---|---|---|
| `ct.path` | `file.path` | stringValue | absolute path |
| — | `file.name` | stringValue | basename (this plan) |
| — | `file.directory` | stringValue | dirname (this plan) |
| `ct.is_new` + `ct.is_removed` | `config_change.type` | stringValue enum | `created` \| `modified` \| `removed` |
| `ct.is_sensitive` | `config_change.sensitive` | boolValue | |
| `ct.meta_change` | `config_change.meta_summary` | stringValue | omit when empty |
| `ct.diff` | `config_change.diff` | stringValue | omit when empty/suppressed |
| — | `config_change.diff_truncated` | boolValue | Plan 4 (otel-diff-truncation) only |
| — | `config_change.notified` | arrayValue&lt;stringValue&gt; | this plan / F7, behind `emit_recipients` (default off) |
| — | `file.mode` | stringValue | e.g. `0644` (this plan) |
| — | `file.owner.name` | stringValue | (this plan) |
| — | `file.group.name` | stringValue | (this plan) |
| — | `file.size` | intValue | bytes (this plan) |
| `ct.files_tracked` | `changetrack.files_tracked` | intValue | common attr |
| `ct.run_duration_ms` | `changetrack.run_duration_ms` | intValue | common attr |
| `ct.heartbeat` | *(removed)* | — | discriminate via `event.name` instead |

### Canonical `event.name` values (this plan / F3)

| Record | `event.name` |
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
| Modify | `lib/ChangeTrack/Report.pm:95-120` | `add_change`/`add_removed` accept `stat` hashref, normalize into `file_meta` |
| Modify | `lib/ChangeTrack/Runner.pm` (4 `add_change` sites: ~443, ~456, ~487, ~511) | Pass `stat => $rec` so stat metadata reaches notifiers |
| Modify | `lib/ChangeTrack/Notify/OTLP.pm` (`new`, `config_keys`, `_build_payload`) | Emit canonical attributes + `event.name` + `file.*` + opt-in recipients |
| Test | `t/21-report.t` | `file_meta` normalization |
| Test | `t/19-notify-otlp.t` | Rewrite `ct.*` assertions to canonical names; add `event.name`, `file.*`, `config_change.type`, recipients tests |

---

## Task 1: Report carries stat metadata as `file_meta`

**Files:**
- Modify: `lib/ChangeTrack/Report.pm:95-120`
- Test: `t/21-report.t`

**Interfaces:**
- Consumes: a stat record hashref from `ChangeTrack::Metadata::record_for`, shape: `{ path, mode (e.g. '0644'), uid, gid, user, group, type, mtime?, size?, target? }`.
- Produces: each change record gains `file_meta => { mode, owner, group, size, mtime }` where each value is the corresponding stat field or `undef`. `owner` maps from stat `user`, `group` from stat `group`. Plans 3–5 read `$change->{file_meta}`.

- [ ] **Step 1: Write the failing test**

Add to the end of `t/21-report.t`, before `done_testing()`:

```perl
# file_meta normalization from a stat record
{
    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->add_change(
        path => '/etc/hosts',
        diff => ['+1.2.3.4 host'],
        stat => {
            path => '/etc/hosts', mode => '0644', uid => 0, gid => 0,
            user => 'root', group => 'root', type => 'file',
            mtime => 1_700_000_000, size => 42,
        },
    );
    my ($c) = $r->changes;
    is($c->{file_meta}{mode},  '0644',        'file_meta.mode from stat');
    is($c->{file_meta}{owner}, 'root',        'file_meta.owner from stat user');
    is($c->{file_meta}{group}, 'root',        'file_meta.group from stat group');
    is($c->{file_meta}{size},  42,            'file_meta.size from stat');
    is($c->{file_meta}{mtime}, 1_700_000_000, 'file_meta.mtime from stat');
}

# add_change without stat: file_meta present, all undef
{
    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->add_change(path => '/etc/hosts', diff => []);
    my ($c) = $r->changes;
    ok(exists $c->{file_meta},          'file_meta present even without stat');
    ok(!defined $c->{file_meta}{mode},  'file_meta.mode undef without stat');
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -lv t/21-report.t`
Expected: FAIL — `file_meta` key does not exist (`Use of uninitialized value` / `is` mismatches).

- [ ] **Step 3: Implement `file_meta` normalization**

In `lib/ChangeTrack/Report.pm`, replace `add_change` (lines 95-106) with:

```perl
# add_change -- Append a change record for a modified or new file.
# Recognized keys: path, is_new, is_removed, is_sensitive, diff,
# meta_change, recipients, stat (a Metadata stat record hashref).
sub add_change {
    my ($self, %args) = @_;
    my $st = $args{stat} // {};
    push @{ $self->{changes} }, {
        path         => $args{path},
        is_new       => $args{is_new}       // 0,
        is_removed   => $args{is_removed}   // 0,
        is_sensitive => $args{is_sensitive} // 0,
        diff         => $args{diff}         // [],
        meta_change  => $args{meta_change}  // '',
        recipients   => $args{recipients}   // [],
        file_meta    => {
            mode  => $st->{mode},
            owner => $st->{user},
            group => $st->{group},
            size  => $st->{size},
            mtime => $st->{mtime},
        },
    };
}
```

In the same file, replace `add_removed` (lines 109-120) with:

```perl
# add_removed -- Append a change record for a file that vanished from disk.
sub add_removed {
    my ($self, %args) = @_;
    push @{ $self->{changes} }, {
        path         => $args{path},
        is_new       => 0,
        is_removed   => 1,
        is_sensitive => 0,
        diff         => [],
        meta_change  => '(file removed from disk)',
        recipients   => $args{recipients} // [],
        file_meta    => { mode => undef, owner => undef, group => undef,
                          size => undef, mtime => undef },
    };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -lv t/21-report.t`
Expected: PASS (all assertions, including pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Report.pm t/21-report.t
git commit -m "feat(report): carry stat metadata as file_meta on change records"
```

---

## Task 2: Runner passes stat record into change reports

**Files:**
- Modify: `lib/ChangeTrack/Runner.pm` (the four `add_change` call sites near lines 443, 456, 487, 511)
- Test: `t/04-runner-rcs.t` (existing runner integration test)

**Interfaces:**
- Consumes: `$rec = $md->record_for($real_path)` — already in scope at line 401 in `_process_file`.
- Produces: every `add_change` call passes `stat => $rec`, so `file_meta` is populated for real files. `add_removed` (line 378) is unchanged — the file is gone, no stat is available.

- [ ] **Step 1: Write the failing test**

Add to the end of `t/04-runner-rcs.t`, before `done_testing()`. This drives a real file through the runner and asserts `file_meta` reaches the report. (Adapt the harness names — `make_runner`/temp-dir setup — to match the helpers already defined at the top of `t/04-runner-rcs.t`; the assertion block below is the new content.)

```perl
# file_meta flows from Runner through to the change report
{
    my ($dir, $cfg) = setup_tracked_dir();        # existing helper in this file
    my $file = "$dir/hosts";
    write_file($file, "1.2.3.4 host\n");          # existing helper
    my $report = run_once($cfg);                  # first run: new file
    write_file($file, "1.2.3.4 host\n5.6.7.8 b\n");
    $report = run_once($cfg);                     # second run: modified

    my ($c) = grep { $_->{path} =~ /hosts$/ } $report->changes;
    ok(defined $c,                       'change recorded for hosts');
    ok(defined $c->{file_meta}{mode},    'file_meta.mode populated by Runner');
    ok(defined $c->{file_meta}{mtime},   'file_meta.mtime populated by Runner');
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -lv t/04-runner-rcs.t`
Expected: FAIL — `file_meta.mode` undef because Runner does not yet pass `stat`.

- [ ] **Step 3: Add `stat => $rec` to each `add_change` call**

In `lib/ChangeTrack/Runner.pm`, add the line `stat => $rec,` to each of the four `add_change(...)` calls. Concretely:

The empty-file meta change (around line 443-450) becomes:

```perl
            $report->add_change(
                path         => $real_path,
                is_new       => 0,
                is_sensitive => $is_sensitive,
                diff         => [],
                meta_change  => $meta_summary,
                recipients   => $recipients,
                stat         => $rec,
            );
```

The empty-file new case (around line 456-463) becomes:

```perl
            $report->add_change(
                path         => $real_path,
                is_new       => 1,
                is_sensitive => $is_sensitive,
                diff         => ['(new empty file)'],
                meta_change  => '',
                recipients   => $recipients,
                stat         => $rec,
            );
```

The new file/symlink case (around line 487-494) becomes:

```perl
        $report->add_change(
            path         => $real_path,
            is_new       => 1,
            is_sensitive => $is_sensitive,
            diff         => ['(new file)'],
            meta_change  => '',
            recipients   => $recipients,
            stat         => $rec,
        );
```

The existing-file changed case (around line 511-518) becomes:

```perl
            $report->add_change(
                path         => $real_path,
                is_new       => 0,
                is_sensitive => $is_sensitive,
                diff         => $diff_lines,
                meta_change  => $meta_summary,
                recipients   => $recipients,
                stat         => $rec,
            );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -lv t/04-runner-rcs.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Runner.pm t/04-runner-rcs.t
git commit -m "feat(runner): plumb stat record into add_change for file_meta"
```

---

## Task 3: Rewrite existing OTLP attribute assertions to canonical names

This task changes the *tests* first (TDD): the existing `ct.*` assertions are rewritten to the canonical names, which fail against the current `ct.*`-emitting code. Task 4 then implements the rename to make them pass.

**Files:**
- Modify: `t/19-notify-otlp.t` (assertion blocks at lines 283-288, 310-311, 333-334, 361)

**Interfaces:**
- Consumes: the canonical names table in Global Constraints.
- Produces: a test suite asserting `file.path`, `config_change.type`, `config_change.sensitive`, `changetrack.files_tracked`, `changetrack.run_duration_ms`, and `event.name`; with the `ct.heartbeat` discriminator removed.

- [ ] **Step 1: Rewrite the value-type assertion block (lines 283-288)**

Replace:

```perl
    ok(exists $a{'ct.path'}{stringValue},      'ct.path uses stringValue');
    ok(exists $a{'ct.is_new'}{boolValue},      'ct.is_new uses boolValue');
    ok(exists $a{'ct.is_sensitive'}{boolValue},'ct.is_sensitive uses boolValue');
    ok(exists $a{'ct.files_tracked'}{intValue},'ct.files_tracked uses intValue');
    # intValue must be a string (spec: int64 encoded as string)
    is(ref($a{'ct.files_tracked'}{intValue}), '', 'ct.files_tracked intValue is a scalar (string)');
```

with:

```perl
    ok(exists $a{'file.path'}{stringValue},          'file.path uses stringValue');
    ok(exists $a{'config_change.type'}{stringValue}, 'config_change.type uses stringValue');
    is($a{'config_change.type'}{stringValue}, 'modified', 'config_change.type=modified for an edit');
    ok(exists $a{'config_change.sensitive'}{boolValue}, 'config_change.sensitive uses boolValue');
    ok(exists $a{'changetrack.files_tracked'}{intValue}, 'changetrack.files_tracked uses intValue');
    # intValue must be a string (spec: int64 encoded as string)
    is(ref($a{'changetrack.files_tracked'}{intValue}), '', 'files_tracked intValue is a scalar (string)');
    ok(exists $a{'event.name'}{stringValue},         'event.name present on change record');
    is($a{'event.name'}{stringValue}, 'changetrack.file.changed', 'event.name=changetrack.file.changed');
```

- [ ] **Step 2: Replace the `ct.heartbeat`-discriminator block (lines 294-312)**

The `ct.heartbeat=false on change record` assertion no longer applies — discrimination is via `event.name`. Replace the whole block (the `# Ct.Heartbeat=False On Change Records` section, lines 291-312) with an `event.name` discrimination check:

```perl
########################################################################
# event.name Discriminates Change vs Heartbeat
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'evname.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );
    $n->send(make_report(with_change => 1));
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    is($a{'event.name'}{stringValue}, 'changetrack.file.changed',
        'change record event.name is changetrack.file.changed (not heartbeat)');
    ok(!exists $a{'ct.heartbeat'}, 'ct.heartbeat attribute removed');
}
```

- [ ] **Step 3: Rewrite the common-fields presence block (lines 333-334)**

Replace:

```perl
    ok(exists $a{'ct.files_tracked'},    'ct.files_tracked present');
    ok(exists $a{'ct.run_duration_ms'},  'ct.run_duration_ms present');
```

with:

```perl
    ok(exists $a{'changetrack.files_tracked'},    'changetrack.files_tracked present');
    ok(exists $a{'changetrack.run_duration_ms'},  'changetrack.run_duration_ms present');
```

- [ ] **Step 4: Rewrite the heartbeat-record assertion (line 361)**

Replace:

```perl
    ok($a{'ct.heartbeat'}{boolValue},    'Heartbeat: ct.heartbeat=true');
```

with:

```perl
    is($a{'event.name'}{stringValue}, 'changetrack.run.heartbeat',
        'Heartbeat: event.name is changetrack.run.heartbeat');
```

- [ ] **Step 5: Rewrite the sensitive/full-diff `ct.diff` assertions (lines 689, 713-714, 737-738, 761)**

Replace each `ct.diff` with `config_change.diff` (key name only; logic unchanged):

```perl
    # line ~689
    ok(!exists $a{'config_change.diff'},  'Sensitive suppress: config_change.diff omitted');
    # line ~713-714
    ok(exists $a{'config_change.diff'},   'sensitive_notify=allow: config_change.diff present');
    like($a{'config_change.diff'}{stringValue}, qr/old_hash/, 'allow: diff content included');
    # line ~737-738
    ok(exists $a{'config_change.diff'},   'Full diff: config_change.diff present');
    like($a{'config_change.diff'}{stringValue}, qr/\+root/, 'Full diff: diff content included');
    # line ~761
    ok(!exists $a{'config_change.diff'},  'No config_change.diff attr without full_diff');
```

- [ ] **Step 6: Run tests to verify they now FAIL against current code**

Run: `prove -lv t/19-notify-otlp.t`
Expected: FAIL — current `OTLP.pm` still emits `ct.*`, so the renamed-key assertions miss.

- [ ] **Step 7: Commit the test changes**

```bash
git add t/19-notify-otlp.t
git commit -m "test(otlp): assert canonical OTel attribute names and event.name"
```

---

## Task 4: Emit canonical attributes from the OTLP builder

**Files:**
- Modify: `lib/ChangeTrack/Notify/OTLP.pm` (`new` line 39-53, `config_keys` line 64, `_build_payload` lines 96-192, add `use File::Basename`)
- Test: `t/19-notify-otlp.t` (made to pass; plus new `file.*`, `config_change.type` enum, and recipients tests)

**Interfaces:**
- Consumes: `$change->{file_meta}` from Task 1; `$change->{recipients}`; the canonical names + `event.name` tables.
- Produces: OTLP `logRecords` whose attributes use the canonical keys. New config key `emit_recipients` (default 0). `config_change.notified` is an `arrayValue` of `stringValue`s, emitted only when `emit_recipients` is true and the change has recipients.

- [ ] **Step 1: Add the `emit_recipients` default and config key, and import File::Basename**

In `lib/ChangeTrack/Notify/OTLP.pm`, after line 34 (`use ChangeTrack::Util qw(hostname);`) add:

```perl
use File::Basename qw(basename dirname);
```

In `new` (after line 50, before `$self->{_endpoint_warned} = 0;`) add:

```perl
    $self->{emit_recipients}     //= 0;
```

Replace `config_keys` (line 64) with:

```perl
sub config_keys { qw(endpoint headers compression full_diff heartbeat timeout insecure resource_attributes emit_recipients) }
```

- [ ] **Step 2: Rewrite `_build_payload` common attributes and heartbeat record (lines 103-123)**

Replace lines 103-123 (the `@common_attrs` declaration through the end of the heartbeat `if` block) with:

```perl
    my @common_attrs = (
        { key => 'changetrack.files_tracked', value => { intValue => "$tracked" } },
    );
    push @common_attrs,
        { key => 'changetrack.run_duration_ms', value => { intValue => sprintf('%d', $dur) } }
        if defined $dur;

    my @log_records;

    if ($is_heartbeat) {
        push @log_records, {
            timeUnixNano         => $ts_nano,
            observedTimeUnixNano => $ts_nano,
            severityNumber       => 9,
            severityText         => 'INFO',
            body                 => { stringValue => 'changetrack-ng heartbeat (no changes)' },
            attributes           => [
                { key => 'event.name', value => { stringValue => 'changetrack.run.heartbeat' } },
                @common_attrs,
            ],
        };
    } else {
```

- [ ] **Step 3: Rewrite the change-record loop (lines 125-166)**

Replace the `for my $c (@{ $report->changes }) { ... }` block (lines 125-166) with:

```perl
        for my $c (@{ $report->changes }) {
            my ($type, $event_name, $body_msg);
            if ($c->{is_removed}) {
                $type = 'removed';
                $event_name = 'changetrack.file.removed';
                $body_msg   = "config file removed: $c->{path}";
            } elsif ($c->{is_new}) {
                $type = 'created';
                $event_name = 'changetrack.file.created';
                $body_msg   = "new config file: $c->{path}";
            } else {
                $type = 'modified';
                $event_name = 'changetrack.file.changed';
                $body_msg   = "config file changed: $c->{path}";
            }

            my @attrs = (
                { key => 'event.name',     value => { stringValue => $event_name } },
                { key => 'file.path',      value => { stringValue => $c->{path} } },
                { key => 'file.name',      value => { stringValue => basename($c->{path}) } },
                { key => 'file.directory', value => { stringValue => dirname($c->{path}) } },
                { key => 'config_change.type', value => { stringValue => $type } },
                { key => 'config_change.sensitive',
                  value => { boolValue => $c->{is_sensitive} ? JSON::PP::true() : JSON::PP::false() } },
                @common_attrs,
            );

            my $fm = $c->{file_meta} // {};
            push @attrs, { key => 'file.mode',       value => { stringValue => $fm->{mode} } }
                if defined $fm->{mode};
            push @attrs, { key => 'file.owner.name', value => { stringValue => $fm->{owner} } }
                if defined $fm->{owner};
            push @attrs, { key => 'file.group.name', value => { stringValue => $fm->{group} } }
                if defined $fm->{group};
            push @attrs, { key => 'file.size', value => { intValue => sprintf('%d', $fm->{size}) } }
                if defined $fm->{size};

            if ($c->{meta_change}) {
                push @attrs,
                    { key => 'config_change.meta_summary', value => { stringValue => $c->{meta_change} } };
            }

            if ($self->{emit_recipients} && @{ $c->{recipients} // [] }) {
                push @attrs, {
                    key   => 'config_change.notified',
                    value => { arrayValue => { values => [
                        map { { stringValue => $_ } } @{ $c->{recipients} }
                    ] } },
                };
            }

            if ($self->{full_diff}) {
                unless ($c->{is_sensitive} && !$self->_sensitive_notify_allowed) {
                    push @attrs, {
                        key   => 'config_change.diff',
                        value => { stringValue => join("\n", @{ $c->{diff} // [] }) },
                    };
                }
            }

            push @log_records, {
                timeUnixNano         => $ts_nano,
                observedTimeUnixNano => $ts_nano,
                severityNumber       => 9,
                severityText         => 'INFO',
                body                 => { stringValue => $body_msg },
                attributes           => \@attrs,
            };
        }
```

- [ ] **Step 4: Rewrite the warning-record loop (lines 168-180)**

Replace the `for my $w (@{ $report->warnings }) { ... }` block with:

```perl
        for my $w (@{ $report->warnings }) {
            push @log_records, {
                timeUnixNano         => $ts_nano,
                observedTimeUnixNano => $ts_nano,
                severityNumber       => 13,
                severityText         => 'WARN',
                body                 => { stringValue => $w },
                attributes           => [
                    { key => 'event.name', value => { stringValue => 'changetrack.run.warning' } },
                    @common_attrs,
                ],
            };
        }
```

- [ ] **Step 5: Run the renamed tests to verify they pass**

Run: `prove -lv t/19-notify-otlp.t`
Expected: PASS (the assertions rewritten in Task 3 now match).

- [ ] **Step 6: Add tests for `file.*`, `config_change.type` enum, and opt-in recipients**

Add `make_report` support for recipients and metadata by extending the existing helper. After the existing `with_change` block in `make_report` (line 153), the simplest path is a dedicated report inline in the new test rather than touching the shared helper. Append before `done_testing()`:

```perl
########################################################################
# file.* Attributes And config_change.type Enum
########################################################################
{
    my $body_file = File::Spec->catfile($tmpdir, 'filemeta.json');
    my ($port, $pid) = start_server(codes => [200], body_file => $body_file);

    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};
    my $n = ChangeTrack::Notify::OTLP->new(
        endpoint => "http://127.0.0.1:$port/v1/logs",
    );

    my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
    $r->add_change(
        path   => '/etc/hosts',
        is_new => 1,
        diff   => ['(new file)'],
        stat   => { mode => '0644', user => 'root', group => 'root',
                    size => 42, mtime => 1_700_000_000, type => 'file' },
    );
    $r->set_end_time(1_000_000_002);
    $n->send($r);
    waitpid($pid, 0);

    my $p   = read_payload($body_file);
    my $rec = $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0];
    my %a   = map { $_->{key} => $_->{value} } @{ $rec->{attributes} };

    is($a{'config_change.type'}{stringValue}, 'created', 'new file => config_change.type=created');
    is($a{'event.name'}{stringValue}, 'changetrack.file.created', 'new file event.name');
    is($a{'file.name'}{stringValue}, 'hosts',     'file.name is basename');
    is($a{'file.directory'}{stringValue}, '/etc', 'file.directory is dirname');
    is($a{'file.mode'}{stringValue}, '0644',      'file.mode propagated');
    is($a{'file.owner.name'}{stringValue}, 'root','file.owner.name propagated');
    is($a{'file.group.name'}{stringValue}, 'root','file.group.name propagated');
    is($a{'file.size'}{intValue}, '42',           'file.size propagated as string intValue');
}

########################################################################
# config_change.notified Is Opt-In (emit_recipients)
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};

    my $make = sub {
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/hosts', diff => [],
            recipients => ['ops@example.com', 'sa@example.com']);
        $r->set_end_time(1_000_000_002);
        return $r;
    };

    # default: recipients NOT emitted
    {
        my $bf = File::Spec->catfile($tmpdir, 'norecip.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        ChangeTrack::Notify::OTLP->new(endpoint => "http://127.0.0.1:$port/v1/logs")
            ->send($make->());
        waitpid($pid, 0);
        my $p = read_payload($bf);
        my %a = map { $_->{key} => $_->{value} }
                @{ $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0]{attributes} };
        ok(!exists $a{'config_change.notified'}, 'recipients omitted by default');
    }

    # emit_recipients=1: recipients emitted as arrayValue
    {
        my $bf = File::Spec->catfile($tmpdir, 'recip.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs", emit_recipients => 1)
            ->send($make->());
        waitpid($pid, 0);
        my $p = read_payload($bf);
        my %a = map { $_->{key} => $_->{value} }
                @{ $p->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0]{attributes} };
        ok(exists $a{'config_change.notified'}, 'recipients emitted when emit_recipients=1');
        my @vals = map { $_->{stringValue} } @{ $a{'config_change.notified'}{arrayValue}{values} };
        is_deeply(\@vals, ['ops@example.com', 'sa@example.com'], 'recipient list correct');
    }
}
```

- [ ] **Step 7: Run the full OTLP test file**

Run: `prove -lv t/19-notify-otlp.t`
Expected: PASS (all blocks).

- [ ] **Step 8: Commit**

```bash
git add lib/ChangeTrack/Notify/OTLP.pm t/19-notify-otlp.t
git commit -m "feat(otlp): emit OTel semantic-convention attributes, event.name, file.*, opt-in recipients"
```

---

## Self-Review

- **Spec coverage:** F2 (canonical names + `config_change.type` enum) — Tasks 3-4. F3 (`event.name`) — Tasks 3-4. F4 (`file.*` propagation) — Tasks 1-2 plumbing + Task 4 emission. F7 (opt-in recipients) — Task 4, default OFF. ✔
- **Placeholder scan:** Task 2 references existing `t/04-runner-rcs.t` helpers (`setup_tracked_dir`/`write_file`/`run_once`) by name — confirm exact helper names when implementing; the assertion block is concrete. No TBDs.
- **Type consistency:** `file_meta` keys (`mode/owner/group/size/mtime`) defined in Task 1 are exactly the keys read in Task 4 Step 3. `config_change.notified` uses `arrayValue.values[].stringValue`, asserted identically in Task 4 Step 6.
- **Constraint check:** No hashes, no actor fields. Sensitive-diff suppression preserved verbatim in Task 4 Step 3. Recipients default OFF (PII guardrail).

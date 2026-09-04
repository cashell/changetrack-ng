# changetrack-ng OTel Logging Conformance Analysis

**Date:** 2026-06-23
**Reference:** `Docs/Logging/logging-reference.md` (the "reference")
**Subjects:** `lib/ChangeTrack/Notify/OTLP.pm`, `lib/ChangeTrack/Notify/File.pm`, and the data they receive from `Report.pm` / `Runner.pm` / `Metadata.pm`
**Authority basis:** The reference is treated as *peer input plus engineering judgment* — not gospel. Where changetrack-ng deviates, this doc states whether the deviation is a defect to fix or a defensible design choice to keep.

---

## 1. Scope, method, and what this tool is

changetrack-ng is a **SysAdmin configuration-change tracking tool**. It is **not** a security monitoring tool, not a HIDS, and is not designed for security detection. It may incidentally be *useful* during a security event or for recovery, but that is not its purpose. This distinction matters because the reference's worked example (§4.1) is framed around a tool with a **security focus** — and several of its illustrative fields (content hashes, actor attribution, detection provenance) exist to serve *that* framing, not ours.

Consequently, the reference's §4.1 field list is treated here as **illustrative, not a checklist**. A field is adopted only when it is **both easy and beneficial** for a config-change tracker. Fields that exist for the reference's security framing, or that would require disproportionate effort, are deliberately not adopted.

changetrack-ng has two structured-output paths:

- **OTLP notifier** — direct OTLP/HTTP+JSON POST to a collector. A *desired feature* for deploying changetrack-ng as a **system component** where collector/agent coverage is thin. Evaluated here on payload **field/format** conformance only; the direct-push architecture is intentional and not critiqued.
- **File notifier** — appends structured JSON to a local log file. This is the on-host emission path and the direct analog to the reference's "emit structured JSON to a log file" standard (§3). changetrack-ng runs as a system component, not a container, so the reference's *stdout-specifically* guidance does not apply — but its **format** guidance (one event per line, OTel Logs data model, semantic-convention names) applies to whatever sink is used.

The OTel output has **not yet been deployed publicly** for any consumer. Format changes are therefore **not breaking** for anything that exists — there is no compatibility burden and no deprecation window required.

---

## 2. Summary verdict

| Path | Verdict |
|------|---------|
| **OTLP notifier** | **Structurally OTel-correct.** Proper `resourceLogs` / `scopeLogs` / `logRecords` envelope, one log record per changed file, `body` present, `severityText`/`severityNumber` present, resource attributes set once per batch. Gaps are **naming and semantic-convention** issues (terse `ct.*` keys, no `event.name`), not shape. |
| **File notifier** | **Not the OTel Logs data model at all.** Emits **one JSON object per run** containing a `files[]` array — the reference is emphatic about **one self-contained object per event**. No `severity_text`/`severity_number`, no `body`, no `resource`/`attributes` split; field names (`tool`, `hostname`, `path`, `is_new`) match neither semantic conventions nor the OTLP notifier's own names. This is the path the reference's emission standard most directly targets, and it is the least conformant. |

**Headline:** the system-component emission path (File notifier) is where the real gap is. The OTLP notifier needs naming alignment; the File notifier needs a structural reshape.

---

## 3. Field-by-field comparison against reference §4.1

Reference §4.1 target event: `config_tracker.file.changed`, severity-mapped, with a `resource` (source identity) / `attributes` (per-event detail) split, semantic-convention `file.*` keys, and a `config_change.*` domain namespace. Remember §4.1 is illustrative — the right-most column records the easy-and-beneficial judgment.

| Reference §4.1 field | OTLP notifier (today) | File notifier (today) | Adopt? |
|---|---|---|---|
| `event.name` | ❌ absent | ❌ absent | **Yes** — easy, aids routing |
| `severity_text` / `severity_number` | ✅ INFO / 9 | ❌ absent | **Yes** (File) |
| `body` (human summary) | ✅ present | ❌ absent | **Yes** (File) |
| `resource{service.*, host.*, os.*}` | ✅ present | ❌ flat `tool`/`version`/`hostname` | **Yes** (File) |
| `deployment.environment.name` | ⚠️ only if operator sets `resource_attributes` | ❌ | Operator-supplied; no default invented |
| `config_change.type` (modified/new/removed) | ⚠️ `ct.is_new`/`ct.is_removed` booleans | ⚠️ same booleans | **Yes** — single enum is clearer |
| `file.path` / `file.name` / `file.directory` | ❌ `ct.path` only | ❌ `path` only | **Yes** — easy, portable |
| `file.owner.name` / `file.mode` / `file.size` | ❌ | ❌ | **Yes** — captured, operationally useful |
| `file.mtime` (occurred time) | ❌ | ❌ | **Yes** — as the occurred timestamp (§F5) |
| `config_change.hash.before` / `.after` | ❌ | ❌ | **No** — security-framing field; tool is VCS-backed |
| `config_change.actor` / `detected_by` | ❌ | ❌ | **No** — tool does not audit *who*; not its purpose |
| `config_change.diff` (+ truncation marker) | ⚠️ `ct.diff`, no size cap | ⚠️ `diff`, no size cap | **Yes** — with configurable cap (§F6) |
| `config_change.notified` (recipients) | ❌ | ❌ | **Yes, behind a config flag** (§F7) |
| occurred vs observed timestamps | ⚠️ both = run start, whole-second | ⚠️ single RFC3339 second-precision | **Yes** — mtime + scan time (§F5) |

---

## 4. Detailed current state

### 4.1 OTLP notifier (`Notify/OTLP.pm`)

`_build_payload` constructs a correct OTLP/HTTP+JSON document. Per changed file it emits a log record with:

- `severityNumber => 9, severityText => 'INFO'` for changes; `13`/`WARN` for warnings; `9`/`INFO` for heartbeat.
- `timeUnixNano` and `observedTimeUnixNano` both set to `sprintf('%d000000000', $report->{start_time} // time())` — i.e. **whole-second** precision, and occurred == observed.
- `body.stringValue` = a human-readable summary.
- Attributes under a terse **`ct.*`** namespace: `ct.path`, `ct.is_new`, `ct.is_removed`, `ct.is_sensitive`, `ct.heartbeat`, `ct.files_tracked`, `ct.run_duration_ms`, `ct.meta_change`, `ct.diff`.
- **No `event.name`.**
- `_resource_attrs` emits `service.name`, `service.version`, `service.instance.id` (= hostname), `host.name` (= hostname), `host.id` (= `/etc/machine-id`), `os.type` (= `$^O`). Operator-supplied `resource_attributes` are merged in. **No `deployment.environment.name`** unless the operator adds it.
- `full_diff` ships the entire diff inline with **no truncation**.

Mechanics (gzip, 3-attempt retry, env-var endpoint precedence, `insecure` TLS bypass) are sound and not in scope here.

### 4.2 File notifier (`Notify/File.pm`)

Appends **one JSON object per run**:

```
{ tool, version, hostname, timestamp, heartbeat, files_tracked,
  files: [ { path, is_new, is_removed, is_sensitive,
             metadata_changed, meta_change, diff } ],
  run_duration_ms }
```

- `timestamp` is RFC3339 UTC at **second precision** (`strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(...))`).
- There is **no severity, no body, no resource/attributes split, no event.name**. It is a bespoke flat schema.
- A consumer cannot treat a single line as a single change event; they must parse the run wrapper and iterate `files[]`. This breaks the per-event query model that §3 exists to provide.

### 4.3 Source data (what is cheaply available)

- `Metadata.pm` already captures `mode` (`%04o`), `uid`/`gid`, resolved owner/group **names**, `mtime`, and `size` for regular files. So `file.mode`, `file.owner.name`, `file.size`, and `file.mtime` are **available at no new cost** — they simply are not propagated through `Report.pm`/`Runner.pm` to the notifiers.
- The change record (`Report::add_change`) already carries `recipients`, but neither notifier emits it.
- Content **hashes** are *not* computed, and should not be. The tool is VCS-backed: it stores file content/diffs in RCS/git. The reference's `hash.*` fields exist to serve its security framing (tamper evidence); for a config-change tracker they would be redundant compute against data the VCS already holds.

---

## 5. Findings, judgment, and disposition

Each finding states whether the reference recommendation makes sense **for this SysAdmin config tool** and whether changetrack-ng should change or hold.

### Recommend change → full implementation plan to be produced

**F1 — File notifier should adopt the OTel Logs data model (one event per line).**
*Makes sense: yes.* Per-event NDJSON with severity/body/resource/attributes is the point of the emission standard, and the File notifier is the system-component path that standard targets. The current per-run wrapper is the single largest conformance gap. **Change.**

**F2 — Adopt semantic-convention attribute names + `config_change.*` domain namespace (replace `ct.*`).**
*Makes sense: yes.* `ct.*` is private and non-portable; `file.path`/`file.name`/`file.directory` and a `config_change.*` namespace are what any OTel-aware backend expects. `config_change.*` is squarely on-domain for a config-change tracker (not security-specific). `config_change.type` becomes a single enum (`modified`/`new`/`removed`) replacing the `is_new`/`is_removed` boolean pair. Since nothing consumes the output yet, `ct.*` is simply replaced — no deprecation needed. **Change.**

**F3 — Add `event.name` under the `changetrack.*` prefix.**
*Makes sense: yes.* `event.name` lets backends route and count event classes. Names: `changetrack.file.changed`, `changetrack.file.removed`, `changetrack.run.heartbeat` (new vs modified is carried by `config_change.type`). Trivially derivable. **Change.**

**F4 — Propagate and emit captured stat fields as `file.*`.**
*Makes sense: yes.* `file.mode`, `file.owner.name`, `file.size` are already captured by `Metadata.pm`; plumbing them to the notifiers turns an operationally meaningful change (a config file's permissions or ownership changing) into queryable structured fields instead of a free-text `meta_change` string. Low effort, clear benefit. **Change.**

**F5 — Split occurred vs observed time, at nanosecond precision.**
*Makes sense: yes.* `file.mtime` is the true *occurred* time; scan time is *observed*. Today both are the run start at whole-second precision. Use mtime for `timeUnixNano` (occurred) and scan time for `observedTimeUnixNano` (observed), at nanosecond precision. The data is already captured. **Change.**

**F6 — Configurable per-file diff size cap (`max_diff_bytes`) with truncation marker.**
*Makes sense: yes, made configurable.* The reference warns against shipping huge diffs inline. Full diffs remain the **default** (`full_diff` keeps its current on/off meaning). A new `max_diff_bytes` option (default **0 = unlimited**) caps the included diff; when a diff exceeds the cap it is truncated and `config_change.diff_truncated` is set true. Per-file, byte-granular. **Change.**

**F7 — Emit recipients as `config_change.notified`, behind a config flag.**
*Makes sense: yes, optional.* The data is already on the change record; emitting it makes "which notifications fired" auditable. A config option enables/disables the field so operators who don't want it can omit it. **Change.**

**F8 — Severity discrimination between change events and heartbeats (configurable).**
*Reference's WARN-for-changes is from §4.1/§4.2 **examples**, not a stated rule.* §3.2 only maps severity text↔number. changetrack-ng cannot assess a change's significance, so uniform INFO is defensible **except** that changes and heartbeats both emit at INFO — severity then fails to distinguish an actual config change from a routine liveness heartbeat in dashboards/alerting. Make change events emit one notch above heartbeats (configurable), rather than forcing WARN unconditionally. **Change (judgment-driven, configurable).**

### Defensible deviation → keep, with rationale (no plan)

**K1 — Direct OTLP push instead of stdout→collector.** Intentional: supports system-component deployment where collector coverage is thin. The reference's stdout-specific guidance is container-oriented and does not apply. **Keep.**

**K2 — No content hashes.** The tool is a VCS-backed config tracker, not a security/tamper-evidence tool; it already stores full content/diffs. Hashes would be redundant compute serving a security framing that is not changetrack-ng's purpose. **Keep** (documented).

**K3 — No actor / detection-provenance fields.** The reference's `config_change.actor` / `detected_by` serve security attribution. changetrack-ng detects *that* a file changed, not *who* changed it, and is not an audit/attribution tool. **Keep** (documented).

---

## 6. Compatibility posture

The OTel/file output has no public consumers yet, so renaming attributes (`ct.*` → semantic-convention + `config_change.*`) and reshaping the File notifier are **not breaking changes**. No deprecation window, no dual-emit, no config gate for the naming. A `CHANGELOG.md` entry should still record the new output schema for users following development, but it need not be flagged as a breaking change. The only **configurable** behaviors introduced are `max_diff_bytes` (F6), the `config_change.notified` enable/disable flag (F7), and the severity-discrimination setting (F8).

---

## 7. Implementation plans

The seven recommended changes are delivered as **five** dependency-ordered plans (tightly-coupled findings are grouped to avoid conflicting edits to the same files):

| Plan file | Covers | Depends on |
|---|---|---|
| `plans/2026-06-23-otel-attribute-model.md` | F2, F3, F4, F7 — data plumbing + semantic-convention naming + `event.name` + optional recipients, in both notifiers | — |
| `plans/2026-06-23-file-notifier-otel-reshape.md` | F1 — File notifier → per-event OTel/NDJSON | attribute-model |
| `plans/2026-06-23-otel-timestamps.md` | F5 — occurred (mtime) vs observed (scan), nanosecond | attribute-model |
| `plans/2026-06-23-otel-diff-truncation.md` | F6 — configurable `max_diff_bytes` + truncation marker | — |
| `plans/2026-06-23-otel-severity-discrimination.md` | F8 — configurable change-vs-heartbeat severity | — |

K1, K2, and K3 produce no plan by design.

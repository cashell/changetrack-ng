# changetrack-ng — Architecture and Design

**Homepage:** <https://github.com/cashell/changetrack-ng>

Date: 2026-06-25
Version: 0.7.0

---

## 1. Overview

`changetrack-ng` is a modular Perl 5.20+ system file change tracker that monitors arbitrary files and directories, records their history in a pluggable VCS (Git, RCS, Fossil, SVN, Mercurial), and dispatches optional notifications (email, webhook, OTLP, JSON file log). It is a complete rewrite of the original `changetrack` (last maintained 2009), combining its per-file flexibility with `etckeeper`-style metadata tracking, ignore patterns, and multi-VCS support.

### 1.1 Design principles

| Principle | Implementation |
|-----------|---------------|
| Zero non-core dependencies | Only Perl core modules (`HTTP::Tiny`, `JSON::PP`, `IO::Compress::Gzip` — all core ≥5.14) |
| Pluggable architecture | VCS and Notifier backends implement abstract Base interfaces |
| Cron/timer friendly | `flock`-based locking; silent skip if already running |
| Fail-safe per-file | Per-file errors warn and continue; VCS-level errors abort |
| Security-aware | Sensitive file auto-detection; diff suppression; list-form command execution |
| Operator-visible | Structured report output; configurable heartbeats for monitoring |

### 1.2 Target environments

- Linux systems (primary: Debian/Ubuntu, RHEL/Fedora, Arch, openSUSE)
- Perl 5.20+ (uses `say`, `state`, `JSON::PP`, `HTTP::Tiny` from core)
- Scheduled invocation via systemd timer or cron
- Package-manager hooks for pre/post-transaction snapshots (apt, pacman, dnf)

---

## 2. Component architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         bin/changetrack-ng                                    │
│  (CLI entry point: option parsing, subcommand dispatch, exit codes)           │
└──────────────────────────┬───────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                       ChangeTrack::Runner                                     │
│  (Orchestration: config → lock → file list → per-file process → notify)      │
├──────────────────────────────────────────────────────────────────────────────┤
│  Depends on: Config, Lock, Metadata, Report, Util, VCS::*, Notify::*         │
└─────┬──────────┬──────────┬───────────┬───────────┬──────────┬──────────────┘
      │          │          │           │           │          │
      ▼          ▼          ▼           ▼           ▼          ▼
┌─────────┐┌─────────┐┌──────────┐┌─────────┐┌─────────┐┌──────────────────┐
│ Config  ││  Lock   ││ Metadata ││ Report  ││  Util   ││ VCS::Base        │
│         ││         ││          ││         ││         ││  ├── Git          │
│ INI v2  ││ flock   ││ JSONL    ││ Change  ││ run_cmd ││  ├── RCS          │
│ parser  ││ pidfile ││ sidecar  ││ accum-  ││ host-   ││  ├── Fossil       │
│ + drop- ││         ││          ││ ulator  ││ name    ││  ├── SVN          │
│ ins     ││         ││          ││         ││ mirror  ││  └── Mercurial    │
└─────────┘└─────────┘└──────────┘└─────────┘└─────────┘└──────────────────┘
                                                          ┌──────────────────┐
                                                          │ Notify::Base     │
                                                          │  ├── Email       │
                                                          │  ├── Webhook     │
                                                          │  ├── OTLP        │
                                                          │  └── File        │
                                                          └──────────────────┘
```

### 2.1 Module responsibilities

| Module | Responsibility |
|--------|---------------|
| `bin/changetrack-ng` | CLI dispatch, option parsing (`Getopt::Long`), subcommand routing |
| `ChangeTrack::Runner` | Main orchestration: config load → lock → build file list → per-file stat+diff → Report accumulation → VCS commit → notification dispatch |
| `ChangeTrack::Config` | INI v2 parser with strict key whitelist (unknown keys fatal) and per-type value coercion/validation; `conf.d`/`track.d`/`notifier.d` drop-in dirs and `@include*` directives; `HOSTNAME` token + `${VAR}` env interpolation (undefined env var is fatal) |
| `ChangeTrack::Lock` | `flock(2)`-based pidfile with timeout/force modes; non-blocking skip for cron safety |
| `ChangeTrack::Metadata` | JSONL sidecar (`.changetrack-metadata`): per-file stat snapshots with unified type classification; immutable-on-load snapshot for change detection; `can_skip_content_diff` fast path; atomic save (tmpfile + rename) |
| `ChangeTrack::Report` | Accumulates changes/warnings during a run; provides `to_text()` and structured data for notifiers |
| `ChangeTrack::Util` | `hostname()`/`fqdn()`, `run_cmd()` (IPC::Open3 list-form, IO::Select drain, no shell, **hardcoded 30s timeout**), `sync_mirror_path()`, `restore_mirror_path()`, `set_debug()` |
| `ChangeTrack::Version` | Single-source version authority (`$VERSION = '0.7.0'`) |
| `ChangeTrack::VCS::Base` | Abstract interface: `init`, `is_initialized`, `output_path`, `add`, `checkin`, `commit`, `diff`, `log_history`, `revert`, `is_dirty`, `model` |
| `ChangeTrack::VCS::Git` | Whole-repo mirror model; `git -C`; batch commit; optional `push_remote` |
| `ChangeTrack::VCS::RCS` | Per-file model; colon-encoded flat layout; immediate `ci -l` per file |
| `ChangeTrack::VCS::Fossil` | Whole-repo; `fossil init`/`open`; uses native `--chdir` flag (no Perl `chdir`); sets `FOSSIL_HOME` when `HOME` unset; optional `push_remote` |
| `ChangeTrack::VCS::SVN` | Whole-repo; `svnadmin create` + `svn checkout file://`; uses Perl `chdir` (saved/restored via `getcwd`); commit pushes to the local repo |
| `ChangeTrack::VCS::Mercurial` | Whole-repo; `hg -R` flag (no chdir); auto-creates `.hg/hgrc`; optional `push_remote` |
| `ChangeTrack::Notify::Base` | Abstract interface: `send()` dispatcher (eval-wrapped), heartbeat gating, sensitive-diff suppression |
| `ChangeTrack::Notify::Email` | Pipes RFC 2822 messages to sendmail; per-recipient grouping; heartbeat always off |
| `ChangeTrack::Notify::Webhook` | HTTP POST JSON to one or more URLs via `HTTP::Tiny`; 3-attempt retry; TLS bypass option |
| `ChangeTrack::Notify::OTLP` | OTLP/HTTP+JSON log records; gzip compression; env-var endpoint/header precedence; heartbeat default ON |
| `ChangeTrack::Notify::File` | Append-only JSONL log with flock; optional heartbeat |

---

## 3. Data flow

### 3.1 Primary `run` cycle

```
 Config.load()          →  Parse INI, validate keys, return Config object
                             │
 Lock.acquire()         →  flock(LOCK_EX|LOCK_NB) or timeout loop
                             │
 _build_file_list()     →  Expand [track] entries (files + recursive dirs)
                         →  Apply ignore patterns (each glob precompiled to its own qr//, tested in turn)
                             │
 ┌─ For each tracked path ───────────────────────────────────────────────────┐
 │  1. Missing from disk? → report removed, done                              │
 │  2. Fast path: can_skip_content_diff + !changed_since_load → skip entirely │
 │  3. update_from_stat → classify type (file/symlink/binary/empty/etc.)      │
 │  4. Dispatch on type:                                                       │
 │     • special/unreadable/binary → warn on first detection, skip content    │
 │     • empty → track metadata changes only                                  │
 │     • symlink → target comparison via metadata (no file I/O)               │
 │     • file → VCS diff (copy to mirror, compare against last commit)        │
 │  5. If new: VCS checkin+add, create metadata entry, add to Report          │
 │  6. If changed: VCS checkin, update metadata, add to Report                │
 └────────────────────────────────────────────────────────────────────────────┘
                             │
 Metadata.save()        →  Atomic tmpfile + rename
                             │
 VCS.commit()           →  Whole-repo: batch commit (Git/Fossil/SVN/Hg)
                         →  Per-file: no-op (RCS commits inline)
                             │
 Notify dispatch        →  For each enabled notifier:
                              • has_changes → send_changes(report)
                              • !has_changes && heartbeat → send_heartbeat(report)
```

### 3.2 Mirror tree model (whole-repo VCS)

All whole-repo backends (Git, Fossil, SVN, Mercurial) use a mirror tree:
- `/etc/passwd` is copied to `$output_dir/etc/passwd`
- Symlinks are serialized as a text file containing `__CHANGTRACK_NG_SYMLINK_TARGET__=<target>`
- The mirror tree is the VCS working copy; diffs are computed by comparing the copy against HEAD/tip
- Revert restores mirror → real file (or recreates symlink)

### 3.3 Flat layout model (RCS)

- `/etc/passwd` maps to `$output_dir/etc:passwd`
- RCS archive is at `$output_dir/RCS/etc:passwd,v`
- `ci -l` is invoked per-file immediately (no batch commit)

### 3.4 Metadata sidecar format

JSONL file (one JSON object per line), sorted by path on write:
```json
{"path":"/etc/passwd","mode":"0644","uid":0,"gid":0,"user":"root","group":"root","type":"file","mtime":1714300000,"size":2345}
{"path":"/etc/shadow","mode":"0640","uid":0,"gid":42,"user":"root","group":"shadow","type":"unreadable","mtime":1714300000,"size":1024}
{"path":"/etc/localtime","mode":"0644","uid":0,"gid":0,"user":"root","group":"root","type":"symlink","target":"/usr/share/zoneinfo/America/Chicago"}
{"path":"/etc/selinux/default/modules/active/policy.kern","mode":"0644","uid":0,"gid":0,"user":"root","group":"root","type":"binary","mtime":1714300000,"size":98304}
```

The `type` field is the single source of truth for file classification:

| Type | Meaning | Tracked content |
|------|---------|-----------------|
| `file` | Regular text file | Full VCS diff |
| `symlink` | Symbolic link | Target path (via `readlink`) |
| `binary` | Regular file with binary content | Metadata only |
| `empty` | Regular file, 0 bytes | Metadata only |
| `unreadable` | Regular file, no read permission | Metadata only |
| `special` | FIFO, socket, device node | Metadata only |
| `directory` | Directory (defensive) | Metadata only |
| `missing` | Previously tracked, now gone | N/A |

Change detection compares live `lstat()` against the immutable "original" snapshot loaded at run start.
The fast path (`can_skip_content_diff`) skips all further processing when mtime+size are unchanged
(for regular file types) or symlink target is unchanged — no file I/O or VCS calls needed.

---

## 4. Configuration system

### 4.1 Format

INI format with three section types: `[global]` (key=value settings), `[notifier:<type>:<name>]` (one notification instance per section), and `[track]` (file/directory entries).

- Recognized `[global]` keys (whitelist, `Config.pm`): `vcs`, `output_dir`, `push_remote`, `ignore`, `sensitive_auto`, `sensitive_notify`, `warn_special_files`, `interval`, `lock_path`, `lock_timeout`
- Array-valued `[global]` keys (`ignore`, `push_remote`) are split on whitespace → arrayrefs; all other `[global]` keys return scalar strings
- Values are type-coerced/validated by class: booleans (`sensitive_auto`, `warn_special_files`), integers (`lock_timeout`, `interval`), paths (`output_dir`, `lock_path`), enums (`vcs` ∈ {rcs,git,fossil,svn,hg,mercurial}; `sensitive_notify` ∈ {suppress,allow})
- **Dead key:** `interval` is whitelisted and integer-validated (`Config.pm`) but never read anywhere in the codebase — it is accepted silently and has no effect. Scheduling is driven entirely by the systemd timer / cron entry, not this key.
- `[notifier:*]` keys are per-instance scalars validated against a per-type whitelist (`email`/`webhook`/`file`/`otlp`); the `enabled` key is required in every notifier section; `email.to` and `webhook.url` are array-valued
- `HOSTNAME` in values is replaced with the system FQDN at parse time; `${VAR}` performs environment-variable expansion (an undefined variable is a fatal error)
- Strict key validation: unknown keys cause a fatal parse error (fail-fast)
- Multi-file loading: `conf.d/`, `track.d/`, `notifier.d/` drop-in directories and `@include`/`@include-track`/`@include-notifier` directives compose at load time (recursion-guarded against include cycles); duplicate notifier `<type>:<name>` pairs across any files are a fatal error

### 4.2 Precedence (OTLP-specific)

For OTLP endpoint and headers, environment variables take precedence over config:
```
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT > OTEL_EXPORTER_OTLP_ENDPOINT > config endpoint
OTEL_EXPORTER_OTLP_HEADERS > config headers
```

---

## 5. VCS backend contract

| Method | Per-file (RCS) | Whole-repo (Git/Fossil/SVN/Hg) |
|--------|---------------|-------------------------------|
| `init` | Creates output_dir + RCS/ | Creates repo (git init / fossil init+open / svnadmin+co / hg init) |
| `output_path($path)` | Colon-encoded flat path | Mirror-tree path under output_dir |
| `checkin($path, $msg)` | Copy + `ci -l` immediately | Copy + stage (add); commit deferred |
| `add($path)` | No-op | Copy to mirror + VCS add |
| `commit($msg)` | No-op | Batch commit all staged; optional `push_remote` (Git, Fossil, Hg) |
| `diff($path)` | `rcsdiff -u` on mirror | Copy to mirror, diff against HEAD/tip |
| `revert($path,$rev)` | `co -r` from RCS archive | Restore file/symlink from a revision |
| `log_history($path)` | `rlog` | Native VCS log |
| `is_dirty` | `rcsdiff -q` vs latest revision (true if no `,v` archive yet) | True if working copy has staged/uncommitted changes |
| `model` | `'per-file'` | `'whole-repo'` |

---

## 6. Notification system

### 6.1 Dispatch model

Notifiers are instantiated per-run with all config values passed as constructor arguments. The `Base::send()` method wraps dispatch in eval, ensuring notifier failures never abort the run.

### 6.2 Heartbeat model

Each notifier independently implements heartbeat gating:
- **Email**: always OFF (anti-spam)
- **Webhook**: OFF by default; opt-in via `heartbeat = 1` in the `[notifier:webhook:*]` section
- **OTLP**: ON by default (monitoring use case: "alert on absence")
- **File**: OFF by default; opt-in via `heartbeat = 1` in the `[notifier:file:*]` section

Heartbeat is only sent when: no changes detected AND the run completed without errors.

### 6.3 Sensitive file handling

- Auto-detection: file is "sensitive" if `(mode & 0004) == 0` (no world-read); overridable per `[track]` entry
- Controlled by `sensitive_auto` (toggle detection) and `sensitive_notify` (`suppress`|`allow` diffs)
- Suppression behavior differs by notifier (it is not uniform):
  - **Email** — diff body replaced with a placeholder line (`[diff suppressed -- sensitive file ...]`)
  - **File** — `config_change.diff` field carries the placeholder string (and is never subject to `max_diff_bytes` truncation)
  - **OTLP** and **Webhook** — the diff key is omitted from the payload entirely (no placeholder)

### 6.4 Structured event model (File and OTLP)

The File and OTLP notifiers emit OpenTelemetry-style structured log records. Each tracked change becomes one record:

- `event.name`: one of `changetrack.file.changed`, `changetrack.file.created`, `changetrack.file.removed`, `changetrack.run.heartbeat`, `changetrack.run.warning`
- File attributes: `file.path`, `file.name`, `file.directory`, `file.mode`, `file.owner.name`, `file.group.name`, `file.size`
- Change attributes: `config_change.type`, `config_change.sensitive`, `config_change.meta_summary`, `config_change.diff`, `config_change.diff_truncated`, `config_change.notified`
- Run attributes: `changetrack.files_tracked`, `changetrack.run_duration_ms`
- OTLP resource attributes: `service.*`, `host.*`, `os.type`, plus machine-id

Severity is mapped from event class via `%SEVERITY` in `Notify::Base` (OTLP severity numbers): DEBUG→5, INFO→9, WARN→13, ERROR→17.

`max_diff_bytes` (File and OTLP) truncates oversized diffs and sets `config_change.diff_truncated = true`; suppressed-sensitive diffs are exempt from truncation (File) or omitted (OTLP). `emit_recipients` controls whether recipient metadata is included.

### 6.5 Webhook delivery

`Notify::Webhook` POSTs JSON via `HTTP::Tiny` to one or more URLs (`_parse_urls`), with 3 attempts and exponential backoff. The `insecure` key disables TLS verification (opt-in). The `full_diff` key controls whether complete diffs are sent; sensitive diffs are omitted entirely.

---

## 7. Security architecture

### 7.1 Command execution and exception safety

All external commands are executed via `ChangeTrack::Util::run_cmd()`:
- Uses `IPC::Open3` with list-form arguments (no shell interpolation)
- Captures stdout/stderr via `IO::Select` to avoid pipe deadlocks; the read timeout is **hardcoded at 30 seconds** (`Util.pm`, `can_read(30)`) — it is not configurable
- Returns structured result `{ success, stdout, stderr, exit_code }`
- No user-controlled data is ever interpolated into shell strings

VCS backend working-directory management differs by backend:
- **SVN** is the only backend that uses Perl `chdir`: it saves the cwd via `Cwd::getcwd`, runs the command, and restores the cwd (guarded so it is restored even on failure).
- **Fossil** uses its native `--chdir` flag (no Perl `chdir`); it also sets `FOSSIL_HOME` when `HOME` is unset.
- **Git** (`git -C`) and **Mercurial** (`hg -R`) use native repository-path flags, never changing the process cwd.

### 7.2 Trust boundaries

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ TRUSTED: config file (root-owned), runtime environment                       │
├─────────────────────────────────────────────────────────────────────────────┤
│ SEMI-TRUSTED: tracked filesystem content (may contain hostile data)          │
│ ─ file content enters VCS diffs/mirror copies but never parsed/executed      │
│ ─ filenames with special chars are safe (list-form exec, no interpolation)   │
├─────────────────────────────────────────────────────────────────────────────┤
│ EXTERNAL: notification endpoints (webhook URLs, OTLP collectors, SMTP)       │
│ ─ outbound-only; payloads constructed by code, not from raw file content     │
│ ─ TLS verification enabled by default; insecure mode requires explicit opt-in│
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.3 Privilege model

- Designed to run as root (to read all tracked files)
- Lock path adapts: root → `/var/run/`, non-root → `$XDG_CACHE_HOME/`
- Config file should be 0640 (contains potential webhook secrets / OTLP auth headers); the Runner warns at load time if the config file is group- or world-readable
- Mirror directory created mode 0700

### 7.4 Threat surface summary

| Surface | Risk | Mitigation |
|---------|------|------------|
| Config file | Secrets exposure (OTLP auth headers, webhook URLs) | Install as 0640; no logging of secret values |
| Tracked file content in diffs | Information disclosure via notifications | Sensitive auto-detection + suppress mode |
| External command execution | Command injection | List-form exec only; no shell |
| Notification delivery | Silent failure → false monitoring confidence | Retry logic; heartbeat signals; warn on failure |
| Symlink following | Unexpected file content capture | `lstat()` for metadata; `sync_mirror_path` handles symlinks explicitly |
| Lock file race | Double-execution | `flock(2)` is atomic; pidfile is advisory |

---

## 8. Operational architecture

### 8.1 Scheduling

| Mechanism | Files | Notes |
|-----------|-------|-------|
| systemd timer | `packaging/systemd/changetrack-ng.timer` + `.service` | Hourly, persistent (catches up on boot) |
| cron | `packaging/cron/changetrack-ng` | Placed in `/etc/cron.hourly/` |
| Package hooks | `packaging/hooks/apt-pre`, `apt-post`, `pacman-*.hook`, `packaging/hooks/dnf/changetrack_ng.py` | Pre/post transaction with `-m` annotation |

### 8.2 Installation layout

```
$PREFIX/bin/changetrack-ng           Main executable (shebang rewritten at install)
$PREFIX/lib/changetrack-ng/          Library modules (use lib path rewritten)
$SYSCONFDIR/changetrack-ng/          Config directory (0640)
/var/lib/changetrack-ng/             Default output_dir (VCS repo + mirror tree)
/var/lib/changetrack-ng/.changetrack-metadata    Metadata sidecar
/var/run/changetrack-ng.lock         Lock file (root)
/var/log/changetrack-ng.log          File notifier output
```

### 8.3 Subcommands

| Subcommand | Purpose |
|------------|---------|
| `run` (default) | Full scan-commit-notify cycle |
| `init` | Explicitly initialize VCS output directory |
| `status` | Show files with pending changes (exit 1 if changes) |
| `diff [path]` | Show unified diff for pending changes |
| `log [path]` | Show VCS history |
| `revert <path> <rev>` | Restore file to a specific revision |
| `update-ignore` | Sync VCS-native ignore file with configured patterns |

There is no `migrate-config` subcommand and no v1→v2 config migration tooling. (`Metadata::import_from_v1_statistics` exists only as a stub that `carp`s "not yet implemented".)

### 8.4 Global options and diagnostics

CLI options (`Getopt::Long`, parsed in `bin/changetrack-ng`): `-c`/`--config`, `--system`, `--user`, `-m`/`--message`, `--no-auto-init`, `-n`/`--dry-run`, `-q`/`--quiet`, `-v`/`--verbose`, `-d`/`--debug`, `-t`/`--trace`, `-f`/`--force`, `-V`/`--version`, `-h`/`--help`.

- Config resolution order: `-c` > `$CHANGETRACK_CONFIG` > `--user`/`--system` > default `/etc/changetrack-ng/changetrack-ng.conf`.
- Diagnostic tiers imply downward: `--trace` ⇒ `--debug` ⇒ `--verbose`. All diagnostics go to STDERR; STDOUT stays clean.
- A `run`/`status`/`diff` against an uninitialized output dir auto-initializes the VCS unless `--no-auto-init` is given.
- `-m`/`--message` supplies the commit annotation; the apt/dnf/pacman hooks pass a `-m` describing the package transaction so pre/post snapshots are labeled.
- All write operations are skipped under `--dry-run`.

### 8.5 Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success (or no changes for `run`) |
| 1 | Changes detected (`status`); or an operational failure / aborted action |
| 2 | Runtime exception |
| 64 | Usage or config error (bad args, unknown subcommand, invalid config) |

---

## 9. Build and test system

### 9.1 Makefile

- `make test` — runs `prove -l t/`
- `make install` — PREFIX-aware install with shebang/use-lib rewriting
- `make install-hooks` — auto-detects package manager, installs hooks with `@BINDIR@` templating
- `make install-systemd` / `make install-cron` — install scheduler units with `@BINDIR@` templating
- `make install-user` (+ `-systemd`/`-cron`/`-uninstall`) — per-user (non-root) install variants
- `make dist` / `dist-minimal` / `dist-deploy` — release tarballs; the file lists are read from `MANIFEST.toml` via `tools/manifest-query --dist <target>` (no longer hardcoded in the Makefile)
- `make manifest-lint` / `make manifest-extra` — validate that listed files exist / find on-disk files missing from the manifest
- `make fatpack` — single-file standalone (via App::FatPacker)
- `make man` — render man pages

### 9.4 Manifest subsystem

`MANIFEST.toml` is the authoritative inventory of distributable files, organized by category (deps, lib, tests, configs, examples, man, docs, packaging, build, legal) with per-file `dist` membership tags and `tested_by` cross-references. `tools/manifest-query` (uses `TOML::Tiny`) reads it to drive the `dist*` targets and the `manifest-lint`/`manifest-extra` checks; it is covered by `t/28-manifest-query.t` against `t/fixtures/manifest-test.toml`. `DEFAULTSDIR` in the Makefile auto-detects `/etc/sysconfig` (dnf systems) vs `/etc/default`.

### 9.2 Test strategy

- Framework: `Test::More` (core), `prove`
- Test isolation: each test creates a temp dir via `File::Temp`; cleanup on exit
- VCS-dependent tests skip (`plan skip_all`) if the binary is not available
- Mock sendmail (`t/lib/ChangeTrack/Test/MockSendmail.pm`) for email tests
- No external network calls in tests

### 9.3 Version management

- Single source: `lib/ChangeTrack/Version.pm` (`our $VERSION = '0.7.0'`)
- All modules: `do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION }`
- Makefile `VERSION` variable must be kept in sync
- RPM spec `Version:` and `%changelog` updated manually

---

## 10. Known architectural limitations

### 10.1 Config-to-notifier data shape mismatch

`Config.pm` returns array-valued keys as arrayrefs, while some notifier constructors were originally designed for scalar strings. The `Webhook` notifier now handles both (via `_parse_urls`), and `OTLP` handles arrayrefs through `_parse_kv_config_value`. However, the contract is implicit rather than enforced by types.

### 10.2 Symlink semantics are mixed

Metadata tracks symlink targets via `readlink()`, while `sync_mirror_path()` writes a serialized snapshot file. This means the VCS stores the link target as a text file, not as a native VCS symlink. The behavior is consistent but the dual representation (metadata JSON vs. mirror snapshot) could confuse operators.

### 10.3 Config key drift potential

The `%KNOWN_GLOBAL_KEYS` whitelist enforces valid keys at parse time, which is strong. However, it also accepts the `interval` key, which is type-validated as an integer but **never read by any code** — a dead key that silently does nothing (scheduling is external, via the systemd timer or cron). The relationship between `sensitive_auto` and the notifier-level `sensitive_notify` is also indirect rather than enforced.

### 10.4 Config validation scope

Global values are now type-checked at parse time via `Config::_validate_global_values()` (booleans, integers, enums, notifier names). Invalid values produce immediate, actionable error messages. Per-track values and cross-field semantic constraints (e.g., mutually exclusive options) are not validated.

---

## 11. Packaging

| Target | Files |
|--------|-------|
| Debian | `packaging/debian/control`, `packaging/debian/rules`, `packaging/debian/changelog`, `packaging/debian/source/format` |
| RPM | `packaging/rpm/changetrack-ng.spec` |
| Tarball | `make dist` |
| Standalone | `make fatpack` |
| systemd | `packaging/systemd/changetrack-ng.{service,timer}` (templated at install) |
| Cron | `packaging/cron/changetrack-ng` |

---

## 12. Dependency inventory

All runtime dependencies are Perl core (≥5.14):

| Module | Purpose | Core since |
|--------|---------|------------|
| `JSON::PP` | JSONL metadata, webhook/OTLP payloads | 5.14 |
| `HTTP::Tiny` | Webhook/OTLP HTTP POST | 5.14 |
| `IO::Compress::Gzip` | OTLP body compression | 5.10 |
| `IPC::Open3` | External command execution | 5.0 |
| `IO::Select` | Non-blocking pipe reads | 5.0 |
| `Fcntl` | flock constants | 5.0 |
| `File::Find` | Directory traversal | 5.0 |
| `File::Copy` | Mirror file operations | 5.0 |
| `File::Path` | `make_path` for mirror dirs | 5.0 |
| `File::Temp` | Test isolation | 5.6 |
| `POSIX` | `strftime`, timestamps | 5.0 |
| `Getopt::Long` | CLI parsing | 5.0 |
| `FindBin` | Locate lib/ relative to bin/ | 5.0 |
| `Sys::Hostname` | Short hostname (`Util::hostname`) | 5.0 |
| `Net::Domain` | FQDN fallback (`Util::fqdn`) | 5.7 |
| `Cwd` | Save/restore cwd in SVN backend (`getcwd`) | 5.0 |

Build-time tooling (`tools/manifest-query`) additionally uses `TOML::Tiny`, which is **not** a Perl core module. It is required only for the manifest-driven `dist*`/`manifest-*` Makefile targets, never at runtime, so the zero-non-core-runtime-dependency guarantee holds.
# Changelog

All notable changes will be documented here.

**Project homepage:** <https://github.com/cashell/changetrack-ng>

## [Unreleased]

### Documentation

- Clarify automatic drop-in directories and explicit `@include*` support for
  custom drop-in files/directories in the README and sample configs.

## [0.7.0] - 2026-06-29

Security hardening release. Consolidated from a multi-tool security review
(`SECURITY-REVIEW.md`); see `SECURITY-PLAN.md` and `SECURITY-IMPL-LOG.md` for the
phased implementation and per-finding status.

### Security

- **TLS verification is now explicit** on the webhook and OTLP notifiers
  (`verify_SSL => 1` on the secure path). Previously verification relied on the
  `HTTP::Tiny` default, which is unverified on the Perl 5.20 floor
  (`HTTP::Tiny` < 0.083), so payloads with auth headers/tokens could be sent over
  unverified TLS even without `insecure = 1`.
- **Credential redaction in logs.** A shared `redact_secrets`/`redact_url` helper
  masks URI userinfo and token-like parameters in: the `--debug` command trace,
  the `--debug` effective-config dump (now also covering `url`/`uri`/`endpoint`/
  `remote`), webhook failure warnings, and Git/Fossil/Mercurial push-failure
  warnings.
- **OTLP header CRLF-injection defense.** Header keys/values are stripped of
  CR/LF/NUL after percent-decoding, preventing HTTP header injection via
  `OTEL_EXPORTER_OTLP_HEADERS`.
- **Email hardening.** Sendmail invocation adds a `--` end-of-options terminator
  before the recipient (argument-injection defense); `From:`/`To:`/`Subject:`
  values are stripped of CR/LF (header-injection defense); `_find_sendmail` skips
  relative `PATH` entries.
- **Path-traversal containment.** Track paths containing `..` are now rejected at
  config load, and the whole-repo VCS backends assert mirror paths stay within
  `output_dir`.
- **Safer on-disk writes.** Metadata sidecar saves now use `File::Temp`
  (`O_EXCL`, mode 0600) instead of a predictable `*.tmp.$$` name; the lock file is
  opened with `O_NOFOLLOW` where available and no longer falls back to a bare,
  world-writable `/tmp` path; `revert` re-checks the target is a regular file
  immediately before `chmod`/`chown`.
- **Webhook info-leak fix.** Diff line counts are zeroed for sensitive files when
  the diff body is suppressed, and the webhook now honors `max_diff_bytes`.

### Added

- **`command_timeout` global config key** (default `120`, `0` = unlimited).
  Bounds every external command with a wall-clock watchdog that kills the child,
  so a hung or runaway tool cannot hang a scheduled (cron/systemd) run.
- **`max_diff_bytes` for the webhook notifier** (default `0` = unlimited),
  matching the otlp/file notifiers; truncation adds a `diff_truncated` flag.
- **`ctime` in the metadata fast path**, so a same-size edit that restores the
  previous mtime is no longer missed.

### Changed

- `run_cmd` now drains stdout/stderr to EOF (no more silent truncation after an
  idle gap) and reports signal termination as `128 + signal`.
- `status`/`diff`/`log` now fail loudly when a VCS backend errors instead of
  reporting a false-clean (empty) result.
- Notifier send failures are now surfaced as warnings and recorded on the run
  report (previously visible only under `--debug`).
- A failed metadata save now aborts the run before committing/notifying, instead
  of proceeding with desynced state.
- OTLP endpoint resolution ignores a defined-but-empty `OTEL_*` env var instead
  of letting it silently disable sends.

### Fixed

- RCS flat-layout archive collision: distinct paths such as `/etc/a/b` and a real
  file named `/etc/a:b` no longer map to the same archive (colon/percent are now
  escaped).
- `git diff --cached` errors are no longer misread as "has changes".
- Unchecked I/O is now checked: `git config` results, `close` after content writes
  (SVN/Mercurial/Fossil), and the `update-ignore` write.
- `init` accepts the `mercurial` alias (not just `hg`).
- An unknown command-line option is reported as such (exit 64) instead of being
  mislabeled as an unknown subcommand.
- A disabled notifier no longer reserves its name, so an enabled same-named
  instance elsewhere loads correctly.
- `revert <path> <rev>` rejects a revision beginning with `-` (argument-injection
  defense).
- Dead/unreachable branches removed; corrected the symlink-snapshot prefix typo;
  fixed POD in `Report`, `VCS::Base`, and `Lock`.

### Migration notes

- **TLS:** endpoints using self-signed certificates without `insecure = 1` will
  now fail TLS verification (correct behavior). Set `insecure = 1` per notifier if
  you intentionally use self-signed certificates.
- **RCS backend:** mirror/archive filenames for tracked paths that contain a
  literal `:` change (the colon is now percent-escaped). Existing archives for
  such paths will be re-created under the new name on the next run.
- **Tracked symlinks** are re-snapshotted once after upgrade due to the corrected
  snapshot prefix constant.
- **Config:** any `[track]` entry containing a `..` segment is now a fatal config
  error; rewrite it as a canonical absolute path.
- **Lock path:** non-root runs without `HOME`/`XDG_*` now use a per-UID lock path
  rather than a shared `/tmp/changetrack-ng.lock`.

## [0.6.1] - 2026-06-25

### Added

- **`emit_recipients` config key** (both `otlp` and `file` notifiers, default `0`).
  When enabled, each change record includes a `config_change.notified` attribute
  listing the configured recipients for that file. Off by default to keep
  recipient lists out of the telemetry stream.
- **`max_diff_bytes` config key** (both `otlp` and `file` notifiers, default `0` =
  unlimited). Caps the size of the `config_change.diff` attribute in the emitted
  record. When a diff exceeds the cap it is truncated and a
  `config_change.diff_truncated = true` flag is added to the record. The full diff
  always remains in the VCS; this only bounds the notification payload. Sensitive-file
  suppressed-diff placeholders are never truncated.
- **`severity_change` config key** (both `otlp` and `file` notifiers, default
  `INFO`). Severity name assigned to file-change, file-create, and file-remove
  event records. Accepts `DEBUG`, `INFO`, `WARN`, or `ERROR` (case-insensitive);
  invalid or blank values fall back to `INFO`.
- **`severity_heartbeat` config key** (both `otlp` and `file` notifiers, default
  `DEBUG`). Severity name for heartbeat ("nothing changed") records.
- **`severity_warning` config key** (both `otlp` and `file` notifiers, default
  `WARN`). Severity name for scan-warning records.
- **Canonical OTel attribute model on both notifiers.** Every event record now
  carries a common set of attributes: `file.path`, `file.name`, `file.directory`,
  `config_change.type`, `config_change.sensitive`, `config_change.diff`,
  `file.mode`, `file.owner.name`, `file.group.name`, `file.size`,
  `changetrack.files_tracked`, `changetrack.run_duration_ms`. Event name values
  are `changetrack.file.changed`, `changetrack.file.created`,
  `changetrack.file.removed`, `changetrack.run.heartbeat`,
  `changetrack.run.warning`.
- **Occurred-time vs observed-time distinction.** Both notifiers now populate
  separate occurred and observed timestamps per record. Occurred time is the
  file mtime (mapped to `timeUnixNano` / `timestamp`); observed time is the
  scan start (`observedTimeUnixNano` / `observed_timestamp`). Records without
  an mtime fall back to observed time for both fields.

### Changed

- **File notifier output format.** The File notifier now writes one
  OTel-shaped JSON record **per event** (one per changed file, one per
  heartbeat, one per warning) as append-only NDJSON, replacing the previous
  single-object-per-run format. Each record carries `timestamp`,
  `observed_timestamp`, `event_name`, `severity_text`, `severity_number`,
  `body`, `resource`, and an `attributes` map.

## [0.6.0] - 2026-05-19

### Breaking Changes

- **Notifier configuration format redesigned.** The flat `notify = email webhook`
  list and all `[global]`-prefixed notifier keys (`email_to`, `email_from`,
  `webhook_url`, `webhook_full_diff`, `otlp_endpoint`, `otlp_headers`,
  `otlp_compression`, `otlp_heartbeat`, `otlp_full_diff`,
  `otlp_resource_attributes`, `notify_log_path`, `file_heartbeat`) are removed.
  Notifiers are now configured via `[notifier:<type>:<name>]` subsections (e.g.,
  `[notifier:email:default]`).  Each section requires `enabled = true|false`.
  Multiple instances of the same type are supported.  Disabled instances are
  discarded at parse time; duplicate instance names (within or across files) are
  a fatal parse error.  See README.md § "Notification Channels" and the example
  configs in `packaging/etc/examples/` for the new format.
- **`migrate-config` subcommand removed.** The `changetrack-ng migrate-config`
  subcommand (which converted a legacy upstream `changetrack` config to the old
  prefixed-key format) has been removed.  Users migrating from the upstream
  `changetrack` tool should refer to `packaging/etc/examples/` for the current
  config format and construct the new format manually.

### Added

- **Drop-in directory support.** Three sibling directories (`conf.d/`,
  `track.d/`, `notifier.d/`) adjacent to the main config file are scanned
  automatically.  Each directory enforces a section restriction (`[global]`
  only, `[track]` only, and `[notifier:*]` only, respectively).  Files are
  processed in sorted order.  Non-existent directories are silently skipped.
- **`@include` directives.** Three include forms are supported in any config
  file:
  - `@include <path>` — include a file or directory (inherits parent
    restriction)
  - `@include-track <path>` — restrict included content to `[track]` sections
  - `@include-notifier <path>` — restrict included content to `[notifier:*]`
    sections

  Directory paths process all `*.conf` files in sorted order.  A visited-paths
  guard prevents infinite recursion.  A missing path is a fatal parse error.
- **Multi-instance notifiers.** Each `[notifier:<type>:<name>]` section
  produces an independent notifier object at runtime.  All instances of all
  enabled types are dispatched during a run.
- **New test files** `t/24-config-sections.t`, `t/25-config-drop-in-dirs.t`,
  `t/26-config-include-directives.t`, `t/27-config-cross-file-errors.t`
  covering the new configuration features.

## [0.5.5] - 2026-05-15

### Added
- `--system` and `--user` flags to explicitly declare which config scope to load.
  - `--system` (default): `/etc/changetrack-ng/changetrack-ng.conf`
  - `--user`: `$HOME/.config/changetrack-ng/changetrack-ng.conf`
  - The two flags are mutually exclusive; specifying both exits with code 64.
  - `--user` without `HOME` set exits with code 64 and an actionable error.
- `CHANGETRACK_CONFIG` environment variable: when set, overrides the default config
  location. Takes precedence over `--system`/`--user` but is superseded by an explicit
  `-c`/`--config` argument. Useful for per-invocation config overrides in scripts.
- Defaults file support: package manager hooks, cron, and systemd timer now source
  `/etc/default/changetrack-ng` (Debian/Ubuntu) or `/etc/sysconfig/changetrack-ng`
  (RHEL/Fedora) before invoking the CLI. This allows administrators to set
  `CHANGETRACK_CONFIG` or `CHANGETRACK_EXTRA_ARGS` system-wide without modifying
  hook or unit files. Template installed by `make install-hooks`.
- `DEFAULTSDIR` Makefile variable (default: `/etc/default` on Debian-like systems,
  `/etc/sysconfig` on RHEL-like systems; auto-detected via `command -v dnf`).
- `packaging/etc/changetrack-ng.default`: template defaults file with commented-out
  `CHANGETRACK_CONFIG` and `CHANGETRACK_EXTRA_ARGS` variables and inline documentation.
- `t/23-config-resolution.t`: 8-test suite covering the full config resolution priority
  chain: `-c` explicit, `$CHANGETRACK_CONFIG` env var, `-c` beats env var, `--user` flag,
  env var beats `--user`, default=system path, `--system`+`--user` conflict, `--user`
  without `HOME`.

## [0.5.4] - 2026-05-14

### Added
- Three-tier diagnostic system with `--verbose/-v`, `--debug/-d`, and `--trace/-t` flags.
  - `--verbose`: high-level run structure — config path, VCS backend, lock lifecycle, file
    counts, commit/notify milestones, and run summary.
  - `--debug`: every external command run (via `run_cmd`), effective config values (keys
    matching `header`, `secret`, `token`, or `password` redacted as `***REDACTED***`),
    per-file actions taken (new/changed/removed only), and notification outcomes.
  - `--trace`: per-file disposition for **all** tracked paths (O(N) output): fast-path
    skips, type classifications, ignore-pattern and internal-path exclusions.
  - Implication chain: `--trace` implies `--debug`; `--debug` implies `--verbose`.
    Chain is enforced at both the CLI layer (`bin/changetrack-ng`) and in `Runner::new()`.
  - All diagnostic output uses STDERR (`warn`); STDOUT remains clean for subcommand data
    (`diff`, `status`, `log`), making it safe to pipe.
- `Util::set_debug($bool)` and `$ChangeTrack::Util::DEBUG` package variable. `run_cmd()`
  emits `[DEBUG] exec: <cmd>` to STDERR before each subprocess, and on non-zero exit.
- `VCS::Base::new()` now accepts and stores `debug` and `trace` arguments.
- `t/22-verbose-debug.t`: 42-test suite covering implication chain, tier isolation,
  secrets redaction, `run_cmd()` debug logging, and STDOUT/STDERR separation.
- `PRODUCT.md`: product-facing overview of functionality, architecture, and diagnostics.
- `CONTRIBUTING.md`: developer guidelines covering coding style, testing, security, and
  dependency policy.

## [0.5.2] - 2026-05-08

### Performance
- `status`, `diff`, and `log` subcommands now apply the metadata sidecar fast-path,
  skipping unchanged files without spawning a VCS process per file. Previously, these
  subcommands invoked the VCS backend once per tracked file regardless of change state.
  The fast-path (`can_skip_content_diff` + `changed_since_load`) was already used by
  `run`; it is now consistently applied across all read-only subcommands.
- `log_path(undef)` additionally skips files where the VCS mirror path doesn't exist
  (never committed, no history to retrieve).

### Tests
- `t/16-subcommands.t`: added fast-path test for `diff_path` on a clean file (expects
  empty result without VCS call) and a multi-file `status` fast-path test confirming
  only the modified file surfaces when one of two tracked files is unchanged.

## [0.5.1] - 2026-05-06

### Fixed
- All unattended invocations (apt, pacman hooks; cron; systemd) now pass `--quiet` by default,
  preventing change reports from flooding terminal output during package manager operations.
  DNF plugin was already fully silent via `subprocess.DEVNULL`.

## [0.5.0] - 2026-05-06

### Added
- `--dry-run` / `-n` flag to analyze changes statically without writing VCS or dispatching notifications.
- Symlink metadata lifecycle maps correctly.
- Added troubleshooting guide in INSTALL.md and documentation for `OTEL_EXPORTER_*` config precedence hierarchy.
- Reimplemented tests mapping to `DEB_BUILD_OPTIONS=nocheck`.
- Each notifier class declares `config_keys()`; `Runner::_build_notifier` now filters the config arg pool to only the keys the target notifier accepts. Surfaced missing `webhook_timeout` key.
- `t/21-report.t`: 52-test dedicated suite for `ChangeTrack::Report`. Added missing `start_time()` / `end_time()` accessors.

### Fixed
- **Webhook Diff Counting**: Prevented diff counts from inflating due to unified diff `+++`/`---` headers.
- **Redundant Commits**: Eliminated redundant `$vcs->add()` execution in checkin flow.
- **VCS Backend Hardening**: Evaluated and wrapped `chdir()` usages in Fossil and SVN in exception-safe environments to prevent directory poisoning on failures. Mercurial utilizes `-R` option.
- **MockSendmail version**: `t/lib/ChangeTrack/Test/MockSendmail.pm` now derives `$VERSION` from `ChangeTrack::Version` instead of a hardcoded string.

### Changed
- **Runner Helper**: Extracted `_build_notifier` inside Runner.
- **Ignore Pre-compilation**: Refactored logic to statically pre-compile all ignore patterns, drastically improving scaling.
- **OTLP performance**: `/etc/machine-id` is now read once via `state` variable and cached for process lifetime.
- **Sensitive detection performance**: `_resolve_sensitive()` accepts pre-computed mode from metadata record, eliminating a redundant `stat()` syscall per tracked file per run.

## [0.4.3] - 2026-05-04

### Changed

- **Metadata type system overhaul**: Replaced `skip_reason` field with unified `type` values
  (`file`, `symlink`, `binary`, `empty`, `unreadable`, `special`, `directory`, `missing`).
  Old metadata files are transparently migrated on next run (lazy, no manual step).
- **Runner rewritten as type-based dispatch**: `_process_file()` uses a single `update_from_stat`
  classification followed by a clean switch on type, eliminating redundant stat calls and
  split-brain logic.

### Fixed

- **Performance**: metadata-based fast path now skips all unchanged files (any type) before
  any file I/O, VCS subprocess calls, or binary probes.
- **Symlinks misclassified as binary**: `-f` follows symlinks, so symlinks to binary targets
  were entering the binary detection path. Now excluded via `!-l` guard in classification.
- **Empty files flagged as binary**: Perl's `-B` returns true for zero-byte files. Now
  classified as `empty` type and handled with a content-free fast path.
- **Binary warnings on every run**: Previously warned even for known-binary files with
  unchanged mtime+size. Now warns only on first detection.
- **getpwuid/getgrgid on non-POSIX**: Guarded with `$^O` check for Windows portability.

### Added

- dnf package-manager integration via plugin files:
	- `packaging/hooks/dnf/changetrack_ng.py`
	- `packaging/hooks/dnf/changetrack_ng.conf`
- `make install-hooks` now installs dnf hooks automatically to `/etc/dnf/plugins/` on dnf systems.
- RPM packaging now ships dnf plugin files and installs them under `/etc/dnf/plugins/`.

## [0.3.0] - 2026-04-28

Initial release.  Clean Perl rewrite of the original `changetrack` tool
(last maintained 2009, broken on Perl 5.26+).

### Added

**Core**
- INI v2 config format with auto-detection and one-shot migration from v1
- JSONL metadata sidecar tracking per-file mtime, size, mode, and sensitive flag
- `flock`-based locking with configurable timeout (default: silent skip)
- Per-file error handling: skip with warning, continue run
- Ignore pattern system with built-in defaults for common noise files
- Pre-commit checks: warn on special files (sockets, FIFOs, devices) and hardlinks
- Sensitive file auto-detection by mode (no group/world read bit); diff suppression in notifications

**VCS backends**
- RCS — per-file `,v` files in output directory (back-compatible layout)
- Git — whole-repo mirror tree; optional push to remotes
- Fossil — whole-repo mirror; fossil open/commit/diff
- SVN — whole-repo mirror; svn add/commit/diff
- Mercurial — whole-repo mirror; hg add/commit/diff

**Subcommands**
- `run` — scan, commit, notify (default)
- `init` — explicit VCS initialization
- `status` — list changed files (exit 1 if any)
- `diff [path]` — show pending unified diff
- `log [path]` — show VCS history
- `revert <path> <rev>` — restore file from a revision
- `update-ignore` — write/refresh VCS-native ignore file
- `migrate-config` — convert v1 config to v2 format

**Notification channels**
- Email — pipes to sendmail; per-file recipient lists in track section
- Webhook — HTTP POST via `HTTP::Tiny`; optional full diff; optional heartbeat
- OTLP/OpenTelemetry — OTLP/HTTP+JSON; gzip; env-var endpoint precedence; 3-attempt retry backoff; heartbeat ON by default
- File — append-only JSON log; optional heartbeat

**Integration**
- systemd oneshot service + hourly timer with `Persistent=true`
- cron.hourly script with systemd-timer guard (no duplicate runs)
- apt hooks (apt.conf.d pre/post directives)
- pacman/ALPM hooks (pre/post transaction)
- `make install-hooks` auto-detects and installs the appropriate hooks
- `make dist` produces a release tarball

**Documentation**
- `man/changetrack-ng.8` — CLI reference (POD source)
- `man/changetrack-ng.conf.5` — config reference (POD source)
- `README.md` — overview and quickstart
- `INSTALL.md` — install paths, scheduling, distro notes

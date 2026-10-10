# changetrack-ng — TODO / Issues / Improvements

Last updated: 2026-10-08

Items are prioritized by severity and grouped by category.

---

## Completed (2026-10-08)

- PERF-3: Lazy DNS evaluation for `HOSTNAME` token expansion in `ChangeTrack::Config::_load_file()`. Defers `_config_hostname()` until a config value matches `\bHOSTNAME\b`.
- CORR-7: Atomic temporary-file-and-rename for `restore_mirror_path()` in `ChangeTrack::Util`. Uses a sibling temporary file in the destination directory, copies to tempfile, preserves existing file mode and ownership, and atomically renames over destination. Cleans up tempfile on failure.
- DEBT-8: Pruned dead stubs (`Metadata::import_from_v1_statistics`, `Runner::_glob_match`) and deprecated/ignored `interval` config key with POD documentation.
- DOC-4: Reconciled developer and architecture documentation (`CLAUDE.md`, `ARCHITECTURE.md`) with codebase reality: configurable `command_timeout` (default 120s), Fossil backend `--chdir` flag usage, removal of v1 config auto-detection reference, and updated test suite count (1,027 tests across 36 files).
- DEBT-9: Deduplicated non-trackable file handling in `ChangeTrack::Runner::_process_file`. Extracted shared `_handle_non_trackable()` helper for `special`, `unreadable`, and `binary` file types while preserving warning, VCS removal staging, and report recording semantics.
- DEBT-10: Consolidate shared VCS backend methods in `VCS::Base` and modernize SVN backend. Hoisted `output_path`, `_rel_path`, `checkin`, and default `is_dirty` to `ChangeTrack::VCS::Base`, eliminated duplicate implementations across Git, Mercurial, Fossil, and SVN backends, removed dead eval wrapper from `Fossil::_run`, and modernized SVN backend to use absolute working-copy paths without process-wide `chdir`.

## Completed (2026-09-18)

- CORR-3: Reconcile vanished files in tracked directories (`DIRECTORY /path`) against recorded metadata sidecar in `_build_file_list()`, enqueuing them for removal processing.
- CORR-4: Implemented `remove($real_path)` across `ChangeTrack::VCS::Base` and all 5 backends (Git, SVN, Mercurial, Fossil, RCS), updating Runner to unlink mirror working copies and stage VCS deletions upon file removal.
- CORR-5: Handled bidirectional file type transitions (`file` ↔ `symlink`, `empty` ↔ `content`, trackable ↔ non-trackable): updated `can_skip_content_diff()` to verify disk state before skipping diffs, updated `changed_since_load()` and `diff_summary()` to detect and report type changes, and trigger new checkin or VCS removal accordingly.
- SEC-5: Insecure permission audit in `_warn_insecure_config_permissions()` now inspects all loaded configuration files returned by `ChangeTrack::Config->loaded_files` (including `conf.d/`, `notifier.d/`, `track.d/`, and `@include` files).
- OPS-5: Subcommand debug and trace propagation — CLI subcommands (`status`, `diff`, `log`, `revert`) in `bin/changetrack-ng` forward `--debug` and `--trace` flags into Runner and activate `run_cmd` debug tracing.
- TEST-10: Comprehensive test coverage for bidirectional file type transitions (`t/36-type-transitions.t`) and directory deletion reconciliation & VCS removals (`t/35-vcs-removal.t`).
- TEST-12: Added symlink capability probe to `t/03-metadata.t` to skip gracefully on restricted environments.
- TEST-13: Fixed `IO::Uncompress::Gunzip` require and error variable typos in `t/19-notify-otlp.t`.
- CONF-1: Config parser inline comment stripping (`#` or `;` preceded by whitespace), full-line `;` comment recognition, and sample config inline comment corrections (`t/34-config-inline-comments.t`).

## Completed (2026-05-06)

- TEST-11: Fixed `t/lib/ChangeTrack/Test/MockSendmail.pm` to derive `$VERSION` dynamically from `ChangeTrack::Version` instead of hardcoding.
- PERF-1: Cached `/etc/machine-id` read in `Notify/OTLP.pm::_resource_attrs()` using a `state` variable — eliminates redundant file I/O on every OTLP export call.
- PERF-2: Pass pre-computed mode integer from metadata record (`oct($rec->{mode})`) to `_resolve_sensitive()` — eliminates a redundant `stat()` syscall per tracked file.
- DEBT-1: Each notifier class now declares `config_keys()`. `Runner::_build_notifier` filters the config arg pool to only the keys the target notifier accepts (plus the shared `sensitive_notify` key). Also surfaced and included `webhook_timeout` which was missing from the old monolithic build.
- TEST-5: Added `t/21-report.t` with 52 tests covering `ChangeTrack::Report` construction, accumulation, `add_removed`, `add_warning`, `is_heartbeat_eligible`, `duration_ms`, and all `to_text` output cases (sensitive suppression, metadata-only changes, removals, warnings section). Also added the missing `start_time` / `end_time` accessors documented in POD but never implemented.
- PKG-1: Makefile `install-systemd` and `install-hooks` targets perform `sed` substitution of `@BINDIR@` at install time.

## Completed (2026-05-05)

- CORR-1: Fixed webhook diff counters to successfully ignore unified diff header boundaries (`+++`/`---`).
- CORR-2: Removed redundant `add()` call after `checkin()` in Runner and documented `checkin()` contract.
- OPS-2 / DEBT-3: Hardened Fossil and SVN chdir usage with exception-safe ensure blocks. Mercurial was confirmed to natively use `-R`.
- TEST-6: Added full lifecycle metadata tracking map tests for symlinks.
- TEST-8: Added `sensitive_auto` x `sensitive_notify` matrix to verify suppression interaction cleanly.
- DEBT-6: Refactored Runner to share `_build_notifier` constructor logic across dispatch and startup paths.
- DEBT-7: Ignore patterns are now precompiled once-per-run into `qr//` constants to fix linear scale CPU.
- FEAT-1: Implemented `--dry-run` / `-n` flag to analyze changes statically without writing VCS or dispatching notifications.
- DOC-1: Updated man page `changetrack-ng.conf(5)` highlighting `OTEL_EXPORTER_*` config precedence hierarchy.
- DOC-2: Added troubleshooting guide in `INSTALL.md`.
- DOC-3: Added relative pointer to `ARCHITECTURE.md` from primary `README.md`.
- PKG-3: Added conditional `override_dh_auto_test` inside `packaging/debian/rules` enabling safe skip via `DEB_BUILD_OPTIONS="nocheck"`.

## Completed (2026-04-30)

- SEC-1: Added `${VAR}` environment expansion support in config values and documented secret-handling guidance (`OTEL_EXPORTER_OTLP_HEADERS` preferred).
- SEC-2: Added startup warning when config is world-readable and contains notifier secret-bearing settings.
- SEC-3: Accepted and documented behavior: `sensitive_notify = suppress` still includes file paths for auditability.
- SEC-4: Hardened revert flow to restore pre-revert file mode/ownership for existing regular files.
- INT-1: Added strict global value validation (booleans, integers, enums, notifier names).
- INT-2: Added `mtime`/`size` tracking in metadata and Runner fast-path to skip VCS diff when unchanged.
- INT-3: File processing and report emission are now deterministic via path sorting.
- OPS-1: Added notifier startup config validation with actionable failures for missing required settings.
- OPS-5: Added lightweight structured Runner logging with timestamp and level output.
- TEST-1: Added integration test coverage for Config -> Runner -> Notifier startup validation path.
- TEST-2: Added end-to-end CLI `revert` symlink target restoration test.
- TEST-3: Added stronger v1->v2 migration round-trip equivalence coverage.
- TEST-4: Added retry/backoff assertions for Webhook and OTLP notifier retry paths.
- DEBT-4: Added inline POD documentation for `bin/changetrack-ng`.
- CORR-1: Fixed webhook line counters to exclude unified diff header lines (`+++`/`---`) and added regression coverage.
- CORR-2: Removed redundant post-checkin `add()` calls in Runner; `checkin()` remains staging contract boundary.
- OPS-2 / DEBT-3: Hardened Fossil/SVN command runners with exception-safe cwd restore and hard failure on restore errors.
- TEST-6: Added symlink metadata lifecycle coverage in `t/03-metadata.t`.
- TEST-8: Added `sensitive_auto` × `sensitive_notify` interaction matrix in `t/10-sensitive.t`.
- DEBT-6: Deduplicated notifier construction through a shared Runner helper.
- DEBT-7: Precompiled ignore patterns once per run instead of per-file recompilation.
- FEAT-1: Added `--dry-run` / `-n` to detect/report changes without VCS mutation, metadata writes, or notifications.
- DOC-1: Updated `changetrack-ng.conf(5)` with explicit file notifier diff option documentation.
- DOC-2: Added troubleshooting section to `INSTALL.md`.
- DOC-3: Added `ARCHITECTURE.md` reference in `README.md`.
- PKG-3: Debian rules now explicitly run `make test` (with `DEB_BUILD_OPTIONS=nocheck` support).

---

## Security Issues

### SEC-6: Enforce private umask (0077) and auto-tighten output directory storage permissions (Critical)

**Issue:** Output directory `/var/lib/changetrack-ng` and sibling repository files (`.fossil`, `-svnrepo`) may be world/group readable when created under default system umasks. Stored copies of sensitive files (e.g. `/etc/shadow`) are exposed to unprivileged users.
**Fix:** Enforce `umask(0077)` at initialization. In `Runner::run()`, probe `$output_dir` and sibling repositories; tighten any group/world permissions to `0700`/`0600` and emit an alert warning recorded in the report. Ensure packaging templates specify mode `0700`.

---

## Data Integrity / Correctness

### CORR-6: Prevent permanent loss of file changes on VCS failure & diff errors (High)

**Issue:** `_process_file` updates in-memory stat snapshots prior to checkin/diff. If an error occurs, the failed state is saved to metadata, causing subsequent runs to skip content diffs via fast-path. Whole-repo metadata sidecar was also saved before VCS commit. VCS diff execution errors in Git/Hg/SVN/Fossil were treated as empty diffs rather than errors.
**Fix:** Roll back in-memory metadata records upon per-file exception. Save metadata sidecar only after successful VCS batch commit. Croak on VCS diff execution errors.


---

## Robustness / Operational

### OPS-6: Make DNF package-manager pre-transaction hook non-blocking (Medium)

**Issue:** `packaging/hooks/dnf/changetrack_ng.py` called `self._run("pre-install", required=True)`, raising `dnf.exceptions.Error` on any non-zero exit and aborting package transactions.
**Fix:** Set `required=False` and emit prominent warnings to `sys.stderr` on non-zero exit status without blocking package management.

### NOTIFY-1: Propagate notifier transport failures and populate webhook report metadata (Medium)

**Issue:** Notifier dispatch swallowed transport errors without bubbling to `Runner::run()`, preventing warnings from appearing in reports. Webhook notifier read `$report->{message}` and `$report->{vcs}`, which were never initialized.
**Fix:** Propagate transport failures so `Runner` records them in `$report->add_warning()`. Pass `vcs` and `message` to `ChangeTrack::Report->new()`.

---

## Performance / Scalability

### PERF-4: Single-pass `lstat` and cached classification in `Metadata.pm` (Phase 2C Medium-Risk)

**Issue:** `can_skip_content_diff()`, `changed_since_load()`, and `update_from_stat()` each issue separate `lstat()` calls and invoke `_classify_file()` (which runs `-B` block reads) for every tracked file on every run.
**Fix:** Perform a single `lstat` per file per run, pass stat buffer into comparison helpers, and defer `-B` binary tests until mtime/size actually change.

---

## Testing

### TEST-9: No notifier failure isolation test (Low)

**Issue:** `Notify/Base.pm`'s `send()` wraps dispatch in `eval` to prevent one notifier's failure from blocking others. This guarantee has no direct test — a notifier that `die`s should not prevent subsequent notifiers from running.

---

## Code Quality / Technical Debt

### DEBT-5: `_glob_to_re()` doesn't handle character classes `[...]` (Low)

**Issue:** The glob-to-regex converter in Runner handles `*`, `?`, and `.` but doesn't support `[abc]` character classes in ignore patterns. These are valid in shell globs.

### DEBT-11: Consolidate HTTP retry/backoff in `Notify::Base` (Phase 2D Medium-Risk)

**Issue:** `Webhook.pm` and `OTLP.pm` maintain nearly identical 3-attempt exponential backoff loops with `HTTP::Tiny`.
**Fix:** Hoist common HTTP request dispatch into `ChangeTrack::Notify::Base`.

---

## Packaging / Distribution

### PKG-4: Substitute `@BINDIR@` and `@DEFAULTSDIR@` placeholders in debian and RPM packaging (High)

**Issue:** `packaging/debian/rules` installed apt hooks directly without `sed` placeholder replacement, leaving `@BINDIR@` unexpanded and silently failing hooks. `packaging/rpm/changetrack-ng.spec` only replaced `@BINDIR@` and omitted `@DEFAULTSDIR@` (`/etc/sysconfig`).
**Fix:** Template `@BINDIR@` and `@DEFAULTSDIR@` consistently across Debian rules and RPM spec.

---

---

## Closed — Won't Fix

These items have been deliberately decided against. They remain here for historical context and to prevent re-opening without new justification.

### OPS-4: Lock polling retry uses `sleep(1)`

**Reason:** `lock_timeout` is typically `0` (skip immediately). For the rare non-zero case, 1s granularity over a handful of retries is acceptable. `select()`-based sub-second polling adds complexity with no practical benefit.

### DEBT-2: `eval "require $class"` pattern for dynamic loading

**Reason:** Class names come from the hardcoded `%NOTIFY_CLASSES` dispatch table in Runner.pm — not from user input. The trust boundary is explicit and static. A comment in Runner.pm documents this. `Module::Load` would add no safety benefit.

### FEAT-2: Per-track exclude patterns

**Reason:** Config schema expansion requiring parser, data structure, file-walk, and migration changes. Global `ignore` patterns cover the vast majority of cases. Deferred to v0.5+ if user demand materialises.

### FEAT-4: Real-time file deletion detection (inotify/fanotify)

**Reason:** changetrack-ng is a polling model by design. A persistent daemon with inotify would be a fundamentally different architecture. Out of scope; documented as a known limitation in the man page.

### PKG-2: zypper hook

**Reason:** zypper's plugin mechanism is significantly more complex than apt/dnf/pacman. openSUSE user base overlap is minimal. Will not be implemented unless contributed externally; dnf support ships and covers the RPM ecosystem.

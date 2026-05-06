# changetrack-ng — TODO / Issues / Improvements

Last updated: 2026-05-05

Items are prioritized by severity and grouped by category.

---

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

None currently open.

---

## Data Integrity / Correctness

(All correctness blockers currently resolved.)

---

## Robustness / Operational

### OPS-3: `run_cmd()` IO::Select timeout is hardcoded to 30s (Low)

**Issue:** The `can_read(30)` call in `Util::run_cmd()` means that a hung VCS subprocess will block for 30 seconds per read cycle. For large repos, some VCS operations (e.g., `svn commit` to a slow remote) may legitimately take longer.

**Recommendation:** Accept a `timeout` parameter in `run_cmd()` args hash, defaulting to 30. Pass through from callers who need longer operations.

### OPS-4: Lock module's polling retry uses `sleep(1)` (Low)

**Issue:** The timeout loop in `Lock::acquire()` calls `$self->_sleep(1)` in a loop, which is a busy-poll with 1-second granularity. For short timeouts this is fine, but for long timeouts it's wasteful.

**Status:** Acceptable for current use cases (lock_timeout is typically 0). Flag for review if longer timeouts become common.

---

## Testing

### TEST-5: No dedicated `Report.pm` test file (Medium)

**Issue:** `Report.pm` is the change accumulator passed to all notifiers, yet it has no dedicated test file. Its behavior is exercised indirectly through notifier tests, but edge cases (empty reports, reports with only metadata changes, reports with mixed sensitive/non-sensitive entries) are not directly covered.

**Recommendation:** Add `t/XX-report.t` covering construction, entry accumulation, summary generation, and sensitive entry handling.

### TEST-7: No test for `Config::dump_v2` (Low)

**Issue:** The `dump_v2` method in Config.pm has no test coverage. Round-trip correctness (parse v2 → dump → parse again → equivalent) should be verified.

### TEST-9: No notifier failure isolation test (Low)

**Issue:** `Notify/Base.pm`'s `send()` wraps dispatch in `eval` to prevent one notifier's failure from blocking others. This guarantee has no direct test — a notifier that `die`s should not prevent subsequent notifiers from running.

### TEST-10: No file type transition tests (Low)

**Issue:** No tests verify correct behavior when a tracked file changes type between runs (e.g., regular file replaced by symlink, empty file gains content, text file becomes binary). These transitions exercise the metadata type system and VCS mirror sync logic.

### TEST-11: `MockSendmail.pm` hardcodes `$VERSION` (Low)

**Issue:** `t/lib/MockSendmail.pm` has `$VERSION = '0.4.3'` hardcoded instead of using `ChangeTrack::Version`. This will drift on version bumps.

**Fix:** Use `our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };` consistent with all other modules.

---

## Code Quality / Technical Debt

### DEBT-1: Notifier constructor receives ALL config keys (Medium)

**Issue:** Runner passes every possible notifier config key to every notifier constructor, regardless of which notifier is being instantiated. Email notifier receives OTLP settings, etc. This is wasteful and confusing.

**Recommendation:** Each notifier class should declare its required/accepted config keys. Runner should pass only relevant keys per notifier.

### DEBT-2: `eval "require $class"` pattern for dynamic loading (Low)

**Issue:** Runner uses string-eval to dynamically load VCS and Notifier modules. While this is a common Perl pattern, it's opaque to static analysis tools and slightly risky if `$class` were ever derived from untrusted input (it isn't today — it comes from a hardcoded hash).

**Status:** Acceptable given the trusted source. Consider `Module::Load` from core for clarity, or document the trust assumption.

### DEBT-5: `_glob_to_re()` doesn't handle character classes `[...]` (Low)

**Issue:** The glob-to-regex converter in Runner handles `*`, `?`, and `.` but doesn't support `[abc]` character classes in ignore patterns. These are valid in shell globs.

**Impact:** Low — built-in ignore patterns don't use character classes, and user-defined patterns rarely need them.

---

## Performance

### PERF-1: OTLP `_resource_attrs()` re-reads `/etc/machine-id` on every call (Low)

**Issue:** `Notify/OTLP.pm`'s `_resource_attrs()` opens and reads `/etc/machine-id` on every invocation. The machine ID is immutable at runtime; reading it once and caching via a `state` variable eliminates redundant file I/O.

**Fix:** `state $cached_id; $cached_id //= do { ... read file ... }; ` — idiomatic for Perl 5.20+ with `feature 'state'` already in scope.

### PERF-2: `_resolve_sensitive` performs redundant `stat()` (Low)

**Issue:** `Runner::_resolve_sensitive()` calls `stat($path)` to check mode bits, but the file was already `lstat()`ed by `Metadata::update_from_stat()` in the same processing loop. The mode is available in the metadata record.

**Recommendation:** Pass the metadata record's `mode` field to `_resolve_sensitive` instead of re-statting. Minor optimization but eliminates one syscall per tracked file per run.

---

## Feature Gaps

### FEAT-2: No way to exclude specific files within a tracked directory (Low)

**Issue:** Ignore patterns are global. There's no per-`[track]` entry ignore mechanism.

**Recommendation:** Consider per-track `exclude=<pattern>` option in the track line.

### FEAT-3: No health-check / self-test subcommand (Low)

**Issue:** Operators have no way to validate their configuration without running a full scan. A `changetrack-ng check` that validates config, tests VCS access, and optionally tests notification delivery would reduce deployment issues.

### FEAT-4: No support for tracking file deletions proactively (Low)

**Issue:** A file that is removed from disk is detected only on the next run. There's no inotify/fanotify integration for real-time deletion alerting.

**Status:** By design — changetrack-ng is a polling model. Document as a known limitation.

---

## Packaging / Distribution

### PKG-1: systemd service and pacman hooks use `@BINDIR@` template (Fixed)

**Status:** The Makefile `install-systemd` and `install-hooks` targets now perform `sed` substitution of `@BINDIR@` at install time. The raw files in the repo contain the placeholder.

### PKG-2: No dnf/zypper hook implementation (Fixed for dnf)

**Status:** `install-hooks` now installs a dnf plugin (`/etc/dnf/plugins/changetrack_ng.py` + `.conf`) and RPM packaging ships the same files. zypper remains unimplemented.

---

## Documentation

(All documentation tickets currently resolved.)

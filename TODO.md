# changetrack-ng — TODO / Issues / Improvements

Last updated: 2026-05-05

Items are prioritized by severity and grouped by category.

---

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

---

## Security Issues

None currently open.

---

## Data Integrity / Correctness

### CORR-1: Webhook `_count_added`/`_count_removed` includes diff header lines (Low)

**Issue:** In `Notify/Webhook.pm`, `_count_added` matches `/^\+/` and `_count_removed` matches `/^-/`. These patterns also match unified diff header lines (`+++` and `---`), inflating each count by 1 per file in the diff. The bug affects only the `lines_added`/`lines_removed` fields in webhook JSON payloads — it does not affect change detection, VCS behavior, or other notifiers.

**Fix:** Anchor the patterns to exclude header lines: `/^\+[^+]/` and `/^-[^-]/`, or skip lines matching `/^(?:\+\+\+|---)\s/`.

### CORR-2: Redundant `add()` call after `checkin()` in Runner `_process_file` (Low)

**Issue:** Runner calls `$vcs->add($real_path)` immediately after `$vcs->checkin($real_path, $msg)`. Every whole-repo backend's `checkin()` already calls `$self->add()` internally (Git.pm, Fossil.pm, SVN.pm, Mercurial.pm all verified). For RCS, `add()` is a no-op. The extra call is dead code that obscures the actual contract.

**Fix:** Remove the redundant `$vcs->add($real_path)` call after `checkin()`. Add a comment on the `checkin()` contract in `VCS/Base.pm` documenting that `checkin` is responsible for staging.

---

## Robustness / Operational

### OPS-2: Fossil/SVN/Hg backends use `chdir()` which is process-global (Medium)

**Issue:** `Fossil.pm` and `SVN.pm` use `getcwd()` + `chdir()` + work + `chdir($old)`. This is not thread-safe and is vulnerable to die/exception between the chdirs (the `chdir($old)` in Fossil's `_run()` is a carp, not a croak, so it continues in the wrong directory on error).

**Recommendation:**
- Use `git -C` pattern (command-line option) where the VCS supports it: Fossil doesn't, but SVN has `--config-dir`
- At minimum, wrap the work in an eval and ensure chdir-back in a finally-like pattern
- Or: fork a subprocess for the chdir-dependent operations

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

### TEST-6: No symlink metadata tests in `03-metadata.t` (Medium)

**Issue:** Symlinks are a first-class type in the metadata system (`update_from_stat` records link targets, `can_skip_content_diff` has symlink-specific logic, `changed_since_load` compares targets, `diff_summary` reports target changes). None of this is tested in `03-metadata.t`.

**Recommendation:** Add symlink lifecycle tests: create symlink → `update_from_stat` → verify `target` field → change target → verify `changed_since_load` → verify `diff_summary` output → verify `can_skip_content_diff` returns false on target change.

### TEST-7: No test for `Config::dump_v2` (Low)

**Issue:** The `dump_v2` method in Config.pm has no test coverage. Round-trip correctness (parse v2 → dump → parse again → equivalent) should be verified.

### TEST-8: No `sensitive_auto` × `sensitive_notify` interaction matrix (Medium)

**Issue:** `sensitive_auto` controls whether files are auto-detected as sensitive; `sensitive_notify` controls whether diffs appear in notifications. These are documented as orthogonal, but there is no test that exercises all four combinations (auto on/off × notify suppress/allow) to verify the interaction behaves as specified.

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

### DEBT-3: Fossil `_run()` uses chdir without exception safety (Medium)

**Issue:** If the fossil command between `chdir($output_dir)` and `chdir($old)` dies, the process remains in the wrong directory. The `chdir($old)` failure is only a `carp`, not a `croak`.

**Recommendation:** Wrap in `eval { ... }; chdir($old) or croak ...; die $@ if $@;` pattern.

### DEBT-5: `_glob_to_re()` doesn't handle character classes `[...]` (Low)

**Issue:** The glob-to-regex converter in Runner handles `*`, `?`, and `.` but doesn't support `[abc]` character classes in ignore patterns. These are valid in shell globs.

**Impact:** Low — built-in ignore patterns don't use character classes, and user-defined patterns rarely need them.

### DEBT-6: Notifier construction duplicated in Runner (Medium)

**Issue:** The ~20-line notifier constructor call block appears identically in `run()` and `_validate_notifier_startup()`. If a new config key is added to the notifier constructor, both sites must be updated in lockstep — a maintenance trap that will eventually cause a divergence bug.

**Recommendation:** Extract a `_build_notifier($class, $cfg)` helper that both call sites invoke. This also sets up cleanly for DEBT-1 (per-notifier key filtering) as a follow-on.

### DEBT-7: Ignore patterns recompiled on every file (Low-Medium)

**Issue:** `_should_ignore()` calls `_glob_to_re()` for every path-containing pattern on every file. For a run with N files and P ignore patterns, this is up to N×P regex compilations. With Perl's `/o` flag unavailable (patterns are dynamic), the cost scales linearly.

**Recommendation:** Precompile all ignore patterns into `qr//` regexes once at the start of the run (after config load). Store them alongside the raw patterns and pass the compiled set to `_should_ignore()`. This is a straightforward change with measurable benefit for large file sets.

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

### FEAT-1: No `--dry-run` mode (Medium)

**Issue:** There's no way to preview what `changetrack-ng run` would do without actually committing changes and sending notifications.

**Recommendation:** Add `--dry-run` / `-n` flag that performs all detection but skips VCS commit and notification dispatch.

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

### PKG-3: Debian package doesn't run tests during build (Low)

**Issue:** `packaging/debian/rules` should invoke `make test` during the build phase.

---

## Documentation

### DOC-1: Man page should document OTLP env-var precedence (Low)

**Issue:** The man page for `changetrack-ng.conf(5)` documents `otlp_endpoint` but doesn't mention that `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` and `OTEL_EXPORTER_OTLP_ENDPOINT` environment variables take precedence.

### DOC-2: No troubleshooting guide (Low)

**Issue:** Common operational issues (lock contention, VCS not initialized, permission errors) have no centralized troubleshooting reference.

### DOC-3: README should reference ARCHITECTURE.md (Low)

**Issue:** The README doesn't mention the architecture document for contributors.

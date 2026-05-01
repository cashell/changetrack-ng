# changetrack-ng — TODO / Issues / Improvements

Last updated: 2026-04-30

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

None currently open.

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

None currently open.

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

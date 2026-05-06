# Changelog

All notable changes will be documented here.

## [Unreleased]

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

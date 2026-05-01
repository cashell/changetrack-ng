# Changelog

All notable changes will be documented here.

## [Unreleased]

### Added

- dnf package-manager integration via plugin files:
	- `hooks/dnf/changetrack_ng.py`
	- `hooks/dnf/changetrack_ng.conf`
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

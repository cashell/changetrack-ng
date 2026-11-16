# changetrack-ng - TODO / Issues / Improvements

Last updated: 2026-11-15

Items are prioritized by severity and grouped by category. See [docs/archive/reviews/2026-11-09-APPLICATION-REVIEW.md](docs/archive/reviews/2026-11-09-APPLICATION-REVIEW.md) and [docs/archive/plans/2026-11-09-IMPLEMENTATION-PLAN.md](docs/archive/plans/2026-11-09-IMPLEMENTATION-PLAN.md) for full analysis and phased execution specs.

> **Branch Progress (`feat/phase-1-config-schema`):**
> - **Phases 1-3 Completed:** `CONF-3`, `CONF-4`, `DEBT-5`, `CORR-14`, `CORR-17`, `FEAT-5`, `NOTIFY-3`, `NOTIFY-4`, `PERF-6`, and partial `CORR-18` (SVN/Mercurial `revert` revision normalization) / `DOC-5` (`${HOSTNAME}` parser support and example config updates).
> - **Remaining in Phase 4:** `CORR-15`, `CORR-16`, `CORR-18` (`log` directory & repo-wide history), `FEAT-6`, `DEBT-15`, `OPS-10` (`--lock-timeout` CLI flag), `PKG-7` (Runner default VCS `git`).
> - **Remaining in Phase 5:** `PKG-6`, `PKG-7` (`Makefile` `SYSCONFDIR`/`LOGROTATEDIR` & `.deb` `override_dh_fixperms`), `OPS-10` (hook `--lock-timeout 30`), `DOC-5` (manuals, docs, `CHANGELOG.md`).

---

## High Priority - Correctness & Core Architecture

### CORR-14: Fix `revert` permission bugs, missing parent directory crash, and mirror index state (High) [Completed in Phase 3]

**Issue:**
1. **Symlink-to-file `0777` bug:** When live `$path` is currently a symlink, `Runner::_snapshot_existing_file()` (`lib/ChangeTrack/Runner.pm:1231-1244`) captures `lstat` mode `0777`. If `revert` restores a revision where `$path` was a regular file, `_restore_file_metadata()` (`1252-1270`) checks only whether the post-revert path is a regular file (`!-l _ && -f _`), ignores `$pre->{is_symlink}`, and runs `chmod(0777, $path)`.
2. **Deleted-file `0600` bug:** When restoring a deleted file, `$pre` is `undef` and `Util::restore_mirror_path()` (`lib/ChangeTrack/Util.pm:438-469`) falls back to the mirror file's mode (`0600 root:root` due to `umask(0077)` in `bin/changetrack-ng:24`).
3. **Missing parent directory crash:** If a deleted file's parent directory was also removed, `Util::restore_mirror_path()` (`lib/ChangeTrack/Util.pm:428`), `RCS::revert()` (`lib/ChangeTrack/VCS/RCS.pm:153`), and `Fossil::revert()` (`lib/ChangeTrack/VCS/Fossil.pm:295`) fail instead of creating missing parent directories.
4. **Spurious symlink warning:** Reverting any existing symlink emits `[WARN] revert metadata restore skipped (not a regular file)` (`lib/ChangeTrack/Runner.pm:1258-1260`).
5. **Mirror index dirtiness:** `Git::revert()` (`lib/ChangeTrack/VCS/Git.pm:194`) runs `git checkout $rev -- $rel`, leaving the historical revision staged in the mirror index instead of keeping the VCS mirror clean at `HEAD` so the next `run` commits and notifies the rollback normally.

### CORR-15: Reject unknown CLI flags and unexpected positional arguments after subcommands (High)

**Issue:** `bin/changetrack-ng:17, 99-111` configures `Getopt::Long` with `pass_through` and only checks if `$subcommand` starts with `-`. Any unknown flag or extra positional argument after the subcommand is left in `@ARGV` and silently ignored by `run`, `init`, `status`, and treated as a literal filename by `diff` and `log` (e.g. `changetrack-ng run --dryrun` executes a live mutating run; `changetrack-ng status /etc/hosts` scans all files; `changetrack-ng diff --help` treats `--help` as a file path).

### CORR-16: Fix `diff` crash on directory paths, missing metadata-only diffs, and `status` non-diffable transition blindspot (High)

**Issue:**
1. `Runner::diff_path($path)` (`lib/ChangeTrack/Runner.pm:1125-1165`) passes a directory path directly to `$vcs->diff($path)`, causing `VCS::Base::_with_temp_mirror_sync()` (`lib/ChangeTrack/VCS/Base.pm:135`) to call `File::Copy::copy` on a directory and die with `Is a directory`. Single-path `diff_path($path)` also omits `_is_non_diffable($path)`.
2. When a file has only a metadata change (`chmod`/`chown`), `changetrack-ng status` reports it and exits `1`, while `changetrack-ng diff` and `changetrack-ng diff <path>` output nothing.
3. `Runner::status()` (`lib/ChangeTrack/Runner.pm:1107`) skips `_is_non_diffable($ep)` before checking `$meta_changed`, hiding transitions where a tracked text file is replaced by a binary or unreadable file.

### FEAT-5: Version `.changetrack-metadata` in VCS and restore historical permissions/ownership on `revert` across all 5 backends (High) [Completed in Phase 3]

**Issue:** `.changetrack-metadata` is currently excluded from VCS commits (`lib/ChangeTrack/Runner.pm:812`) and written only after `$vcs->commit()` (`319-333`). As a result, metadata-only changes (`chmod`/`chown`) produce no VCS commit on any backend (invisible in `changetrack-ng log`), and `revert <path> <rev>` cannot restore the historical `mode`, `uid`, and `gid` recorded at `<rev>`.
- **Whole-repo backends (`Git`, `Fossil`, `SVN`, `Mercurial`):** Stage and commit `.changetrack-metadata` inside the VCS repository before `$vcs->commit()` (rolling back on commit failure), and extract `<rev>`'s `.changetrack-metadata` entry during `revert <path> <rev>` to restore historical `mode`, `uid`, and `gid` while keeping the VCS mirror at `HEAD`.
- **RCS (`per-file`):** Pass `-f` to `ci -l` in `RCS::checkin()` (`lib/ChangeTrack/VCS/RCS.pm:89`) when metadata changed so a revision is always created, and store/read per-revision metadata (`[meta: mode=... uid=... gid=...]`) so `RCS::revert()` restores historical permissions and ownership with full 5-backend parity.

### CONF-3: Replace `[global] ignore =` with `[ignore]` section, fix directory/subtree ignore pruning, and ship whole-`/etc` example (High) [Completed in Phases 1-2]

**Issue:**
1. Legacy `[global] ignore =` syntax is awkward for multi-line exclusions and cannot be bundled inside `track.d/*.conf` drop-ins (`lib/ChangeTrack/Config.pm:315`).
2. Directory and subtree ignore patterns (including `@BUILTIN_IGNORE` entries `lvm/cache`, `lvm/archive`, `network/run` at `lib/ChangeTrack/Runner.pm:136-137`) do not work because `_build_file_list()` (`734-748`) never tests `_should_ignore()` on directories and `_compile_ignore_patterns()` (`882-896`) anchors path patterns with `$` (`qr{(?:^|/)${re}$}`) with `*` as `[^/]*`.
3. `[ignore]` does not override explicit file entries in `[track]` (`684-701`), and deleted-file reconciliation (`764-793`) does not purge newly ignored paths from `.changetrack-metadata`.
- **Resolution:** Remove `[global] ignore` in `Config.pm` in favor of a line-oriented `[ignore]` section (allowed in main config, `conf.d/*.conf`, `track.d/*.conf`, and `@include*`). Ensure `[ignore]` unconditionally overrides `[track]` via early directory pruning (`$File::Find::prune = 1`) during traversal plus a unified post-filter across all candidate tracked paths and metadata reconciliation. Update `_compile_ignore_patterns()` to match directory subtrees (`(?:^|/)${re}(?:/|$)`), `[...]` character classes (superseding `DEBT-5`), and `**` globs. Ship a curated `packaging/etc/examples/track.d/etc-full.conf` example for whole-`/etc` tracking.

---

## Medium Priority - Features, CLI, Config & Notifications

### CORR-17: Report metadata changes on already-tracked `binary`, `unreadable`, and `special` files (Medium) [Completed in Phase 2]

**Issue:** In `Runner::_process_file()` (`lib/ChangeTrack/Runner.pm:427-438`), `$md->update_from_stat` mutates the in-memory metadata record before `_handle_non_trackable()` (`580-600`) returns early without calling `$report->add_change`. Subsequent `chmod`/`chown`/size changes on already-tracked non-trackable files overwrite `.changetrack-metadata` with zero report or notification.

### CORR-18: Normalize `SVN` and `Mercurial` revision strings in `revert` and fix `log` on directories and deleted files (Medium) [Part 1 Completed in Phase 3; Part 2 in Phase 4]

**Issue:**
1. `SVN::revert()` (`lib/ChangeTrack/VCS/SVN.pm:175`) rejects the leading `r` in `r2` revisions printed by `SVN::log_history()`; `Mercurial::revert()` (`lib/ChangeTrack/VCS/Mercurial.pm:153`) rejects `1:8f3a9b2c1d4e` changeset strings printed by `Mercurial::log_history()`.
2. `changetrack-ng log <dir>` fails on `Fossil` (`finfo` only accepts files) and `RCS`; no-arg `changetrack-ng log` (`lib/ChangeTrack/Runner.pm:1177-1188`) skips deleted files and spawns `O(N)` VCS subprocesses.

### FEAT-6: Non-destructive historical inspection (`show <path> <rev>`, `diff [path] [rev1] [rev2]`, `revert --dry-run`) across all 5 backends (Medium)

**Issue:** Operators cannot view a historical revision or compare two revisions without overwriting live files on disk, and `revert` ignores `--dry-run` (`bin/changetrack-ng:218-253`).
- Extend `diff [path] [rev1] [rev2]` across all 5 VCS backends (`0` revs = live vs `HEAD`; `1` rev = `<rev>` vs live; `2` revs = `<rev1>` vs `<rev2>`).
- Add `changetrack-ng show <path> <rev>` to print the historical content (or symlink target) and recorded metadata of `<path>` at `<rev>` to `STDOUT`.
- Honor `--dry-run` / `-n` in `revert` to preview the restoration without modifying disk.

### DEBT-15: Remove obsolete `update-ignore` subcommand (Medium)

**Issue:** `cmd_update_ignore` (`bin/changetrack-ng:256-328`) only supports `git`, writes an untracked `.gitignore` into `$output_dir`, and is functionally obsolete because Perl filters ignores during discovery and `Git::add()` uses `git add -f --`. Remove `update-ignore` from `bin/changetrack-ng`, `man/changetrack-ng.8`, `README.md`, `PRODUCT.md`, `ARCHITECTURE.md`, `AGENTS.md`, and `t/16-subcommands.t`.

### NOTIFY-3: Capture VCS revision IDs in `ChangeTrack::Report` and surface in all notification channels (Medium) [Completed in Phase 3]

**Issue:** `VCS::*::commit()`, `RCS::checkin()`, and `ChangeTrack::Report` do not record committed revision identifiers, so Email, Webhook, OTLP, and File notifications omit the revision ID needed for `diff` or `revert`. Capture the commit/revision ID across all 5 backends and emit it in `Report::to_text()`, Email, Webhook JSON, and `File`/`OTLP` attributes (`vcs.revision` / `config_change.revision`).

### NOTIFY-4: Fix per-track email recipient consistency on deleted files, multi-instance email deduplication, and `push_remote` warning propagation (Medium) [Completed in Phases 2-3]

**Issue:**
1. Deleted files in tracked directories (`lib/ChangeTrack/Runner.pm:775-793`) match only the single longest directory prefix (`last` at line 788), dropping parent-directory recipients that receive creation/modification alerts (`632-637`).
2. Multiple enabled `[notifier:email:*]` sections (`lib/ChangeTrack/Notify/Email.pm:73-74`) each send to `@track_recips`, duplicating per-track emails.
3. `push_remote` failures in `Git.pm:142`, `Fossil.pm:255`, and `Mercurial.pm:115` only `carp` to `STDERR` instead of adding a warning to `$report`, omitting `changetrack.run.warning` events and allowing false heartbeats.

### CONF-4: Add `max_file_size` guard and stricter `[track]` entry validation (Medium) [Completed in Phases 1-2]

**Issue:**
1. Large text/data files whose first 4 KB pass Perl's `-B` check (`lib/ChangeTrack/Metadata.pm:156-168`) are copied in full into `$output_dir` and `/tmp`, with their full unified diff buffered in memory. Add `[global]` `max_file_size` (default `10485760` / 10 MB, `0` = unlimited) to track oversized files as metadata-only with a one-time warning.
2. `Config.pm` (`509-565`) silently ignores unknown `key=value` options in `[track]`, fails to split comma-separated per-track recipients, and `Runner::_resolve_sensitive()` (`922-925`) ignores `sensitive=true`/`false`. Listing a directory in `[track]` without `DIRECTORY` fails with `Is a directory` during mirroring instead of being caught or handled cleanly.

---

## Medium Priority - Packaging, Hooks & Operational Reliability

### PKG-6: Fix DNF hook installation (DNF4 `pluginpath` + DNF5 `actions.d`) and Pacman defaults sourcing (Medium)

**Issue:**
1. `Makefile:286-290` and `packaging/rpm/changetrack-ng.spec:63-66` install `changetrack_ng.py` into `/etc/dnf/plugins/` (`pluginconfpath`), where DNF4 ignores `.py` files (expecting Python `site-packages/dnf-plugins/`), and Fedora 41+ / RHEL 10 use DNF5 (`libdnf5`), which requires an actions configuration (`/etc/dnf/libdnf5-plugins/actions.d/changetrack-ng.actions`).
2. `packaging/hooks/pacman-pre.hook:11` and `pacman-post.hook:11` invoke `@BINDIR@/changetrack-ng` directly without sourcing `/etc/default/changetrack-ng` or `/etc/sysconfig/changetrack-ng`.

### OPS-10: Add `--lock-timeout` CLI override and use it in package manager hooks (Medium)

**Issue:** Default `lock_timeout` is `0` (`etc/changetrack-ng.conf:56`). If an hourly cron/systemd scan holds the lock when `apt`, `dnf`, or `pacman` runs, the hook immediately skips and drops the pre/post package snapshot. Add `--lock-timeout <seconds>` to `bin/changetrack-ng` and pass `--lock-timeout 30` in package manager hooks.

### PKG-7: Fix `Makefile` `SYSCONFDIR`/`LOGROTATEDIR` defaults, `.deb` `dh_fixperms`, and `cmd_init` default VCS (Medium)

**Issue:**
1. `Makefile:7-18` defaults `PREFIX = /usr/local`, placing config in `/usr/local/etc/changetrack-ng/` and logrotate in `/usr/local/etc/logrotate.d/`, while `bin/changetrack-ng:73` hardcodes `/etc/changetrack-ng/changetrack-ng.conf`. Default `SYSCONFDIR ?= /etc` and `LOGROTATEDIR ?= /etc/logrotate.d`, and rewrite the default config path in `_install_bin` when `SYSCONFDIR` is overridden.
2. `packaging/debian/rules` lacks `override_dh_fixperms`, resetting `/etc/changetrack-ng/changetrack-ng.conf` to `0644` and `/var/lib/changetrack-ng` to `0755`.
3. When `vcs` is unset in config, `Runner::_setup()` (`lib/ChangeTrack/Runner.pm:1021`) defaults to `rcs` while `cmd_init` (`bin/changetrack-ng:146`) prints `git`. Align both to default to `git`.

### DOC-5: Fix broken `${HOSTNAME}` examples and reconcile documentation with codebase behavior (Medium)

**Issue:**
1. `README.md:159`, `man/changetrack-ng.conf.5:398`, and `docs/COOKBOOK.md:27, 66, 180` use `from = changetrack-ng@${HOSTNAME}`, which produces invalid addresses or croaks on startup in `Config.pm:352-356`. Support `${HOSTNAME}` alongside bare `HOSTNAME` in `Config.pm` and clean up docs.
2. Reconcile `PRODUCT.md` (`DIRECTORY` in `[track]` example, `compression` default), `etc/changetrack-ng.conf` and `packaging/etc/examples/*` (`sensitive_auto` bitmask `(mode & 0004) == 0`, `push_remote` backends, `conf.d` override comment, `interval` comment, `[ignore]` section), `ARCHITECTURE.md` (version, removed v1 stub, `RCS::revert` `co -p`, `status`/`diff` non-auto-init, foreign VCS dirs, `__CHANGETRACK_NG_SYMLINK_TARGET__` spelling, `.jsonl` path), `man/changetrack-ng.8` (`--force` and lock timeout exit codes), `man/changetrack-ng.conf.5` (NDJSON per-event File notifier), `INSTALL.md`, and `packaging/debian/control` (`Homepage` URL).

---

## Low Priority - Performance & Technical Debt

### PERF-6: Skip rewriting `.changetrack-metadata` when state is unchanged (Low) [Completed in Phase 2]

**Issue:** `Runner::run()` (`lib/ChangeTrack/Runner.pm:330-333`) rewrites `.changetrack-metadata` on every non-dry-run execution even when zero files or metadata records changed.

---

## Completed (2026-11-03)

- SEC-7: Prune foreign VCS control directories (`.git`, `.svn`, `.hg`, `RCS`, `CVS`, `_darcs`, `.bzr`) and Fossil checkout databases (`.fslckout`, `_FOSSIL_`) during file discovery in `Runner::_build_file_list()`, silently purge stale foreign VCS paths from `.changetrack-metadata`, and issue startup warnings if foreign VCS repositories are detected directly inside `$output_dir`.
- SEC-8: Mirror isolation protections against tracked VCS ignore and attribute files: enforce `git add -f --`, neutralize attributes via `$GIT_DIR/info/attributes` (`* !text !eol !ident !filter !diff`), `svn add --no-ignore`, `hg status -A` (matching untracked and ignored states), and `fossil add --force`.
- SEC-9: Bound `run_cmd` child stdin writes and handle close calls with `alarm` based on `timeout` in `ChangeTrack::Util`, ensuring processes that fail to read stdin or stall on write cannot block execution indefinitely.
- CORR-12: Acquire advisory run lock (`lock_timeout`, `force => 0`) in `Runner::revert_path()` to prevent concurrent `revert` invocations or racing with scheduled `run` executions.
- CORR-13: Sequence VCS file removal ahead of in-memory metadata removal in `Runner::_process_file()` and `_handle_non_trackable()` with rollback on failure, and expand SVN and Mercurial status checks in `remove()` (`!` status) to tolerate already-unlinked working copy files.
- OPS-9: Check `chmod` return value in `Runner::_enforce_output_permissions()` and emit an explicit warning if tightening output directory or repository permissions fails.
- DEBT-14: Consolidated `--debug` config dump loops and broadened sensitive key redaction via `Runner::_redacted_config_value()`; write `.gitignore` atomically via temporary file and rename with `0600` permissions in `changetrack-ng update-ignore`.

## Completed (2026-10-23)

- CORR-8: Made `diff()` and `is_dirty()` non-mutating across all 5 VCS backends (`Git`, `RCS`, `SVN`, `Mercurial`, `Fossil`) via `ChangeTrack::VCS::Base::_with_temp_mirror_sync()`, preventing read-only `status`, `diff`, and `run --dry-run` invocations from altering the VCS mirror or masking changes from subsequent runs.
- CORR-9: Fixed `ChangeTrack::VCS::RCS::revert()` to use `co -p<rev>` instead of `co -r<rev> -l`, preventing RCS lock corruption on subsequent check-ins, and routed `RCS::output_path()` through `_mirror_rel()` to reject `..` path traversal.
- CORR-10: Fixed `run`, `status`, and `diff` to capture unified diffs when a tracked non-empty file is truncated to 0 bytes, and updated `status` to report metadata-only changes (`chmod`/`chown`) with `(meta: ...)`.
- CORR-11: Fixed `Mercurial::log_history()`, `SVN::log_history()`, and `SVN::revert()` to support files that have been deleted from the working tree.
- OPS-7: Expanded `Runner::_internal_exclude_paths()` to automatically exclude the SVN repository directory (`$output_dir-svnrepo`), `lock_path`, and enabled `file` notifier log paths from self-tracking.
- OPS-8: Routed `Notify::Email::_send_one()` through `ChangeTrack::Util::run_cmd()` with `SIGPIPE` protection (`local $SIG{PIPE} = 'IGNORE'`) and applied `command_timeout` across all CLI subcommands (`status`, `diff`, `log`, `revert`, `init`).
- CONF-2: `conf.d/*.conf` drop-in files can now override scalar `[global]` keys (`vcs`, `output_dir`, `interval`, etc.) defined in the base config file while still rejecting conflicting definitions between multiple `conf.d/*.conf` drop-ins or duplicate keys within the same file.
- NOTIFY-2: Consolidated OpenTelemetry change-event normalization into `ChangeTrack::Notify::Base::_build_change_event()`, ensuring `Notify::File` and `Notify::OTLP` emit identical attributes and consistently emit the `'[diff suppressed - sensitive file; view via VCS log]'` placeholder when `sensitive_notify = suppress`.
- DEBT-12: Removed unused `config_keys()` and duplicate `_sleep()` methods from notifier classes, unused `parse_claude_md()` from `tools/doc-lint`, and redundant `install` rules from `packaging/debian/rules`.
- PERF-5: Cached `HEAD` existence in `ChangeTrack::VCS::Git` and removed redundant per-commit `crlf-glob` subprocess invocation in `ChangeTrack::VCS::Fossil::commit()`.
- PKG-5: Fixed `make install-user-systemd` in `Makefile` to strip the root-only `@DEFAULTSDIR@` `EnvironmentFile` directive and rewrite `--system` to `--user`.

## Completed (2026-10-08)

- SEC-6: Enforce private umask (`0077`) at initialization in `bin/changetrack-ng`, runtime inspection and auto-tightening of `$output_dir` and sibling repo stores to `0700`/`0600` with warning reporting in `Runner.pm`, and packaging directory permission `0700` in `Makefile` and RPM spec.
- CORR-6: Rollback of in-memory metadata records upon per-file exception in `Runner.pm`, sequence metadata sidecar save after VCS batch commit, and croak on VCS diff execution errors across Git, Mercurial, SVN, and Fossil backends.
- OPS-6: Made DNF package manager pre-transaction hook non-blocking (`required=False` in `packaging/hooks/dnf/changetrack_ng.py`) with stderr warning emission.
- NOTIFY-1: Propagated notifier delivery errors to `Runner` report warnings and added `vcs` and `message` accessors to `ChangeTrack::Report`.
- PKG-4: Substituted `@BINDIR@` and `@DEFAULTSDIR@` placeholders across Debian rules (`packaging/debian/rules`) and RPM spec (`packaging/rpm/changetrack-ng.spec`).
- TEST-9: Added notifier failure isolation and warning recording tests in `t/37-review-findings.t`.
- PERF-3: Lazy DNS evaluation for `HOSTNAME` token expansion in `ChangeTrack::Config::_load_file()`. Defers `_config_hostname()` until a config value matches `\bHOSTNAME\b`.
- CORR-7: Atomic temporary-file-and-rename for `restore_mirror_path()` in `ChangeTrack::Util`. Uses a sibling temporary file in the destination directory, copies to tempfile, preserves existing file mode and ownership, and atomically renames over destination. Cleans up tempfile on failure.
- DEBT-8: Pruned dead stubs (`Metadata::import_from_v1_statistics`, `Runner::_glob_match`) and deprecated/ignored `interval` config key with POD documentation.
- DOC-4: Reconciled developer and architecture documentation (`CLAUDE.md`, `ARCHITECTURE.md`, `man/changetrack-ng.8`, `man/changetrack-ng.conf.5`) with codebase reality: configurable `command_timeout` (default 120s), Fossil backend `--chdir` flag usage, Subversion backend absolute working-copy paths, private 0700 storage permissions, removal of v1 config auto-detection reference, and updated test suite count (1,043 tests across 36 files).
- DEBT-9: Deduplicated non-trackable file handling in `ChangeTrack::Runner::_process_file`. Extracted shared `_handle_non_trackable()` helper for `special`, `unreadable`, and `binary` file types while preserving warning, VCS removal staging, and report recording semantics.
- DEBT-10: Consolidate shared VCS backend methods in `VCS::Base` and modernize SVN backend. Hoisted `output_path`, `_rel_path`, `checkin`, and default `is_dirty` to `ChangeTrack::VCS::Base`, eliminated duplicate implementations across Git, Mercurial, Fossil, and SVN backends, removed dead eval wrapper from `Fossil::_run`, and modernized SVN backend to use absolute working-copy paths without process-wide `chdir`.
- PERF-4: Single-pass `lstat` and stat buffer propagation in `ChangeTrack::Metadata` and `ChangeTrack::Runner::_process_file`. Passed optional `$stat_ref` arrayref to `can_skip_content_diff()`, `changed_since_load()`, `update_from_stat()`, `diff_summary()`, and `_classify_file()` to eliminate redundant stat syscalls per tracked file.
- DEBT-11: Consolidate HTTP retry and backoff in `Notify::Base`. Hoisted `_http_post_with_retry` and fallback `_sleep` helper to `ChangeTrack::Notify::Base`, delegating HTTP POST dispatch and 3-attempt exponential backoff from `Webhook.pm` and `OTLP.pm` while preserving notifier-specific payload formatting, gzip compression, header resolution, and mockable `_sleep` hooks.

## Completed (2026-09-18)

- CORR-3: Reconcile vanished files in tracked directories (`DIRECTORY /path`) against recorded metadata sidecar in `_build_file_list()`, enqueuing them for removal processing.
- CORR-4: Implemented `remove($real_path)` across `ChangeTrack::VCS::Base` and all 5 backends (Git, SVN, Mercurial, Fossil, RCS), updating Runner to unlink mirror working copies and stage VCS deletions upon file removal.
- CORR-5: Handled bidirectional file type transitions (`file` ↔ `symlink`, `empty` ↔ `content`, trackable ↔ non-trackable): updated `can_skip_content_diff()` to verify disk state before skipping diffs, updated `changed_since_load()` and `diff_summary()` to detect and report type changes, and trigger new checkin or VCS removal accordingly.
- SEC-5: Insecure permission audit in `_warn_insecure_config_permissions()` now inspects all loaded configuration files returned by `ChangeTrack::Config->loaded_files` (including `conf.d/`, `notifier.d/`, `track.d/`, and `@include` files).
- OPS-5: Subcommand debug and trace propagation - CLI subcommands (`status`, `diff`, `log`, `revert`) in `bin/changetrack-ng` forward `--debug` and `--trace` flags into Runner and activate `run_cmd` debug tracing.
- TEST-10: Comprehensive test coverage for bidirectional file type transitions (`t/36-type-transitions.t`) and directory deletion reconciliation & VCS removals (`t/35-vcs-removal.t`).
- TEST-12: Added symlink capability probe to `t/03-metadata.t` to skip gracefully on restricted environments.
- TEST-13: Fixed `IO::Uncompress::Gunzip` require and error variable typos in `t/19-notify-otlp.t`.
- CONF-1: Config parser inline comment stripping (`#` or `;` preceded by whitespace), full-line `;` comment recognition, and sample config inline comment corrections (`t/34-config-inline-comments.t`).

## Completed (2026-05-06)

- TEST-11: Fixed `t/lib/ChangeTrack/Test/MockSendmail.pm` to derive `$VERSION` dynamically from `ChangeTrack::Version` instead of hardcoding.
- PERF-1: Cached `/etc/machine-id` read in `Notify/OTLP.pm::_resource_attrs()` using a `state` variable - eliminates redundant file I/O on every OTLP export call.
- PERF-2: Pass pre-computed mode integer from metadata record (`oct($rec->{mode})`) to `_resolve_sensitive()` - eliminates a redundant `stat()` syscall per tracked file.
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

## Code Quality / Technical Debt

### DEBT-5: `_glob_to_re()` doesn't handle character classes `[...]` (Low) [Completed in Phase 2]

**Issue:** The glob-to-regex converter in Runner handles `*`, `?`, and `.` but doesn't support `[abc]` character classes in ignore patterns. These are valid in shell globs. (Scheduled for resolution under `CONF-3` above.)

---

## Someday / Maybe

### DEBT-13: Remove legacy Windows (`MSWin32`) shims and test skip guards (Very Low)

**Issue:** Early development left behind scattered `$^O eq 'MSWin32'` branches, backslash path normalizations, and `MSWin32` test skip guards (e.g., `Metadata.pm`, `Runner.pm`, `t/30-run-cmd.t`). Because `changetrack-ng` is strictly a Unix/Linux system tool by design and is not intended to support Windows, these shims could eventually be pruned - very low priority, and we may not bother unless touching those areas anyway.

---

## Closed - Won't Fix

These items have been deliberately decided against. They remain here for historical context and to prevent re-opening without new justification.

### OPS-4: Lock polling retry uses `sleep(1)`

**Reason:** `lock_timeout` is typically `0` (skip immediately). For the rare non-zero case, 1s granularity over a handful of retries is acceptable. `select()`-based sub-second polling adds complexity with no practical benefit.

### DEBT-2: `eval "require $class"` pattern for dynamic loading

**Reason:** Class names come from the hardcoded `%NOTIFY_CLASSES` dispatch table in Runner.pm - not from user input. The trust boundary is explicit and static. A comment in Runner.pm documents this. `Module::Load` would add no safety benefit.

### FEAT-2: Per-track exclude patterns

**Reason:** Config schema expansion requiring parser, data structure, file-walk, and migration changes. Global `ignore` patterns cover the vast majority of cases. Deferred to v0.5+ if user demand materialises.

### FEAT-4: Real-time file deletion detection (inotify/fanotify)

**Reason:** changetrack-ng is a polling model by design. A persistent daemon with inotify would be a fundamentally different architecture. Out of scope; documented as a known limitation in the man page.

### PKG-2: zypper hook

**Reason:** zypper's plugin mechanism is significantly more complex than apt/dnf/pacman. openSUSE user base overlap is minimal. Will not be implemented unless contributed externally; dnf support ships and covers the RPM ecosystem.

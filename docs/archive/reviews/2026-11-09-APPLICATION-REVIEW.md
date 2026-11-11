# changetrack-ng Application & Architecture Review

- **Date:** 2026-11-09
- **Baseline:** v0.7.5 (`main`)
- **Companion plan:** [2026-11-09-IMPLEMENTATION-PLAN.md](../plans/2026-11-09-IMPLEMENTATION-PLAN.md)
- **Scope:** Full application review across documentation (`PRODUCT.md`, `ARCHITECTURE.md`, `README.md`, `INSTALL.md`, `docs/*`, `man/*`), historical context (`TODO.md`, `CHANGELOG.md`), CLI subcommands (`bin/changetrack-ng`), core orchestration (`Runner.pm`, `Config.pm`, `Metadata.pm`, `Report.pm`, `Util.pm`, `Lock.pm`), all 5 VCS backends (`Git`, `RCS`, `Fossil`, `SVN`, `Mercurial`), all 4 notifier backends (`Email`, `Webhook`, `OTLP`, `File`), and packaging/hooks (`Makefile`, `packaging/*`).

---

## 1. What Is Already Solid (Keep As-Is)

Several foundational design choices fit the purpose of `changetrack-ng` cleanly and do not warrant refactoring or feature churn:

- **Polling and hook-driven execution model:** Avoiding a persistent `inotify`/`fanotify` daemon keeps operational complexity and idle resource consumption at zero while fitting `systemd` timers, `cron`, and package-manager hooks naturally.
- **Subprocess execution and watchdog boundaries:** `ChangeTrack::Util::run_cmd` (`lib/ChangeTrack/Util.pm:221-386`) enforces list-form `IPC::Open3` execution without shell interpolation, non-blocking `IO::Select` output draining, `alarm`-bounded stdin writes, and a process-group watchdog (`command_timeout`, default 120s).
- **Fast-path stat scan and non-mutating inspection:** Single-pass `lstat` propagation in `ChangeTrack::Metadata` (`can_skip_content_diff`) skips unchanged files without file I/O or VCS invocations, and `ChangeTrack::VCS::Base::_with_temp_mirror_sync` (`lib/ChangeTrack/VCS/Base.pm:118-162`) ensures `status`, `diff`, and `run --dry-run` never mutate the VCS mirror.
- **Foreign VCS and mirror isolation:** `ChangeTrack::Runner::_build_file_list` (`lib/ChangeTrack/Runner.pm:734-755`) prunes nested `.git`, `.svn`, `.hg`, `CVS`, `.bzr`, and `_darcs` directories and skips Fossil checkout state files, while whole-repo backends neutralize tracked ignore and attribute files (`git add -f --`, `.git/info/attributes`, `svn add --no-ignore`, `hg status -A`, `fossil add --force`) so `changetrack-ng` coexists safely with `etckeeper` and application repositories.
- **OpenTelemetry event normalization and sensitivity model:** `ChangeTrack::Notify::Base::_build_change_event` (`lib/ChangeTrack/Notify/Base.pm:171-266`) provides a shared schema across the `File` and `OTLP` notifiers, and separating mode-based `sensitive_auto` detection (`(mode & 0004) == 0`) from `sensitive_notify` diff suppression is clear and predictable.

---

## 2. Worthwhile Feature & Design Improvements

### 2.1 Versioned Metadata in VCS & Full-Fidelity `revert` Across All 5 Backends

- **Current behavior:**
  - `.changetrack-metadata` is excluded from VCS tracking (`lib/ChangeTrack/Runner.pm:812`) and is written only after `$vcs->commit()` completes (`lib/ChangeTrack/Runner.pm:319-333`).
  - **Metadata-only changes create no VCS commit on any backend:** When only `chmod` or `chown` occurs on a file, whole-repo backends (`Git`, `Fossil`, `SVN`, `Mercurial`) copy identical file bytes into `$output_dir`, see no staged content diff in `commit()`, and return without committing. On `RCS`, `ChangeTrack::VCS::RCS::checkin` (`lib/ChangeTrack/VCS/RCS.pm:89`) runs `ci -l -m"$msg"` without `-f`; when file contents are unchanged, GNU `ci` prints `file unchanged; reverting to previous revision` and creates no revision. Consequently, `changetrack-ng log <path>` never shows permission or ownership changes.
  - **Metadata changes on binary, unreadable, and special files are silently dropped:** In `Runner::_process_file` (`lib/ChangeTrack/Runner.pm:427-438`), `$md->update_from_stat` updates the in-memory metadata record before `Runner::_handle_non_trackable` (`lib/ChangeTrack/Runner.pm:580-600`) returns early without calling `$report->add_change`. Permission, ownership, or size changes on already-tracked `binary`, `unreadable`, or `special` files overwrite `.changetrack-metadata` with zero report or notification.
  - **`revert` cannot restore historical permissions or ownership:** `Runner::revert_path` (`lib/ChangeTrack/Runner.pm:1214-1270`) only snapshots the current live file on disk before restoring file contents. If a change broke both permissions and content, `revert` restores the prior content while retaining the broken permissions.
- **Recommended design (preserving 5-backend parity):**
  - **Whole-repo backends (`Git`, `Fossil`, `SVN`, `Mercurial`):** Track `.changetrack-metadata` inside the VCS repository (write and stage `.changetrack-metadata` before `$vcs->commit()`, rolling back on commit failure). Metadata-only changes then produce a real VCS commit, and `revert <path> <rev>` can read the historical `.changetrack-metadata` entry from `<rev>` to restore the recorded `mode`, `uid`, and `gid` (including when restoring a deleted file).
  - **RCS (`per-file`):** Pass `-f` to `ci -l` in `RCS::checkin` (`lib/ChangeTrack/VCS/RCS.pm:89`) when metadata changed so a revision is always created, and record a structured metadata line in the RCS revision log (or track `.changetrack-metadata,v`) so `RCS::revert` can restore historical `mode`, `uid`, and `gid` for `<rev>`.
  - **Non-trackable files (`binary`, `unreadable`, `special`):** In `Runner::_handle_non_trackable` (`lib/ChangeTrack/Runner.pm:580-600`), check `$md->changed_since_load($real_path, $st)` on previously recorded entries and emit a metadata-change report entry when `mode`, `uid`, `gid`, `size`, or `mtime` changed.

### 2.2 Flexible Ignore Model & Curated Whole-`/etc` Example Profiles

- **Current behavior:**
  - **Directory and subtree ignore patterns do not work:** `@BUILTIN_IGNORE` (`lib/ChangeTrack/Runner.pm:136-137`) includes directory patterns (`lvm/cache`, `lvm/archive`, `network/run`), and tracking `DIRECTORY /etc` requires ignoring noisy subtrees (such as `/etc/letsencrypt`, `/etc/ssl/certs`, `/etc/pki`, `/etc/alternatives`). However, `Runner::_build_file_list` (`lib/ChangeTrack/Runner.pm:734-748`) only calls `_should_ignore` (`lib/ChangeTrack/Runner.pm:861-876`) on regular files and symlinks (`return unless -f $_ || -l $_` after returning early on directories at line 740). In addition, `_compile_ignore_patterns` (`lib/ChangeTrack/Runner.pm:882-896`) compiles any pattern containing `/` into `qr{(?:^|/)${re}$}` (anchored with `$` at the end of the file path, with `*` translated to `[^/]*`). As a result, `lvm/cache` or `/etc/letsencrypt` never matches `/etc/lvm/cache/.cache` or `/etc/letsencrypt/archive/example.com/cert1.pem`.
  - **Drop-ins in `track.d/` cannot bundle ignores:** `Config.pm` (`lib/ChangeTrack/Config.pm:315`) restricts `track.d/*.conf` to `[track]` sections only, so a drop-in that tracks `DIRECTORY /etc` cannot bundle its accompanying exclusions in the same file. (Note: `Config::_set_global_key` at `lib/ChangeTrack/Config.pm:400-404` already appends multiple `ignore = ...` lines in `[global]`, though documentation and comments describe `ignore` as a single line.)
  - **Deleted-file reconciliation ignores `_should_ignore`:** In `Runner::_build_file_list` (`lib/ChangeTrack/Runner.pm:764-793`), if a noisy path was tracked once before an ignore pattern was added for it and the file is later rotated or removed, it is still reported as removed because `_should_ignore` is not consulted during metadata reconciliation.
- **Recommended design (`CONF-3`):**
  1. **Replace `[global] ignore =` with a dedicated `[ignore]` section:** Remove the clunky `[global] ignore` key in `Config.pm` and introduce a line-oriented `[ignore]` section (one pattern or path per line, allowed in the main config, `conf.d/*.conf`, `track.d/*.conf`, and `@include*`).
  2. **`[ignore]` always overrides `[track]` (two-stage directory prune + post-filter):** During directory traversal in `File::Find`, prune matching directories early (`$File::Find::prune = 1`) so large ignored subtrees are never walked; then apply `_should_ignore` as a unified post-filter across the entire candidate tracked file list (including explicit `[track]` file entries) so `[ignore]` unconditionally wins on any overlap. Also silently purge newly ignored paths from `.changetrack-metadata` during reconciliation (matching foreign VCS path cleanup at `lib/ChangeTrack/Runner.pm:766-769`).
  3. **Fix directory/subtree pattern matching:** Update `_compile_ignore_patterns` (`lib/ChangeTrack/Runner.pm:882-896`) so path patterns match both the directory and any descendant path (`(?:^|/)${re}(?:/|$)`), and add `[...]` character class support (superseding `DEBT-5`) and `**` globs.
  4. **Whole-`/etc` example configuration:** Ship a curated example drop-in in `packaging/etc/examples/track.d/` showing how to track `DIRECTORY /etc` cleanly while ignoring high-churn/flapping paths (`letsencrypt/`, `ssl/certs/`, `pki/ca-trust/extracted/`, `alternatives/`, `mtab*`, `adjtime`, `ld.so.cache`, `udev/hwdb.bin`, `lvm/cache/`, `lvm/archive/`).

### 2.3 Non-Destructive Historical Inspection & Revision Ergonomics (All 5 Backends)

- **Current behavior:**
  - **No way to inspect or diff a historical revision without overwriting the live file:** `Runner::diff_path` (`lib/ChangeTrack/Runner.pm:1125-1165`) only compares live disk state against the latest commit (`HEAD`/tip). There is no `show <path> <rev>` or `diff <path> <rev1> [rev2]`, and `cmd_revert` (`bin/changetrack-ng:218-253`) ignores `--dry-run` (running `changetrack-ng --dry-run -f revert /etc/hosts <rev>` overwrites `/etc/hosts` on disk).
  - **Notifications omit revision IDs:** None of the VCS `commit()`/`checkin()` methods or `ChangeTrack::Report` (`lib/ChangeTrack/Report.pm`) capture the new commit hash or revision number. When an operator receives an Email, Webhook, OTLP, or File alert, they must log into the host and run `changetrack-ng log <path>` before they can run `revert`.
  - **Revision strings from `log` fail when passed directly to `revert` on SVN and Mercurial:**
    - `SVN::log_history` (`lib/ChangeTrack/VCS/SVN.pm:135`) prints `r2`, `r1`, but `SVN::revert` (`lib/ChangeTrack/VCS/SVN.pm:175`) invokes `svn cat -r $rev "$url\@$rev"`, which fails with `Syntax error in revision argument 'r2'` unless the leading `r` is stripped.
    - `Mercurial::log_history` (`lib/ChangeTrack/VCS/Mercurial.pm:141`) prints `changeset: 1:8f3a9b2c1d4e`, which `Mercurial::revert` (`lib/ChangeTrack/VCS/Mercurial.pm:153`) (`hg revert -r`) rejects as a revision range (`can't revert to multiple revisions`) unless split.
  - **No-arg `changetrack-ng log` hides deleted files and spawns `O(N)` VCS processes:** `Runner::log_path` (`lib/ChangeTrack/Runner.pm:1170-1190`) iterates current live files and skips `unless -e $ep || -l $ep` (line 1181), so operators cannot discover deleted files or their pre-deletion revisions via `changetrack-ng log`.
- **Recommended design:**
  - Support historical revision arguments in `diff` (`changetrack-ng diff [path] [rev1] [rev2]`), add `show` (or `revert --dry-run`) to inspect historical revisions without mutating live files across all 5 backends.
  - Capture the committed revision ID from `$vcs->commit` / `$vcs->checkin` into `ChangeTrack::Report` and surface it in text reports, Email bodies, Webhook JSON, and OTLP/File attributes (`vcs.revision` / `config_change.revision`).
  - Normalize `$rev` in `SVN::revert` (strip leading `r`) and `Mercurial::revert` (extract revision/node from `rev:node`) so revision tokens copied from `changetrack-ng log` work directly in `revert`.
  - Update no-arg `changetrack-ng log` to run a single repository-wide log on whole-repo backends (and iterate all `$output_dir/RCS/*,v` archives on RCS) so deleted files and batch commits are included.

### 2.4 Large-File Guard (`max_file_size`) & Stricter `[track]` Validation

- **Current behavior:**
  - **No file size limit before mirroring and in-memory diffing:** `Metadata::_classify_file` (`lib/ChangeTrack/Metadata.pm:156-168`) uses Perl's `-B` operator, which only inspects the first ~4 KB of a file. If a large text file (e.g., a 200 MB `.sql` dump, `.json` export, or uncompressed log) lands in a tracked directory, `Util::sync_mirror_path` (`lib/ChangeTrack/Util.pm:411`) copies the full file into `$output_dir`, `VCS::Base::_with_temp_mirror_sync` (`lib/ChangeTrack/VCS/Base.pm:135`) copies it a second time into `/tmp`, and `Util::run_cmd` (`lib/ChangeTrack/Util.pm:326`) + `Report.pm` (`lib/ChangeTrack/Report.pm:208`) buffer the entire unified diff in memory.
  - **Silent `[track]` misconfigurations:**
    - Listing a directory in `[track]` without the `DIRECTORY` prefix (e.g. `/etc/nginx` instead of `DIRECTORY /etc/nginx`) is parsed as `kind => 'file'` (`lib/ChangeTrack/Config.pm:519-520`), which fails on every run in `sync_mirror_path` (`Is a directory`) while tracking zero files inside `/etc/nginx`.
    - Unknown `[track]` `key=value` options (e.g. `sensitve=yes`) are silently ignored (`lib/ChangeTrack/Config.pm:556-558`), and `sensitive=true` / `sensitive=false` is silently ignored because `Runner::_resolve_sensitive` (`lib/ChangeTrack/Runner.pm:922-925`) only matches `/^(yes|1)$/i` and `/^(no|0)$/i` (falling back to `sensitive_auto`).
    - Comma-separated per-track emails (`: a@x.com,b@x.com`) are not split on commas in `Config::_parse_rest` (`lib/ChangeTrack/Config.pm:554`), unlike `[notifier:email] to` (`lib/ChangeTrack/Config.pm:373`).
- **Recommended design:**
  - Add a `[global]` `max_file_size` option (e.g., default `10485760` bytes / 10 MB, `0` = unlimited). Files exceeding `max_file_size` are handled as metadata-only (`oversize`, recording size, mode, uid/gid, and mtime with a one-time warning) without copying multi-megabyte files into the VCS mirror or diff buffer.
  - Validate `[track]` options in `Config.pm` with the same strictness as `[global]` (reject unknown option keys, accept standard booleans `true`/`false`/`on`/`off`/`yes`/`no`/`1`/`0` for `sensitive=`, split per-track recipients on `[\s,]+`), and either auto-promote or emit an explicit warning when a `[track]` file path is a directory on disk.

### 2.5 Removing `update-ignore` (`DEBT-15`)

- `cmd_update_ignore` (`bin/changetrack-ng:256-328`) only implements `git` (printing `"not yet supported"` for `fossil`, `svn`, and `hg`), writes an untracked `.gitignore` inside `$output_dir`, and has no operational effect because Perl filters ignore patterns before mirroring and `Git::add` (`lib/ChangeTrack/VCS/Git.pm:96`) passes `git add -f --`. Removing `update-ignore` from the CLI dispatch table, documentation, and tests eliminates dead code and a 5-backend parity inconsistency.

---

## 3. Concrete Bugs & Operational Traps

1. **`revert` clobbers file permissions (`0777` on symlink-to-file; `0600` on deleted file; missing parent directory crash):**
   - **Symlink-to-file `0777` bug:** When the current live path on disk is a symlink, `Runner::_snapshot_existing_file` (`lib/ChangeTrack/Runner.pm:1231-1244`) captures `lstat` mode `0777`. When `revert` restores a revision where that path was a regular file, `Runner::_restore_file_metadata` (`lib/ChangeTrack/Runner.pm:1252-1270`) checks only whether the post-revert file is a regular file (`if (-l _ || !-f _)`), ignores `$pre->{is_symlink}`, and executes `chmod(0777, $path)` (`lib/ChangeTrack/Runner.pm:1263`), making the restored file world-writable.
   - **Deleted-file `0600` bug:** When restoring a deleted file, `$pre` is `undef` and `Util::restore_mirror_path` (`lib/ChangeTrack/Util.pm:438-469`) falls back to the mirror file's permissions (`0600 root:root` due to `umask(0077)` at `bin/changetrack-ng:24`). Restoring a deleted `/etc/hosts` or `/etc/resolv.conf` leaves it `0600`.
   - **Missing parent directory crash:** If a deleted file's parent directory was also removed, `Util::restore_mirror_path` (`lib/ChangeTrack/Util.pm:428`) (`tempfile(DIR => $dir)`) croaks instead of calling `make_path($dir)` (and `RCS::revert` at `lib/ChangeTrack/VCS/RCS.pm:153` and `Fossil::revert` at `lib/ChangeTrack/VCS/Fossil.pm:295` also omit `make_path(dirname($mirror))`).
   - **Spurious warning on symlink revert:** Whenever an existing symlink is reverted, `Runner::_restore_file_metadata` (`lib/ChangeTrack/Runner.pm:1258-1260`) emits `[WARN] revert metadata restore skipped (not a regular file)`.

2. **CLI `Getopt::Long` `pass_through` silently ignores flags and extra arguments after the subcommand (`bin/changetrack-ng:17, 99-111`):**
   - Because `pass_through` is enabled and line 99 only checks whether `$subcommand` starts with `-`, any unrecognized flag placed after the subcommand is left in `@ARGV` and silently ignored by `run`, `init`, `status`, and `update-ignore`.
   - `changetrack-ng run --dryrun` (typo) silently executes a real mutating run; `changetrack-ng status /etc/hosts` silently ignores `/etc/hosts` and scans all files; `changetrack-ng diff --help` treats `--help` as a file path.

3. **`diff` on a tracked directory crashes; `diff` on metadata-only changes prints nothing (`lib/ChangeTrack/Runner.pm:1125-1165`):**
   - Running `changetrack-ng diff /etc/nginx` passes `/etc/nginx` directly to `$vcs->diff`, where `VCS::Base::_with_temp_mirror_sync` (`lib/ChangeTrack/VCS/Base.pm:135`) calls `File::Copy::copy` on `$output_dir/etc/nginx` and dies with `Failed to backup ...: Is a directory` (`log <dir>` similarly fails on `Fossil` and `RCS`).
   - When a file has only a `chmod`/`chown` change, `changetrack-ng status` reports it and exits `1`, but `changetrack-ng diff` and `changetrack-ng diff <path>` output nothing because `diff_path` never checks `$md->changed_since_load`.
   - In `Runner::status` (`lib/ChangeTrack/Runner.pm:1107`), `next if $self->_is_non_diffable($ep)` runs before checking `$meta_changed`, so a tracked text file replaced by a binary or unreadable file (which `run` stages for VCS removal) is invisible to `status`.

4. **Per-track email recipient bugs on deleted files & multiple email notifiers:**
   - For live files, `Runner::_merge_file_entry` (`lib/ChangeTrack/Runner.pm:632-637`) unions recipients across overlapping `DIRECTORY` entries, whereas for deleted files `Runner::_build_file_list` (`lib/ChangeTrack/Runner.pm:775-793`) stops at the single longest directory prefix (`last` at line 788), dropping parent-directory recipients from deletion notifications.
   - In `Notify::Email::send_changes` (`lib/ChangeTrack/Notify/Email.pm:73-74`), per-track `@track_recips` override `$self->{to}` in every enabled `[notifier:email:*]` instance, sending duplicate emails when more than one email notifier is enabled.

5. **`push_remote` failures do not record report warnings or suppress heartbeats (`lib/ChangeTrack/VCS/Git.pm:142`, `lib/ChangeTrack/VCS/Fossil.pm:255`, `lib/ChangeTrack/VCS/Mercurial.pm:115`):**
   - Failed `git push` / `fossil push` / `hg push` calls only `carp` to `STDERR` (redirected to `/dev/null` by cron and hooks) instead of recording a warning on `$report`. Off-host backup failures emit no `changetrack.run.warning` event in `File`/`OTLP` and still report a healthy heartbeat.

6. **Packaging, `make install`, and hook issues:**
   - **DNF hook path (`Makefile:286-290`, `packaging/rpm/changetrack-ng.spec:63-66`):** Installs `changetrack_ng.py` to `/etc/dnf/plugins/changetrack_ng.py`. DNF4 only reads `.conf` files from `/etc/dnf/plugins/` (`pluginconfpath`) and loads `.py` plugins from Python's `site-packages/dnf-plugins/` (`pluginpath`); additionally, Fedora 41+ and RHEL 10 use DNF5 (`libdnf5`), which ignores Python DNF4 plugins.
   - **Package hook lock contention (`lock_timeout = 0`):** Because default `lock_timeout = 0` (`etc/changetrack-ng.conf:56`) and there is no `--lock-timeout` CLI flag, if an hourly timer scan holds the lock when `apt`, `dnf`, or `pacman` runs, the hook immediately skips and drops the pre/post-transaction snapshot.
   - **Pacman hooks ignore defaults file (`packaging/hooks/pacman-pre.hook:11`, `packaging/hooks/pacman-post.hook:11`):** Invoke `@BINDIR@/changetrack-ng` directly without sourcing `/etc/default/changetrack-ng`.
   - **`.deb` `dh_fixperms` resets `0640`/`0700` (`packaging/debian/rules`):** Without an `override_dh_fixperms` target, `dh_fixperms` resets `/etc/changetrack-ng/changetrack-ng.conf` from `0640` to `0644` and `/var/lib/changetrack-ng` from `0700` to `0755` (causing the first run after package install to emit a `[WARN] Tightened insecure permissions` event, suppressing the first run's heartbeat).
   - **`make install` default `PREFIX=/usr/local` mismatch (`Makefile:7-18, 148-151` vs `bin/changetrack-ng:73`):** `sudo make install` places the config in `/usr/local/etc/changetrack-ng/changetrack-ng.conf` and the logrotate policy in `/usr/local/etc/logrotate.d/changetrack-ng` (ignored by system `logrotate`), while `_install_bin` leaves `/etc/changetrack-ng/changetrack-ng.conf` hardcoded in `bin/changetrack-ng`.
   - **Unconditional `.changetrack-metadata` rewrite (`lib/ChangeTrack/Runner.pm:330-333`):** Every non-dry-run execution rewrites `.changetrack-metadata` via tempfile+rename even when zero files or metadata changed.
   - **`cmd_init` vs `Runner` default VCS mismatch (`bin/changetrack-ng:146` vs `lib/ChangeTrack/Runner.pm:1021`):** When `vcs` is omitted from config, `Runner` initializes `rcs` (`$output_dir/RCS`), while `cmd_init` prints `"Initialized git repository"`.

---

## 4. Documentation vs. Code Discrepancies

- **Broken `${HOSTNAME}` syntax in email examples (`README.md:159`, `man/changetrack-ng.conf.5:398`, `docs/COOKBOOK.md:27, 66, 180`):** All three use `from = changetrack-ng@${HOSTNAME}`. In `Config.pm:352-356`, `\bHOSTNAME\b` is substituted before `\$\{...\}` env-var expansion: if `fqdn()` has a dot (`host.example.com`), it produces literal `changetrack-ng@${host.example.com}`; if `fqdn()` has no dot (`localhost`), `_expand_env_vars` looks up `$ENV{localhost}` and fatally croaks on startup.
- **Missing `DIRECTORY` keyword in `PRODUCT.md:68-72`:** The `[track]` example lists `/etc`, `/usr/local/etc`, and `/var/spool/cron` without `DIRECTORY`, which fails on every run.
- **`sensitive_auto` bitmask comment in configs (`etc/changetrack-ng.conf:67`, `packaging/etc/examples/changetrack-ng.conf-default:67`, `packaging/etc/examples/changetrack-ng.conf-full:90-91`):** Comments state `lacks group+world read` / `(mode & 0044 == 0)`, whereas `Runner.pm:936` tests `(mode & 0004) == 0` (lacks world read).
- **OTLP `compression` default (`man/changetrack-ng.conf.5:296`, `packaging/etc/examples/changetrack-ng.conf-full:217`, `PRODUCT.md:116`):** State `compression` defaults to `gzip`, whereas `Notify::OTLP::new` (`lib/ChangeTrack/Notify/OTLP.pm:45`) defaults `$self->{compression} //= ''` (uncompressed).
- **`push_remote` SVN claim (`etc/changetrack-ng.conf:37`, `packaging/etc/examples/changetrack-ng.conf-default:37`, `packaging/etc/examples/changetrack-ng.conf-full:52`, `man/changetrack-ng.conf.5:98`):** List `svn` under `push_remote`, which `SVN.pm` (`lib/ChangeTrack/VCS/SVN.pm:108`) does not implement.
- **Stale statements in `ARCHITECTURE.md`, `man/changetrack-ng.8`, `man/changetrack-ng.conf.5`, `INSTALL.md`, and `packaging/debian/control`:**
  - `ARCHITECTURE.md`: Lists version `0.7.3` (lines 6, 81, 402), says `Metadata::import_from_v1_statistics` exists as a stub (line 351, removed in `DEBT-8`), says `RCS::revert` uses `co -r` instead of `co -p` (line 211), says `status`/`diff` auto-initialize VCS (line 359, they croak at `Runner.pm:1037`), lists `RCS` among pruned foreign VCS dirs (line 106, also `man/changetrack-ng.conf.5:125`), spells `__CHANGTRACK_NG_SYMLINK_TARGET__=` missing an `E` (line 136, also `Util.pm:84` and `AGENTS.md:111`), and lists `/var/log/changetrack-ng.log` instead of `.jsonl` (line 336).
  - `man/changetrack-ng.8:104-105` and `bin/changetrack-ng:489-490`: State `--force` does not affect the run lock, whereas `Runner::run` passes `force => $opts{force}` into `Lock` (forcing blocking acquisition), and line 142 states lock timeout exits `0` when `Lock::acquire` (`lib/ChangeTrack/Lock.pm:119`) actually croaks (exiting `2` on `run` and `1` on `revert`).
  - `man/changetrack-ng.conf.5:350`: States the File notifier `"Appends one JSON object per run"` rather than one NDJSON event per change/heartbeat/warning.
  - `INSTALL.md`: Line 26 says `sudo make install` installs `/etc/logrotate.d/changetrack-ng`; line 58 says `changetrack-ng.conf-user` sets `lock_path`; line 129 advises checking for stale `flock` files after crashes.
  - `packaging/etc/examples/conf.d/local-settings.conf:10-11`: States scalar keys in `conf.d/` cannot override the main config (changed in `CONF-2`).
  - `packaging/etc/examples/changetrack-ng.conf-user:34-35`: Claims `interval = 3600` is read by `make install-user-systemd` / `install-user-cron`.
  - `packaging/debian/control:8`: Uses `https://github.com/changetrack-ng/changetrack-ng` instead of `https://github.com/cashell/changetrack-ng`.

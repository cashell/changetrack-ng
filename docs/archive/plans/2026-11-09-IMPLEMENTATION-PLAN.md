# changetrack-ng Phased Implementation Plan

- **Date:** 2026-11-09
- **Baseline:** v0.7.5 (`main`)
- **Source Review:** [2026-11-09-APPLICATION-REVIEW.md](../reviews/2026-11-09-APPLICATION-REVIEW.md)
- **Tracking Ledger:** [TODO.md](../../../TODO.md)

---

## 1. Execution & Orchestration Model

This plan is structured for an **Orchestrator + Subagent** workflow:

- **Orchestrator (Lead Model):** Manages branch/worktree lifecycles, spawns subagents with isolated git worktrees (`Workspace: "branch"` or `"share"`), reviews subagent diffs against repository guardrails, resolves cross-worktree integration, runs phase-gate test suites (`make dev-check && make test`), and prepares PRs.
- **Worker Subagents (Gemini 3.8 Flash / Claude Sonnet 5.5):** Execute bounded, self-contained **Work-Packages (WPs)** with explicit file ownership, concrete method contracts, and targeted test suites.
- **Collision Prevention:** Within each phase, parallel work-packages touch **disjoint file sets** wherever possible. Where two work-packages in the same phase touch a shared file (such as `lib/ChangeTrack/Runner.pm`), the dependency order (`Sequential after WP ...`) is explicitly marked so the orchestrator runs or merges them in sequence.
- **Feature Branch & Checkpoint Commits:** Work is executed on a feature branch off `origin/main` and committed after each appropriate checkpoint (work-package and phase), overriding the default `AGENTS.md` VCS restriction once confirmed by the user.
- **Pre-Flight Branch Note:** Before spawning Phase 1 subagents, ensure a clean feature branch is checked out from the latest `origin/main` (carrying over `TODO.md`, `MANIFEST.toml`, `docs/archive/reviews/2026-11-09-APPLICATION-REVIEW.md`, and this plan file, then committing the baseline planning docs so subagent worktrees branched from `HEAD` inherit them).

### Standing Guardrails for Every Subagent Prompt

Every subagent invocation must include these constraints:
1. **Zero non-core Perl runtime dependencies** (Perl 5.20+ core only; no subroutine signatures, bareword filehandles, or 2-arg `open`).
2. **All external commands via `ChangeTrack::Util::run_cmd()`** (list-form `IPC::Open3` only; never shell interpolation; no process-global `chdir()`).
3. **Full 5-VCS backend parity** (`Git`, `RCS`, `Fossil`, `SVN`, `Mercurial`).
4. **Config identity invariant:** `etc/changetrack-ng.conf` and `packaging/etc/examples/changetrack-ng.conf-default` must remain byte-identical (`make config-lint`).
5. **Manifest invariant:** Any created or deleted file must be updated in `MANIFEST.toml` in the same change (`make dev-check`).
6. **Subcommand sync invariant:** Any change to CLI subcommands must update all 7 locations checked by `tools/doc-lint` (`bin/changetrack-ng` `%dispatch`, header comment, `_usage`, inline POD, `man/changetrack-ng.8`, `AGENTS.md`, and `README.md`).
7. **Comment & prose style:** Follow `AGENTS.md` comment header/divider conventions (`72` `#` marks, ASCII only, **never use em dashes** anywhere in comments, strings, POD, or markdown).

---

## 2. Phase Overview & TODO Mapping

| Phase | Work-Packages | TODO IDs | Status | Summary |
|---|---|---|---|---|
| **Phase 1** | WP 1A, WP 1B | `CONF-3`, `CONF-4`, `DOC-5` (partial) | Completed | Config parser overhaul: replace `[global] ignore =` with `[ignore]` section, add `max_file_size`, strict `[track]` option validation, `${HOSTNAME}` support, update all configs/fixtures, add `etc-full.conf` example |
| **Phase 2** | WP 2A, WP 2B | `CONF-3`, `DEBT-5`, `CONF-4`, `CORR-17`, `NOTIFY-4` (partial), `PERF-6` | Completed | Runner & Metadata engine: two-stage directory-prune + post-filter ignore engine (`[ignore]` overrides `[track]`), `[...]` and `**` globs, `max_file_size` classification, non-trackable metadata reporting, dirty-only metadata save, email recipient fixes |
| **Phase 3** | WP 3A, WP 3B, WP 3C | `FEAT-5`, `CORR-14`, `CORR-18` (partial), `NOTIFY-3`, `NOTIFY-4` (partial) | Completed | Versioned `.changetrack-metadata` in VCS across all 5 backends, full-fidelity historical `revert` (`mode`/`uid`/`gid`, parent dirs, clean `HEAD` mirror, `0777`/`0600` fixes), revision IDs in `Report` and all notifiers, `push_remote` report warnings |
| **Phase 4** | WP 4A, WP 4B | `CORR-15`, `CORR-16`, `CORR-18`, `FEAT-6`, `DEBT-15`, `OPS-10` (CLI), `PKG-7` (VCS default) | Pending | CLI hardening & historical inspection: reject unknown post-subcommand flags/args, add `show <path> <rev>`, extend `diff [path] [rev1] [rev2]`, add `revert --dry-run`, add `--lock-timeout`, fix `diff`/`log` on directories and deleted files, remove `update-ignore` |
| **Phase 5** | WP 5A, WP 5B | `PKG-6`, `PKG-7`, `OPS-10` (hooks), `DOC-5` | Pending | Packaging, hooks, and documentation sweep: DNF4 `pluginpath` + DNF5 `actions.d`, Pacman defaults sourcing, hook `--lock-timeout 30`, `Makefile` `SYSCONFDIR=/etc`, `.deb` `override_dh_fixperms`, full documentation reconciliation, `CHANGELOG.md` |

---

## Phase 1: Configuration Schema Overhaul (`CONF-3`, `CONF-4`, `DOC-5`)

**Why first:** Replacing `[global] ignore =` with a dedicated `[ignore]` section modifies the configuration grammar used by example configs and test fixtures. Landing Phase 1 first gives all subsequent phases a clean, stable configuration contract.

### WP 1A: `ChangeTrack::Config` Parser (`[ignore]`, `max_file_size`, `[track]` Validation, `${HOSTNAME}`)
- **TODO IDs:** `CONF-3`, `CONF-4`, `DOC-5` (partial)
- **Execution Mode:** Parallel with WP 1B (disjoint files)
- **Owned Files:**
  - `lib/ChangeTrack/Config.pm`
  - `t/01-config-v2.t`
  - `t/02-config-dropin.t`
  - `t/34-config-inline-comments.t`
  - `t/fixtures/config-v2-basic.ini`
  - `t/fixtures/config-v2-full.ini`
- **Implementation Specifications:**
  1. **Remove `[global] ignore =` and add `[ignore]` section (`CONF-3`):**
     - Remove `'ignore'` from `%KNOWN_GLOBAL_KEYS` and `%ARRAY_GLOBAL_KEYS` in `lib/ChangeTrack/Config.pm`. If `$section eq 'global'` encounters `key eq 'ignore'`, croak with an actionable message: `"Config error in $path line $lineno: 'ignore' in [global] is no longer supported; use an [ignore] section instead"`.
     - In `_load_file()`, recognize `[ignore]` as a valid section header (`elsif ($hdr eq 'ignore')`).
     - Update `_check_section_allowed()` and `_include_restrict()`:
       - Files in `track.d/*.conf` (or included via `@include-track`) may contain both `[track]` and `[ignore]` sections so a drop-in file can bundle its tracked paths and exclusions together.
       - Also support `@include-ignore <path>` (restricting to `[ignore]` only) and an optional sibling `ignore.d/*.conf` drop-in directory in `load()` (scanned right after `track.d/`).
     - Inside `$section eq 'ignore'`, parse each non-empty, non-comment line by:
       - Stripping inline comments via `_strip_inline_comment($line)`.
       - Trimming leading/trailing whitespace.
       - Expanding `HOSTNAME`/`${HOSTNAME}`, `${VAR}`, and leading `~` (`_expand_home_path`).
       - Appending the pattern to `@{ $self->{ignore} }` (deduplicating exact string matches while preserving first-seen order).
     - Add `$cfg->ignore()` accessor returning `$self->{ignore} // []`.
  2. **Add `max_file_size` global key (`CONF-4`):**
     - Add `max_file_size => 1` to `%KNOWN_GLOBAL_KEYS` and `%INT_GLOBAL_KEYS` in `lib/ChangeTrack/Config.pm` (validated as a non-negative integer; `0` means unlimited; default `10485760` applied by `Runner`).
  3. **Support `${HOSTNAME}` alongside `HOSTNAME` (`DOC-5`):**
     - In `_load_file()` (and `_parse_and_add_track()` / `[ignore]` line expansion), replace both `\$\{HOSTNAME\}` and `\bHOSTNAME\b` with `$resolve_hostname->()` *before* calling `_expand_env_vars()` so `changetrack-ng@${HOSTNAME}` expands to the system FQDN without triggering an undefined `$ENV{HOSTNAME}` or invalid `${fqdn}` error.
  4. **Strict `[track]` entry validation (`CONF-4`):**
     - In `_parse_rest()` (`lib/ChangeTrack/Config.pm:538-565`):
       - Split email recipients (before option tokens) on `[\s,]+` instead of `\s+` so comma-separated addresses (`: a@example.com, b@example.com`) work identically to `[notifier:email] to`.
       - Validate `key=value` tokens against `%KNOWN_TRACK_OPTIONS = (sensitive => 1)`. Croak with `"Config error in $path line $lineno: unknown [track] option '$k'"` on unknown option keys.
       - For `sensitive=<v>`, accept `'auto'` (case-insensitive) or any boolean literal accepted by `_parse_bool()` (`true`/`false`/`yes`/`no`/`on`/`off`/`1`/`0`), normalizing the stored value in `$opts{sensitive}` to `'yes'`, `'no'`, or `'auto'`. Croak on invalid values.
  5. **Update POD & Unit Tests:**
     - Update POD in `lib/ChangeTrack/Config.pm` to document `[ignore]`, `$cfg->ignore`, `max_file_size`, and `[track]` validation.
     - Update `t/fixtures/config-v2-*.ini`, `t/01-config-v2.t`, `t/02-config-dropin.t`, and `t/34-config-inline-comments.t` to test `[ignore]` sections, `track.d/*.conf` with `[ignore]`, rejection of legacy `[global] ignore =`, `max_file_size`, `${HOSTNAME}`, comma-separated `[track]` recipients, `sensitive=true/false`, and rejection of unknown `[track]` option keys.
- **Validation:** `prove -l t/01-config-v2.t t/02-config-dropin.t t/34-config-inline-comments.t`

### WP 1B: Default/Example Configurations, Whole-`/etc` Example Drop-In & Remaining Test Configs
- **TODO IDs:** `CONF-3`, `CONF-4`, `DOC-5` (partial)
- **Execution Mode:** Parallel with WP 1A (disjoint files)
- **Owned Files:**
  - `etc/changetrack-ng.conf`
  - `packaging/etc/examples/changetrack-ng.conf-default`
  - `packaging/etc/examples/changetrack-ng.conf-full`
  - `packaging/etc/examples/changetrack-ng.conf-minimal`
  - `packaging/etc/examples/changetrack-ng.conf-user`
  - `packaging/etc/examples/conf.d/local-settings.conf`
  - `packaging/etc/examples/track.d/system-core.conf`
  - `packaging/etc/examples/track.d/etc-full.conf` (new file)
  - `Makefile` (`_install_examples` target only)
  - `MANIFEST.toml` (entry for `packaging/etc/examples/track.d/etc-full.conf`)
  - Any test files outside `t/01*`, `t/02*`, `t/34*` that contain `ignore =` in `[global]` (grep `^\s*ignore\s*=` across `t/`)
- **Implementation Specifications:**
  1. **Update `etc/changetrack-ng.conf` and `packaging/etc/examples/changetrack-ng.conf-default` (keep byte-identical):**
     - Remove `ignore =` from `[global]` and add an `[ignore]` section above `[track]` with clear comments explaining one-pattern-per-line syntax, directory/subtree matching, and built-in defaults.
     - Add `# max_file_size = 10485760` under `[global]` with a comment explaining that files above this byte limit (default 10 MB; `0` = unlimited) are tracked as metadata-only.
     - Fix the `sensitive_auto` comment from `(lacks group+world read = sensitive)` to `(lacks world read, i.e. (mode & 0004) == 0)`.
     - Fix the `push_remote` comment from `(git, fossil, svn, hg)` to `(git, fossil, hg)`.
  2. **Update `-full`, `-minimal`, `-user`, and `conf.d/local-settings.conf`:**
     - Convert `ignore =` in `[global]` to `[ignore]` sections.
     - Document `max_file_size` in `changetrack-ng.conf-full`.
     - Fix the `sensitive_auto` bitmask comment (`0004`, not `0044`), `push_remote` backend list, `compression` default comment in `changetrack-ng.conf-full`, `conf.d` scalar override comment in `conf.d/local-settings.conf`, and `interval` comment in `changetrack-ng.conf-user`.
  3. **Add `packaging/etc/examples/track.d/etc-full.conf` (`CONF-3`):**
     - Create a well-commented example drop-in showing how to track `DIRECTORY /etc` with an accompanying `[ignore]` section that excludes noisy/flapping subtrees and runtime files (`letsencrypt/`, `ssl/certs/`, `pki/ca-trust/extracted/`, `alternatives/`, `ld.so.cache`, `mtab*`, `adjtime`, `resolv.conf`, `udev/hwdb.bin`, `lvm/cache/`, `lvm/archive/`, `network/run/`, `cups/subscriptions.conf*`, `.pwd.lock`, `nologin`).
     - Register `packaging/etc/examples/track.d/etc-full.conf` in `Makefile` (`_install_examples`) and `MANIFEST.toml`.
  4. **Migrate any remaining `t/*.t` inline configs from `[global] ignore =` to `[ignore]`:**
     - Grep `ignore\s*=` across `t/` (such as `t/11-ignore.t`, `t/16-subcommands.t`, etc.) and update those test configs to use `[ignore]` sections.
- **Validation:** `make config-lint`

---

## Phase 2: Core Engine Overhaul - Ignore Pruning, `max_file_size`, Metadata & Recipient Fixes (`CONF-3`, `DEBT-5`, `CONF-4`, `CORR-17`, `NOTIFY-4`, `PERF-6`)

### WP 2A: `ChangeTrack::Metadata` (`max_file_size` & Dirty Tracking) and `ChangeTrack::Notify::Email`
- **TODO IDs:** `CONF-4` (partial), `PERF-6` (partial), `NOTIFY-4` (partial)
- **Execution Mode:** Parallel with WP 2B (disjoint files)
- **Owned Files:**
  - `lib/ChangeTrack/Metadata.pm`
  - `lib/ChangeTrack/Notify/Email.pm`
  - `t/03-metadata.t`
  - `t/07-notify-email.t`
- **Implementation Specifications:**
  1. **`oversize` classification in `lib/ChangeTrack/Metadata.pm` (`CONF-4`):**
     - Extend `_classify_file($path, $stat_ref, $max_file_size)` and `update_from_stat($self, $path, $stat_ref, $max_file_size)`:
       - After checking `!S_ISREG($mode)`, `!-r $path`, and `$size == 0` (`empty`), if `defined $max_file_size && $max_file_size > 0 && $size > $max_file_size`, return `'oversize'` immediately (before `-B $path`, avoiding file I/O on huge files).
     - Include `'oversize'` alongside `'binary'`, `'unreadable'`, and `'special'` in `can_skip_content_diff` / `changed_since_load` / `diff_summary` handling so metadata changes (`mode`, `uid`, `gid`, `size`, `mtime`) and type transitions (`file <-> oversize`) are detected identically to `binary`.
  2. **Dirty tracking in `lib/ChangeTrack/Metadata.pm` (`PERF-6`):**
     - Initialize `$self->{dirty} = 0` in `new()` and `load()` (set `$self->{dirty} = 1` in `load()` only if `!-f $self->{path}`).
     - In `update_from_stat()`: compare the newly computed record fields (`type`, `mode`, `uid`, `gid`, `user`, `group`, `mtime`, `size`, `target`) against the existing record in `$self->{records}{$path}`; set `$self->{dirty} = 1` only if the record did not exist or any field changed.
     - In `mark_removed($path)`: set `$self->{dirty} = 1` if `exists $self->{records}{$path}` before deleting.
     - In `rollback_path($path)`: restore the snapshot and recalculate or preserve `$self->{dirty}`.
     -In `save()`: reset `$self->{dirty} = 0` after atomic `rename` succeeds.
     - Add `is_dirty($self)` accessor returning `$self->{dirty} ? 1 : 0`.
  3. **Prevent duplicate per-track emails across multiple `[notifier:email:*]` instances (`NOTIFY-4`):**
     - In `lib/ChangeTrack/Notify/Email.pm` (`send_changes`, lines 66-78): accept constructor option `use_track_recipients` (default `1`). When multiple email notifier instances are configured, `Runner::_dispatch_notifiers` can pass `use_track_recipients => 1` only to the first enabled email notifier (or only when `$inst->{instance_name} eq 'default'`), while secondary email notifier instances always send to their configured `$self->{to}` list instead of duplicating per-track override emails.
  4. **Tests:**
     - Add unit tests in `t/03-metadata.t` for `oversize` classification, `file <-> oversize` transitions, and `is_dirty` state transitions.
     - Add unit tests in `t/07-notify-email.t` verifying multi-instance email behavior with per-track recipients.
- **Validation:** `prove -l t/03-metadata.t t/07-notify-email.t`

### WP 2B: `ChangeTrack::Runner` Ignore Engine, Directory Pruning, `max_file_size` & Non-Trackable Reporting
- **TODO IDs:** `CONF-3`, `DEBT-5`, `CONF-4`, `CORR-17`, `NOTIFY-4` (deleted-file recipients), `PERF-6`
- **Execution Mode:** Parallel with WP 2A (or immediately after WP 2A if testing `oversize`/`is_dirty` integration in `Runner.pm`)
- **Owned Files:**
  - `lib/ChangeTrack/Runner.pm`
  - `t/11-ignore.t`
  - `t/32-detection-fidelity.t`
  - `t/35-vcs-removal.t`
- **Implementation Specifications:**
  1. **Switch `Runner.pm` to `$cfg->ignore` and overhaul `_compile_ignore_patterns` / `_glob_to_re` (`CONF-3`, `DEBT-5`):**
     - Read user ignore patterns from `@{ $cfg->ignore }` instead of `$cfg->global('ignore')`.
     - Update `_glob_to_re($glob)` (`lib/ChangeTrack/Runner.pm:901-912`):
       - Support `**` (matching across directory separators: `.*`, with `/**/` matching `(?:/|/.*/)`).
       - Support `[...]` character classes (`DEBT-5`): when encountering `[`, scan for a closing `]` (handling leading `!` or `^` as negation `[^...]` and disallowing `/` inside the class) and emit the regex character class; if unclosed `[`, escape as `\[`.
       - Keep `*` -> `[^/]*` and `?` -> `[^/]`.
     - Update `_compile_ignore_patterns($patterns)` (`lib/ChangeTrack/Runner.pm:882-896`):
       - Strip trailing slashes from `$pat` (`$pat =~ s{/+$}{}`), skipping if empty.
       - If `$pat =~ m{/}`: compile as `{ path => 1, re => qr{(?:^|/)${re}(?:/|$)} }` so a directory/path pattern like `lvm/cache` or `/etc/letsencrypt` matches `/etc/lvm/cache` itself (for directory pruning) AND `/etc/lvm/cache/.cache` or `/etc/letsencrypt/archive/domain/cert1.pem` (any descendant).
       - If `$pat !~ m{/}`: compile as `{ path => 0, re => qr/^${re}$/, seg_re => qr{(?:^|/)${re}(?:/|$)} }` so plain patterns match `basename($path)` or any path segment.
  2. **Two-Stage Directory Prune + Post-Filter in `_build_file_list()` (`CONF-3`):**
     - **Stage 1 (Early directory pruning during `File::Find`):** In `lib/ChangeTrack/Runner.pm:734-741`, when `-d $_ && !-l $_`, also check `_should_ignore($p, basename($p), $ignore_pats)`. If true, emit `$self->_trace("$p: pruned (ignored directory)")`, set `$File::Find::prune = 1`, and `return`.
     - **Directory listed without `DIRECTORY` keyword (`CONF-4`):** In `lib/ChangeTrack/Runner.pm:684-701`, when `$entry->{kind} eq 'file'` and `-d $entry->{path} && !-l $entry->{path}`, emit `$self->_warn("[track] entry '$entry->{path}' is a directory; treating as 'DIRECTORY $entry->{path}'")`, add the warning to `$report` if defined, and process it through the directory-tracking logic instead of letting `sync_mirror_path` fail with `Is a directory`.
     - **Stage 2 (Unified post-filter so `[ignore]` always overrides `[track]`):** After collecting `%by_path` from both explicit `file` entries and `DIRECTORY` walks, iterate `keys %by_path` and delete any `$p` where `_should_ignore($p, basename($p), $ignore_pats)` or `_is_excluded_path($p, $exclude_paths)` is true (`$self->_trace("$p: ignored by pattern")`).
     - **Stage 3 (Reconciliation cleanup & deleted-file recipient union, `CONF-3` & `NOTIFY-4`):**
       - In the deleted-file reconciliation loop (`lib/ChangeTrack/Runner.pm:764-793`), if `_should_ignore($stored_path, basename($stored_path), $ignore_pats)` is true, call `$md->mark_removed($stored_path)` and `next` (silently forgetting newly ignored files without emitting a false deletion alert).
       - When matching a deleted `$stored_path` against `%dir_opts` (`775-793`), do not stop at `last;`: collect and union `recipients` across **all** enclosing tracked directories in `%dir_opts` (matching live-file `_merge_file_entry` union behavior), while using the most specific directory's `sensitive` override.
  3. **`max_file_size` and non-trackable metadata change reporting (`CONF-4`, `CORR-17`, `PERF-6`):**
     - Pass `$max_file_size = $cfg->global('max_file_size') // (10 * 1024 * 1024)` to `$md->update_from_stat($real_path, \@st, $max_file_size)`.
     - Add `'oversize'` to `_is_non_diffable()` and `_handle_non_trackable()` (emitting a one-time warning `"skipping oversize file ($size bytes > max_file_size $max_file_size): $real_path"` on first detection or transition from `file` to `oversize`).
     - In `_handle_non_trackable()` (`lib/ChangeTrack/Runner.pm:551-603`): when `defined $existing` and `$meta_changed` (where `$existing->{type}` was already non-trackable, or transitioned between non-trackable states), call `$report->add_change(...)` with `diff => "(metadata changed: $meta_summary)"` and `meta_changed => $meta_summary` so metadata changes on `binary`, `unreadable`, `special`, and `oversize` files are reported (`CORR-17`).
     - In `Runner::run()` (`330-333`): only call `$md->save()` when `$md->is_dirty` (`PERF-6`).
  4. **Tests:**
     - Expand `t/11-ignore.t` to test: directory/subtree ignore patterns (`lvm/cache`, `/etc/letsencrypt`), `File::Find` directory pruning (verifying via `--trace` that files inside pruned directories are never visited), `[ignore]` overriding explicit `[track]` file entries, `[...]` character classes, `**` globs, and reconciliation of newly ignored files.
     - Expand `t/32-detection-fidelity.t` and `t/35-vcs-removal.t` for `max_file_size` (`oversize`), `[track]` directory-without-`DIRECTORY` handling, non-trackable metadata change reporting (`CORR-17`), and deleted-file parent-directory recipient union (`NOTIFY-4`).
- **Validation:** `prove -l t/11-ignore.t t/32-detection-fidelity.t t/35-vcs-removal.t`

---

## Phase 3: Versioned `.changetrack-metadata`, Full-Fidelity `revert` & Revision IDs (`FEAT-5`, `CORR-14`, `CORR-18`, `NOTIFY-3`, `NOTIFY-4`)

### WP 3A: VCS Backends (`VCS/Base.pm`, `Git.pm`, `RCS.pm`, `Fossil.pm`, `SVN.pm`, `Mercurial.pm`) & `Util::restore_mirror_path`
- **TODO IDs:** `FEAT-5`, `CORR-14`, `CORR-18` (revision normalization), `NOTIFY-3` (VCS commit revision return), `NOTIFY-4` (`push_remote` warnings)
- **Execution Mode:** Parallel with WP 3B (disjoint files)
- **Owned Files:**
  - `lib/ChangeTrack/Util.pm`
  - `lib/ChangeTrack/VCS/Base.pm`
  - `lib/ChangeTrack/VCS/Git.pm`
  - `lib/ChangeTrack/VCS/RCS.pm`
  - `lib/ChangeTrack/VCS/Fossil.pm`
  - `lib/ChangeTrack/VCS/SVN.pm`
  - `lib/ChangeTrack/VCS/Mercurial.pm`
  - `t/05-vcs-rcs.t`, `t/06-vcs-git.t`, `t/13-vcs-fossil.t`, `t/14-vcs-svn.t`, `t/15-vcs-hg.t`, `t/20-util-symlink-mirror.t`
- **Implementation Specifications:**
  1. **Recreate missing parent directories in `Util::restore_mirror_path` (`CORR-14`):**
     - In `lib/ChangeTrack/Util.pm:420-479`: before creating the symlink or calling `tempfile(DIR => $dir)`, check `make_path($dir) unless -d $dir;` so restoring a deleted file whose parent directory was also removed succeeds cleanly.
  2. **Keep VCS mirror clean at `HEAD` during `revert` & ensure mirror parent dirs (`CORR-14`, `CORR-18`):**
     - In `SVN::revert($real_path, $rev)` (`lib/ChangeTrack/VCS/SVN.pm:165`): normalize `$rev =~ s/^r(?=\d+$)//i` so `r2` from `svn log` works directly (`CORR-18`).
     - In `Mercurial::revert($real_path, $rev)` (`lib/ChangeTrack/VCS/Mercurial.pm:147`): normalize `$rev =~ s/^\d+:([0-9a-f]+)$/$1/i` so `1:8f3a9b2c1d4e` from `hg log` works directly (`CORR-18`).
     - In `RCS::revert`, `Fossil::revert`, `Git::revert`, `SVN::revert`, `Mercurial::revert`: ensure `make_path(dirname($mirror))` before writing to `$mirror`, and wrap the mirror checkout in `_with_temp_mirror_sync` (or restore `$mirror` and the VCS index back to `HEAD` after calling `restore_mirror_path($mirror, $real_path)`) so `revert` only updates the live file on disk while leaving the VCS mirror clean at `HEAD`/tip.
  3. **Return revision IDs & `push_remote` warnings from `commit()` / `checkin()` (`NOTIFY-3`, `NOTIFY-4`):**
     - Whole-repo `commit($msg)` (`Git`, `Fossil`, `SVN`, `Mercurial`):
       - Return a hashref `{ committed => 1, revision => $rev, warnings => \@push_warnings }` (or `{ committed => 0 }` when nothing staged):
         - `Git`: run `git -C $output_dir rev-parse --short=12 HEAD` after commit.
         - `Fossil`: parse `checkout:\s+([0-9a-f]{10,40})` from `fossil info --chdir $output_dir` (or `commit` stdout `New_Version: <hash>`).
         - `SVN`: parse `Committed revision (\d+)\.` from `svn commit` stdout (formatted as `r<N>`).
         - `Mercurial`: run `hg -R $output_dir log -r . -T '{node|short}'`.
       - On `push_remote` failure (`Git.pm:142`, `Fossil.pm:255`, `Mercurial.pm:115`), push the failure message onto `@push_warnings` in addition to `carp` so `Runner` records it in `$report->add_warning(...)`.
     - `RCS::checkin($real_path, $msg)` (`lib/ChangeTrack/VCS/RCS.pm:80-95`):
       - Pass `-f` to `ci -l` (`ci -f -l -m"$msg"`) so metadata-only changes (`chmod`/`chown`) always create a new RCS revision (`FEAT-5`).
       - Parse `new revision:\s*([0-9.]+)` (or `initial revision:\s*([0-9.]+)`) from `ci` stderr and return the revision string (e.g. `'1.2'`).
  4. **Historical metadata lookup `metadata_at_revision($real_path, $rev)` across all 5 backends (`FEAT-5`):**
     - Add `metadata_at_revision($self, $real_path, $rev)` to `VCS::Base`:
       - On whole-repo backends (`Git`, `Fossil`, `SVN`, `Mercurial`), retrieve `.changetrack-metadata` at `$rev`:
         - `Git`: `git -C $output_dir show "$rev:.changetrack-metadata"`
         - `Fossil`: `fossil cat "$output_dir/.changetrack-metadata" --chdir $output_dir -r $rev`
         - `SVN`: `svn cat -r $rev "$repo_url/.changetrack-metadata\@$rev"` (after stripping leading `r`)
         - `Mercurial`: `hg -R $output_dir cat -r $rev "$output_dir/.changetrack-metadata"` (after normalizing `rev:node`)
         Parse the JSONL output line-by-line via `JSON::PP::decode_json` and return the hashref whose `path eq $real_path` (or `undef` if not found).
       - On `RCS` (`RCS.pm`):
         - Maintain `$output_dir/RCS/.changetrack-metadata,v` (or parse `[meta: ...]` from `rlog -r$rev` on the file's `,v` archive plus embed `[changetrack-meta: mode=0644 uid=0 gid=0]` in every `RCS::checkin` commit message):
         - Embedding `[changetrack-meta: mode=%s uid=%d gid=%d user=%s group=%s]` in the revision message passed to `RCS::checkin` (or storing it in `RCS::checkin` from the live `lstat($real_path)`) means every per-file RCS revision `1.x` is 100% self-contained! `RCS::metadata_at_revision($real_path, $rev)` simply runs `rlog -r$rev $archive` and extracts `mode`, `uid`, `gid`, `user`, `group` for revision `$rev`.
  5. **Tests:**
     - Update `t/05-vcs-rcs.t`, `t/06-vcs-git.t`, `t/13-vcs-fossil.t`, `t/14-vcs-svn.t`, `t/15-vcs-hg.t`, and `t/20-util-symlink-mirror.t` to test: `commit`/`checkin` revision return values, `metadata_at_revision`, `SVN` `r2` and `Mercurial` `1:node` normalization in `revert`, missing parent directory recreation on `revert`, and clean `HEAD` mirror state after `revert`.
- **Validation:** `prove -l t/05-vcs-rcs.t t/06-vcs-git.t t/13-vcs-fossil.t t/14-vcs-svn.t t/15-vcs-hg.t t/20-util-symlink-mirror.t`

### WP 3B: `ChangeTrack::Report` & Notifiers (`Email`, `Webhook`, `File`, `OTLP`) Revision ID Surfacing
- **TODO IDs:** `NOTIFY-3`
- **Execution Mode:** Parallel with WP 3A (disjoint files)
- **Owned Files:**
  - `lib/ChangeTrack/Report.pm`
  - `lib/ChangeTrack/Notify/Base.pm`
  - `lib/ChangeTrack/Notify/Email.pm`
  - `lib/ChangeTrack/Notify/Webhook.pm`
  - `lib/ChangeTrack/Notify/File.pm`
  - `lib/ChangeTrack/Notify/OTLP.pm`
  - `t/21-report.t`, `t/08-notify-webhook.t`, `t/09-notify-file.t`, `t/19-notify-otlp.t`
- **Implementation Specifications:**
  1. **`ChangeTrack::Report` (`lib/ChangeTrack/Report.pm`):**
     - Add `revision` attribute (`$report->revision` getter/setter, plus optional per-change `revision => $rev` in `add_change` for per-file `RCS` mode).
     - When `$report->set_revision($rev)` is called after a whole-repo batch commit, backfill `$_->{revision} //= $rev` on all changes and removals in the report.
     - In `Report::to_text()`: include `Revision: <revision>` in the report header when `$report->revision` is defined, and `[rev <c->{revision}>]` on per-file lines when per-file revisions are present.
  2. **Notifiers (`Email`, `Webhook`, `File`, `OTLP`):**
     - `Notify::Email`: Include `Revision: <revision>` in the email summary header (or per-file header for RCS).
     - `Notify::Webhook`: Include `revision => $report->revision` (when defined) at the top level of the JSON payload and `revision => $c->{revision}` on each change object when defined.
     - `Notify::Base::_build_change_event()` (`lib/ChangeTrack/Notify/Base.pm:171-266`): When `$change->{revision}` (or `$report->revision`) is defined and non-empty, emit `'vcs.revision' => $rev` in the OpenTelemetry event attributes (automatically inherited by both `Notify::File` and `Notify::OTLP`).
  3. **Tests:**
     - Add assertions in `t/21-report.t`, `t/08-notify-webhook.t`, `t/09-notify-file.t`, and `t/19-notify-otlp.t` verifying `revision` / `vcs.revision` emission.
- **Validation:** `prove -l t/21-report.t t/08-notify-webhook.t t/09-notify-file.t t/19-notify-otlp.t`

### WP 3C: `ChangeTrack::Runner` Metadata Versioning in VCS & `revert_path` Integration
- **TODO IDs:** `FEAT-5`, `CORR-14`, `NOTIFY-3`, `NOTIFY-4`
- **Execution Mode:** Sequential after WP 3A and WP 3B
- **Owned Files:**
  - `lib/ChangeTrack/Runner.pm`
  - `t/04-runner-rcs.t`, `t/36-type-transitions.t`, `t/37-review-findings.t`
- **Implementation Specifications:**
  1. **Stage and commit `.changetrack-metadata` on whole-repo backends (`FEAT-5`):**
     - Keep `"$output_dir/.changetrack-metadata"` in `_internal_exclude_paths()` so `[track]` directory walks never treat the sidecar as a user-tracked config file.
     - In `Runner::run()` (`lib/ChangeTrack/Runner.pm:318-334`), when `!$self->{dry_run}` and `($report->has_changes || $md->is_dirty)`:
       - For whole-repo backends (`$vcs->model eq 'whole-repo'`):
         1. Back up any existing `$md_path` bytes in memory (or sibling `.bak`).
         2. Call `$md->save()` *before* `$vcs->commit($commit_msg)`.
         3. Stage `.changetrack-metadata` into the VCS mirror (`$vcs->add("$output_dir/.changetrack-metadata")` or backend-native stage of `$md_path`).
         4. Call `my $commit_res = eval { $vcs->commit($commit_msg) };`. If `$@`, restore the backed-up `.changetrack-metadata` file on disk and re-croak so failed commits never advance `.changetrack-metadata`!
       - For `per-file` (`RCS`): capture `$rev = $vcs->checkin($real_path, $msg)` during `_process_file`, pass `revision => $rev` to `$report->add_change(...)`, and call `$md->save()` after the loop.
     - Record `$commit_res->{revision}` on `$report->set_revision(...)` (`NOTIFY-3`) and pass any `@{$commit_res->{warnings}}` to `$self->_warn($_)` and `$report->add_warning($_)` (`NOTIFY-4`).
  2. **Restore historical `mode`, `uid`, and `gid` in `Runner::revert_path()` (`FEAT-5`, `CORR-14`):**
     - In `Runner::revert_path($self, $path, $rev)` (`lib/ChangeTrack/Runner.pm:1214-1270`):
       - Query `my $hist_meta = $vcs->metadata_at_revision($path, $rev);` (falling back to `$md->record_for($path)` if `<rev>` predates versioned metadata, or `_snapshot_existing_file($path)` if neither exists and the pre-revert file was a regular file).
       - Call `$vcs->revert($path, $rev)`.
       - In `_restore_file_metadata($self, $path, $target_meta)`:
         - `lstat($path)` the restored target.
         - If `-l _` (the restored target is a symlink): return immediately **without** warning (`CORR-14`).
         - If `!-f _`: warn and return.
         - Determine `$mode`: if `$target_meta` has a string mode (e.g. `"0640"` from metadata), convert via `oct($target_meta->{mode})`; elsif `$target_meta->{mode}` is numeric and `!$target_meta->{is_symlink}`, use `$target_meta->{mode}`; else default to `0644` (never applying `0777` from a pre-revert symlink or leaving `0600` from the mirror copy!).
         - Apply `chmod($mode, $path)` and (when `$> == 0` and defined `$target_meta->{uid}` / `$target_meta->{gid}`) `chown($target_meta->{uid}, $target_meta->{gid}, $path)`.
  3. **Tests:**
     - Add end-to-end tests in `t/04-runner-rcs.t`, `t/36-type-transitions.t`, and `t/37-review-findings.t` covering:
       - Metadata-only (`chmod`/`chown`) changes creating a real VCS commit visible in `log` across whole-repo (`Git`) and `RCS`.
       - `revert <path> <rev>` restoring historical permissions (`0640` vs `0600`) after a `chmod` change.
       - `revert <path> <rev>` on a deleted file restoring its recorded `0644` permissions (not `0600`) and recreating missing parent directories.
       - `revert <path> <rev>` from a live symlink back to a historical regular file restoring `0644` (never `0777`) and reverting a symlink without spurious warnings.
       - `push_remote` failure recording a warning in `$report->warnings` and suppressing heartbeat eligibility.
- **Validation:** `prove -l t/04-runner-rcs.t t/36-type-transitions.t t/37-review-findings.t`

---

## Phase 4: CLI Hardening & Historical Inspection (`CORR-15`, `CORR-16`, `CORR-18`, `FEAT-6`, `DEBT-15`, `OPS-10`, `PKG-7`)

### WP 4A: VCS Backends Historical `diff`, `show_at_revision` & `log_history` Parity
- **TODO IDs:** `FEAT-6` (VCS methods), `CORR-18` (`log` directory & repo-wide history)
- **Execution Mode:** Parallel with early prep, sequential before WP 4B
- **Owned Files:**
  - `lib/ChangeTrack/VCS/Base.pm`
  - `lib/ChangeTrack/VCS/Git.pm`
  - `lib/ChangeTrack/VCS/RCS.pm`
  - `lib/ChangeTrack/VCS/Fossil.pm`
  - `lib/ChangeTrack/VCS/SVN.pm`
  - `lib/ChangeTrack/VCS/Mercurial.pm`
  - `t/05-vcs-rcs.t`, `t/06-vcs-git.t`, `t/13-vcs-fossil.t`, `t/14-vcs-svn.t`, `t/15-vcs-hg.t`
- **Implementation Specifications:**
  1. **Add `show_at_revision($self, $real_path, $rev)` to `VCS::Base` and all 5 backends (`FEAT-6`):**
     - Normalize `$rev` (`SVN` strip leading `r`; `Mercurial` strip `<num>:`).
     - Retrieve the content of `$real_path` at `$rev` without mutating the live file or leaving the mirror dirty:
       - `Git`: `git -C $output_dir show "$rev:$rel"`
       - `RCS`: `co -q -p$rev $archive`
       - `Fossil`: `fossil cat $mirror --chdir $output_dir -r $rev`
       - `SVN`: `svn cat -r $rev "$url\@$rev"`
       - `Mercurial`: `hg -R $output_dir cat -r $rev $mirror`
     - Croak with an actionable message if `$real_path` or `$rev` does not exist.
     - If the content begins with `__CHANGETRACK_NG_SYMLINK_TARGET__=`, format or return `{ is_symlink => 1, target => $target, content => $raw }` so `Runner::show_path` can display symlink targets clearly.
  2. **Extend `diff($self, $real_path, $rev1, $rev2)` across all 5 backends (`FEAT-6`):**
     - When neither `$rev1` nor `$rev2` is defined: existing pending diff (live file vs latest commit).
     - When `$rev1` is defined and `$rev2` is `undef`: unified diff from `$rev1` to the current live file on disk (using `_with_temp_mirror_sync` so live file is synced to mirror and compared against `$rev1`).
     - When both `$rev1` and `$rev2` are defined: unified diff between `$rev1` and `$rev2` in VCS (`git diff $rev1 $rev2 -- $rel`; `rcsdiff -u -r$rev1 -r$rev2 $archive`; `fossil diff --chdir $output_dir --from $rev1 --to $rev2 $rel`; `svn diff -r "$rev1:$rev2" "$url\@$peg"`; `hg -R $output_dir diff -r $rev1 -r $rev2 $mirror`).
  3. **Repo-wide `log_history(undef)` and directory `log` support (`CORR-18`):**
     - Support `log_history($self, $real_path)`:
       - When `$real_path` is `undef`:
         - Whole-repo backends (`Git`, `Fossil`, `SVN`, `Mercurial`): run a single repository-level log (`git log --stat`, `fossil timeline -n 0 -v`, `svn log -v`, `hg log -v`, excluding `.changetrack-metadata` noise where applicable or showing commit summaries) so deleted files and batch commits are shown in `O(1)` subprocess calls.
         - `RCS`: scan all `*,v` archives in `$output_dir/RCS/` (including archives for deleted files!) and return their `rlog` histories.
       - When `$real_path` is a directory on `Fossil` or `RCS`, Runner expands or filters matching tracked/historical files under `$real_path`.
  4. **Tests:**
     - Add tests across `t/05-vcs-rcs.t`, `t/06-vcs-git.t`, `t/13-vcs-fossil.t`, `t/14-vcs-svn.t`, and `t/15-vcs-hg.t` for `show_at_revision`, 1-arg and 2-arg historical `diff`, and repo-wide `log_history(undef)` including deleted files.
- **Validation:** `prove -l t/05-vcs-rcs.t t/06-vcs-git.t t/13-vcs-fossil.t t/14-vcs-svn.t t/15-vcs-hg.t`

### WP 4B: `bin/changetrack-ng` & `Runner.pm` Subcommands (`show`, `diff`, `log`, `revert --dry-run`, `--lock-timeout`, Arity Check, Drop `update-ignore`)
- **TODO IDs:** `CORR-15`, `CORR-16`, `CORR-18`, `FEAT-6`, `DEBT-15`, `OPS-10` (CLI), `PKG-7` (VCS default)
- **Execution Mode:** Sequential after WP 4A
- **Owned Files:**
  - `bin/changetrack-ng`
  - `lib/ChangeTrack/Runner.pm`
  - `man/changetrack-ng.8`
  - `README.md`
  - `PRODUCT.md`
  - `ARCHITECTURE.md`
  - `AGENTS.md`
  - `t/16-subcommands.t`
- **Implementation Specifications:**
  1. **Strict CLI option and positional argument validation (`CORR-15`):**
     - In `bin/changetrack-ng`: remove `pass_through` from `Getopt::Long::Configure('no_ignore_case', 'bundling')` so `GetOptions` parses global options across the entire `@ARGV` and immediately rejects any unknown `--flag` with exit code `64` (whether placed before or after the subcommand!).
     - In `cmd_run`, `cmd_init`, and `cmd_status`: if `@ARGV > 0`, warn `"changetrack-ng $subcommand: unexpected argument '$ARGV[0]'\n"`, print usage to `STDERR`, and return `64`.
     - In `cmd_log`: allow `0` or `1` path argument (`@ARGV <= 1` or exit `64`).
     - In `cmd_diff`: allow `0` to `3` arguments (`[path] [rev1] [rev2]`; if `1` argument is given, treat it as `path`; if `2` or `3` arguments, `($path, $rev1, $rev2)`; if `@ARGV > 3`, exit `64`).
     - In `cmd_show` and `cmd_revert`: require exactly `2` arguments (`<path> <rev>` or exit `64`).
  2. **Add `--lock-timeout` CLI flag (`OPS-10`) & align default VCS to `git` (`PKG-7`):**
     - Add `'lock-timeout=i' => \$opts{lock_timeout}` to `GetOptions` in `bin/changetrack-ng` (rejecting negative integers with exit `64`). Pass `lock_timeout => $opts{lock_timeout}` into `ChangeTrack::Runner->new(...)` in `cmd_run` and `cmd_revert`.
     - In `Runner::_lock_for($self, $cfg, $force)`: use `$self->{lock_timeout} // $cfg->global('lock_timeout') // 0`.
     - In `Runner.pm` (`run`, `_internal_exclude_paths`, `_setup`): change the unset `vcs` fallback from `'rcs'` to `'git'`, matching `cmd_init` and `man/changetrack-ng.conf.5` (`PKG-7`).
  3. **Add `show <path> <rev>` and `revert --dry-run`, and extend `diff` & `log` (`FEAT-6`, `CORR-16`, `CORR-18`):**
     - Add `cmd_show` in `bin/changetrack-ng` and `Runner::show_path($self, $path, $rev)`:
       - Calls `$vcs->metadata_at_revision($path, $rev)` and `$vcs->show_at_revision($path, $rev)`.
       - Prints metadata header (`# Path: ...`, `# Revision: ...`, `# Mode: ... Owner: ... Type: ...` when available) followed by the historical content (or symlink target) to `STDOUT`.
     - Update `cmd_revert` and `Runner::revert_path`:
       - When `$opts{dry_run}` (`--dry-run` / `-n`) is set: skip the interactive `[y/N]` prompt, do not modify disk, and print a preview showing the target metadata (`mode`/`uid`/`gid`) and unified diff between current live `$path` and `<rev>`.
       - Validate VCS initialization and path/revision before prompting `[y/N]` in interactive mode.
     - Update `Runner::diff_path($self, $path, $rev1, $rev2)` (`CORR-16`, `FEAT-6`):
       - When `$path` is a tracked directory (or prefix of tracked entries) and no revs are given, iterate all matching tracked entries under `$path` instead of passing the directory to `$vcs->diff`.
       - Check `_is_non_diffable($path)` on single-path pending diffs (unless `$meta_changed`).
       - When a pending file has no content diff (`!@$diff`) but `$md->changed_since_load($path)` is true, return `["(metadata changed: " . $md->diff_summary($path) . ")"]` so `changetrack-ng diff` shows metadata-only changes consistently with `changetrack-ng status`.
     - Update `Runner::status()` (`lib/ChangeTrack/Runner.pm:1107`, `CORR-16`): check `$md->changed_since_load($ep)` *before* `next if $self->_is_non_diffable($ep)` so `file -> binary`/`unreadable`/`oversize` transitions are reported by `status`.
     - Update `Runner::log_path($self, $path)` (`CORR-18`):
       - When `$path` is `undef`, call `$vcs->log_history(undef)` (showing repo-wide history including deleted files).
       - When `$path` is a directory, expand matching current + metadata-recorded paths under `$path` on backends where `log_history` is per-file (`Fossil`, `RCS`).
  4. **Remove `update-ignore` completely (`DEBT-15`):**
     - Delete `'update-ignore'` from `%dispatch`, `cmd_update_ignore()`, and `_update_gitignore()` in `bin/changetrack-ng`.
     - Update all 7 subcommand lists verified by `tools/doc-lint` (`bin/changetrack-ng` header comment, `_usage`, inline POD, `%dispatch`, `man/changetrack-ng.8`, `AGENTS.md`, `README.md`), plus `PRODUCT.md` and `ARCHITECTURE.md`, replacing `update-ignore` with `show`.
  5. **Tests:**
     - Update `t/16-subcommands.t` to remove `update-ignore` tests and add coverage for:
       - `show <path> <rev>` across backends (regular file, symlink, deleted file).
       - `diff <path> <rev1>` and `diff <path> <rev1> <rev2>`.
       - `diff <dir>` and `diff` on metadata-only (`chmod`) changes.
       - `revert --dry-run` (verifying live file is untouched).
       - `log` (no-arg and `<dir>`) showing deleted files.
       - Rejection of unknown flags after subcommands (`changetrack-ng run --dryrun` exits `64`) and extra positional args (`changetrack-ng status /etc/hosts` exits `64`).
       - `--lock-timeout` CLI flag.
- **Validation:** `prove -l t/16-subcommands.t && make dev-check`

---

## Phase 5: Packaging, Hooks & Documentation Sweep (`PKG-6`, `PKG-7`, `OPS-10`, `DOC-5`)

### WP 5A: Packaging, Hooks (`DNF4`/`DNF5`, `Pacman`, `--lock-timeout`), `Makefile` & Debian Rules
- **TODO IDs:** `PKG-6`, `PKG-7`, `OPS-10` (hooks)
- **Execution Mode:** Parallel with WP 5B (disjoint files)
- **Owned Files:**
  - `Makefile`
  - `packaging/hooks/apt-pre`
  - `packaging/hooks/apt-post`
  - `packaging/hooks/apt-pre-debug`
  - `packaging/hooks/apt-post-debug`
  - `packaging/hooks/dnf/changetrack_ng.py`
  - `packaging/hooks/dnf/changetrack-ng.actions` (new file)
  - `packaging/hooks/pacman-pre.hook`
  - `packaging/hooks/pacman-post.hook`
  - `packaging/logrotate/changetrack-ng`
  - `packaging/debian/rules`
  - `packaging/debian/control`
  - `packaging/rpm/changetrack-ng.spec`
  - `MANIFEST.toml` (entry for `packaging/hooks/dnf/changetrack-ng.actions`)
- **Implementation Specifications:**
  1. **`Makefile` `SYSCONFDIR` and `LOGROTATEDIR` defaults & `_install_bin` config path rewrite (`PKG-7`):**
     - In `Makefile`: change `SYSCONFDIR ?= /etc` and `LOGROTATEDIR ?= /etc/logrotate.d` so `sudo make install` (with default `PREFIX = /usr/local`) installs config to `/etc/changetrack-ng/changetrack-ng.conf` and logrotate policy to `/etc/logrotate.d/changetrack-ng`.
     - In `_install_bin`: also rewrite `/etc/changetrack-ng/changetrack-ng.conf` in `bin/changetrack-ng` to `$(SYSCONFDIR)/$(NAME)/$(NAME).conf` so custom `SYSCONFDIR` overrides work at runtime.
  2. **DNF4 `pluginpath` + DNF5 `actions.d` support (`PKG-6`):**
     - Create `packaging/hooks/dnf/changetrack-ng.actions` for DNF5 (`libdnf5-plugin-actions` format):
       - `pre_transaction::::/bin/sh -c '. @DEFAULTSDIR@/changetrack-ng 2>/dev/null || true; @BINDIR@/changetrack-ng run -q --lock-timeout 30 -m "pre-install: dnf" ${CHANGETRACK_EXTRA_ARGS:-} 2>/dev/null || true'`
       - `post_transaction::::/bin/sh -c '. @DEFAULTSDIR@/changetrack-ng 2>/dev/null || true; @BINDIR@/changetrack-ng run -q --lock-timeout 30 -m "post-install: dnf" ${CHANGETRACK_EXTRA_ARGS:-} 2>/dev/null || true'`
     - Update `Makefile` (`install-hooks`) and `packaging/rpm/changetrack-ng.spec`:
       - Install `changetrack_ng.conf` to `/etc/dnf/plugins/changetrack_ng.conf`.
       - Install `changetrack_ng.py` into the Python DNF4 plugin directory (`%{python3_sitelib}/dnf-plugins/changetrack_ng.py` in RPM spec; auto-detected via `python3 -c "import sysconfig; print(sysconfig.get_path('purelib'))"` fallback `/usr/lib/python3/dist-packages` in `Makefile`).
       - Install `changetrack-ng.actions` (with `@BINDIR@` and `@DEFAULTSDIR@` substituted) into `/etc/dnf/libdnf5-plugins/actions.d/changetrack-ng.actions`.
     - Register `packaging/hooks/dnf/changetrack-ng.actions` in `MANIFEST.toml`.
  3. **Pacman defaults sourcing & `--lock-timeout 30` across all hooks (`PKG-6`, `OPS-10`):**
     - Update `packaging/hooks/pacman-pre.hook` and `pacman-post.hook` to execute `/bin/sh -c '. /etc/default/changetrack-ng 2>/dev/null || true; @BINDIR@/changetrack-ng run --quiet --lock-timeout 30 -m "pre-install: pacman" ${CHANGETRACK_EXTRA_ARGS:-}'` (and `"post-install: pacman"`).
     - Add `--lock-timeout 30` to `apt-pre`, `apt-post`, `apt-pre-debug`, `apt-post-debug`, and `changetrack_ng.py`.
     - Add `/var/log/changetrack-ng-apt-debug.log` to `packaging/logrotate/changetrack-ng`.
  4. **Debian `override_dh_fixperms` and `Homepage` fix (`PKG-7`, `DOC-5`):**
     - In `packaging/debian/rules`: add `override_dh_fixperms:` calling `dh_fixperms` followed by `chmod 0640 debian/changetrack-ng/etc/changetrack-ng/changetrack-ng.conf` and `chmod 0700 debian/changetrack-ng/var/lib/changetrack-ng`.
     - In `packaging/debian/control:8`: update `Homepage:` to `https://github.com/cashell/changetrack-ng`.
- **Validation:** `make dev-check`

### WP 5B: Documentation & Manual Page Reconciliation (`DOC-5`)
- **TODO IDs:** `DOC-5`
- **Execution Mode:** Parallel with WP 5A (disjoint files)
- **Owned Files:**
  - `README.md`
  - `PRODUCT.md`
  - `ARCHITECTURE.md`
  - `INSTALL.md`
  - `docs/COOKBOOK.md`
  - `docs/QUICKSTART.md`
  - `man/changetrack-ng.8`
  - `man/changetrack-ng.conf.5`
  - `AGENTS.md`
  - `CHANGELOG.md`
- **Implementation Specifications:**
  1. **Update config documentation for `[ignore]`, `max_file_size`, `show`, `diff`, `revert --dry-run`, and `--lock-timeout`:**
     - Update `man/changetrack-ng.conf.5`, `README.md`, `PRODUCT.md`, `ARCHITECTURE.md`, `docs/COOKBOOK.md`, and `docs/QUICKSTART.md` to replace `[global] ignore =` examples with `[ignore]` sections, document `max_file_size`, and document `track.d/etc-full.conf`.
     - Update `man/changetrack-ng.8`, `README.md`, `PRODUCT.md`, and `ARCHITECTURE.md` for `show <path> <rev>`, historical `diff [path] [rev1] [rev2]`, `revert --dry-run`, `--lock-timeout`, and versioned `.changetrack-metadata`.
  2. **Fix all remaining doc-vs-code discrepancies (`DOC-5`):**
     - `PRODUCT.md:68-72`: Add `DIRECTORY` prefix to `/etc`, `/usr/local/etc`, `/var/spool/cron` in the `[track]` example; fix OTLP `compression` default note; clarify static hook `-m` annotations.
     - `man/changetrack-ng.conf.5`: Fix OTLP `compression` default (uncompressed `''` unless set to `gzip`), `push_remote` backend list (`git`, `fossil`, `hg`), File notifier description (per-event NDJSON), and foreign VCS directory list (`.git`, `.hg`, `.svn`, `CVS`, `.bzr`, `_darcs`).
     - `man/changetrack-ng.8` & `bin/changetrack-ng` POD: Clarify `--force` lock behavior on `run` vs `revert`, and document accurate exit codes on lock contention/timeout.
     - `ARCHITECTURE.md`: Update version header, add `command_timeout` and `max_file_size` to `[global]` whitelist, update `[ignore]` section description, fix `RCS::revert` (`co -p`), fix `status`/`diff` non-auto-init description, remove stale `Metadata::import_from_v1_statistics` and `Cwd` references, fix `__CHANGETRACK_NG_SYMLINK_TARGET__=` spelling (also in `AGENTS.md` and `lib/ChangeTrack/Util.pm` POD), and fix `/var/log/changetrack-ng.jsonl` path.
     - `INSTALL.md`: Reconcile `make install` paths with `SYSCONFDIR=/etc`, clarify `lock_path` default resolution (`$XDG_RUNTIME_DIR` -> `$XDG_CACHE_HOME`), include `.gz` on installed man page paths, and remove stale `flock` file cleanup advice.
  3. **Update `CHANGELOG.md`:**
     - Record all Added, Changed, Removed (`[global] ignore =`, `update-ignore`), and Fixed items under `## [Unreleased]`.
- **Validation:** `make dev-check && make test`

---

## 3. Final Verification Gate

After all 5 phases are merged into the feature branch:

```bash
make config-lint
make dev-check
make test
```

Ensure zero em dashes exist anywhere in the repository (`git grep -I $'\xe2\x80\x94'`) before opening the pull request.

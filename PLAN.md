# changetrack-ng Implementation Plan

**Version:** 0.3.0 (initial)
**License:** GPLv3
**Language:** Perl 5.20+
**Status:** Design complete, ready for implementation

---

## 1. Project Overview

`changetrack-ng` is a clean Perl rewrite of the original `changetrack` tool (last maintained 2009, broken on Perl 5.26+ due to `find2perl` removal). It combines `changetrack`'s flexibility (arbitrary file lists, per-file email notifications) with `etckeeper`'s features (metadata tracking, ignore patterns, multi-VCS support, package manager hooks).

### Source materials
- Original `changetrack` (Perl, ~400 lines): `../changetrack/changetrack`
- Initial analysis: `../ct-orig/changetrack-initial-analysis.md`
- `etckeeper` 1.18.23 source (reference for features to port): `../ct-orig/etckeeper_1.18.23.orig/`

---

## 2. Confirmed Design Decisions

| Decision | Choice |
|---|---|
| Name | `changetrack-ng` |
| Language | Perl, target 5.20+ |
| Approach | Clean rewrite (not a patch of original) |
| VCS backends | RCS, Git, Fossil, SVN, Mercurial — all required |
| Hard deps | Perl core only (`HTTP::Tiny`, `JSON::PP`, `IO::Compress::Gzip` are core ≥5.14) |
| Soft deps | `IPC::Run`, `Capture::Tiny`, `Path::Tiny` — used if available, fallback otherwise |
| Config format | INI v2, with v1 (original) auto-detection and one-shot migration |
| Init behavior | Implicit on first run; `--no-auto-init` to disable |
| Output dir layout | RCS: flat `:`-separated (back-compat); whole-repo VCS: mirror tree |
| Metadata | JSONL sidecar (`.changetrack-metadata`), one file per line |
| Sensitive handling | Auto-detect by mode (no world read — triggers on 0600 and 0640) → suppress diff in notifications; per-entry override |
| Notifications | Email (sendmail pipe), Webhook (HTTP::Tiny), OTLP (HTTP+JSON, gzip), File (log append) — modular, all optional, all zero-dep |
| Webhook payload | Summary by default; full diff opt-in via `webhook_full_diff = 1` |
| OTLP signal | Logs (one record per file change); summary by default, full diff opt-in via `otlp_full_diff = 1` |
| Heartbeat | Per-notifier opt-in. OTLP defaults ON (monitoring use case); Webhook/File default OFF; Email forced OFF (anti-spam). Heartbeat = single "no changes" record per run, lets monitoring distinguish silence from agent failure. |
| Schedule | Hourly default; configurable; both cron.hourly and systemd timer shipped |
| Commit messages | Timestamp + optional hook annotation, batch-wide for whole-repo VCS |
| Versioning | Semver, starting at 0.3.0 |
| Distribution | Tarball + Makefile (PREFIX-configurable); Deb/RPM later |
| Install paths | `PREFIX=/usr/local` default; `PREFIX=/usr` deploys to `/usr/bin` + `/etc` |
| Locking | `flock` on pidfile; skip silently if locked |
| Error handling | Per-file errors skip with warning; VCS errors abort run |

---

## 3. Project Layout

```
changetrack-ng/
├── PLAN.md                          (this file)
├── README.md
├── INSTALL.md
├── LICENSE                          (GPLv3 text)
├── CHANGELOG.md
├── Makefile
├── .gitignore
│
├── bin/
│   └── changetrack-ng               (entry point, ~150 lines: option parsing + dispatch)
│
├── lib/
│   └── ChangeTrack/
│       ├── Config.pm                (INI v2 parser + v1 detection)
│       ├── Runner.pm                (main scan/diff/checkin orchestration)
│       ├── Metadata.pm              (JSONL read/write, stat() comparison)
│       ├── Report.pm                (run accumulator passed to notifiers)
│       ├── Util.pm                  (run_cmd, hostname, path helpers)
│       ├── Lock.pm                  (flock pidfile)
│       │
│       ├── VCS/
│       │   ├── Base.pm              (abstract interface)
│       │   ├── RCS.pm
│       │   ├── Git.pm
│       │   ├── Fossil.pm
│       │   ├── SVN.pm
│       │   └── Mercurial.pm
│       │
│       └── Notify/
│           ├── Base.pm
│           ├── Email.pm             (sendmail pipe)
│           ├── Webhook.pm           (HTTP::Tiny POST)
│           ├── OTLP.pm              (OpenTelemetry Logs over HTTP+JSON, gzip)
│           └── File.pm              (append to log file)
│
├── etc/
│   └── changetrack-ng.conf          (default v2 config, well-commented)
│
├── man/
│   ├── changetrack-ng.8             (main manpage)
│   └── changetrack-ng.conf.5        (config format manpage)
│
├── packaging/
│   ├── hooks/
│   │   ├── apt-pre                  (Debian/Ubuntu)
│   │   ├── apt-post
│   │   ├── dnf/
│   │   │   ├── changetrack_ng.py    (Fedora/RHEL dnf plugin)
│   │   │   └── changetrack_ng.conf
│   │   ├── pacman-pre               (Arch)
│   │   ├── pacman-post
│   │   ├── zypper-pre               (openSUSE)
│   │   └── zypper-post
│   ├── systemd/
│   │   ├── changetrack-ng.service
│   │   └── changetrack-ng.timer
│   ├── cron/
│   │   └── changetrack-ng.cron      (cron.hourly script)
│   ├── rpm/
│   │   └── changetrack-ng.spec
│   └── debian/
│       ├── control
│       ├── rules
│       ├── changelog
│       └── source/format
│
└── t/                               (test suite, prove-runnable)
    ├── 00-load.t
    ├── 01-config-v2.t
    ├── 02-config-v1-compat.t
    ├── 03-metadata.t
    ├── 04-runner-rcs.t
    ├── 05-vcs-rcs.t
    ├── 06-vcs-git.t
    ├── 07-notify-email.t
    ├── 08-notify-webhook.t
    ├── 09-notify-file.t
    ├── 10-sensitive.t
    ├── 11-ignore.t
    ├── 12-locking.t
    ├── 13-vcs-fossil.t
    ├── 14-vcs-svn.t
    ├── 15-vcs-hg.t
    ├── 16-subcommands.t
    ├── 17-precommit-checks.t
    ├── 19-notify-otlp.t
    ├── lib/
    │   └── ChangeTrack/Test/
    │       ├── Harness.pm           (test fixture helpers)
    │       └── MockSendmail.pm
    └── fixtures/
        ├── config-v2-basic.ini
        ├── config-v2-full.ini
        ├── config-v1-legacy.conf
        └── tree/                    (sample file trees for runner tests)
```

---

## 4. Build & Test Strategy

### 4.1 Makefile

```make
NAME       := changetrack-ng
VERSION    := 0.3.0

PREFIX     ?= /usr/local
BINDIR     ?= $(PREFIX)/bin
LIBDIR     ?= $(PREFIX)/lib/$(NAME)
SYSCONFDIR ?= $(if $(filter /usr,$(PREFIX)),/etc,$(PREFIX)/etc)
DATADIR    ?= /var/lib/$(NAME)
MANDIR     ?= $(PREFIX)/share/man
SYSTEMDDIR ?= /etc/systemd/system
HOOKSDIR   ?= $(LIBDIR)/hooks
DESTDIR    ?=
```

Targets: `all`, `test`, `install`, `uninstall`, `dist`, `clean`, `install-hooks` (auto-detects pkg manager), `install-systemd`, `install-cron`.

`install` rewrites the shebang and `use lib` paths in `bin/changetrack-ng` to match `LIBDIR` at install time.

### 4.2 Test Strategy

- **Framework:** `Test::More` (core) + `prove`. No external test deps.
- **Coverage target:** ~80% for `Config`, `Metadata`, `Runner`, `VCS::Base`, `Notify::Base`. Smoke tests on each concrete VCS/notify backend.
- **Integration tests** that require an external tool (`git`, `rcs`, `fossil`, `svn`, `hg`, `sendmail`) check for the binary at the top of the test file and `plan skip_all` if missing. CI matrix runs each environment separately.
- **Test isolation:** every test creates a temp dir under `File::Temp`, runs the operations there, cleans up on exit.
- **Mock notifiers** for non-network testing: `t/lib/ChangeTrack/Test/MockSendmail.pm` provides a fake sendmail that captures arguments and stdin to a file the test can inspect.

### 4.3 Perl version target

- **Floor:** 5.20 (gets `\h`/`\v`, `s///r`, `JSON::PP`, `HTTP::Tiny` in core).
- **Idioms:** lexical filehandles, 3-arg `open`, `use strict; use warnings; use feature qw(say state)`. NO subroutine signatures (not stable until 5.36). Traditional `my ($self, @args) = @_;` unpacking.
- **Forbidden:** bareword filehandles, 2-arg open, `find2perl`, `Mail::SendMail`, `do FILE`, indirect method syntax, prototypes on subs.

---

## 5. Implementation Phases

Each phase is independently testable and leaves the tool in a working (if incomplete) state. Phases 1–4 together produce a usable v0.3.0 alpha; phases 5–10 fill out features and polish.

---

### Phase 1: Foundation

**Goal:** Project skeleton, build system, test harness, config parser. No tracking logic yet.

**New files:**
- `Makefile` (with PREFIX/BINDIR/SYSCONFDIR variables, targets above)
- `bin/changetrack-ng` (skeleton: parses `--version`, `--help`, dispatches to subcommand stubs)
- `lib/ChangeTrack/Config.pm`
- `lib/ChangeTrack/Util.pm` (initial: `hostname()`, `run_cmd()` wrapper)
- `etc/changetrack-ng.conf` (default well-commented config)
- `t/00-load.t`, `t/01-config-v2.t`, `t/02-config-v1-compat.t`
- `t/fixtures/config-v2-basic.ini`, `t/fixtures/config-v2-full.ini`, `t/fixtures/config-v1-legacy.conf`
- `LICENSE` (GPLv3), `README.md` (stub), `.gitignore`, `CHANGELOG.md`

**`ChangeTrack::Config` API:**

```perl
my $cfg = ChangeTrack::Config->load($path);   # auto-detects v1 vs v2; dies on parse error
$cfg->global('vcs');                          # e.g. 'git'
$cfg->global('notify');                       # arrayref ['email','webhook']
$cfg->global('ignore');                       # arrayref of glob patterns
$cfg->tracks();                               # arrayref of track entries:
    # [ { kind => 'file'|'directory', path => '/etc/passwd',
    #     emails => ['root@...'], options => { sensitive => 'auto' } }, ... ]
$cfg->version();                              # 1 or 2
ChangeTrack::Config->migrate_v1_to_v2($v1_path, $v2_path);
```

**Config v2 grammar:**

```ini
# Comments start with #
[global]
vcs                = git                 # rcs|git|fossil|svn|hg
output_dir         = /var/lib/changetrack-ng
notify             = email webhook       # space-separated; subset of email|webhook|otlp|file
email_from         = changetrack-ng@HOSTNAME    # HOSTNAME is substituted
push_remote        =                     # space-separated remotes for whole-repo VCS
webhook_url        =                     # space-separated URLs
webhook_full_diff  = 0
webhook_heartbeat  = 0                   # send a "no changes" beacon each run
otlp_endpoint      =                     # full URL incl. /v1/logs path
otlp_full_diff     = 0
otlp_compression   = gzip                # gzip|none
otlp_headers       =                     # k=v pairs, space-separated, backslash-escape spaces
otlp_resource_attributes =               # additional OTLP resource attrs, k=v space-separated
otlp_heartbeat     = 1                   # default ON: monitoring channel benefits from beacons
notify_log_path    = /var/log/changetrack-ng.log
file_heartbeat     = 0                   # append a "no changes" record each run
ignore            = *.swp *~ #*# *.bak *.dpkg-* *.rpmnew
sensitive_auto    = 1
sensitive_notify  = suppress             # suppress|allow
warn_special_files = 1
interval          = hourly               # hourly|daily|<cron-expr>
lock_path         = /var/run/changetrack-ng.lock
lock_timeout      = 0                    # 0 = skip if locked

[track]
# file-spec : email1 email2 [opt=val ...]
/etc/passwd : root@localhost
/etc/hosts
DIRECTORY /etc/nginx : admin@example.com
DIRECTORY /etc/ssl/private sensitive=yes
```

**v1 detection:** A file is v1 if it has no `[global]` or `[track]` section header and any non-blank/non-comment line matches the v1 grammar (`^[/@~][^:]*\s*(:\s*\S+)?\s*$`).

**Exit criteria:**
- [ ] `make test` passes (`prove t/`)
- [ ] `bin/changetrack-ng --version` prints `0.3.0`
- [ ] `bin/changetrack-ng --help` lists all subcommands (even if they're stubs)
- [ ] All v2 sample configs round-trip (parse → dump → parse → equal)
- [ ] All known v1 quirks parse correctly with `Config->load()` (e.g., `@` find directive parses as a v1 directory entry, but the v1→v2 migrator emits `DIRECTORY` with a warning that find-expr translation is manual)

---

### Phase 2: Core MVP — RCS Backend

**Goal:** End-to-end tracking with RCS only. No notifications yet (output to stdout). Tool is functionally usable for a single-user setup.

**New files:**
- `lib/ChangeTrack/VCS/Base.pm`
- `lib/ChangeTrack/VCS/RCS.pm`
- `lib/ChangeTrack/Metadata.pm`
- `lib/ChangeTrack/Report.pm`
- `lib/ChangeTrack/Runner.pm`
- `t/03-metadata.t`, `t/04-runner-rcs.t`, `t/05-vcs-rcs.t`

**`ChangeTrack::VCS::Base` interface:**

```perl
package ChangeTrack::VCS::Base;
sub new           { ... }       # ($class, %args) — args: output_dir, options (push_remote, etc.)
sub init          { die 'unimpl' }   # ($self) — set up output_dir for tracking
sub is_initialized { die 'unimpl' }  # ($self) — bool
sub output_path   { die 'unimpl' }   # ($self, $real_path) — where to copy the working file
sub checkin       { die 'unimpl' }   # ($self, $real_path, $msg) — record current state
sub add           { die 'unimpl' }   # ($self, $real_path) — stage new file (no-op for RCS)
sub commit        { die 'unimpl' }   # ($self, $msg) — finalize batch (no-op for RCS)
sub diff          { die 'unimpl' }   # ($self, $real_path) — return arrayref of diff lines
sub log_history   { die 'unimpl' }   # ($self, $real_path) — return arrayref of log lines
sub revert        { die 'unimpl' }   # ($self, $real_path, $rev)
sub is_dirty      { die 'unimpl' }   # ($self, $real_path) — bool
sub model         { die 'unimpl' }   # 'per-file' or 'whole-repo'
```

**RCS implementation:**
- `output_path()` flattens `/etc/passwd` → `$output_dir/etc:passwd` (matching original layout for migration ease)
- `init()` creates `$output_dir` and `$output_dir/RCS/`
- `checkin()` copies file to `output_path()`, runs `ci -l -m"$msg"`
- `is_dirty()` runs `rcsdiff -q` and checks exit code
- `model()` returns `'per-file'`

**`ChangeTrack::Metadata`:**

```perl
my $md = ChangeTrack::Metadata->load($path);   # reads JSONL; returns object indexed by path
$md->record_for($path);                        # hashref { mode, uid, gid, user, group, type, target? }
$md->update_from_stat($path);                  # repopulates record by stat()-ing the live file
$md->changed_since_load($path);                # bool: has the live file changed vs loaded record
$md->diff_summary($path);                      # human string: 'mode 0644 → 0600, owner root → www-data'
$md->save($path);                              # writes JSONL, sorted by path, atomic via tempfile+rename
$md->import_from_v1_statistics($dir);          # one-shot migration from old .statistics format
```

JSONL line schema:
```json
{"path":"/etc/passwd","mode":"0644","uid":0,"gid":0,"user":"root","group":"root","type":"file"}
{"path":"/etc/x.link","target":"/etc/real","type":"symlink"}
```

**Runner orchestration (`Runner::run()`):**

1. Load config; resolve `HOSTNAME` substitutions
2. Acquire lock (stubbed in Phase 1, real in Phase 6)
3. Instantiate VCS backend from `vcs` config key
4. If `!$vcs->is_initialized` and `!$opt{no_auto_init}`: `$vcs->init`
5. Load `.changetrack-metadata` (or empty if first run)
6. Build file list from track entries (expand globs and DIRECTORY entries via `File::Find`); apply ignore patterns; resolve sensitive flag (auto-detect or explicit override)
7. For each file:
   - Skip if backup file (`~`), unsafe filename, directory (unless DIRECTORY mode), special, unreadable
   - If not in metadata → mark new, copy to VCS, record metadata
   - Else: compare metadata → record meta_changes; compare content via `diff` → record diff
   - If anything changed: `$vcs->checkin(...)`, update report
8. After loop: write metadata sidecar, `$vcs->commit($msg)` with batch message
9. Return `$report`
10. Phase 2 only: print report to stdout (notifications come in Phase 3)

**Commit message format:** `changetrack-ng run @ 2026-04-27T14:00:00 [hook: apt-pre install nginx]` — second bracket only if `-m` / `--message` provided.

**Exit criteria:**
- [ ] `changetrack-ng run -c t/fixtures/config-v2-basic.ini` works on a temp tree, commits to RCS, prints summary
- [ ] Re-running with no changes is a no-op (no commits made, exit 0)
- [ ] Modifying a file's permissions only is detected and committed (metadata change with empty content diff)
- [ ] Modifying file content is detected and committed
- [ ] New file appears in tracked output dir with `,v` history
- [ ] Removed file (file vanishes from disk between runs) reported correctly — design choice: log removal in metadata diff, but don't delete VCS history
- [ ] `t/04-runner-rcs.t` exercises all of the above end-to-end with a real `rcs`/`ci`/`co` (skip_all if not installed)

---

### Phase 3: Notifications + Sensitive Files

**Goal:** Email and File notifiers; sensitive file diff suppression in notifications (but not in VCS).

**New files:**
- `lib/ChangeTrack/Notify/Base.pm`
- `lib/ChangeTrack/Notify/Email.pm`
- `lib/ChangeTrack/Notify/File.pm`
- `t/lib/ChangeTrack/Test/MockSendmail.pm`
- `t/07-notify-email.t`, `t/09-notify-file.t`, `t/10-sensitive.t`

**`Notify::Base` interface:**

```perl
sub new            { ... }   # %args from config
sub send           { ... }   # ($self, $report) — best-effort, never dies; dispatches to send_changes/send_heartbeat
sub send_changes   { ... }   # ($self, $report) — required; report has at least one file
sub send_heartbeat { ... }   # ($self, $report) — optional; default no-op
sub heartbeat_enabled { ... } # ($self) — bool from config; default class method returns 0
sub name           { ... }   # for logging
```

The `send` dispatcher in `Base`:
- If `$report->has_changes`: call `send_changes($report)`
- Else if `$self->heartbeat_enabled`: call `send_heartbeat($report)`
- Else: no-op (this is the default for Email)

This keeps the heartbeat decision local to each notifier and prevents email noise by default. The `Report` exposes `has_changes()` (bool: any file changed) and `is_heartbeat_eligible()` (bool: clean run, no errors — heartbeats only fire on successful clean runs, not on aborts).

**Sensitive logic** lives in `Runner`, not `Notify`. The `Report` object stores per-file `sensitive => 1` and the `Notify::*` modules check this flag and replace `diff_text` with a placeholder string when set:

```
[diff suppressed -- sensitive file (no world read)]
```

The `Report` itself has full diff content; suppression is applied only when serializing for notifications. This means if `sensitive_notify = allow` is set globally, full diffs are sent — explicit opt-out path.

**Sensitive auto-detection:**
- Trigger: file has `mode & 0004 == 0` (no world read; catches 0600 and 0640)
- Per-entry `options.sensitive`:
  - `auto` (default): use the auto-detect rule
  - `yes` / `1`: force sensitive regardless of mode
  - `no` / `0`: force not sensitive regardless of mode
- A metadata change to make a previously-sensitive file world-readable is **always** notified prominently (this is the security-relevant event)

**Email notifier:**
- One mail per recipient, batching all their files
- `From: $email_from` (HOSTNAME-substituted)
- `Subject: [changetrack-ng] Changes on $hostname @ $date`
- Body: per-file blocks, each with metadata change summary + diff (or sensitive placeholder)
- Sendmail pipe: detect `/usr/sbin/sendmail` first, then `/usr/lib/sendmail`, fall back to `sendmail` in PATH; die gracefully with notification-skipped warning if none found
- Per-file recipients in track entries (from v1) are merged with `[global]` `email_to` (if added later) and any `--mail-to` CLI flag
- **Heartbeat: forced off.** `heartbeat_enabled` always returns false regardless of any config key. Email is anti-spam by design — silence means no changes, period. Monitoring "is the agent alive" is the OTLP/Webhook channel's job.

**File notifier:**
- Append-only to `notify_log_path`
- One JSON object per run (entire report) — single line for grep-ability, but pretty-print mode optional
- Locking via `flock` to handle concurrent runs (paranoia)
- **Heartbeat:** controlled by `file_heartbeat = 0|1`, default `0`. When enabled, every run appends a record (even with no changes) — useful for log-shipper-based monitoring (Loki/Splunk/etc. tailing the file). The heartbeat record has `"heartbeat": true` and an empty `files` array.

**Exit criteria:**
- [ ] Email notifier produces correct mail when tested with mock sendmail (verifies headers, recipient batching, body content)
- [ ] File notifier appends one JSON object per run, valid JSON each line
- [ ] Sensitive auto-detect works: file with `0640` perms gets diff suppressed in notification
- [ ] Sensitive override works: `sensitive=no` on an `0640` file sends full diff
- [ ] Sensitive metadata change (e.g. `0640` → `0644`) is reported in full even when content diff is suppressed
- [ ] VCS history contains full diff regardless of sensitive flag (verify by reading back via `vcs->diff` after commit)
- [ ] Email never sends on a no-change run, even if `email_heartbeat=1` is set in config (forced-off contract verified)
- [ ] File notifier with `file_heartbeat=1` appends a heartbeat record on a clean no-change run; with `=0` it appends nothing

---

### Phase 4: Whole-Repo VCS — Git Backend

**Goal:** Validate the abstraction holds for whole-repo backends. Single Git backend exercises every interface concern that Fossil/SVN/Hg will later replicate.

**New files:**
- `lib/ChangeTrack/VCS/Git.pm`
- `t/06-vcs-git.t`

**Implementation:**
- `output_path()` returns `$output_dir/$real_path` (mirror tree, e.g. `/var/lib/changetrack-ng/etc/passwd`)
- `init()` creates `$output_dir`, runs `git init`, sets `user.email`/`user.name` from config (defaults: `changetrack-ng@hostname` / `changetrack-ng`)
- `add()` copies real file to mirror path (creating intermediate dirs), then `git add $mirror_path`
- `checkin()` is just `add()` (deferred commit)
- `commit()` runs `git commit -m "$msg"` — but only if there's something staged (`git diff --cached --quiet`)
- `diff()` runs `git diff --no-color HEAD -- $mirror_path` for already-tracked, or computes diff of new file vs `/dev/null`
- `is_dirty()` is `git status --porcelain $mirror_path`
- `revert($file, $rev)` is `git checkout $rev -- $mirror_path` then copy back to real location (with confirmation prompt)
- `model()` returns `'whole-repo'`
- After successful commit: if `push_remote` set, run `git push $remote` for each (best-effort, log warning on fail)

**Cross-cutting changes in this phase:**
- `Runner` learns to call `add()` for new files separately from `checkin()` (or merge them — design decision: `checkin` is the universal verb, internal to each backend whether it stages or commits)
- Metadata sidecar location: for Git, write to `$output_dir/.changetrack-metadata` and let Git track it as a normal file (excluded from .gitignore — it's tracked content)
- Switching `vcs` value between runs without a fresh `output_dir` is a hard error (different on-disk layouts)

**Exit criteria:**
- [ ] First run on a fresh tree produces a Git repo with mirror tree and one initial commit
- [ ] Second run with no changes makes no commit (`git log` count unchanged)
- [ ] Modifying a file produces one new commit with the right message
- [ ] Modifying multiple files in one run produces ONE atomic commit
- [ ] Metadata sidecar is committed as part of the snapshot
- [ ] `push_remote = origin` pushes after commit (test with a local bare repo as remote)
- [ ] `t/06-vcs-git.t` skip_all if `git` not installed

---

### Phase 5: Webhook Notifier

**Goal:** Webhook delivery via `HTTP::Tiny` (Perl core).

**New files:**
- `lib/ChangeTrack/Notify/Webhook.pm`
- `t/08-notify-webhook.t`

**Payload structure (changes):**
```json
{
  "tool": "changetrack-ng",
  "version": "0.3.0",
  "hostname": "...",
  "timestamp": "2026-04-27T14:00:00Z",
  "vcs": "git",
  "message": "changetrack-ng run @ ...",
  "heartbeat": false,
  "files_tracked": 142,
  "run_duration_ms": 1837,
  "files": [
    {
      "path": "/etc/passwd",
      "is_new": false,
      "is_removed": false,
      "is_sensitive": false,
      "diff_lines_added": 1,
      "diff_lines_removed": 1,
      "metadata_changed": false,
      "diff": "..."           // only present if webhook_full_diff=1 and !is_sensitive
    }
  ]
}
```

**Heartbeat payload** (only sent when `webhook_heartbeat=1` AND no changes detected):
```json
{
  "tool": "changetrack-ng",
  "version": "0.3.0",
  "hostname": "...",
  "timestamp": "2026-04-27T14:00:00Z",
  "vcs": "git",
  "message": "changetrack-ng heartbeat (no changes)",
  "heartbeat": true,
  "files_tracked": 142,
  "run_duration_ms": 1837,
  "files": []
}
```

The `heartbeat` boolean is always present (even on changes payloads), so receivers can filter on it without inspecting `files.length`.

**Behavior:**
- Multiple URLs supported (space-separated `webhook_url`)
- POST with `Content-Type: application/json`, configurable timeout (default 10s)
- Retry: 3 attempts with exponential backoff for transient failures (5xx, network errors)
- 4xx responses are not retried (assume permanent client error, log warning)
- TLS verification on by default; `webhook_insecure = 1` to disable for self-signed certs (with a loud warning)
- **Heartbeat:** controlled by `webhook_heartbeat = 0|1`, default `0` (preserves traditional "send only on change" behavior). When enabled, every clean run produces a POST — receivers can detect agent silence as "missing heartbeats" rather than ambiguous "no traffic". Heartbeats use the same retry/timeout policy as change payloads.

**Test approach:** spin up a tiny server in a forked child via `IO::Socket::INET` (core), accept one POST, verify body, exit. No external test deps.

**Exit criteria:**
- [ ] Single URL POST works with summary payload
- [ ] Multiple URLs all receive the payload
- [ ] `webhook_full_diff = 1` includes diff content (except sensitive files)
- [ ] Server returning 500 triggers retry then logs warning
- [ ] Server returning 404 logs warning without retry
- [ ] Network unreachable doesn't abort the run
- [ ] `webhook_heartbeat = 0` (default) produces no POST on a clean no-change run
- [ ] `webhook_heartbeat = 1` produces exactly one POST per clean no-change run with `heartbeat: true`
- [ ] Heartbeat payload retries on 5xx using the same policy as change payloads

---

### Phase 6: Polish — Ignore, Pre-commit Checks, Locking

**Goal:** Operational robustness features. After this phase, the tool is production-deployable for the RCS+Git use case.

**Sub-tasks:**

**6a. Ignore patterns** (`Runner` + new `update-ignore` subcommand)
- Apply ignore globs during `File::Find` traversal (skip matching paths)
- Built-in defaults applied on top of user `ignore` list (with built-ins overridable):
  - Editor temp: `*.swp`, `*~`, `#*#`, `.*.sw?`
  - Package manager: `*.dpkg-*`, `*.dpkg-old`, `*.rpmnew`, `*.rpmsave`, `*.pacnew`, `*.pacorig`, `*.pacsave`, `*.apk-new`
  - System runtime: `mtab`, `mtab.fuselock`, `ld.so.cache`, `prelink.cache`, `adjtime`, `udev/hwdb.bin`, `lvm/cache`, `lvm/archive`, `network/run`, `.pwd.lock`
  - Misc: `*.pyc`, `*.pyo`, `*.elc`, `init.d/.depend.*`
- New subcommand `changetrack-ng update-ignore` writes VCS-native ignore file (`.gitignore`, `.hgignore`, `.fossil-ignore`) for whole-repo backends, with `# managed by changetrack-ng` markers like etckeeper

**6b. Pre-commit checks** (port from `etckeeper/pre-commit.d/20warn-problem-files`)
- Special files (sockets, FIFOs, devices) → warn, skip from VCS, log to report
- Hardlinked regular files (`nlink > 1`) → warn (most VCS silently break hardlinks)
- Suppressible: config `warn_special_files = 0` or CLI `--quiet`

**6c. Locking** (`lib/ChangeTrack/Lock.pm`)
- `flock` on `lock_path` (default `/var/run/changetrack-ng.lock` for root, `~/.cache/changetrack-ng.lock` for user)
- `LOCK_EX | LOCK_NB`; if blocked: skip silently and exit 0 (cron-friendly default)
- `lock_timeout > 0`: retry every second up to N seconds before giving up
- `--force` CLI flag breaks the lock (with warning)

**New files:**
- `lib/ChangeTrack/Lock.pm`
- `t/11-ignore.t`, `t/12-locking.t`, `t/17-precommit-checks.t`

**Exit criteria:**
- [ ] Files matching ignore globs are skipped (verified per-pattern)
- [ ] Built-in defaults skip common noise without user config
- [ ] `update-ignore` subcommand writes correct `.gitignore` for Git backend (round-trippable)
- [ ] Concurrent run with held lock exits 0 silently
- [ ] `lock_timeout = 5` waits then proceeds when the lock releases
- [ ] Special file warning fires for a FIFO; file is skipped from commit
- [ ] Hardlink warning fires for a regular file with `nlink > 1`

---

### Phase 7: Remaining VCS Backends

**Goal:** Fossil, SVN, Mercurial. Mostly mechanical given the abstraction is validated.

**New files:**
- `lib/ChangeTrack/VCS/Fossil.pm`
- `lib/ChangeTrack/VCS/SVN.pm`
- `lib/ChangeTrack/VCS/Mercurial.pm`
- `t/13-vcs-fossil.t`, `t/14-vcs-svn.t`, `t/15-vcs-hg.t`

**Notable per-backend quirks:**

- **Fossil:** repo is a single `.fossil` file outside the working dir; need to track repo-file path separately from working dir. Use `fossil init <repo>` then `fossil open <repo>` in the mirror tree. Ignore via `fossil settings ignore-glob`. No native ignore file but a `.fossil-settings/ignore-glob` directory works.
- **SVN:** local repo via `svnadmin create` + `svn checkout file://...` into mirror tree. Ignore via `svn:ignore` property — set with `svn propset`. Push: `svn commit` already pushes (unlike git/hg/fossil).
- **Mercurial:** `hg init` in mirror tree. Ignore via `.hgignore` (regex by default; we'll use `syntax: glob` header). Push via `hg push <remote>`.

**Exit criteria for each backend:**
- [ ] Init creates correct repo structure
- [ ] Atomic commit captures multi-file changes
- [ ] Diff/log/revert work
- [ ] Ignore file generation produces VCS-native syntax
- [ ] Push (where applicable) works to a local test remote
- [ ] Each test file `skip_all` if the VCS tool isn't installed

---

### Phase 8: Subcommands

**Goal:** User-facing operations beyond `run`.

**Subcommands to implement:**
- `run` (already done) — scan and commit; default action
- `init` — explicit initialization (already implicit; add the explicit form)
- `status` — show files that would be committed without committing
- `diff [path]` — show pending diff for one file (or all)
- `log [path]` — show history (delegates to backend)
- `revert <path> <rev>` — restore a file from a specific revision (with confirmation)
- `update-ignore` (already done in 6a)
- `migrate-config <v1-path> [<v2-output>]` — convert v1 config to v2

**`migrate-config` notes:**
- Reads v1 grammar, emits v2 INI
- `@ <find-expr>` entries become `# TODO: manual translation needed` comment + commented-out `DIRECTORY` line; can't safely auto-translate find expressions
- Preserves email annotations
- Adds a sensible `[global]` section with defaults the user can review

**New files:**
- `t/16-subcommands.t`
- (subcommand handlers go in `bin/changetrack-ng` plus dispatch to `Runner`)

**Exit criteria:**
- [ ] All subcommands listed in `--help` and have basic test coverage
- [ ] `status` exits 0 if clean, 1 if dirty (cron-friendly check)
- [ ] `diff` and `log` produce VCS-equivalent output
- [ ] `revert` prompts before overwriting unless `--force`
- [ ] `migrate-config` round-trips a typical v1 file with reasonable defaults

---

### Phase 9: OpenTelemetry (OTLP) Notifier

**Goal:** Modular OTLP/HTTP+JSON exporter for centralized monitoring/aggregation, sitting alongside Email/Webhook/File at the same `Notify::*` tier. Native, dependency-free implementation.

**Why OTLP** (vs. just relying on the webhook from Phase 5):
The webhook gives generic HTTP POST integration; OTLP gives a standardized telemetry format consumable by any OpenTelemetry collector (Loki, Tempo, Splunk, Datadog, Elastic, Honeycomb, etc.) with no per-vendor adapter code on either side. For centralized fleet-wide monitoring of `/etc` changes, this is materially more useful than a vendor-specific webhook payload.

**Dependency analysis:**

All required Perl modules are already core in 5.14+ (well within our 5.20 floor):

| Module | Purpose | Core since |
|---|---|---|
| `HTTP::Tiny` | HTTP transport | 5.14 |
| `JSON::PP` | JSON encode | 5.14 |
| `IO::Compress::Gzip` | gzip body compression | 5.10 |
| `IO::Socket::SSL` | HTTPS (already needed for webhook) | not core, but de-facto present |

→ **Zero additional Perl module dependencies.** OTLP support sits at the same dependency tier as the webhook notifier — if webhook works, OTLP works. Documented in INSTALL.md alongside the webhook note about `IO::Socket::SSL` for HTTPS.

**Transport choice:** OTLP/HTTP with JSON encoding only.
- OTLP/gRPC requires `Grpc::XS` — non-core, heavy, excluded.
- OTLP/HTTP+protobuf requires `Google::ProtocolBuffers` — non-core, excluded.
- OTLP/HTTP+JSON is officially supported by all major collectors and is the natural fit for a Perl tool.

**Telemetry signal:** Logs (one OTLP `LogRecord` per file change). Per-run metrics (counters, run-duration histogram) and traces (run-as-trace, file-as-span) considered as v0.4 stretch goals — see notes below.

**New files:**
- `lib/ChangeTrack/Notify/OTLP.pm`
- `t/19-notify-otlp.t`

**Config keys (`[global]`):**

```ini
notify                   = email webhook otlp     # otlp added to notification list
otlp_endpoint            = https://otel.example.com/v1/logs
                                                  # full URL with /v1/logs path
otlp_full_diff           = 0                      # 0 = summary only; 1 = include diff content
otlp_compression         = gzip                   # gzip|none
otlp_headers             = Authorization=Bearer\ xxx X-Tenant=acme
                                                  # space-separated k=v pairs; backslash-escape spaces
otlp_timeout             = 10                     # seconds
otlp_insecure            = 0                      # 1 disables TLS verification (warns)
otlp_resource_attributes = deployment.environment=prod team=platform
                                                  # additional resource attributes beyond defaults
otlp_heartbeat           = 1                      # default ON: send beacon each clean no-change run
                                                  # set to 0 to suppress
```

**Default resource attributes** (sent on every export, before user overrides):

| Attribute | Source |
|---|---|
| `service.name` | `"changetrack-ng"` |
| `service.version` | `"0.3.0"` |
| `service.instance.id` | `<hostname>` |
| `host.name` | `<hostname>` |
| `host.id` | `/etc/machine-id` if readable, else absent |
| `os.type` | `lc(uname -s)` |

`otlp_resource_attributes` from config is merged on top — user values win on conflict.

**Log record schema (one per file change):**

```json
{
  "timeUnixNano": "<ns since epoch — when the change occurred>",
  "observedTimeUnixNano": "<ns since epoch — when changetrack-ng noticed>",
  "severityNumber": 9,
  "severityText": "INFO",
  "body": {"stringValue": "File changed: /etc/passwd"},
  "attributes": [
    {"key": "ct.path",               "value": {"stringValue": "/etc/passwd"}},
    {"key": "ct.vcs",                "value": {"stringValue": "git"}},
    {"key": "ct.is_new",             "value": {"boolValue": false}},
    {"key": "ct.is_removed",         "value": {"boolValue": false}},
    {"key": "ct.is_sensitive",       "value": {"boolValue": false}},
    {"key": "ct.metadata_changed",   "value": {"boolValue": false}},
    {"key": "ct.diff_lines_added",   "value": {"intValue": 1}},
    {"key": "ct.diff_lines_removed", "value": {"intValue": 1}},
    {"key": "ct.commit_id",          "value": {"stringValue": "<vcs commit ref or rcs rev>"}},
    {"key": "ct.diff",               "value": {"stringValue": "<full diff>"}}
                                       /* present only when otlp_full_diff=1 AND !is_sensitive */
  ]
}
```

The full export wraps these in OTLP's `resourceLogs[].scopeLogs[].logRecords[]` envelope (a single resource per export, single scope `changetrack-ng`).

**Heartbeat log record** (only sent when `otlp_heartbeat=1` AND no changes detected — default behavior):

```json
{
  "timeUnixNano": "<run start ns>",
  "observedTimeUnixNano": "<run start ns>",
  "severityNumber": 9,
  "severityText": "INFO",
  "body": {"stringValue": "changetrack-ng heartbeat (no changes)"},
  "attributes": [
    {"key": "ct.heartbeat",       "value": {"boolValue": true}},
    {"key": "ct.vcs",             "value": {"stringValue": "git"}},
    {"key": "ct.files_tracked",   "value": {"intValue": 142}},
    {"key": "ct.run_duration_ms", "value": {"intValue": 1837}}
  ]
}
```

The `ct.heartbeat` boolean attribute is also present (set to `false`) on regular change records, so dashboards can filter `ct.heartbeat = true` to chart "agent alive" signals separately from change events. The `ct.files_tracked` and `ct.run_duration_ms` attributes are present on both kinds of records — useful for spotting "agent silently stopped tracking some files" via dashboard alerts on the count gauge.

**Why heartbeat defaults ON for OTLP:** OTLP is specifically a monitoring/observability protocol. The whole reason to ship telemetry to a collector is so that monitoring systems can alert on conditions including absence-of-events. Without heartbeats, `no logs from $hostname for 24h` is ambiguous (no changes? agent dead? config broken? collector outage?). With heartbeats at the configured `interval`, missing heartbeats are unambiguously bad — the canonical "alert on absence" pattern. Users wanting to suppress can set `otlp_heartbeat=0`.

**Severity mapping:**

| Event | severityNumber | severityText |
|---|---|---|
| File added or content changed (normal) | 9 | INFO |
| Sensitive file: content changed (no perm change) | 9 | INFO |
| Sensitive file: permissions loosened (e.g. 0640 → 0644) | 13 | WARN |
| Special file detected (FIFO, socket, device) | 13 | WARN |
| Hardlinked file detected (`nlink > 1`) | 13 | WARN |
| VCS error during run | 17 | ERROR |

**Sensitive file handling:** identical contract to webhook (Phase 5). The `ct.diff` attribute is omitted for sensitive files even when `otlp_full_diff=1`. The change itself is still reported — `ct.path`, `ct.is_sensitive=true`, line counts, metadata change. Suppression applies only to diff content. `sensitive_notify = allow` overrides as with email/webhook.

**Compression:** when `otlp_compression = gzip`, the JSON body is gzipped via `IO::Compress::Gzip` and `Content-Encoding: gzip` is set. Honored by all standard OTLP collectors; significant size reduction for full-diff payloads.

**Headers and auth:**
- `otlp_headers` parsed as space-separated `key=value` pairs with backslash-escaped spaces inside values.
- Environment variable `OTEL_EXPORTER_OTLP_HEADERS` (comma-separated `k=v` pairs, per OpenTelemetry spec) takes precedence over config — enables CI / secret-manager integration without putting tokens in the config file.
- `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` env vars also honored, matching the spec.

**Endpoint normalization:** the OTLP/HTTP spec requires the path component `/v1/logs`. If `otlp_endpoint` doesn't end in `/v1/logs`, append it (with a warning on first run so the user can fix their config).

**Retry / failure behavior:** identical to webhook — 3 retries with exponential backoff for 5xx and network errors; no retry for 4xx; failures are warnings, never abort the run. Failed exports never block VCS commits.

**Tests** (`t/19-notify-otlp.t`):
- Forked HTTP server (~50 lines using core `IO::Socket::INET`) acts as a mock OTLP receiver
- Verify request body decodes to valid OTLP JSON, has correct resource attributes, log record count, severity
- Verify gzip: receiver decodes `Content-Encoding: gzip` body
- Verify `otlp_full_diff=0` omits `ct.diff` attribute; `=1` includes it for non-sensitive files
- Verify sensitive file: `ct.diff` omitted with `otlp_full_diff=1`
- Verify `OTEL_EXPORTER_OTLP_HEADERS` env var overrides config
- Verify endpoint normalization: `https://x.example/` → `https://x.example/v1/logs` (with warning)
- Verify retry on 503, give up after 3 attempts, log warning
- Verify run continues normally when receiver is unreachable
- Verify `otlp_heartbeat=1` (default) sends exactly one log record with `ct.heartbeat=true` on a clean no-change run
- Verify `otlp_heartbeat=0` sends nothing on a clean no-change run
- Verify change records include `ct.heartbeat=false` (so dashboards can filter unambiguously)

**Stretch (deferred to v0.4):**
- **OTLP metrics:** counters for `ct.files_changed_total`, `ct.runs_total`, `ct.errors_total`, `ct.sensitive_changes_total`; histogram for `ct.run_duration_seconds`. Requires implementing the OTLP metrics schema (more verbose than logs but mechanically similar).
- **OTLP traces:** each run as a trace, each file as a span. Useful for performance diagnosis on slow runs but lower value than logs/metrics.
- **W3C trace context propagation:** if changetrack-ng is invoked from a hook with `TRACEPARENT`/`TRACESTATE` env vars set (e.g. by an instrumented package manager), include them in the export as parent context.

**Exit criteria:**
- [ ] OTLP notifier implemented with zero external Perl dependencies (verified by `make test` on a minimal Perl 5.20 install with only core modules)
- [ ] Mock OTLP receiver test passes for summary mode (`otlp_full_diff=0`)
- [ ] Mock OTLP receiver test passes for full-diff mode (`otlp_full_diff=1`)
- [ ] Sensitive file diff content is omitted in OTLP records
- [ ] Gzip compression works end-to-end (mock receiver decompresses successfully)
- [ ] Severity escalation works (permission loosened on sensitive file → WARN)
- [ ] `otlp_headers` parsing handles backslash-escaped spaces correctly
- [ ] `OTEL_EXPORTER_OTLP_HEADERS` env var precedence verified
- [ ] Endpoint normalization warns once and appends `/v1/logs` correctly
- [ ] Failed export logs warning but doesn't abort run
- [ ] Heartbeat default ON verified end-to-end (clean no-change run produces one record)
- [ ] Heartbeat suppression (`otlp_heartbeat=0`) verified
- [ ] Manual test: send to a real local OTel Collector (e.g. `otel/opentelemetry-collector-contrib`) and verify receipt in the collector's debug exporter, including heartbeat records distinguishable from change records via `ct.heartbeat` attribute

---

### Phase 10: Integration — Hooks, Systemd, Cron

**Goal:** First-class integration with system tooling.

**Sub-tasks:**

**10a. Package manager hooks**
- Hook files in `packaging/hooks/` directory (apt/pacman shell hook formats, plus dnf Python plugin)
- `make install-hooks`: detects active package manager from `/etc/os-release` or presence of binaries (`apt`, `dnf`, `pacman`, `zypper`), installs into the appropriate location:
  - apt: `/etc/apt/apt.conf.d/80changetrack-ng`
  - dnf: `/etc/dnf/plugins/changetrack_ng.py` + `/etc/dnf/plugins/changetrack_ng.conf`
  - pacman: `/usr/share/libalpm/hooks/changetrack-ng-pre.hook` + `-post.hook`
  - zypper: `/etc/zypp/zypper.d/changetrack-ng` (zypper plugin mechanism is more involved; may defer)
- Each hook just calls `changetrack-ng run -m "pre-install: $PACKAGE"` (or post-)

**10b. Systemd timer**
- `packaging/systemd/changetrack-ng.service`: oneshot type, runs `/usr/local/bin/changetrack-ng run`
- `packaging/systemd/changetrack-ng.timer`: `OnCalendar=hourly` (or whatever `interval` config says — but the timer file is static; if user changes interval they re-`make install-systemd` or override with a drop-in)
- `make install-systemd`: copies units, runs `systemctl daemon-reload`, suggests `systemctl enable --now changetrack-ng.timer`

**10c. Cron**
- `packaging/cron/changetrack-ng`: shell script that checks for the systemd timer first (skip if active), then runs the tool
- `make install-cron`: installs to `/etc/cron.hourly/changetrack-ng` with mode `0755`

**Exit criteria:**
- [ ] Hook scripts manually verifiable: invoke them with mock env vars and confirm `changetrack-ng run` is called with right args
- [ ] `make install-systemd` installs units and prints next-steps
- [ ] `make install-cron` and `make install-systemd` are mutually exclusive (or at least, the cron script no-ops when the timer is enabled)
- [ ] One distro-specific install verified end-to-end (likely Debian, given availability) — manual test, not automated

---

### Phase 11: Distribution & Documentation

**Goal:** Ready-to-distribute tarball with full docs.

**Sub-tasks:**

- `man/changetrack-ng.8` — POD source committed; converted to roff at build time via `pod2man`
- `man/changetrack-ng.conf.5` — same
- `README.md` — full overview, quickstart, comparison with original changetrack and etckeeper
- `INSTALL.md` — install paths, dependency notes, distro-specific gotchas
- `CHANGELOG.md` — `0.3.0` entry summarizing initial features
- `Makefile` `dist` target — produces `changetrack-ng-0.3.0.tar.gz` with all source + docs
- POD documentation in every `lib/ChangeTrack/*.pm` (extracted by `perldoc`)

**Optional (deferred to v0.4 or v1.0):**
- Debian packaging skeleton (`packaging/debian/` dir, `debmake`-friendly)
- RPM spec file
- AUR PKGBUILD

**Exit criteria:**
- [ ] `make dist` produces a clean tarball
- [ ] Tarball extracts and `make && make test && sudo make install` works on a clean Debian/Ubuntu VM
- [ ] `man changetrack-ng` and `man changetrack-ng.conf` show correctly formatted pages
- [ ] `perldoc ChangeTrack::Config` (etc.) shows module documentation

---

## 6. Cross-Cutting Concerns

### 6.1 Error handling philosophy

| Error class | Behavior | Exit code |
|---|---|---|
| Per-file: permission denied, transient I/O, special file | Warn, skip file, continue | 0 |
| Per-file: unsafe filename (control chars, shell metachars) | Warn, skip file, log to report | 0 |
| Notification failure (sendmail, webhook 5xx after retries) | Warn, log, continue | 0 |
| VCS-level failure (commit error, repo corrupted) | Abort run | 2 |
| Config parse error | Abort with line number | 64 |
| Lock held (no timeout) | Silent skip | 0 |
| Lock timeout exceeded | Warn, exit | 75 |
| Help / version | Print and exit | 0 |
| Bad CLI args | Usage to stderr, exit | 64 |

(Following sysexits.h conventions where applicable.)

### 6.2 Logging

- `--quiet`: only warnings/errors to stderr
- (default): one-line-per-file progress to stdout, summary at end
- `--verbose`: per-step internal state, useful for debugging
- All log lines prefixed with `[changetrack-ng]` or sub-component name

### 6.3 Security

- **Filename sanitization:** existing changetrack already rejects filenames with control chars and shell metas — preserved. Extend to reject NUL bytes, non-UTF-8 sequences (warning, configurable strictness).
- **Subprocess execution:** never use `system($string)` or backticks with interpolated paths. All external commands invoked via array form (`system(@args)` or `IPC::Run::run(\@args, ...)`).
- **Sensitive files:** auto-detect by mode (see Phase 3). Diffs of sensitive files never leave the local system via notification, only persist to the local VCS repo.
- **Output dir permissions:** `init()` creates dir with mode `0700` (root) or `0750` (user) by default. Tracked content can include sensitive material.
- **Webhook URLs:** TLS verification on by default. Tokens/secrets in webhook URLs are an existing concern; document that `webhook_url` may contain credentials and the config file should be `0600`.

### 6.4 Concurrency model

- Single-process, single-threaded per run
- Locking prevents overlapping runs (see Phase 6c)
- Notifications happen at the end of the run, after all VCS operations — failed notifications never corrupt the VCS state
- VCS backends that are themselves not safe under concurrent access (RCS without proper locks) rely on the changetrack-ng lock to prevent issues

### 6.5 Forward compatibility

- Config file has implicit version (v1 detected by absence of sections; v2 explicit)
- Future v3 introduces `version = 3` key in `[global]`; absence implies v2
- JSONL metadata format is forward-compatible (extra fields ignored by older readers)
- Adding a new VCS backend: new module + register in `Runner`'s vcs-class lookup; no other changes needed

---

## 7. Open Questions / Deferred to Future

- **Removed file handling:** when a tracked file disappears, current proposal is to log it in metadata and leave VCS history intact. Should there be an option to also explicitly mark "file removed" in the VCS commit (e.g. `git rm` for the mirror tree)? Defer to user feedback after Phase 4.
- **Diff size limits:** very large file changes can produce huge diffs, painful in email. Add `max_diff_lines` config option in v0.4 — truncate diff with `[... N more lines ...]` marker if exceeded.
- **Encryption at rest:** out of scope for v0.3. Users wanting encrypted history can use git-crypt / equivalent on top.
- **GUI / web UI:** out of scope. Possibly a separate companion project later.
- **Centralized server mode:** out of scope. The webhook notifier is the integration point for any centralized aggregator.
- **Windows support:** not a goal. Tool targets Unix-like systems (Linux primary, BSD/macOS best-effort).
- **`fossil` server-side push:** Fossil's push model differs from git's; may need a separate `push_remote` syntax or different config key. Validate during Phase 7.

---

## 8. Phase Dependency Graph

```
Phase 1 (Foundation)
    └─→ Phase 2 (Core MVP — RCS)
            ├─→ Phase 3 (Notifications + Sensitive)
            │       ├─→ Phase 5 (Webhook)
            │       │       └─→ Phase 9 (OTLP)
            │       └─→ (Phase 9 also depends on Phase 5 patterns)
            └─→ Phase 4 (Git backend)
                    └─→ Phase 6 (Polish — Ignore, Precommit, Lock)
                            └─→ Phase 7 (Remaining VCS: Fossil, SVN, Hg)
                                    └─→ Phase 8 (Subcommands)
                                            └─→ Phase 10 (Integration: Hooks, Systemd, Cron)
                                                    └─→ Phase 11 (Distribution + Docs)
```

Phases 3 and 4 are independent of each other after Phase 2 — could be parallelized if desired, but the natural session-by-session progression is sequential. Phase 9 (OTLP) reuses the HTTP transport patterns established in Phase 5 (Webhook) and can technically be done any time after Phase 5; placement after Phase 8 is purely a feature-priority ordering, not a hard dependency.

**Estimated effort** (single-developer, focused part-time work):
- Phase 1: 1–2 sessions
- Phase 2: 2–3 sessions (most design crystallization happens here)
- Phase 3: 1–2 sessions
- Phase 4: 2 sessions
- Phase 5: 1 session
- Phase 6: 2 sessions
- Phase 7: 2–3 sessions (one per backend, mostly mechanical)
- Phase 8: 1–2 sessions
- Phase 9: 1–2 sessions (OTLP — schema work + mock-receiver test harness is the bulk)
- Phase 10: 2 sessions
- Phase 11: 1 session

**Total:** ~16–22 focused work sessions for a complete v0.3.0.

---

## 9. Done Criteria for v0.3.0

A v0.3.0 release ships when:
- [ ] All 11 phases complete
- [ ] Test suite passes on Linux with all five VCS tools installed
- [ ] Smoke-tested manually on at least one Debian-family and one RHEL-family system
- [ ] `make dist` tarball installs cleanly with `make install`
- [ ] `man changetrack-ng` works post-install
- [ ] Existing v1 changetrack config can be migrated and runs equivalently with `vcs = rcs`
- [ ] OTLP exporter verified end-to-end against a real OpenTelemetry Collector instance

# changetrack-ng — Product Overview

**Homepage:** <https://github.com/cashell/changetrack-ng>

Version: 0.5.4

---

## What It Does

`changetrack-ng` is a system file change tracker for Linux systems. It monitors arbitrary files and directories for modifications, records their history in a version control system, and optionally sends notifications when changes are detected. It is designed to run unattended via cron or systemd timer, providing an auditable record of configuration drift, unauthorized edits, or routine maintenance activity.

It is a complete rewrite of the original `changetrack` (last maintained 2009), combining per-file flexibility with `etckeeper`-style metadata tracking, ignore patterns, and multi-VCS support.

---

## Key Features

- **Multi-VCS backends** — Git, RCS, Fossil, SVN, or Mercurial. Choose the tool your team already knows.
- **Pluggable notifications** — Email, webhook (HTTP POST JSON), OTLP (OpenTelemetry logs), or local JSON file log. Multiple notifiers can be active simultaneously.
- **Sensitive file protection** — Files without world-read permission are automatically flagged; diffs can be suppressed from notifications to prevent secret leakage.
- **Metadata tracking** — Records ownership, permissions, file type, and symlink targets alongside content history.
- **Ignore patterns** — Glob-based exclusions to skip noisy or irrelevant files within tracked directories.
- **Package manager hooks** — Pre/post-transaction snapshots for apt, dnf, and pacman annotate commits with package operations.
- **Heartbeat signaling** — Configurable "no changes" heartbeats for monitoring systems that alert on silence.
- **Zero non-core dependencies** — Runs on any Perl 5.20+ system with no CPAN modules required.
- **Cron-safe locking** — `flock`-based; overlapping invocations silently skip rather than corrupt state.

---

## Subcommands

| Command | Purpose |
|---------|---------|
| `run` (default) | Full scan → commit → notify cycle |
| `init` | Initialize the VCS output directory |
| `status` | Show files with pending changes (exit 1 if any) |
| `diff [path]` | Show unified diff for pending or historical changes |
| `log [path]` | Show VCS history for a tracked file |
| `revert <path> <rev>` | Restore a file to a specific historical revision |
| `update-ignore` | Sync VCS-native ignore file with configured patterns |
| `migrate-config` | Convert a legacy v1 config file to the current v2 format |

---

## Configuration

Configuration uses an INI-style format with two sections:

```ini
[global]
output_dir   = /var/lib/changetrack-ng
vcs          = git
notify       = email webhook
email_to     = ops@example.com
webhook_url  = https://hooks.example.com/changetrack
ignore       = *.swp *~ .git

[track]
/etc
/usr/local/etc
/var/spool/cron
/home/deploy/.ssh/authorized_keys
```

**Global settings** control VCS backend selection, notification channels, ignore patterns, sensitive file behavior, and operational parameters (lock timeout, push remotes, OTLP endpoints, etc.).

**Track entries** list individual files or directories to monitor. Directories are traversed recursively; ignore patterns apply during traversal.

The `HOSTNAME` token is interpolated in values, useful for multi-host configs managed by a CM tool.

---

## VCS Backends

| Backend | Model | Commit style | Notes |
|---------|-------|-------------|-------|
| Git | Whole-repo mirror | Batch (all changes in one commit per run) | Optional `push_remote` for central collection |
| RCS | Per-file flat layout | Immediate (`ci -l` per file) | Lightweight; no external repo needed |
| Fossil | Whole-repo mirror | Batch | Self-contained SQLite repo |
| SVN | Whole-repo mirror | Batch | Local `file://` repository via `svnadmin` |
| Mercurial | Whole-repo mirror | Batch | Uses `hg -R` (no working directory change) |

All whole-repo backends store tracked files in a mirror tree: `/etc/passwd` becomes `$output_dir/etc/passwd`. Symlinks are serialized as text files containing their target path.

---

## Notification Channels

| Channel | Payload | Heartbeat | Use case |
|---------|---------|-----------|----------|
| Email | Plain-text with inline diffs | Always off | Human review; existing alerting workflows |
| Webhook | JSON POST to one or more URLs | Opt-in | ChatOps, ticketing, custom integrations |
| OTLP | OpenTelemetry log records (gzip) | On by default | Observability platforms; alert-on-absence |
| File | Append-only JSONL | Opt-in | Local audit trail; log shipping |

Notifications include: hostname, timestamp, list of changed files, metadata diffs, and (unless suppressed) content diffs.

---

## Scheduling

`changetrack-ng` is designed for periodic invocation:

- **systemd timer** (preferred): hourly with `Persistent=true` to catch up after downtime.
- **cron**: drop-in script for `/etc/cron.hourly/`.
- **Package hooks**: apt, dnf, and pacman hooks trigger pre/post-transaction runs with annotation messages (`-m "apt: <package list>"`).

The flock-based lock ensures concurrent invocations (e.g., cron + package hook) do not conflict.

---

## File Type Handling

| Detected type | Tracked content | Example |
|---------------|----------------|---------|
| Regular text file | Full versioned diff | `/etc/passwd` |
| Symlink | Link target path | `/etc/localtime` |
| Binary file | Metadata only (size, perms, ownership) | `/etc/selinux/.../policy.kern` |
| Empty file | Metadata only | `/etc/machine-id` (before population) |
| Unreadable file | Metadata only (warns on first detection) | `/etc/shadow` |
| Special (FIFO, socket, device) | Metadata only (warns) | `/dev/log` |
| Missing (previously tracked) | Reported as removed | Deleted config files |

---

## Diagnostics

Three levels of diagnostic output are available, all written to STDERR (keeping STDOUT clean for subcommand data):

| Flag | Level | Implies | What it shows |
|------|-------|---------|---------------|
| `-v, --verbose` | `[VERBOSE]` | — | High-level run structure: config file path used, VCS backend and output directory, lock status, resolved path count, commit and notification milestones, run summary |
| `-d, --debug` | `[DEBUG]` | verbose | Every external VCS command with full arguments, effective config values (secrets redacted), files where action is taken (new/changed/removed), notification send outcomes |
| `-t, --trace` | `[TRACE]` | debug | Per-file disposition for every tracked file — fast-path skips (mtime+size unchanged), type classifications, ignore-pattern matches. Produces O(N) output for N tracked files. Use for diagnosing why a specific file is or isn't being tracked. |

Examples:

```bash
# High-level run overview
changetrack-ng --verbose run

# Full diagnostic detail (commands + actioned files)
changetrack-ng --debug run 2>debug.log

# Everything including per-file decisions (can be very large)
changetrack-ng --trace run 2>trace.log

# Inspect config + VCS commands without modifying anything
changetrack-ng --debug --dry-run run
```

---

## Installation Layout

```
/usr/local/bin/changetrack-ng              Executable
/usr/local/lib/changetrack-ng/             Library modules
/etc/changetrack-ng/changetrack-ng.conf    Configuration (mode 0640)
/var/lib/changetrack-ng/                   VCS repository + mirror tree
/var/run/changetrack-ng.lock               Lock file (root)
```

Packages available for Debian (`.deb`), RPM (`.spec`), standalone tarball, and single-file fatpack.

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success / no changes |
| 1 | Changes detected (`status`) or operational warning |
| 2 | Runtime error |
| 64 | Usage error (bad arguments) |

# changetrack-ng

**Homepage:** <https://github.com/cashell/changetrack-ng>

A modernized Perl rewrite of the `changetrack` system file change tracker.

## Overview

`changetrack-ng` watches a list of files and directories for changes, records
each change in a VCS repository (RCS, Git, Fossil, SVN, or Mercurial), and
optionally sends notifications via email, HTTP webhook, OpenTelemetry (OTLP),
or an append-only JSON log.

It combines the per-file flexibility of the original
[changetrack](https://sourceforge.net/projects/changetrack/) with the
modern VCS and package-manager integration of
[etckeeper](https://etckeeper.branchable.com/).

**Why not just use etckeeper?**
etckeeper is purpose-built for `/etc`; changetrack-ng tracks arbitrary paths,
supports per-file email recipients, and adds OTLP/observability integration.

**Why not just use the original changetrack?**
The original (last maintained 2009) is broken on Perl 5.26+ and relies on
the removed `find2perl`.  changetrack-ng is a clean rewrite with no
compatibility debt.

## Features

- **Five VCS backends:** Choose RCS for per-file versioning or Git, Fossil, SVN, and Mercurial for global tree mirrors.
- **Four Notification Channels:** Deliver unified diffs via Email, JSON to HTTP Webhook endpoints, structured events via OTLP/OpenTelemetry, or to a local File log. 
- **Sensitive File Protection:** Automatic mode-based detection. Files with no group/world read bit (`0600` / `0640`) have their contents fully captured in the local secure VCS mirror, but their diff contents are unconditionally stripped from all outbound notifications (Email, Webhook, OTLP).
- **Package Manager Integration:** Automatic pre- and post-install hooks for `apt`, `dnf`, and `pacman` ensure system changes by package updates are logically bundled and committed together.
- **Zero External Dependencies:** Built safely on Perl core modules natively (requiring only `HTTP::Tiny`, `JSON::PP`, and `IO::Compress::Gzip` across Perl ≥ 5.20+).
- **Flexible Execution:** Deploy via `cron.hourly`, `systemd` timers, explicit CLI invocations, or event-driven pipelines. Note there is no daemon to manage—all execution is polling-based or hook-driven.

## How it Works

`changetrack-ng` executes in a sequence that ensures consistency and safe delivery:
1. **Config & Run-Lock:** `changetrack-ng run` acquires a lock (`~/.cache/...` or `/var/run/...`) to prevent race conditions during updates.
2. **Scan Phase:** It recursively walks target directories filtering out globally/locally ignored files (like `*.swp` or `/etc/mtab`).
3. **Diff Check:** Uses `lstat` combinations alongside sidecar metadata diffs to catch permission adjustments and skips expensive content diffs unless modifications exist.
4. **VCS Commit:** All accumulated changes are written atomically or batch-staged to the chosen backend.
5. **Notification Dispatch:** Change reports and unified diffs are passed down the pipeline to every enabled notification channel (observing sensitive file diff scrubbing restrictions natively).

## Quick Start

```sh
# Install
sudo make install

# Install systemd timer (recommended) or cron
sudo make install-systemd   # then: sudo systemctl enable --now changetrack-ng.timer
# OR
sudo make install-cron

# Install package manager hooks (auto-detects apt/dnf/pacman)
sudo make install-hooks

# Edit config
sudo $EDITOR /etc/changetrack-ng/changetrack-ng.conf

# First run
sudo changetrack-ng run
```

Unprivileged user-home install (no sudo):

```sh
make install-user
$HOME/.local/bin/changetrack-ng run
```

For this mode, edit `$HOME/.config/changetrack-ng/changetrack-ng.conf` and set
`output_dir` under your home directory.

Minimal config — track /etc with Git and no notifications:

```ini
[global]
vcs        = git
output_dir = /var/lib/changetrack-ng

[track]
DIRECTORY /etc
```

## Requirements

- Perl 5.20 or later
- At least one VCS tool: `rcs`, `git`, `fossil`, `svn`, or `hg`
- `IO::Socket::SSL` for HTTPS endpoints (not core, but widely packaged)

## Configuration

Config uses INI v2 format.  The installed default at
`/etc/changetrack-ng/changetrack-ng.conf` is fully commented, but logically is split into `[global]` settings and `[track]` targets.

Security notes:
- Treat the config as sensitive data and set mode `0640` or stricter.
- Prefer environment-backed secrets for OTLP headers (`${VAR}` expansion in
  config values is supported, and `OTEL_EXPORTER_OTLP_HEADERS` is preferred
  for secret tokens).

### Example Structure

```ini
[global]
vcs           = git
output_dir    = /var/lib/changetrack-ng
notify        = email webhook otlp
email_to      = default-admin@example.com
email_from    = changetrack-ng@${HOSTNAME}
webhook_url   = https://events.example.com/webhook
webhook_full_diff = 1

[track]
# Send diffs to default-admin
DIRECTORY /etc/systemd

# Override default email for networking configs
DIRECTORY /etc/NetworkManager : network-team@example.com

# Auto-suppresses diff content over 0600 sensitive file
/etc/shadow 

# Explicit sensitive tracking over 0644 file
/etc/ssl/certs/custom.crt sensitive=yes
```

To migrate a legacy `changetrack` v1 config:

```sh
sudo changetrack-ng migrate-config /etc/changetrack.conf
```

For internals and module boundaries, see [ARCHITECTURE.md](ARCHITECTURE.md).
For operational troubleshooting, see [INSTALL.md](INSTALL.md#troubleshooting).

## Subcommands

| Command | Description |
|---|---|
| `run` | Scan, commit, notify (default) |
| `run --dry-run` or `-n` | Detect and report changes statically without mutating VCS or sending notifications |
| `init` | Initialize VCS repo explicitly |
| `status` | List changed files |
| `diff [path]` | Show pending unified diff |
| `log [path]` | Show VCS history |
| `revert <path> <rev>` | Restore file from a revision |
| `update-ignore` | Refresh VCS ignore file |
| `migrate-config <v1> [<v2>]` | Convert v1 config to v2 |

## Notification Channels

`changetrack-ng` supports four parallel notification channels to report changes. You can enable them individually or simultaneously via the `notify` config key (e.g., `notify = email webhook`).

### 1. Email
Sends traditional email diffs to administrators. Recipients can be defined globally or overriding on a per-file/per-directory basis directly in the `[track]` list. This allows routing changes of specific subsystems (like `/etc/nginx`) to specific teams.

### 2. HTTP Webhook
Sends a JSON POST payload to one or more endpoints. Useful for Slack/Teams integrations, custom automation, or SIEM ingestion. Payloads can optionally include full unified diffs or just file-level metadata.

### 3. OTLP / OpenTelemetry
Exports one OTLP log record per changed file, fitting natively into modern observability stacks (Loki, Datadog, Splunk, etc.). Heartbeat records (sent even on no-change runs) let monitoring systems distinguish true silence from agent failure without vendor-specific logic.

```ini
[global]
notify           = otlp
otlp_endpoint    = https://otelcol.example.com:4318/v1/logs
otlp_compression = gzip
otlp_heartbeat   = 1
```

*Note on OTLP Security:* The OTLP spec requires respecting standard agent environments. The resolution precedence enforces `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` > `OTEL_EXPORTER_OTLP_ENDPOINT` > `otlp_endpoint` config. Always prefer injecting `OTEL_EXPORTER_OTLP_HEADERS` via the environment rather than hardcoding sensitive bearer tokens directly into `changetrack-ng.conf`.

### 4. File Log
Appends individual JSON objects (one per run) to a local log file, ensuring a machine-readable audit trail exists locally alongside the VCS repo.

## Install Paths

| Variable | Default | Notes |
|---|---|---|
| `PREFIX` | `/usr/local` | Set to `/usr` for system-wide install |
| `BINDIR` | `$(PREFIX)/bin` | Binary location |
| `LIBDIR` | `$(PREFIX)/lib/changetrack-ng` | Perl modules |
| `SYSCONFDIR` | `$(PREFIX)/etc` (or `/etc` for `/usr`) | Config dir |
| `DATADIR` | `/var/lib/changetrack-ng` | VCS output dir |
| `MANDIR` | `$(PREFIX)/share/man` | Man pages |

Override any variable on the `make` command line:

```sh
sudo make install PREFIX=/usr
```

First-class user targets:

- `make install-user`
- `make install-user-systemd`
- `make install-user-cron`

## Development

```sh
make test          # Run full test suite (requires prove)
prove -l t/01-config.t   # Run a single test file
```

Tests live in `t/` and cover all implemented modules.  All tests use only
core Perl modules; no network access required.

## License

GNU General Public License v3 or later.  See `LICENSE`.

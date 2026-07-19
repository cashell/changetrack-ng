# changetrack-ng

**Homepage:** <https://github.com/cashell/changetrack-ng>

A modernized rewrite of the `changetrack` system file change tracker.

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
- **Configurable Tracking:** Track arbitrary files and directories, with per-file/per-directory overrides for notification recipients, sensitive-file flags, and ignore patterns.
- **System and User Modes:** Run as root to track system paths, or as an unprivileged user to track home directories.  Each mode has its own config and VCS repo.

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

Config uses a single INI format with `[global]`, `[track]`, and
`[notifier:<type>:<name>]` sections.  The installed default at
`/etc/changetrack-ng/changetrack-ng.conf` is fully commented.
Comments start with `#` or `;` — either as a full line or inline after a
value (when preceded by whitespace, e.g. `timeout = 10  # seconds`).

Security notes:
- Treat the config as sensitive data and set mode `0640` or stricter.
- Prefer environment-backed secrets for OTLP headers (`${VAR}` expansion in
  config values is supported, and `OTEL_EXPORTER_OTLP_HEADERS` is preferred
  for secret tokens).
- The webhook and OTLP notifiers verify TLS certificates by default. Set
  `insecure = 1` on a notifier only if you intentionally use a self-signed
  endpoint.

Reliability notes:
- `command_timeout` (global, default `120` seconds, `0` = unlimited) bounds every
  external command with a watchdog that kills the child, so a hung or runaway tool
  cannot stall a scheduled (cron/systemd) run.
- The webhook notifier honors `max_diff_bytes` (default `0` = unlimited) to cap the
  diff size in the POST payload, mirroring the `otlp` and `file` notifiers.

### Example Structure

```ini
[global]
vcs        = git
output_dir = /var/lib/changetrack-ng

[notifier:email:default]
enabled = true
to      = default-admin@example.com
from    = changetrack-ng@${HOSTNAME}

[notifier:webhook:default]
enabled   = true
url       = https://events.example.com/webhook
full_diff = 1

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

### Drop-in Directories

Automatic drop-ins are fixed sibling directories next to the main config file:

| Directory | Allowed sections |
|---|---|
| `conf.d/` | `[global]` only |
| `track.d/` | `[track]` only |
| `notifier.d/` | `[notifier:*]` only |

All `*.conf` files in each directory are processed in sorted order and merged
into the main config. Custom automatic drop-in directories are not configured
separately; use explicit `@include` directives for custom files or directories.

### `@include` Directives

```ini
@include /etc/changetrack-ng/extra.conf
@include-track /etc/changetrack-ng/track.d/
@include-notifier /etc/changetrack-ng/notifier.d/
```

The include path may be a file or a directory. Directory includes process
sorted `*.conf` files, which makes them the supported mechanism for custom
drop-in directories. `@include-track` and `@include-notifier` enforce section
restrictions in the included path.  Recursion is prevented by a visited-paths
guard.

For internals and module boundaries, see [ARCHITECTURE.md](ARCHITECTURE.md).
For operational troubleshooting, see [INSTALL.md](INSTALL.md#troubleshooting).

## Global Options

These flags apply to all subcommands:

| Flag | Short | Description |
|---|---|---|
| `--system` | | Load `/etc/changetrack-ng/changetrack-ng.conf` (default when no flag is given). |
| `--user` | | Load `$HOME/.config/changetrack-ng/changetrack-ng.conf`. `--system` and `--user` are mutually exclusive. |
| `--config <path>` | `-c` | Load the specified config file directly. Overrides `--system`, `--user`, and `$CHANGETRACK_CONFIG`. |
| `--verbose` | `-v` | Show high-level run structure: config path, VCS backend, lock status, file counts, commit and notify outcomes |
| `--debug` | `-d` | Show all external commands run, effective config values (secrets redacted), per-file actions taken. Implies `--verbose`. |
| `--trace` | `-t` | Show per-file disposition for every tracked path (O(N): fast-path skips, type classifications, ignore matches). Implies `--debug`. |
| `--quiet` | `-q` | Suppress all INFO output. Intended for unattended/cron/hook invocations. |
| `--dry-run` | `-n` | Detect changes without writing to VCS or dispatching notifications. |

All diagnostic output (`--verbose`, `--debug`, `--trace`) goes to **STDERR**. STDOUT remains clean and contains only subcommand data (diffs, status listings, log output), making it safe to pipe.

### Config resolution order

The config file is selected in this priority order (highest wins):

1. `-c <path>` / `--config <path>` — explicit path on the command line
2. `$CHANGETRACK_CONFIG` — environment variable (useful in scripts and hook overrides)
3. `--system` / `--user` — explicit scope flag
4. Default: system config (`/etc/changetrack-ng/changetrack-ng.conf`)

The **defaults file** (`/etc/default/changetrack-ng` on Debian-like systems,
`/etc/sysconfig/changetrack-ng` on RHEL-like systems) is sourced by cron, systemd,
and package manager hooks before invoking the CLI. It lets administrators set
`CHANGETRACK_CONFIG` or `CHANGETRACK_EXTRA_ARGS` system-wide without editing hook or
unit files. The template is installed by `make install-hooks`.

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

## Notification Channels

`changetrack-ng` supports four parallel notification channels to report changes.
Each channel is configured with a `[notifier:<type>:<name>]` section.  Multiple
instances of the same type are supported (e.g., two webhook endpoints with
different URLs).  A channel is active when its section contains `enabled = true`.
Disabled instances are ignored at parse time.

### 1. Email
Sends traditional email diffs to administrators. Recipients can be defined globally or overriding on a per-file/per-directory basis directly in the `[track]` list. This allows routing changes of specific subsystems (like `/etc/nginx`) to specific teams.

### 2. HTTP Webhook
Sends a JSON POST payload to one or more endpoints. Useful for Slack/Teams integrations, custom automation, or SIEM ingestion. Payloads can optionally include full unified diffs or just file-level metadata.

### 3. OTLP / OpenTelemetry
Exports one OTLP log record per changed file, fitting natively into modern observability stacks (Loki, Datadog, Splunk, etc.). Heartbeat records (sent even on no-change runs) let monitoring systems distinguish true silence from agent failure without vendor-specific logic.

```ini
[notifier:otlp:default]
enabled     = true
endpoint    = https://otelcol.example.com:4318/v1/logs
compression = gzip
heartbeat   = 1
```

*Note on OTLP Security:* The resolution precedence enforces
`OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` > `OTEL_EXPORTER_OTLP_ENDPOINT` >
`endpoint` config key.  Always prefer injecting `OTEL_EXPORTER_OTLP_HEADERS`
via the environment rather than hardcoding bearer tokens in the config file.

### 4. File Log
Appends one OTel-shaped JSON record per event (one per changed file, one per
heartbeat, one per warning) to a local NDJSON log file, ensuring a
machine-readable audit trail exists locally alongside the VCS repo.

### Shared OTLP and File Notifier Config Keys

The following keys are supported by both the `otlp` and `file` notifiers:

| Key | Default | Description |
|---|---|---|
| `emit_recipients` | `0` | When `1`, each change record includes a `config_change.notified` attribute listing the configured recipients for that file. Off by default to keep recipient lists out of the telemetry stream. |
| `max_diff_bytes` | `0` (unlimited) | Caps the size of the `config_change.diff` attribute in the emitted record. When a diff exceeds the cap, the diff is truncated and `config_change.diff_truncated = true` is added. The full diff is always retained in the VCS. Sensitive-file suppressed-diff placeholders are never truncated. |
| `severity_change` | `INFO` | Severity name for file-change, file-create, and file-remove records. Accepts `DEBUG`, `INFO`, `WARN`, or `ERROR` (case-insensitive). Invalid or blank values fall back to `INFO`. |
| `severity_heartbeat` | `DEBUG` | Severity name for heartbeat ("nothing changed") records. Same accepted values as `severity_change`. |
| `severity_warning` | `WARN` | Severity name for scan-warning records. Same accepted values as `severity_change`. |

Example using non-default severities and diff truncation:

```ini
[notifier:otlp:default]
enabled           = true
endpoint          = https://otelcol.example.com:4318/v1/logs
heartbeat         = 1
severity_change   = WARN
severity_warning  = ERROR
max_diff_bytes    = 65536

[notifier:file:audit]
enabled           = true
path              = /var/log/changetrack-ng.log
emit_recipients   = 1
max_diff_bytes    = 32768
```

## Install Paths

| Variable | Default | Notes |
|---|---|---|
| `PREFIX` | `/usr/local` | Set to `/usr` for system-wide install |
| `BINDIR` | `$(PREFIX)/bin` | Binary location |
| `LIBDIR` | `$(PREFIX)/lib/changetrack-ng` | Perl modules |
| `SYSCONFDIR` | `$(PREFIX)/etc` (or `/etc` for `/usr`) | Config dir |
| `DATADIR` | `/var/lib/changetrack-ng` | VCS output dir |
| `MANDIR` | `$(PREFIX)/share/man` | Man pages |
| `DEFAULTSDIR` | `/etc/default` (Debian) or `/etc/sysconfig` (RHEL, auto-detected) | Defaults file directory |

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
make manifest-lint # Validate MANIFEST.toml (checks all listed files exist)
```

Tests live in `t/` and cover all implemented modules.  All tests use only
core Perl modules; no network access required.

## File Inventory

`MANIFEST.toml` is the authoritative inventory of every file in the repository.
Each entry records the file's description, install path, permissions, which
distribution tarballs include it, and tags for navigation.

`tools/manifest-query` is a Perl script that reads `MANIFEST.toml` via
`TOML::Tiny` and answers structured queries:

```sh
tools/manifest-query --dist full          # files in the full source tarball
tools/manifest-query --dist deploy        # files in the deploy tarball
tools/manifest-query --category library   # all library modules
tools/manifest-query --tag vcs            # all files tagged "vcs"
tools/manifest-query --validate           # verify all listed files exist on disk
tools/manifest-query --deps-deb           # Depends:/Recommends: lines for debian/control
tools/manifest-query --build-deps-deb     # Build-Depends: lines for debian/control
```

`TOML::Tiny` (`libtoml-tiny-perl` / `perl-TOML-Tiny`) is required to run
`tools/manifest-query` but is **not** a runtime dependency of changetrack-ng
itself.

## License

GNU General Public License v3 or later.  See `LICENSE`.

# changetrack-ng

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

- **Five VCS backends:** RCS (per-file), Git, Fossil, SVN, Mercurial (whole-repo mirror)
- **Four notification channels:** Email, HTTP Webhook, OTLP/OpenTelemetry, File log
- **Sensitive file protection:** files with no group/world read bit have their
  diffs suppressed in outbound notifications
- **Package manager hooks:** apt, pacman, dnf — record pre/post-install state
- **Zero extra dependencies:** uses only Perl core modules (`HTTP::Tiny`,
  `JSON::PP`, `IO::Compress::Gzip` are core ≥ 5.14)
- **Runs on any schedule:** cron.hourly, systemd timer, or on-demand
- **Config migration:** auto-detects and migrates legacy v1 configs

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
`/etc/changetrack-ng/changetrack-ng.conf` (or `/usr/local/etc/…` for
prefix installs) is fully commented.  See `man changetrack-ng.conf` for the
complete reference.

Security notes:
- Treat the config as sensitive data and set mode `0640` or stricter.
- Prefer environment-backed secrets for OTLP headers (`${VAR}` expansion in
  config values is supported, and `OTEL_EXPORTER_OTLP_HEADERS` is preferred
  for secret tokens).

To migrate a legacy `changetrack` v1 config:

```sh
sudo changetrack-ng migrate-config /etc/changetrack.conf
```

## Subcommands

| Command | Description |
|---|---|
| `run` | Scan, commit, notify (default) |
| `init` | Initialize VCS repo explicitly |
| `status` | List changed files |
| `diff [path]` | Show pending unified diff |
| `log [path]` | Show VCS history |
| `revert <path> <rev>` | Restore file from a revision |
| `update-ignore` | Refresh VCS ignore file |
| `migrate-config <v1> [<v2>]` | Convert v1 config to v2 |

## OTLP / OpenTelemetry

When `notify = otlp` is set, changetrack-ng exports one OTLP log record per
changed file.  Heartbeat records (sent even on no-change runs) let monitoring
systems distinguish silence from agent failure.

```ini
[global]
notify           = otlp
otlp_endpoint    = https://otelcol.example.com:4318/v1/logs
otlp_compression = gzip
otlp_heartbeat   = 1
```

The `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`
environment variables override the config value.
`OTEL_EXPORTER_OTLP_HEADERS` overrides `otlp_headers` and is preferred for
credential-bearing headers.

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

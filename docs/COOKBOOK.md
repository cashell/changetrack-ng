# changetrack-ng Operations Cookbook

**Homepage:** <https://github.com/cashell/changetrack-ng>

This document provides practical, production-ready configuration recipes for common deployment scenarios.

---

## Recipe 1: Standard Server Host Integrity

Monitor `/etc`, `/usr/local/etc`, and scheduled cron jobs on a Linux server using Git, hourly systemd timers, automated package-manager hooks, and email notifications to the operations team.

### 1. Configuration: `/etc/changetrack-ng/changetrack-ng.conf`

```ini
[global]
vcs               = git
output_dir        = /var/lib/changetrack-ng
ignore            = *.swp *~ *.bak *.tmp
sensitive_auto    = 1
sensitive_notify  = suppress
command_timeout   = 120

[notifier:email:ops]
enabled = true
to      = sysadmins@example.com
from    = changetrack-ng@${HOSTNAME}

[track]
DIRECTORY /etc
DIRECTORY /usr/local/etc
DIRECTORY /var/spool/cron
/etc/shadow
```

### 2. Enable Timers and Hooks

```sh
sudo make install PREFIX=/usr
sudo make install-hooks
sudo make install-systemd
sudo systemctl enable --now changetrack-ng.timer
```

*Outcome:*
- System packages installed via `apt`, `dnf`, or `pacman` trigger pre/post snapshots annotated with package names.
- Hourly timer scans for uncommitted manual edits and commits them with unified diffs emailed to `sysadmins@example.com`.
- `/etc/shadow` diffs are automatically suppressed in outbound emails to prevent credential leakage while still preserving versioned history in `/var/lib/changetrack-ng`.

---

## Recipe 2: Web Infrastructure with Team-Specific Notification Routing

Manage a reverse proxy server running Nginx and TLS certificates, routing web server configuration changes to the web team and security certificates to the security operations team.

### Configuration: `/etc/changetrack-ng/changetrack-ng.conf`

```ini
[global]
vcs        = git
output_dir = /var/lib/changetrack-ng

[notifier:email:default]
enabled = true
to      = noc@example.com
from    = changetrack-ng@${HOSTNAME}

[track]
# Core system files go to the default recipient (noc@example.com)
/etc/hosts
/etc/resolv.conf
/etc/sysctl.conf

# Nginx configurations routed directly to the web development team
DIRECTORY /etc/nginx : web-team@example.com

# SSL certificates and private keys routed to SecOps, diffs suppressed
DIRECTORY /etc/ssl/certs : secops@example.com
DIRECTORY /etc/ssl/private : secops@example.com sensitive=yes
```

---

## Recipe 3: Enterprise Observability with OpenTelemetry (OTLP)

Send structured change events directly into an enterprise observability pipeline (such as an OpenTelemetry Collector, Grafana Loki, Datadog, or Splunk).

### 1. Configuration: `/etc/changetrack-ng/changetrack-ng.conf`

```ini
[global]
vcs        = git
output_dir = /var/lib/changetrack-ng

[notifier:otlp:collector]
enabled             = true
endpoint            = https://otelcol.internal.example.com:4318/v1/logs
compression         = gzip
heartbeat           = 1
severity_change     = INFO
severity_warning    = WARN
severity_heartbeat  = DEBUG
max_diff_bytes      = 65536
emit_recipients     = 0
resource_attributes = environment=production service.namespace=infrastructure
```

### 2. Environment Secret Injection: `/etc/default/changetrack-ng`

```sh
# Sourced automatically by systemd timer and cron
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer eyJhbGciOi..."
```

*Outcome:*
- Every modified file emits an individual OTel log record with structured attributes (`file.path`, `file.mode`, `config_change.diff`, `config_change.type`).
- Diffs larger than 64 KB are automatically truncated and marked with `config_change.diff_truncated = true`.
- When no changes occur during a run, a heartbeat record (`changetrack.run.heartbeat`) is dispatched, enabling alert-on-absence rules in monitoring dashboards without false positives.

---

## Recipe 4: Multi-Destination Audit Pipeline (Local JSONL + ChatOps Webhook)

Maintain a compliant, tamper-evident local audit log alongside instant Slack/Teams alerting for operations channels.

### Configuration: `/etc/changetrack-ng/changetrack-ng.conf`

```ini
[global]
vcs        = git
output_dir = /var/lib/changetrack-ng

# Append-only local audit log with diff size cap
[notifier:file:local_audit]
enabled        = true
path           = /var/log/changetrack-ng.jsonl
full_diff      = 1
max_diff_bytes = 32768
heartbeat      = 0

# HTTP POST payload to webhook integration (Slack/Teams/SIEM)
[notifier:webhook:chatops]
enabled        = true
url            = https://webhook.internal.example.com/alerts/system-drift
full_diff      = 1
max_diff_bytes = 16384
timeout        = 10

[track]
DIRECTORY /etc
DIRECTORY /usr/local/bin
DIRECTORY /usr/local/sbin
```

---

## Recipe 5: Unprivileged Dotfile Tracking

Monitor personal configuration files (`~/.config`, `~/.bashrc`, SSH authorized keys) as an unprivileged user without requiring sudo or root access.

### 1. Installation

```sh
make install-user
make install-user-systemd
systemctl --user enable --now changetrack-ng.timer
```

### 2. Configuration: `~/.config/changetrack-ng/changetrack-ng.conf`

```ini
[global]
vcs        = git
output_dir = ~/.local/state/changetrack-ng
lock_path  = ~/.cache/changetrack-ng.lock

[notifier:email:me]
enabled = true
to      = user@example.com
from    = dotfiles@${HOSTNAME}

[track]
~/.bashrc
~/.profile
~/.ssh/authorized_keys sensitive=yes
DIRECTORY ~/.config/nvim
DIRECTORY ~/.config/git
```

*Outcome:*
- User session timer runs hourly in the background.
- Lock file defaults to `~/.cache/` and VCS repository lives in `~/.local/state/`.
- Private keys or authorized keys are protected from outbound diff exposure via `sensitive=yes`.

---

## Recipe 6: Centralized Remote Backup (Git / Fossil push_remote)

Automatically push every committed change batch to an internal, central Git repository for off-site backup and fleet-wide visibility.

### Configuration: `/etc/changetrack-ng/changetrack-ng.conf`

```ini
[global]
vcs         = git
output_dir  = /var/lib/changetrack-ng
push_remote = origin

[track]
DIRECTORY /etc
```

### Initial Remote Setup in Mirror Repository

```sh
sudo -u root git -C /var/lib/changetrack-ng remote add origin git@git.example.com:fleet-configs/${HOSTNAME}.git
sudo -u root git -C /var/lib/changetrack-ng push -u origin main
```

*Outcome:*
- Every run that detects modifications stages the changes, creates a batch commit, and automatically runs `git push origin` to backup changes off-host.

# Installation

**Source:** <https://github.com/cashell/changetrack-ng>

## Requirements

- Perl 5.20 or later
- At least one VCS backend: `rcs`, `git`, `fossil`, `svn`, or `hg`
- `IO::Socket::SSL` for HTTPS webhook/OTLP endpoints (not core; see below)
- `make` (GNU make or BSD make)

## Basic Install

```sh
make test            # verify the test suite passes
sudo make install    # installs to /usr/local by default
```

To install system-wide (binary in `/usr/bin`, config in `/etc`):

```sh
sudo make install PREFIX=/usr
```

To install into a staging directory (e.g., for packaging):

```sh
make install DESTDIR=/tmp/pkg PREFIX=/usr
```

## Unprivileged (User-Home) Install

`changetrack-ng` fully supports non-root operation for monitoring files the
current user can read.

Recommended user install:

```sh
make install-user
```

This installs to:

- binary: `~/.local/bin/changetrack-ng`
- modules: `~/.local/lib/changetrack-ng/`
- config: `~/.config/changetrack-ng/changetrack-ng.conf`
- default data dir suggestion: `~/.local/state/changetrack-ng`

`make install-user` installs a pre-configured user template (`packaging/etc/examples/changetrack-ng.conf-user`) with home-directory paths already set for `output_dir` and `lock_path`.

Then edit config (at minimum, set your `[track]` entries):

```ini
[global]
vcs = git
output_dir = ~/.local/state/changetrack-ng

[track]
DIRECTORY ~/.config
```

Path expansion notes:
- Path fields support `~`/`~/...` expansion (resolved from `$HOME`).
- `${ENV_VAR}` expansion is supported in all values, including `[track]` entries.
- Expanded paths must be absolute.

Run once manually:

```sh
~/.local/bin/changetrack-ng run
```

Notes:
- For non-root runs, lock file defaults to `$XDG_CACHE_HOME/changetrack-ng.lock`
	or `~/.cache/changetrack-ng.lock`.
- Package-manager hooks are root/system scope and are not applicable to
	unprivileged installs.

## Config

Ready-to-use example configs and drop-in templates are installed under
`/usr/share/doc/changetrack-ng/examples/`:

| File | Purpose |
|------|----------|
| `changetrack-ng.conf-full` | Full reference — every option with detailed comments |
| `changetrack-ng.conf-default` | Balanced defaults — all options with concise guidance |
| `changetrack-ng.conf-minimal` | Quickstart — git + email + common system files |
| `changetrack-ng.conf-user` | Non-root install — home directory paths and dotfiles |
| `conf.d/local-settings.conf` | Example `[global]` drop-in |
| `track.d/system-core.conf` | Example `[track]` drop-in |
| `notifier.d/email.conf` | Example email notifier drop-in |
| `notifier.d/otlp.conf` | Example OTLP notifier drop-in |

For a fresh system install, start from the minimal example:

```sh
# PREFIX=/usr:
sudo cp /usr/share/doc/changetrack-ng/examples/changetrack-ng.conf-minimal \
        /etc/changetrack-ng/changetrack-ng.conf
sudo $EDITOR /etc/changetrack-ng/changetrack-ng.conf
```

At minimum, set the files/directories to track in `[track]` and enable at
least one `[notifier:*]` section if you want change notifications.  The full
reference config documents every supported option with accepted values and
defaults.

## Troubleshooting

### Another instance is running

- Symptom: run exits quietly or logs indicate lock contention.
- Checks:
	- Verify `lock_path` in config.
	- Check for stale lock files after unclean shutdown.
	- If needed for debugging, set `lock_timeout` to a small non-zero value.

### VCS not initialized

- Symptom: startup fails with VCS initialization error.
- Fix:
	- Run `changetrack-ng init` once.
	- Ensure `output_dir` is writable by the runtime user.

### Permission denied on tracked paths

- Symptom: warnings about unreadable files or missing diffs.
- Fix:
	- Run under an account with read access to tracked paths.
	- Keep `sensitive_auto = 1` unless you explicitly want full diff output.

### No notifications received

- Symptom: commits happen but email/webhook/OTLP output is missing.
- Checks:
	- Confirm the relevant `[notifier:<type>:<name>]` section exists and has `enabled = true`.
	- For email, validate `sendmail_path` or MTA availability.
	- For webhook/OTLP, verify endpoint reachability and TLS settings.
	- For OTLP headers, prefer `OTEL_EXPORTER_OTLP_HEADERS` for secrets.

## Scheduling

### systemd (recommended)

```sh
sudo make install-systemd
sudo systemctl enable --now changetrack-ng.timer
```

The timer fires hourly with `Persistent=true` so missed runs are caught on
the next boot.

### systemd (user session)

```sh
make install-user-systemd
systemctl --user enable --now changetrack-ng.timer
```

This installs units in `~/.config/systemd/user/` and runs as your user.

### cron

```sh
sudo make install-cron
```

Installs a script to `/etc/cron.hourly/changetrack-ng`.  The script
automatically no-ops when the systemd timer is active to avoid duplicate runs.

### cron (user crontab)

```sh
make install-user-cron
# then run: crontab -e and paste the printed line
```

User cron is the portable option when `systemd --user` is unavailable.

## Package Manager Hooks

```sh
sudo make install-hooks
```

Auto-detects the package manager and installs the appropriate hooks:

| Package manager | Hook type | Files installed |
|---|---|---|
| apt | apt.conf.d directives | `/etc/apt/apt.conf.d/80changetrack-ng-{pre,post}` |
| dnf | Python plugin hooks | `/etc/dnf/plugins/changetrack_ng.{py,conf}` |
| pacman | ALPM hooks | `/usr/share/libalpm/hooks/changetrack-ng-{pre,post}.hook` |

## Man Pages

```sh
sudo make install-man
```

Requires `pod2man` (ships with Perl).  Installs:

- `man/changetrack-ng.8` → `$(MANDIR)/man8/changetrack-ng.8`
- `man/changetrack-ng.conf.5` → `$(MANDIR)/man5/changetrack-ng.conf.5`

## Uninstall

```sh
sudo make uninstall
```

This removes the binary and library files.  Config (`$(SYSCONFDIR)/changetrack-ng/`)
and data (`$(DATADIR)`) are intentionally left in place.

## Distro-Specific Notes

### Debian / Ubuntu

```sh
sudo apt-get install perl git libio-socket-ssl-perl
sudo make install PREFIX=/usr
sudo make install-hooks
sudo make install-systemd
sudo systemctl enable --now changetrack-ng.timer
```

### RHEL / Fedora

```sh
sudo dnf install perl git perl-IO-Socket-SSL
sudo make install PREFIX=/usr
sudo make install-hooks
sudo make install-systemd
sudo systemctl enable --now changetrack-ng.timer
```

### Arch Linux

```sh
sudo pacman -S perl git perl-io-socket-ssl
sudo make install PREFIX=/usr
sudo make install-hooks
sudo make install-systemd
sudo systemctl enable --now changetrack-ng.timer
```

## Alternative Distributions

### Single-file standalone script (FatPack)

Produces a self-contained `changetrack-ng-VERSION.pl` that embeds all
`ChangeTrack::*` modules and needs no separate `lib/` installation.
Requires `App::FatPacker` from CPAN.

```sh
cpan App::FatPacker   # once, to install the tool
make fatpack
sudo install -m 755 changetrack-ng-VERSION.pl /usr/local/bin/changetrack-ng
```

All core Perl modules (`HTTP::Tiny`, `JSON::PP`, etc.) are still required
on the target system; they are not bundled.

### RPM (Fedora / RHEL / openSUSE)

The spec file is at `packaging/rpm/changetrack-ng.spec`.  Build with:

```sh
make dist
cp changetrack-ng-VERSION.tar.gz ~/rpmbuild/SOURCES/
rpmbuild -ba packaging/rpm/changetrack-ng.spec
# Installs to ~/rpmbuild/RPMS/noarch/
```

Requires `rpmdevtools` (`dnf install rpmdevtools`).

### Debian package (Debian / Ubuntu)

The packaging skeleton is in `packaging/debian/`.  Build with:

```sh
sudo apt-get install debhelper devscripts
make dist
make debian-build-setup
dpkg-buildpackage -b --no-sign
make debian-build-cleanup
# .deb lands in the parent directory
```

Or from the source tree directly:

```sh
make debian-build-setup
debuild -b --no-sign
make debian-build-cleanup
```

The resulting `.deb` installs to `/usr/bin`, `/usr/lib/changetrack-ng/`,
`/etc/changetrack-ng/`, and `/var/lib/changetrack-ng/`.

## IO::Socket::SSL

The `IO::Socket::SSL` module is required for HTTPS webhook or OTLP endpoints.
It is not a Perl core module but is widely packaged:

| Distro | Package |
|---|---|
| Debian/Ubuntu | `libio-socket-ssl-perl` |
| RHEL/Fedora | `perl-IO-Socket-SSL` |
| Arch | `perl-io-socket-ssl` |
| CPAN | `IO::Socket::SSL` |

If not installed and an HTTPS endpoint is configured, HTTP::Tiny will fail
with a clear error message.

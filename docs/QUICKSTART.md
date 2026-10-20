# changetrack-ng — 5-Minute Quickstart Guide

**Homepage:** <https://github.com/cashell/changetrack-ng>

This guide walks you through installing, configuring, and testing `changetrack-ng` in under five minutes.

---

## Step 1: Install changetrack-ng

Verify that Perl 5.20+ and Git are installed, run tests, and install to `/usr/local`:

```sh
# Clone and enter directory
git clone https://github.com/cashell/changetrack-ng.git
cd changetrack-ng

# Run pre-flight test suite
make test

# Install executable, libraries, and default configurations
sudo make install
```

---

## Step 2: Configure Monitored Paths

`changetrack-ng` installs a balanced default configuration at `/etc/changetrack-ng/changetrack-ng.conf`. For this quick evaluation, create a minimal configuration monitoring `/etc/hosts` and `/etc/resolv.conf`:

```sh
sudo tee /etc/changetrack-ng/changetrack-ng.conf > /dev/null << 'EOF'
[global]
vcs        = git
output_dir = /var/lib/changetrack-ng

[track]
/etc/hosts
/etc/resolv.conf
EOF
```

---

## Step 3: Run the Initial Scan

Execute the first scan. `changetrack-ng` automatically initializes the Git repository in `/var/lib/changetrack-ng` and records the initial state:

```sh
sudo changetrack-ng run
```

Verify that the repository was created:

```sh
sudo git -C /var/lib/changetrack-ng status
```

---

## Step 4: Make a Test Change

Simulate an administrative configuration change to `/etc/hosts`:

```sh
echo "# test entry for changetrack-ng" | sudo tee -a /etc/hosts
```

---

## Step 5: Inspect Pending Changes

Use the CLI subcommands to inspect pending filesystem modifications before committing:

```sh
# Check change status (exits 1 if changes exist, 0 if clean)
sudo changetrack-ng status

# View unified diff against the last recorded snapshot
sudo changetrack-ng diff
```

---

## Step 6: Commit the Changes

Run `changetrack-ng run` to capture the modifications into version control:

```sh
sudo changetrack-ng run -m "manual edit: added test entry"
```

Verify the commit log:

```sh
sudo changetrack-ng log /etc/hosts
```

---

## Step 7: Test Reversion

Restore `/etc/hosts` to its original revision:

```sh
# Copy the initial commit hash from the log output above
sudo changetrack-ng revert /etc/hosts HEAD~1
```

Confirm that the test line was removed from `/etc/hosts`:

```sh
tail -n 3 /etc/hosts
```

---

## Step 8: Enable Automated Background Monitoring

Install the systemd timer to automatically scan and record changes hourly:

```sh
sudo make install-systemd
sudo systemctl enable --now changetrack-ng.timer
```

To integrate with system package management (`apt`, `dnf`, `pacman`), install the transaction hooks:

```sh
sudo make install-hooks
```

---

## Where to Go Next

- **Add Notifications:** Configure Email, Slack/Webhook, or OpenTelemetry (OTLP) alerts in [README.md](../README.md#notification-channels).
- **Production Recipes:** Review real-world configurations in the [Operations Cookbook](COOKBOOK.md).
- **Full CLI Reference:** See the manual page `man changetrack-ng` or [man/changetrack-ng.8](../man/changetrack-ng.8).
- **Configuration Details:** See `man changetrack-ng.conf` or [man/changetrack-ng.conf.5](../man/changetrack-ng.conf.5).

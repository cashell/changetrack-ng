# Security Policy — changetrack-ng

**Homepage:** <https://github.com/cashell/changetrack-ng>

`changetrack-ng` tracks changes to critical system and user configuration files. Because it typically operates with elevated privileges (root) and captures file content and diffs, security is an architectural priority.

---

## Supported Versions

Security updates are actively provided for the latest minor release branch:

| Version | Supported |
|---|---|
| `0.7.x` | Yes (Active) |
| `< 0.7.0` | No (Upgrade recommended) |

---

## Reporting a Vulnerability

If you discover a security vulnerability in `changetrack-ng`, please report it responsibly by contacting the maintainer directly:

- **Primary Contact:** Christopher Cashell <topher@zyp.org>
- **Response Target:** Acknowledgement within 48 hours, followed by patch development and coordinated release.

Please include:
- A description of the issue and its potential security impact.
- Step-by-step reproduction instructions or a minimal proof of concept.
- The version of `changetrack-ng`, Perl, VCS backend, and Linux distribution in use.

Please do not open public GitHub issues or discussions for undisclosed security vulnerabilities.

---

## Security Model and Invariants

`changetrack-ng` is designed with the following security boundaries:

### 1. Command Execution Safety
- **No Shell Interpolation:** All external command executions (VCS operations, `sendmail`, utilities) are executed exclusively through `ChangeTrack::Util::run_cmd()` using list-form arguments passed to `IPC::Open3`.
- **Injection Prevention:** Untrusted filenames or metadata from tracked filesystems can never trigger shell injection or command chaining.
- **Subprocess Watchdog:** Every external subprocess execution is bounded by a configurable `command_timeout` (default: 120 seconds, `0` = unlimited). Hung or runaway subprocesses are terminated via `SIGTERM` followed by `SIGKILL` to prevent resource exhaustion or scheduler deadlocks.

### 2. Filesystem Permissions and Mirror Protection
- **Restrictive Umask:** The executable initializes with `umask(0077)` to ensure that all created files, mirror trees, and temporary files default to owner-only permissions.
- **Repository Mirror Permissions:** The repository output directory (`output_dir`, default `/var/lib/changetrack-ng`) is created with mode `0700`. At runtime, `ChangeTrack::Runner` inspects the directory and any sibling backend repositories (such as `.fossil` or Subversion databases) and automatically tightens permissions if group or world access is detected.
- **Configuration File Security:** Configuration files may contain notification endpoints and credentials (e.g. OTLP authorization headers, webhook tokens). Configuration files must be mode `0640` or stricter. The runner emits a startup warning if a configuration containing secrets is world-readable.

### 3. Sensitive File Protection and Diff Scrubbing
- **Automatic Classification:** By default (`sensitive_auto = 1`), files lacking world-read permission (`(mode & 0004) == 0`, such as `0600` or `0640` like `/etc/shadow` or private keys) are automatically classified as sensitive. Individual files or directories can be explicitly marked sensitive via `sensitive=yes` in the `[track]` section.
- **Notification Diff Scrubbing:** Under default settings (`sensitive_notify = suppress`), sensitive file contents are fully versioned and preserved within the local secure VCS mirror (`0700`), but unified diff contents are stripped from outbound notifications (Email, Webhook, OTLP, and File logs).
- **Auditability:** Even when diff content is suppressed, file paths and change types are retained in notifications to preserve audit trails.

### 4. Credential Hygiene
- **Environment Variable Injection:** Sensitive tokens (e.g. HTTP authorization headers) should be injected via environment variables rather than stored in cleartext on disk.
- **Precedence:** For OpenTelemetry, standard environment variables take precedence over config settings:
  `OTEL_EXPORTER_OTLP_HEADERS` overrides `headers`, and `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` > `OTEL_EXPORTER_OTLP_ENDPOINT` > `endpoint`.
- **Config Interpolation:** Config values support `${VAR}` expansion; an undefined environment variable triggers an immediate, fatal parse error to prevent runs with empty secrets.

### 5. Safe State Mutations
- **Atomic Revert Restoration:** `ChangeTrack::Util::restore_mirror_path()` restores files via sibling temporary files (`File::Temp`) and atomic POSIX `rename()`, preserving original mode and ownership and preventing live file truncation on failure.
- **Atomic Metadata Persistence:** The JSONL sidecar (`.changetrack-metadata`) is written to a PID-tagged temporary file and atomically renamed only after VCS batch commits succeed.

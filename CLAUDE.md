# CLAUDE.md

This file provides guidance to AI coding assistants (Claude, Copilot, etc.) when working with code in this repository.

## What This Is

`changetrack-ng` is a Perl 5.20+ system file change tracker — a modernized rewrite of the original `changetrack` (last maintained 2009). It monitors files/directories for changes and records them in a pluggable VCS (Git, RCS, Fossil, SVN, Mercurial), with optional notifications via email, webhook, OTLP, or JSON file log.

## Commands

```bash
make test                  # Run full test suite via `prove -l t/` (also runs config-lint)
prove -l t/06-vcs-git.t    # Run a single test file
make config-lint           # Verify installed default config == canonical -default example (File::Compare)
make install               # Install to /usr/local (override with PREFIX=...)
make install-hooks         # Install package manager hooks (auto-detects apt/dnf/pacman)
make install-systemd       # Install systemd timer (templates @BINDIR@)
make install-cron          # Install hourly cron job
make dist                  # Build release tarball
make fatpack               # Build standalone single-file script
```

No build step required — Perl modules are used directly from `lib/`.

## Context Budget (Read This First)

- Start with this file and only the files directly related to the user request.
- Consult `ARCHITECTURE.md` for system design, data flow, and security model.
- Consult `MANIFEST.toml` as the authoritative file index: every repo file is listed with its category, install path, dist targets, and tags — useful for navigation without grepping the filesystem.
- Do **not** read `PLAN.md` by default. It is large (52KB) and should be consulted only when roadmap/phase details are explicitly needed.
- Prefer targeted symbol/file searches over reading large files end-to-end.
- Keep responses concise: report only what changed, why, and how it was validated.

## Architecture Quick Reference

**Entry point:** `bin/changetrack-ng` — dispatches subcommands (`run`, `init`, `status`, `diff`, `log`, `revert`, `update-ignore`). Default subcommand is `run`.

**Core modules in `lib/ChangeTrack/`:**

| Module | Role |
|--------|------|
| `Runner.pm` | Orchestration: config → lock → file list → process → commit → notify |
| `Config.pm` | INI v2 parser; strict key validation; auto-detects v1; `HOSTNAME` interpolation |
| `Metadata.pm` | JSONL sidecar (`.changetrack-metadata`); stat snapshots; atomic save |
| `Report.pm` | Per-run change accumulator; passed to notifiers |
| `Util.pm` | `hostname()`, `run_cmd()` (IPC::Open3, no shell), `sync_mirror_path()`, `set_debug()` |
| `Lock.pm` | `flock(2)` pidfile; timeout/force modes |
| `Version.pm` | Single-source version authority |

**VCS backends (`lib/ChangeTrack/VCS/`):** all extend `Base.pm`.
- `Git.pm` — Whole-repo mirror model; batch commit; optional `push_remote`
- `RCS.pm` — Per-file model; colon-encoded flat layout; immediate `ci -l`
- `Fossil.pm` — Whole-repo; `chdir`-based commands
- `SVN.pm` — Whole-repo; local file:// repo via `svnadmin create`
- `Mercurial.pm` — Whole-repo; uses `hg -R` flag (no chdir)

**Notifiers (`lib/ChangeTrack/Notify/`):** all extend `Base.pm`; all optional.
- `Email.pm` — Pipes to sendmail; heartbeat always off (anti-spam)
- `File.pm` — Appends JSON log; optional heartbeat
- `Webhook.pm` — HTTP POST JSON; 3-attempt retry; TLS bypass option
- `OTLP.pm` — OTLP/HTTP+JSON logs; gzip; env-var precedence; heartbeat default ON

**Data flow:** Config → Lock → File list → Per-file (stat + VCS diff) → Report → Metadata save → VCS commit → Notify dispatch

## Critical Implementation Details

### Command execution safety
All external commands go through `Util::run_cmd()` which uses `IPC::Open3` with list-form arguments (never shell interpolation). This is a deliberate security boundary — preserve it. When `$ChangeTrack::Util::DEBUG` is set (via `set_debug(1)`), `run_cmd()` emits `[DEBUG] exec:` lines to STDERR showing every command invoked.

### Diagnostic output tiers
Three levels, each implying the ones below it:

| Flag | Label | Output to | Purpose |
|------|-------|-----------|----------|
| `--verbose/-v` | `[VERBOSE]` | STDERR | High-level run structure: config path, VCS/output_dir, lock status, file counts, commit/notify milestones |
| `--debug/-d` | `[DEBUG]` | STDERR | Every external command (via `run_cmd`), effective config dump (secrets redacted), files where action is taken, notification outcomes |
| `--trace/-t` | `[TRACE]` | STDERR | Per-file disposition for ALL tracked files (O(N) output): fast-path skips, type classifications, ignore-pattern matches |

Implication chain: `--trace` → `--debug` → `--verbose`. All diagnostic output uses `warn` (STDERR) to keep STDOUT clean for subcommand data output (`diff`, `status`, `log`).

### Config data shapes
- Array-valued `[global]` keys: `ignore`, `push_remote` — returned as arrayrefs; appended across multi-file loads
- All other `[global]` keys return scalar strings; conflicting values across files are a fatal parse error
- `[notifier:*]` keys are per-instance scalars stored in `$cfg->notifiers->{<type>}` as an arrayref of instance hashrefs
- When adding a new global key, decide scalar vs array-valued and update `%ARRAY_GLOBAL_KEYS` accordingly

### Sensitive file detection
- Auto-detect: `(mode & 0004) == 0` means sensitive (no world-read)
- `sensitive_auto` controls whether auto-detection is active (default: on)
- `sensitive_notify` controls whether diffs appear in notifications (`suppress`|`allow`)
- These two settings are orthogonal: auto affects _detection_, notify affects _output_

### Symlink handling
- Metadata: `lstat()` + `readlink()` → records link target in JSON
- VCS mirror: `sync_mirror_path()` writes a text file with `__CHANGTRACK_NG_SYMLINK_TARGET__=<target>`
- Restore: `restore_mirror_path()` reads this prefix and recreates symlink
- This is consistent but non-obvious; document any changes

### Metadata atomicity
`Metadata::save()` uses tmpfile + rename pattern. This is correct and intentional.

## Known Gaps to Fix (see TODO.md)

- Notifier `headers` and `resource_attributes` (OTLP) are scalar strings; the parser in OTLP.pm handles scalar/arrayref polymorphically via `_parse_kv_config_value()` — this is fragile and worth hardening
- `sensitive_auto` is read by Runner but the relationship to notifier behavior could be clearer
- `Util::run_cmd()` IO::Select timeout is hardcoded to 30s instead of accepting a parameter for slow VCS ops

## Key Design Constraints

- **Zero non-core dependencies** — only Perl core modules. `HTTP::Tiny`, `JSON::PP`, `IO::Compress::Gzip` are all core ≥5.14.
- **Modern and Idiomatic Perl** — readable, maintainable style. `strict`/`warnings`/`feature qw(say state)`. No subroutine signatures (not stable until 5.36).
- **Perl 5.20 floor** — gets `JSON::PP`, `HTTP::Tiny`, `\h`/`\v`, `s///r` in core.
- **Sensitive file protection** — auto-detected by mode; diff suppression in notifications.
- **Locking** — `flock` pidfile; silently skip if locked (cron-safe).
- **Per-file errors** skip with warning; VCS errors abort the run.
- **Config validation** — strict key whitelist; unknown keys = fatal parse error.

## Comment Style Guidelines

All Perl code in this repository follows these comment conventions:

- **No Unicode or ANSI** in comments or section decorations. Dividers use `#` marks only (no em-dashes, box-drawing characters, or arrows).
- **Every function/method** has at least a one-line comment. Larger or complex functions include the function name, inputs, outputs, and a brief description.
- **Major section dividers** use a line of 72 `#` marks before (and optionally after) the section heading. Minor sections use a single `#` comment line or blank comment lines.
- **Every non-trivial code file** has a structured header block (see examples below).
- **Documentation focus**: *what* not *how*. Tag non-obvious implementations with `# COMPLEX:`. Include *why* for design decisions.
- **Accuracy**: fix inaccurate comments outright when the correct behavior is clear.
- **POD**: all `lib/` modules have accurate, comprehensive POD. `t/*.t` files get a header comment block but no POD.

### File header format

All code files start with: vim modeline → perltidy directive → SPDX divider block → description.

The description line is mandatory and must start with the file/module name, then ` - `, then a concise description.

**bin/ (executable) file:**

```perl
#!/usr/bin/perl
# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# changetrack-ng - Main CLI entry point; parses options and dispatches
#   to subcommands (run, init, status, diff, log, revert, update-ignore).
#
use strict;
use warnings;
```

**lib/ (module) file:**

```perl
# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Runner - Orchestration: config -> lock -> file list ->
#   process -> commit -> notify
#
package ChangeTrack::Runner;

use strict;
use warnings;

=head1 NAME

ChangeTrack::Runner - Main orchestration engine
```

**t/ (test) file:**

```perl
# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 01-config-v2.t - Tests for v2 INI config parsing (ChangeTrack::Config).
#
use strict;
use warnings;
use Test::More;
```

### Section divider format (72 `#` marks)

```perl
########################################################################
# Major Section Name
########################################################################
```

Minor sections use a single `#` line or blank comment lines around the heading.

---

## Agent Workflow

- For small fixes: inspect minimal scope, patch only affected files, run targeted tests first.
- For larger changes: make a short plan (3–5 bullets), then implement in small, reviewable steps.
- Avoid unrelated refactors or style churn unless explicitly requested.
- Preserve CLI behavior and config compatibility unless the task requires a breaking change.
- After any code change, run at minimum the relevant test file; run `make test` for broader changes.

## Cross-Project Guardrails

- Prefer the simplest reliable solution over clever or highly abstract designs.
- Reuse existing repository patterns before introducing new structure.
- Keep functions focused and names descriptive; favor explicit behavior over hidden magic.
- Validate and sanitize external input (CLI args, config values, file content assumptions) before use.
- Handle errors explicitly and fail gracefully with actionable messages.
- Do not expose sensitive data in logs, notifications, or error output.
- Document non-trivial behavior and edge-case decisions, especially in modules with operational risk.
- Do not perform version-control operations unless explicitly requested by the user.

## Testing Strategy

- Run the most relevant test file(s) first (for fast feedback).
- Run `make test` before finalizing when behavior changed beyond a narrow isolated path.
- When adding/changing behavior, add or update tests in `t/` in the same change.
- For notifier or config-shaping changes, add integration coverage that instantiates notifiers through real config parsing (`Config -> Runner -> Notifier`).
- Test isolation: each test creates a temp dir via `File::Temp`; cleanup on exit.
- VCS-dependent tests skip (`plan skip_all`) if the binary isn't available.
- On non-Unix systems, expect `getpwuid/getgrgid` and fork/sendmail limitations; prefer skip guards.

## Documentation Requirements

All user-visible changes, interface additions, and behavior changes must be documented before the work is considered complete. At minimum:
- `CHANGELOG.md`: add an entry under `[Unreleased]` (or the target version) describing what changed and why.
- `README.md`: update or add sections for any new flags, subcommands, or behavioral options.
- `PRODUCT.md`: update if the change affects product-level features or observable behavior.
- `CONTRIBUTING.md`: update if the change affects developer workflow, module structure, or coding conventions.

## Version Management

**Single-source version:** `lib/ChangeTrack/Version.pm` is the Perl-side authority (`our $VERSION = '...'`).
All other `lib/` modules use `do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION }`.

On every version bump, update **all** of the following in sync:

| File | What to update |
|---|---|
| `lib/ChangeTrack/Version.pm` | `our $VERSION = '...'` |
| `Makefile` | `VERSION := ...` |
| `CHANGELOG.md` | Move `[Unreleased]` items into a new `[x.y.z] - YYYY-MM-DD` section |
| `packaging/rpm/changetrack-ng.spec` | `Version:` field and a new `%changelog` entry |
| `packaging/debian/changelog` | New entry in `dpkg-style` format (version, distro, urgency, details, maintainer line) |
| `PRODUCT.md` | `Version:` header in the frontmatter |
| `MANIFEST.toml` | `[meta] version` and `updated` fields |

## Copyright and Licensing

All source files carry SPDX tags:
- `SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>`
- `SPDX-License-Identifier: GPL-3.0-or-later`

Files that cannot carry inline SPDX tags (markdown, LICENSE, packaging/debian/) are covered by `.reuse/dep5`.

## Implementation Boundaries

- Do not pull in phase roadmap work from `PLAN.md` unless the user request explicitly asks for it.
- Keep the "zero non-core dependencies" constraint intact for new code.
- Do not add subroutine signatures (stable only in 5.36+).
- Forbidden patterns: bareword filehandles, 2-arg open, indirect method syntax, prototypes on subs.

## Implementation Status

All roadmap implementation phases have been pre-completed and validated against `TODO.md` as of version 0.5.0.
Tests in `t/` (764 total) cover all implemented modules with a stable architecture (`--dry-run` modes, fully exception-safe chdir patterns, and `DEB_BUILD_OPTIONS` mapping). See `TODO.md` for remaining isolated operational, test-gap, or refactoring optimizations.

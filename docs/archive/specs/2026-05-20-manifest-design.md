# Design: MANIFEST.toml — File Inventory for changetrack-ng

**Date:** 2026-05-20
**Status:** Approved
**Author:** Christopher Cashell

---

## Goal

Create an authoritative, structured file inventory (`MANIFEST.toml`) for the
changetrack-ng project that serves two purposes simultaneously:

1. **Human reference** — developers, packagers, and contributors can consult
   it to understand every file in the repository: what it is, where it installs,
   which distribution tarballs include it, and how it relates to other files.
2. **Build automation input** — a `tools/manifest-query` Perl script reads the
   manifest via TOML::Tiny and answers structured queries (file lists by dist
   target, install paths, packaging dependency lines), allowing the Makefile to
   derive file lists rather than maintain them by hand.

---

## File Location

| Artifact | Path |
|---|---|
| Manifest | `MANIFEST.toml` (repo root) |
| Query tool | `tools/manifest-query` |

---

## Format

TOML, using **Approach A**: files are nested TOML tables keyed by their
repository-relative path, grouped under category section headers.

```toml
[category."path/to/file"]
description  = "..."
install_path = "..."
permissions  = "0644"
dist         = ["full", "deploy"]
tags         = ["core", "config"]
tested_by    = ["t/01-foo.t"]
notes        = "Optional non-obvious context"
```

Build-time dependency: **TOML::Tiny** (CPAN; packaged as `libtoml-tiny-perl`
on Debian/Ubuntu and `perl-TOML-Tiny` on RHEL+EPEL).

---

## `[meta]` Section

Scalar fields at the top of the file:

| Field | Value |
|---|---|
| `version` | Current release version (e.g. `"0.6.0"`) |
| `updated` | ISO date of last manifest update |
| `homepage` | `"https://github.com/cashell/changetrack-ng"` |
| `license` | `"GPL-3.0-or-later"` |
| `min_perl` | `"5.20"` |

### `[[meta.deps]]` — Dependency records

Each dependency is one `[[meta.deps]]` array entry. Fields:

| Field | Type | Notes |
|---|---|---|
| `name` | string | Human-readable name of the dep |
| `relationship` | string | See values below |
| `group` | string | Groups `requires_one_of` alternatives (e.g. `"vcs_backend"`) |
| `version` | string | Version constraint if applicable (e.g. `">= 5.20"`) |
| `source` | string | `"system"` (default) or `"cpan"` |
| `deb_package` | string | Debian/Ubuntu package name; `|`-separated for OR deps |
| `rpm_package` | string | RHEL/Fedora package name |
| `cpan_module` | string | CPAN module name (fallback / reference) |
| `notes` | string | Context for the dependency |

**`relationship` values:**

| Value | Meaning | Debian mapping | RPM mapping |
|---|---|---|---|
| `requires` | Hard runtime requirement | `Depends:` | `Requires:` |
| `requires_one_of` | One member of `group` must be present | `Depends: a \| b \| c` | `Recommends:` each |
| `recommends` | Optional but strongly suggested | `Recommends:` | `Recommends:` |
| `build_requires` | Needed to build/test | `Build-Depends:` | `BuildRequires:` |
| `build_optional` | Needed only for optional build targets | `Build-Depends-Indep:` | noted in spec |

### Dependency inventory

```toml
[[meta.deps]]
name         = "perl"
relationship = "requires"
version      = ">= 5.20"
deb_package  = "perl"
rpm_package  = "perl"
notes        = "Core modules HTTP::Tiny, JSON::PP, IO::Compress::Gzip (all core >= 5.14)"

[[meta.deps]]
name         = "git"
relationship = "requires_one_of"
group        = "vcs_backend"
deb_package  = "git"
rpm_package  = "git"

[[meta.deps]]
name         = "rcs"
relationship = "requires_one_of"
group        = "vcs_backend"
deb_package  = "rcs"
rpm_package  = "rcs"

[[meta.deps]]
name         = "fossil"
relationship = "requires_one_of"
group        = "vcs_backend"
deb_package  = "fossil"
rpm_package  = "fossil"

[[meta.deps]]
name         = "subversion"
relationship = "requires_one_of"
group        = "vcs_backend"
deb_package  = "subversion"
rpm_package  = "subversion"

[[meta.deps]]
name         = "mercurial"
relationship = "requires_one_of"
group        = "vcs_backend"
deb_package  = "mercurial"
rpm_package  = "mercurial"

[[meta.deps]]
name         = "sendmail"
relationship = "recommends"
deb_package  = "sendmail | postfix | exim4"
rpm_package  = "postfix"
notes        = "Required only when using the Email notifier"

[[meta.deps]]
name         = "TOML::Tiny"
relationship = "build_requires"
source       = "system"
deb_package  = "libtoml-tiny-perl"
rpm_package  = "perl-TOML-Tiny"
cpan_module  = "TOML::Tiny"
notes        = "Required for tools/manifest-query"

[[meta.deps]]
name         = "App::FatPacker"
relationship = "build_optional"
source       = "system"
deb_package  = "libapp-fatpacker-perl"
rpm_package  = "perl-App-FatPacker"
cpan_module  = "App::FatPacker"
notes        = "Required for make fatpack only"

[[meta.deps]]
name         = "pod2man"
relationship = "build_requires"
source       = "system"
deb_package  = "perl"
rpm_package  = "perl"
notes        = "Included in standard Perl packages; required for make install-man"
```

---

## Per-File Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `description` | string | yes | One-line description of what the file is and does |
| `install_path` | string | when installed | Absolute path with `$(MAKE_VAR)` placeholders; omit for non-installed files |
| `permissions` | string | when installed | `"0755"`, `"0644"`, `"0640"` |
| `dist` | array | when applicable | Subset of `["full", "deploy", "minimal", "deb", "rpm", "arch"]`; omit if excluded from all tarballs |
| `tags` | array | no | Semantic labels for filtering and AI navigation |
| `tested_by` | array | no | On library files: which `t/*.t` files cover this module |
| `tests` | array | no | On test files: which modules/behaviors are under test |
| `notes` | string | no | Non-obvious context, design decisions, caveats |

### `dist` values

| Value | Meaning |
|---|---|
| `"full"` | Included in the full source tarball (`make dist`) |
| `"deploy"` | Included in the production deployment tarball (`make dist-deploy`) |
| `"minimal"` | Included in the minimal fatpacked tarball (`make dist-minimal`) |
| `"deb"` | Used by Debian/Ubuntu packaging (`dpkg-buildpackage`) |
| `"rpm"` | Used by RHEL/Fedora packaging (`rpmbuild`) |
| `"arch"` | Used by Arch Linux packaging (PKGBUILD, future) |

---

## Category Taxonomy

Fourteen categories. Library modules are split into three distinct categories
rather than using tags alone, enabling O(1) table lookups for "all VCS backends"
or "all notifiers."

| Category | Contents |
|---|---|
| `program` | `bin/changetrack-ng` — the main CLI executable |
| `library` | Core `lib/ChangeTrack/*.pm` modules (Config, Lock, Metadata, Report, Runner, Util, Version) |
| `library_vcs` | `lib/ChangeTrack/VCS/` — Base abstract class + 5 VCS backends |
| `library_notify` | `lib/ChangeTrack/Notify/` — Base abstract class + 4 notifier implementations |
| `test` | All `t/*.t` test files |
| `test_support` | `t/lib/` test helpers and `t/fixtures/` data files |
| `config` | `etc/changetrack-ng.conf` — deployed default system configuration |
| `example` | `packaging/etc/examples/` — example configs and drop-in fragments for docs |
| `man` | `man/changetrack-ng.8`, `man/changetrack-ng.conf.5` (pod2man sources; `.gz` variants are generated) |
| `doc` | User-facing documentation: README, CHANGELOG, INSTALL, CONTRIBUTING, ARCHITECTURE, PRODUCT |
| `dev_doc` | Internal developer docs: PLAN.md, TODO.md, CLAUDE.md |
| `packaging` | All files under `packaging/debian/`, `packaging/rpm/`, `packaging/hooks/`, `packaging/systemd/`, `packaging/cron/`, and `packaging/etc/changetrack-ng.default` |
| `build` | `Makefile`, `MANIFEST.toml`, `tools/manifest-query` |
| `legal` | `LICENSE`, `.reuse/dep5`, `.gitignore` |

### Packaging sub-tags

Files in the `packaging` category carry additional tags to identify their
packaging system and function:

| Tags | Files |
|---|---|
| `["packaging", "debian"]` | `packaging/debian/control`, `changelog`, `copyright`, `rules`, `source/format` |
| `["packaging", "debian", "systemd"]` | `packaging/debian/changetrack-ng.service`, `.timer` |
| `["packaging", "rpm"]` | `packaging/rpm/changetrack-ng.spec` |
| `["packaging", "hooks", "apt"]` | `packaging/hooks/apt-pre`, `apt-post`, debug variants |
| `["packaging", "hooks", "dnf"]` | `packaging/hooks/dnf/changetrack_ng.conf`, `.py` |
| `["packaging", "hooks", "pacman"]` | `packaging/hooks/pacman-pre.hook`, `pacman-post.hook` |
| `["packaging", "systemd"]` | `packaging/systemd/changetrack-ng.service`, `.timer` |
| `["packaging", "cron"]` | `packaging/cron/changetrack-ng` |
| `["packaging", "defaults", "debian"]` | `packaging/etc/changetrack-ng.default` |

---

## `tools/manifest-query` Interface

A Perl script using TOML::Tiny. Output is always newline-separated file paths
(or structured text for `--deps-*` modes), suitable for shell capture.

```
# File lists
tools/manifest-query --dist full
tools/manifest-query --dist deploy
tools/manifest-query --dist deb
tools/manifest-query --category library_vcs
tools/manifest-query --tag vcs

# Field extraction
tools/manifest-query --dist full --field install_path

# Dependency output for packaging
tools/manifest-query --deps-deb          # runtime Depends:/Recommends: lines
tools/manifest-query --build-deps-deb    # Build-Depends: lines
tools/manifest-query --deps-rpm          # Requires:/Recommends: lines
tools/manifest-query --build-deps-rpm    # BuildRequires: lines

# Validation
tools/manifest-query --validate          # verify every listed file exists on disk
```

---

## Makefile Integration — Two Phases

### Phase 1: Lint target (in this work)

Add a `manifest-lint` target. Low-risk, immediately useful. Detects manifest
drift whenever a file is added or removed.

```makefile
manifest-lint:
    perl -MTOML::Tiny tools/manifest-query --validate
```

Also add `manifest-lint` to the `.PHONY` list and mention it in `make all`
help output.

### Phase 2: Manifest-driven dist targets (separate follow-on work)

Refactor `dist`, `dist-deploy`, and `dist-minimal` to derive their file lists
from `tools/manifest-query --dist <target>` via `$(shell ...)` rather than
hard-coded path lists. This is non-trivial Makefile surgery and belongs in its
own commit/review.

---

## Maintenance Model

- **Adding or removing a file:** update `MANIFEST.toml` in the same commit.
- **Version bumps:** update `[meta] version` and `updated` alongside `Version.pm`,
  `Makefile`, and `CHANGELOG.md`. Add to the version bump checklist in `CLAUDE.md`.
- **Drift detection:** `make manifest-lint` — checks that every file listed in
  the manifest exists on disk. Reverse check (files on disk missing from the
  manifest) is a future enhancement; note it in `TODO.md`.

---

## Documentation Updates (end of Phase 1)

| File | Change |
|---|---|
| `README.md` | Add section on the manifest and `tools/manifest-query` |
| `CONTRIBUTING.md` | Add rule: update `MANIFEST.toml` when adding/removing files; run `make manifest-lint` before committing |
| `CLAUDE.md` | Add `MANIFEST.toml` to version bump checklist; note manifest as authoritative file index for AI navigation |
| `INSTALL.md` | Note `TOML::Tiny` as a build-time dep for manifest tooling |

---

## Open Items / Future Enhancements

- Reverse lint: detect files on disk not listed in the manifest (complement to
  `--validate`). Add to `TODO.md`.
- Phase 2 Makefile refactor: derive `dist`/`dist-deploy`/`dist-minimal` file
  lists from the manifest.
- `--deps-rpm` and `--build-deps-rpm` query modes (can stub and implement
  alongside `--deps-deb`).
- Arch Linux PKGBUILD support (packaging category already anticipates `"arch"`
  in `dist`).

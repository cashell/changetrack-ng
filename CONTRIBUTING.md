# Contributing to changetrack-ng

---

## Development Setup

```bash
git clone https://github.com/cashell/changetrack-ng.git
cd changetrack-ng
make test    # Requires Perl 5.20+ and prove
```

No build step is needed — modules are loaded directly from `lib/`. Tests run via `prove -l t/`.

---

## File Headers

All Perl code files start with a structured header containing vim configuration, perltidy directives, SPDX metadata, and a file description. The format differs by file type:

The description line must start with the file/module name, then ` - `, then a concise description.

### bin/ (executable) files

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

### lib/ (module) files

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

=head1 DESCRIPTION

...
```

### t/ (test) files

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

### Header format notes

- **Vim modeline** (line 2): `ts=4` (tabs = 4 spaces), `sw=4` (shift width), `et` (expand tabs to spaces), `sm` (show matching brackets), `ai` (auto-indent), `smd` (show mode), `sc` (showcmd), `bg=dark`
- **Perltidy directive** (line 3): Standard 4-space indent with void context, minimal vertical tightness, left paren on opening lines, cuddled braces, no blank lines before close brace, paren space, and continuation indent as specified
- **SPDX divider** (lines 4, 7): 72 `#` marks provide visual separation
- **Description** (line 9+): Must begin with the script/module/test file name, then ` - `, then description text. Wrap continuation lines with `#   ` (hash + 3 spaces); aim for ~70 chars per line. End with blank comment line (`#`) to close the header.

---

## Comment Style

All Perl code in this repository follows these comment conventions:

- **No Unicode or ANSI** in comments or section decorations. Dividers use `#` marks only; no em-dashes, box-drawing characters, or arrows.
- **Every function/method** has at least a one-line comment. Larger or complex functions include the function name, inputs, outputs, and a brief description.
- **Major section dividers** use a line of 72 `#` marks before (and optionally after) the section heading. Minor sections use a single `#` comment line or blank comment lines before/after.
- **Documentation focus**: comments explain *what* the code does, not *how*. Unless the implementation is non-obvious, in which case tag it with `# COMPLEX:` to flag it for future cleanup. Include a *why* note for significant design decisions.
- **Accuracy**: comments must accurately reflect the code they describe. Fix inaccurate comments outright where the correct behavior is clear.
- **POD**: all `lib/` modules include POD covering `NAME`, `SYNOPSIS`, `DESCRIPTION`, and all public methods. POD must be accurate and kept in sync with the implementation. Test files (`t/*.t`) do not use POD, but do get a file-header comment block.

### Section dividers

Major sections (72 `#` marks):

```perl
########################################################################
# Section Name
########################################################################
```

Minor sections (single line or surrounding blank comment lines):

```perl
# Minor heading
```

---

## Code Style

This project uses modern, idiomatic Perl 5.20+:

- **Always**: `use strict; use warnings; use feature qw(say state);`
- **Prefer**: `say` over `print "...\n"`, `state` for persistent lexical variables
- **Allowed**: `s///r` (non-destructive substitution), `\h`/`\v` character classes, postfix dereferencing (`$hashref->%*`)
- **Forbidden**:
  - Subroutine signatures (not stable until 5.36)
  - Bareword filehandles (`open FH, ...`)
  - Two-argument `open`
  - Indirect method syntax (`new Foo(...)`)
  - Prototypes on subroutines
  - Shell-interpolated command execution (backticks, `system($string)`)

### Naming conventions

- Modules: `CamelCase` (`ChangeTrack::VCS::Git`)
- Subroutines and methods: `snake_case` (`sync_mirror_path`, `can_skip_content_diff`)
- Private/internal subs: prefixed with `_` (`_validate_global_values`)
- Constants: `UPPER_SNAKE_CASE` (`%KNOWN_GLOBAL_KEYS`, `$SYMLINK_PREFIX`)
- Variables: `$snake_case`, `@snake_case`, `%snake_case`

### Formatting

- 4-space indentation (no tabs)
- Opening brace on the same line as the control structure
- Spaces around operators and after commas
- Blank line between logical sections within a sub

---

## Module Structure

All modules live under `lib/ChangeTrack/`. Every module:

1. Declares `package ChangeTrack::*;`
2. Imports `strict`, `warnings`, and `feature qw(say state)`
3. Sets version via: `our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };`
4. Ends with `1;`

Constructors use hash-based blessed references:

```perl
sub new {
    my ($class, %args) = @_;
    my $self = bless {
        output_dir => $args{output_dir} // croak("output_dir required"),
    }, $class;
    return $self;
}
```

---

## External Command Execution

**All** external commands must go through `ChangeTrack::Util::run_cmd()`:

```perl
my $result = run_cmd('git', '-C', $repo_dir, 'status', '--porcelain');
if ($result->{success}) {
    say $result->{stdout};
}
```

- Always pass arguments as a list (never a single string)
- Never interpolate variables into shell strings
- This is a hard security boundary — no exceptions

---

## Dependencies

Runtime dependencies are limited to Perl core modules (core since ≥5.14). Do not introduce CPAN dependencies. If you need functionality beyond core, discuss the justification in your PR.

Test dependencies are also core-only (`Test::More`, `File::Temp`, `File::Path`).

---

## Testing

### Running tests

```bash
make test                     # Full suite
prove -l t/06-vcs-git.t       # Single test
prove -l -v t/               # Verbose output
```

### Writing tests

- Create test files in `t/` named `##-description.t` (numbered for ordering)
- Use `Test::More` as the test framework
- Isolate each test with `File::Temp::tempdir(CLEANUP => 1)`
- Skip VCS-backend tests when the binary isn't available:
  ```perl
  use Test::More;
  plan skip_all => 'git not available' unless `which git 2>/dev/null`;
  ```
- On non-Unix systems, guard against `getpwuid`/`getgrgid`/fork limitations with skip blocks
- Test the public interface; avoid reaching into internal state unless testing a specific edge case
- When adding or changing behavior, include test coverage in the same commit

### Test patterns

- **Unit tests**: exercise a single module's methods in isolation
- **Integration tests**: wire Config → Runner → VCS/Notifier to verify data flow
- **Mock objects**: `t/lib/ChangeTrack/Test/MockSendmail.pm` for email tests; similar patterns for other externals
- No network calls in tests — mock HTTP endpoints or use file-based notifiers

---

## Error Handling

- Per-file errors: `warn` and continue processing remaining files
- VCS-level errors: `die`/`croak` to abort the run (these are non-recoverable)
- Notifier errors: wrapped in `eval`; failures warn but never abort
- Use `croak` (from `Carp`) for API misuse; `die` for runtime failures
- Provide actionable error messages that include the failed path or operation

---

## Config Changes

### Sample config files

The example configs must stay consistent:

- `packaging/etc/examples/changetrack-ng.conf-default` is the **canonical** default config.
  `etc/changetrack-ng.conf` is the installed default and a **byte-identical** copy of it, kept at
  the repo root so it is easy to find and browse. After editing the canonical example, resync the
  installed copy and verify with the lint target:
  ```bash
  cp packaging/etc/examples/changetrack-ng.conf-default etc/changetrack-ng.conf
  make config-lint   # also runs automatically as part of `make test`
  ```
  `config-lint` uses the core `File::Compare` module (no external `cmp`/`diff`), so it runs anywhere
  Perl does.
- `changetrack-ng.conf-full` is the comprehensive reference: it must document **every** key the
  parser accepts (all `%KNOWN_GLOBAL_KEYS` and `%KNOWN_NOTIFIER_KEYS`), and must not document keys
  the parser would reject.
- `changetrack-ng.conf-minimal` stays minimal; `changetrack-ng.conf-user` targets non-root installs.

### Adding a new global key

1. Add it to `%KNOWN_GLOBAL_KEYS` in `Config.pm` (unknown keys are fatal parse errors)
2. Decide if it's scalar or array-valued; update `%ARRAY_GLOBAL_KEYS` if array-valued
3. Add the appropriate type table entry (`%BOOL_GLOBAL_KEYS`, `%INT_GLOBAL_KEYS`,
   `%ENUM_GLOBAL_KEYS`, or `%PATH_GLOBAL_KEYS`) if the value has constraints
4. Document the key in `README.md` and the config example files. Edit the canonical
   `-default` example, resync `etc/changetrack-ng.conf` from it (`make config-lint` enforces they
   match), and update the `-full` reference

### Adding a new notifier type

1. Add the type to `%KNOWN_NOTIFIER_KEYS` in `Config.pm` with its allowed keys
2. Add entries to `%ARRAY_NOTIFIER_KEYS`, `%BOOL_NOTIFIER_KEYS`, `%INT_NOTIFIER_KEYS`,
   `%PATH_NOTIFIER_KEYS`, and `%ENUM_NOTIFIER_KEYS` as appropriate for each key
3. Create `lib/ChangeTrack/Notify/<Type>.pm` extending `ChangeTrack::Notify::Base`
4. Implement `name()`, `heartbeat_enabled()`, `validate_config()`, and `send($report)`
5. Add the type to `_build_notifiers()` in `Runner.pm`
6. Add test coverage in a new `t/##-notify-<type>.t`; add an enabled instance to
   `t/fixtures/config-v2-full.ini` and verify it through `t/18-integration-notifiers.t`

### Adding a new key to an existing notifier type

1. Add the key to `%KNOWN_NOTIFIER_KEYS{<type>}` in `Config.pm`
2. Add the appropriate type table entry as above
3. Update the notifier module constructor to read the new key
4. Update `validate_config()` if the key is required
5. Add a test case in the relevant `t/##-notify-<type>.t`

---

## Manifest Maintenance

`MANIFEST.toml` is the authoritative file inventory.  Keep it accurate:

- **Adding a file:** add a corresponding `[category."path"]` entry in the same commit.
- **Removing a file:** remove its entry from `MANIFEST.toml` in the same commit.
- **Run `make manifest-lint` before committing** to verify all listed files exist on disk.
  (`TOML::Tiny` / `libtoml-tiny-perl` is required for this check.)

---

## Commit Guidelines

- Write clear, descriptive commit messages (imperative mood: "Add webhook retry logic")
- One logical change per commit
- Reference issue numbers where applicable
- Run `make test` before submitting; all tests must pass

---

## Security Considerations

- Never log secrets (webhook URLs with tokens, OTLP auth headers) at default verbosity
- Preserve the sensitive-file auto-detection model — changes that weaken it need explicit justification
- Respect trust boundaries: config is trusted, tracked file content is semi-trusted, network endpoints are untrusted
- Mirror directories are created mode 0700; config should be 0640

---

## Licensing

All source files carry SPDX tags:

```
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
```

Include these headers in any new source files.

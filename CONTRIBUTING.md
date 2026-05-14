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

When adding a new configuration key:

1. Add it to `%KNOWN_GLOBAL_KEYS` in `Config.pm` (unknown keys are fatal)
2. Decide if it's scalar or array-valued; update `%ARRAY_KEYS` if array
3. Add type validation in `_validate_global_values()` if the value has constraints
4. Document the key in `README.md` and the config example
5. Add a test case in `t/02-config.t`

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

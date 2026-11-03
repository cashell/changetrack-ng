# changetrack-ng Audit Remediation Plan

- **Date:** 2026-10-28
- **Source:** [AUDIT-REPORT.md](AUDIT-REPORT.md). Finding numbers below match the report.
- **Baseline:** `5d91430` (main)

## Approach

The work is split into four small PRs, ordered by risk. Each PR is self-contained, carries its own tests and docs, and can ship on its own.

| PR | Findings | Theme | Size (est.) |
|----|----------|-------|-------------|
| A | 1, 2, 8 | Git/SVN/Hg mirror must not obey the tracked tree's VCS files | ~25 lines + tests + recovery docs |
| B | 3 | `run_cmd` stdin write must respect the timeout | ~15 lines + 1 test |
| C | 4, 5, 7 | Locking and error-path correctness | ~30 lines + 2 tests |
| D | 6, 9 | Lean and hygiene | about -15 / +10 lines |

Every PR runs the same checks before merge:

```bash
prove -l t/<relevant>.t   # fast feedback first
make dev-check
make test
```

Docs that apply to every PR:

- Add a `CHANGELOG.md` entry under `[Unreleased]`.
- Update `README.md`, `PRODUCT.md` or `CONTRIBUTING.md` only where behavior changes, as noted per PR.

Release:

- A version bump is **not** part of these PRs. When a release is cut, confirm the exact `x.y.z` first, then follow the full gate in `AGENTS.md`, including `make packages`.

---

## PR A: Mirror isolation (findings 1, 2, 8). Do first.

### A1. Prune foreign VCS directories and excluded paths during the walk

**File:** `lib/ChangeTrack/Runner.pm:662-678` (`_build_file_list`, the `find` callback)

1. Add a module-level constant near the other file-scope lexicals:
   ```perl
   # Foreign VCS control directories; mirroring them nests a repo inside the
   # mirror and makes the backend silently skip everything below it.
   my %FOREIGN_VCS_DIRS = map { $_ => 1 } qw(.git .hg .svn CVS .bzr _darcs);
   ```
2. At the top of `wanted`, before the `-f || -l` check:
   ```perl
   if (-d $_ && !-l $_) {
       my $p = $File::Find::name;
       if ($FOREIGN_VCS_DIRS{ basename($p) } || _is_excluded_path($p, $exclude_paths)) {
           $self->_trace("$p: pruned (foreign VCS dir or internal path)");
           $File::Find::prune = 1;
       }
       return;
   }
   ```
3. Keep the per-file `_is_excluded_path` check. It still covers excluded *files*, such as the lock file and file-notifier logs.
4. Check whether a mirrored Fossil `.fslckout` or `_FOSSIL_` *file* makes Fossil treat a subfolder as a nested checkout. If it does, add those basenames as skipped files, not pruned directories.

**Reconcile check:** Look at the deleted-file reconcile at `Runner.pm:682-686`. Old metadata records for `/etc/.git/*` paths still exist on disk, so `next if -e $stored_path` keeps them as live records forever. Drop or skip records whose path has a `%FOREIGN_VCS_DIRS` segment, so they don't linger. Decide: silently forget them (recommended), or report them as removed once (noisy).

### A2. Force-add in Git

**File:** `lib/ChangeTrack/VCS/Git.pm:64`

- Change `'add', $mirror` to `'add', '-f', '--', $mirror`. The `--` also guards a mirror path that starts with `-`.
- **Verify first:** `_update_gitignore` (`bin/changetrack-ng:281`) must write the same `ignore` patterns that `Runner::_should_ignore` already applies before `add` is called. If it does, `-f` changes nothing for those patterns, because ignored files never reach `add`. If `.gitignore` can hold anything else, keep that rule in `_should_ignore` instead.
- Also check the SVN `svn:ignore` and Hg `.hgignore` equivalents:
  - SVN `add --force` adds ignored files only with `--no-ignore`. Confirm this, and add `--no-ignore` if needed.
  - For Hg, a mirrored `.hgignore` only matters if it sits at the mirror root. Check the `hg add` behavior for explicitly named files: they are added even when ignored.

- **Verify (sibling of F2):** a tracked dir's `.gitattributes` is mirrored and git applies it. `text`/`eol`/`ident`/`filter` can change stored bytes and what `revert` writes back (for example CRLF coming back as LF), and `-diff` hides diffs in notifications. Candidate fix: write `* !text !eol !ident !filter !diff` (`!` resets to unspecified, which is git's default; do not use `-diff`, which would mark every file binary) to `.git/info/attributes` at `init`, and on first run for existing repos.

### A3. Startup warning for an already-broken mirror

**File:** `lib/ChangeTrack/Runner.pm`. Call this once per run, after `_setup` / `is_initialized`, for whole-repo backends only.

- Scan for foreign VCS directories *inside* the mirror, other than the backend's own root control dir: `output_dir/.git`, `.hg` or `.svn`. Use a bounded `find` with prune at the first hit.
- If any exist, warn and add a report warning. Example: `"Nested repository at <path> inside the mirror; files below it were not being committed. See README 'Recovering from a nested repository'."`
- Do **not** delete anything automatically (see the open decision below).

### A4. Tests

- **New file `t/40-mirror-isolation.t`.** Skip if `git` is missing.
  1. Create a tracked dir with a real nested repo (`git init tracked/sub`) and a file `tracked/sub/conf`. Run. Assert `git -C output_dir ls-files` contains `.../sub/conf` and contains nothing under `.../sub/.git/`.
  2. Create a tracked dir holding a `.gitignore` that lists `secret.local`, plus that file. Run. Assert `secret.local` is in HEAD and the report has no warnings.
  3. Make `output_dir` a child of a tracked dir. Run with `trace => 1`. Assert no `[TRACE]` line mentions a path under `output_dir/.git/`, which proves the prune happens before files are visited.
  4. Seed a mirror with a nested `.git` dir (simulating an old install). Run. Assert the A3 warning appears and the run still completes. Verified 2026-10-28: `git add -f -- etc/conf` inside a nested repo still exits 0 and stages nothing, so upgraded installs do not start aborting. They just stay silently broken until recovery. That is why A3 matters.
- If SVN and Hg are installed, run case 1 against them too, using the existing skip-guard pattern from `t/14-vcs-svn.t` and `t/15-vcs-hg.t`.

### A5. Docs

- **`CHANGELOG.md`:**
  - Fixed: files under a tracked directory that contains a `.git`/`.svn`/`.hg` directory (e.g. etckeeper's `/etc/.git`) were silently never committed.
  - Fixed: files listed in a tracked `.gitignore` were never recorded.
  - Changed: foreign VCS control directories are no longer tracked.
- **`README.md`:** Add a section "Coexisting with etckeeper / tracked repos" and a "Recovering from a nested repository" procedure:
  ```bash
  # 1. Upgrade, then list nested repos inside the mirror (do not delete yet)
  find /var/lib/changetrack-ng -mindepth 2 \( -name .git -o -name .svn -o -name .hg \) -type d -prune -print
  # 2. Remove only those listed paths (never output_dir/.git itself)
  # 3. Force a full re-record: move the metadata aside so every file is seen as new once
  mv /var/lib/changetrack-ng/.changetrack-metadata /root/changetrack-metadata.bak
  changetrack-ng run -v
  ```
  Note: step 3 sends one notification listing every tracked file as NEW.
- **`PRODUCT.md`:** add one line under tracking behavior saying that foreign VCS dirs are skipped.

### Open decision (ask before implementing A3)

Should the tool *auto-repair* a nested repo it finds in the mirror? That would mean removing the nested control dir and dropping metadata for the paths below it, so they re-record. The recommendation is **no**: warn and document a manual recovery. Auto-deleting inside the history store is hard to undo, and the warning already makes the problem visible.

---

## PR B: `run_cmd` stdin timeout (finding 3)

**File:** `lib/ChangeTrack/Util.pm:276-282`, and the kill path after the select loop.

### B1. Implementation (option A, recommended: smallest)

```perl
my $stdin_ok = 1;
{
    local $SIG{PIPE} = 'IGNORE';
    # Bound the stdin write by the same deadline as the drain loop; a child
    # that never reads would otherwise block print() past the timeout.
    $stdin_ok = eval {
        local $SIG{ALRM} = sub { die "stdin write timed out\n" };
        alarm($timeout) if defined $deadline;
        if (length $input) { print {$in_fh} $input; }
        close($in_fh);          # close inside the alarm: flushing can block too
        alarm(0);
        1;
    };
    alarm(0);
}
$timed_out = 1 unless $stdin_ok;
```

- Skip the select loop when `$timed_out` is already set, so control goes straight to the existing TERM, sleep 0.2, KILL and reap code. Make sure `$in_fh` is closed on that path (`close` it again inside `eval {}`, ignoring errors).
- `alarm` takes whole seconds. Use `alarm(int($timeout) || 1)`.
- Make sure no caller of `run_cmd` already uses `alarm`. Grep `alarm` in `lib/` and `bin/`. Nesting would cancel the outer alarm.

**Option B (fallback if option A is flaky on some platform):** make `$in_fh` non-blocking and feed it with `syswrite` chunks from the existing loop, using a second `IO::Select` for writable handles. This is about 25 lines, needs no signals, and is deterministic. Pick it if the B2 test fails intermittently under option A.

### B2. Test

**File:** `t/30-run-cmd.t`. Add a case. Skip on `MSWin32`, where `alarm` does not interrupt blocking I/O.

```perl
{
    my $t0 = time;
    my $r  = run_cmd(
        cmd     => [$perl, '-e', 'sleep 30'],
        input   => ('x' x 1_000_000),
        timeout => 2,
    );
    ok($r->{timed_out},      'stdin write to a non-reading child is bounded by timeout');
    ok(time - $t0 < 10,      'returned promptly');
    ok(!$r->{success},       'reported as failure');
}
```

### B3. Optional follow-up (not required to close finding 3)

Add `max_diff_bytes` to the email notifier, reusing `Notify::Base::_truncate_diff`. Email is the only notifier without a size cap. This is a new config key, so it needs the `Config.pm` whitelist (lines 131-165), the `-default` example, README, CHANGELOG, and `make config-lint`. Track it separately.

### B4. Docs

- `CHANGELOG.md`, Fixed: a notifier or command that stopped reading stdin could hang a run past `command_timeout` and hold the lock, so all later runs were skipped.

---

## PR C: Locking and error paths (findings 4, 5, 7)

### C1. Lock `revert` (finding 4)

**File:** `lib/ChangeTrack/Runner.pm:1090-1097`, with the lock code currently inline at `Runner.pm:201-216`.

1. Extract `_lock_for($cfg, $force)` from `run()`. It resolves `lock_path` (falling back to `_default_lock_path()`), calls `_ensure_lock_parent_dir`, and returns a `ChangeTrack::Lock` object. Make `run()` use it with no change in behavior.
2. In `revert_path`, use `my ($vcs, $cfg) = $self->_setup;`. Then `my $lock = $self->_lock_for($cfg, 0); $lock->acquire or croak "Another changetrack-ng run holds the lock ($lock_path); retry shortly";`. `_setup` already returns `($vcs, $cfg, $output_dir)`. Release the lock at the end; `DESTROY` also covers this.
3. **Important:** pass `force => 0` for revert. In `bin/changetrack-ng`, `--force` means "skip the y/N prompt" for `revert` but "steal the lock" for `run`. Both reach the Runner as `$self->{force}`. Revert must never steal a live run's lock.
4. Make sure `cmd_revert` reports the croak cleanly and exits non-zero (check its current `eval` and exit-code handling).

**Test** (`t/16-subcommands.t` or new `t/41-revert-lock.t`):
- Acquire the lock in the test with `ChangeTrack::Lock->new(path => $lock)->acquire`.
- Call `revert_path`. Assert it dies with the lock message and the live file is unchanged.
- Release the lock, call again, and assert the revert succeeds.

### C2. Remove before forgetting (finding 5)

**File:** `lib/ChangeTrack/Runner.pm:414-430`

```perl
unless (@st) {
    if (defined $existing) {
        unless ($self->{dry_run}) {
            eval { $vcs->remove($real_path) };
            if (my $err = $@) {
                $err =~ s/\n$//;
                $self->_warn("VCS remove failed for $real_path (will retry next run): $err");
                $report->add_warning("VCS remove failed for $real_path: $err");
                return;    # keep the metadata record so the next run retries
            }
        }
        $report->add_removed(path => $real_path, recipients => $recipients);
        $md->mark_removed($real_path);
        ...
```

- **Check that every backend's `remove` is safe to retry** when the mirror file is already gone:
  - Git (`Git.pm:69-81`): it checks `-e` before `unlink` and checks HEAD before `git rm`. OK.
  - RCS: `unlink if -e`. OK.
  - SVN, Hg, Fossil: confirm `rm --force` on an already-missing path does not croak. Make it idempotent where it does.
- **Check the reconcile step** (`Runner.pm:682-686`): it must re-queue a path whose record still exists but whose file is gone, so the retry happens. It already does this (`next if -e $stored_path || -l $stored_path`).

**Test** (`t/35-vcs-removal.t`, which already has removal fixtures):
- Wrap the backend so `remove` dies on its first call (`local *ChangeTrack::VCS::Git::remove = sub { die "simulated\n" }`).
- Run. Assert a warning, no `add_removed`, and that the metadata record still exists.
- Restore the method and run again. Assert the file is gone from HEAD and the record is gone.

### C3. Honest permission warning (finding 7)

**File:** `lib/ChangeTrack/Runner.pm:1220-1230`

```perl
my $msg = chmod($new_mode, $path)
    ? sprintf("Tightened insecure permissions on %s from %04o to %04o", $path, $mode & 07777, $new_mode)
    : sprintf("Cannot tighten insecure permissions on %s (%04o): %s", $path, $mode & 07777, $!);
```

- No new test. The change is trivial, and making `chmod` fail portably in a test requires root or special mounts. Existing tests for the success message must still pass.

### C4. Docs

- `CHANGELOG.md`:
  - Fixed: `revert` now takes the run lock.
  - Fixed: failed VCS removals are retried instead of being dropped.
  - Fixed: a failed permission tightening is reported as a failure.
- `README.md`, revert section: one line saying revert waits for, or refuses while, a run holds the lock.

---

## PR D: Lean and hygiene (findings 6, 9)

### D1. Single redaction helper (finding 6)

**File:** `lib/ChangeTrack/Runner.pm:266-296`

1. Add `_redacted_config_value($key, $val)`. It joins arrayrefs, maps undef to `''`, returns `'***REDACTED***'` when the key matches the secret regex, and otherwise returns `redact_secrets($val)`.
2. Replace both loop bodies with one call each.
3. Before widening the regex, list every key in the `Config.pm` whitelist (lines 109-165) and mark which ones carry secrets. Add only the missing ones (likely candidates: `key`, `auth`, `bearer`, `credential`).

**Test:** Grep `t/` for an existing `REDACTED` assertion and extend it, or add one. Run with `debug => 1` on a config whose webhook `url` and `headers` contain a token. Capture STDERR and assert the token string never appears.

### D2. Atomic `.gitignore` rewrite (finding 9)

**File:** `bin/changetrack-ng:281-310` (`_update_gitignore`)

- Write to `File::Temp->new(DIR => dirname($path), UNLINK => 0)`, `print` with return checks, `close or die`, `chmod 0600`, then `rename`. This mirrors `Metadata::save`.
- **Test:** the existing `update-ignore` test in `t/16-subcommands.t` must still pass. Also assert that no `*.tmp*` file is left behind.

### D3. Docs

- `CHANGELOG.md`, Changed: `update-ignore` writes `.gitignore` atomically.
- Add a note under Internal for the redaction refactor only if the regex was widened (that is a user-visible security fix).

---

## Deferred / not planned

- **Left-out items from the report:** the `init_vcs` variable name, the RCS working-file write, and the `_with_temp_mirror_sync` backup path. Pick these up only if those functions are touched for other reasons.
- **Not-checked areas from the report:** `Config.pm` include and drop-in handling, Webhook/OTLP retry and TLS, `tools/`, packaging and install hooks, Fossil/SVN/Hg internals. These deserve a follow-up audit pass. They are not covered by this plan.

## Housekeeping

- `AUDIT-REPORT.md` and `AUDIT-PLAN.md` are not in `MANIFEST.toml`, so `tools/manifest-query`'s unlisted-file check (part of `make dev-check`) will flag them. Either add them to `MANIFEST.toml` as `dev_doc` (excluded from dist), or move them to `docs/archive/` and list them there, or delete them once the PRs land.
- When all four PRs are merged, close out the matching "Known Gaps" in `AGENTS.md` and `TODO.md` where they overlap.

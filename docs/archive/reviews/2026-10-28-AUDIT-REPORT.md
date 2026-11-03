# changetrack-ng Audit Report

- **Date:** 2026-10-28
- **Commit audited:** `5d91430` (main, clean tree)
- **Scope:** the whole repo, read the way a new maintainer would. The focus was the run path, VCS backends, locking, `run_cmd`, metadata, and the notifiers.
- **Priority order used:** correct, safe, holds under load, tested, fast, lean.
- **Companion plan:** [2026-10-28-AUDIT-PLAN.md](../plans/2026-10-28-AUDIT-PLAN.md)

## What this repo does

changetrack-ng watches system files such as `/etc/*` and records each change in a version-control repo (Git, RCS, Fossil, SVN or Mercurial). It can also send an alert by email, webhook, OTLP or a JSON log file. It runs as root from cron, a systemd timer, or apt/dnf/pacman hooks.

**Load assumed:** one host and one run at a time. Runs can overlap now and then: a cron run, a package-hook run, and a person typing `revert` or `diff`. A `flock` pidfile lock (a file only one process can hold at a time) keeps `run` invocations apart. With `lock_timeout = 0` (the default), a second run is skipped silently.

### Terms used below

- **Mirror:** the copy of the tracked tree kept under `output_dir`. Whole-repo backends (Git, Fossil, SVN, Hg) commit from it.
- **Metadata:** the `.changetrack-metadata` JSONL file. It holds the last-seen size, mtime, ctime, mode and owner of each file.
- **Fast path:** a file is skipped without any diff when its mtime, size and ctime match its metadata. As a result, once metadata is saved for a change, that change is never looked at again.
- **HEAD:** the latest commit in the mirror repo.

---

## Must fix

### 1. Tracking `/etc` on an etckeeper host silently records nothing

`lib/ChangeTrack/Runner.pm:662-678` (directory walk), with the effect seen at `lib/ChangeTrack/VCS/Git.pm:64`.

- **What this is:** `_build_file_list` walks each `DIRECTORY` entry with `File::Find` and queues every regular file and symlink. That includes the files of another tool's repo, like `/etc/.git/*` (etckeeper), `.svn/`, or `.hg/`.
- **Problem:** The copied files rebuild a working Git repo at `output_dir/etc/.git`. Git then treats `etc/` as a nested repo. `git -C output_dir add output_dir/etc/passwd` **exits 0 and stages nothing**. The commit step sees nothing staged and does nothing. Metadata is still saved, so the fast path skips the change on every later run.
- **Fix:** In the `wanted` callback, prune directories named `.git`, `.hg`, `.svn`, `CVS`, `.bzr` and `_darcs` with `$File::Find::prune = 1`. Existing installs also need a recovery step; see the plan.
- **If we skip it:** On any host using etckeeper (common on Debian/Ubuntu), no change under `/etc` is recorded, and nothing warns about it.

**Evidence (reproduced on this machine, Git for Windows):**

```text
$ git init -q m && git init -q m/etc && echo p > m/etc/passwd
$ git -C m add "$PWD/m/etc/passwd"; echo "exit=$?"
exit=0
$ git -C m status --short
?? etc/
$ git -C m ls-files -s
(empty)
```

**Additional notes:**
- The same bug hits SVN (a mirrored `.svn/` makes a nested working copy) and Mercurial (`.hg/`).
- For Fossil, check whether a mirrored `.fslckout` / `_FOSSIL_` *file* has the same effect. Those are files, not directories, so prune alone will not catch them.
- No current test covers a tracked folder that contains another repo.

### 2. Files listed in a tracked `.gitignore` are never recorded

`lib/ChangeTrack/VCS/Git.pm:64`

- **What this is:** A `.gitignore` inside a tracked folder is copied into the mirror like any other file, and Git then obeys it in the mirror.
- **Problem:** Say `/srv/app/.gitignore` lists `config.local`. Then `git add .../srv/app/config.local` exits 1 with "The following paths are ignored". `add` croaks, `_process_file` rolls back the metadata for that file and warns, and the same thing happens on every run.
- **Fix:** Use `git add -f`. `-f` (force) adds the file even when an ignore rule matches it.
- **If we skip it:** The files people ignore in their own repos are usually the local config and secrets, which is exactly what this tool should track. The warning repeats on every run, so people learn to ignore it.

**Evidence (reproduced):**

```text
$ printf 'shadow\n' > m/etc/.gitignore && echo s > m/etc/shadow
$ git -C m add "$PWD/m/etc/shadow"; echo "exit=$?"
The following paths are ignored by one of your .gitignore files:
etc/shadow
exit=1
```

**Additional notes:**
- `.gitattributes` copied into the mirror is applied the same way: `text`/`eol` rules change stored line endings, and `export-ignore` is harmless. Attribute `filter=` drivers only run if they are defined in git *config*, which the mirror does not have, so there is no code-execution risk. I did not test this.
- The `update-ignore` subcommand writes `output_dir/.gitignore` on purpose. Using `-f` on `git add` overrides that too. The plan covers how to keep it working.

### 3. A hung mail program hangs the run forever and blocks all later runs

`lib/ChangeTrack/Util.pm:276-282`

- **What this is:** `run_cmd` writes the whole stdin string with a blocking `print`, closes stdin, and only *then* starts the `IO::Select` loop that enforces `timeout`.
- **Problem:** The email notifier sends the whole message through stdin (`Notify/Email.pm:156`). It has no `max_diff_bytes` cap, so one large diff can produce a body over the pipe buffer (about 64 KB on Linux). If sendmail stops reading (queue disk full, a stuck `postdrop`, a broken milter), the `print` blocks forever. The timeout never starts. The run keeps the lock, and every later cron or hook run sees the lock held and exits silently.
- **Fix:** Put the stdin write under the same deadline. The simplest way is an `alarm`-guarded write that, on timeout, goes into the existing TERM/KILL path. The more robust way is a non-blocking write inside the select loop. See the plan.
- **If we skip it:** Change tracking stops on that host until someone notices and kills the process. Nothing alerts on it.

**Additional notes:**
- `t/30-run-cmd.t:97-104` tests a child that *exits* without reading stdin (the SIGPIPE case). Nothing tests a child that *stays alive* without reading.
- Webhook and OTLP use `HTTP::Tiny` with their own `timeout`, so they are not affected.

---

## Should fix

### 4. `revert` runs without the run lock

`lib/ChangeTrack/Runner.pm:1090-1097` (called from `bin/changetrack-ng` `cmd_revert`)

- **What this is:** `revert_path` calls `$vcs->revert`, which runs `git checkout <rev> -- <path>` (this writes the index) or RCS `co`. It then restores the live file.
- **Problem:** `run()` takes `ChangeTrack::Lock` (`Runner.pm:201-216`), but `revert_path` does not. Suppose a person reverts during an apt-hook run. Two git processes then use the same index, and one fails with `index.lock: File exists`. Either the run aborts with "VCS commit failed", or the revert fails after `git checkout` changed the mirror but before the live file was restored.
- **Fix:** Take the same lock at the start of `revert_path` and fail with a clear message if it is held.
- **If we skip it:** Rare. But it happens during upgrades, which is exactly when people revert.

### 5. A failed VCS remove loses the deletion for good

`lib/ChangeTrack/Runner.pm:414-430`

- **What this is:** When a tracked file is gone, the code calls `add_removed`, then `$md->mark_removed`, then `$vcs->remove` inside an `eval`.
- **Problem:** If `$vcs->remove` fails (for example `git rm` hits a stale `index.lock`), it only warns. The metadata record is already dropped, so the reconcile step (`Runner.pm:682-686`) never brings the path back. HEAD keeps the file forever. For Git, the mirror file has already been unlinked (`Git.pm:73-75`), but the deletion was never staged.
- **Fix:** Call `$vcs->remove` first. Call `mark_removed` and `add_removed` only if it succeeds. On failure, keep the record so the next run tries again.
- **If we skip it:** History shows deleted files as still present, and notifications for those deletions are reported but never committed.

### 6. Config redaction code exists twice

`lib/ChangeTrack/Runner.pm:266-296`

- **What this is:** The `--debug` config dump redacts secrets in two loops, one for `[global]` and one per notifier instance. Both use the same key regex `/header|secret|token|password|url|uri|endpoint|remote/i` and the same `redact_secrets` fallback.
- **Problem:** The two copies must always change together. If a new secret-bearing key (say `api_key` or `auth`) is added to one regex and not the other, that secret prints to stderr, and cron mails stderr to root. `api_key`, `auth` and `bearer` are already not covered by the regex.
- **Fix:** Pull out one `_redacted_config_value($key, $val)` helper and call it from both loops. Add `key|auth|bearer|credential` to the regex while there.
- **If we skip it:** A future secret leaks into debug output and root's mailbox.

### 7. "Tightened permissions" is logged even when `chmod` failed

`lib/ChangeTrack/Runner.pm:1220-1230`

- **What this is:** At startup, group/world bits are removed from `output_dir` and the sibling Fossil/SVN repos, because they hold copies of files like `/etc/shadow`.
- **Problem:** The return value of `chmod` is ignored. On a read-only mount, NFS with root_squash, or an immutable directory, the message still says "Tightened ... to 0700" and the directory stays world-readable.
- **Fix:** On failure, warn `"Cannot tighten insecure permissions on $path ($mode): $!"` instead.
- **If we skip it:** The operator thinks the copies of secrets are protected when they are not.

---

## Nice to have

### 8. The file walk enters excluded folders

`lib/ChangeTrack/Runner.pm:662-673`

- **What this is:** Internal exclusions (`output_dir`, the lock file, file-notifier logs) are checked per *file* inside `wanted`, after `find` has already gone into the folder.
- **Problem:** If a parent of `output_dir` is tracked (for example `DIRECTORY /var/lib`), every run walks every object under `output_dir/.git` and drops them one by one. Run time grows with history size.
- **Fix:** In the same prune block as finding 1, prune any directory where `_is_excluded_path` is true.
- **If we skip it:** Runs get slower over time. Results stay correct.

### 9. The mirror `.gitignore` is rewritten in place

`bin/changetrack-ng:301` (`_update_gitignore`, from line 281)

- **What this is:** `update-ignore` opens `output_dir/.gitignore` with `'>'` (truncate) and writes the new patterns.
- **Problem:** A crash, kill or full disk mid-write leaves the file empty or cut short. The next run then stages `*.swp`, `*~` and other files that should be ignored.
- **Fix:** Write to a sibling temp file and `rename`, the same pattern as `Metadata::save`.
- **If we skip it:** Junk files occasionally get committed into history.

---

## Left out (3 smaller items)

- `init_vcs` (`Runner.pm:921`) puts `_setup`'s second return value (the config) into a variable named `$md`. It is a misleading name only; it changes no behavior.
- RCS `revert` (`RCS.pm:155-158`) writes the RCS working file non-atomically. This is harmless, because `restore_mirror_path` then writes the live file atomically.
- `VCS::Base::_with_temp_mirror_sync` (`Base.pm:138`) does not restore its backup if `sync_mirror_path` dies partway. I could not build a case where this causes harm, so it is not a finding.

## Checked and fine

- `run_cmd` uses list-form `IPC::Open3` with no shell, redacts argv/stderr, and has a TERM-then-KILL watchdog.
- `Metadata::save` writes a temp file in the same directory, applies `chmod 0600`, checks `close`, then does `rename`.
- `Lock` uses `sysopen` with `O_NOFOLLOW` and mode `0600`.
- `VCS::Base::_mirror_rel` rejects `..` segments.
- RCS `output_path` percent-escapes `%` and `:` before mapping `/` to `:`, so `/a/b` and a file named `/a:b` cannot collide.
- Git `diff` compares against HEAD, so a commit that fails is found again on the next run. No change is lost.
- Email strips CR/LF from From/To/Subject, uses `--` before recipients, and passes `-oi`.
- Sensitive-diff suppression is applied in Email (`_diff_text_for`), Webhook, OTLP/File (`Notify/Base.pm:208`) and the console report (`Report.pm:205`).
- `cmd_revert` rejects revisions that start with `-` and asks y/N unless `--force` is given.
- `bin/changetrack-ng` sets `umask(0077)`.

## Verdict

Fix 1 and 3 first. Finding 1 silently records nothing on common etckeeper hosts. Finding 3 can stop all tracking on a host with no alert.

**Lean:** about -15 lines possible (finding 6). No dependencies to remove.

## Not checked

- `Config.pm` include and drop-in handling, and its path validation, were only skimmed.
- Fossil, SVN and Mercurial were only checked for the nested-repo point.
- Webhook/OTLP retry and TLS-bypass code was not reviewed.
- `tools/`, `packaging/`, systemd/cron/hook install scripts were not reviewed.
- The test suite was not run. The audit ran on Windows without a checked Perl/RCS toolchain. Only the Git behaviour in findings 1 and 2 was reproduced.
- `.gitattributes` effects in the mirror were not tested.

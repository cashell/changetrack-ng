<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
-->

# changetrack-ng — Implementation Guide & Fix Specifications (Hand-Off)

This document provides a comprehensive, actionable specification for addressing genuine issues identified during code review. It is structured for an Antigravity (or developer) instance running on Linux to implement, test, and verify using the native toolchain.

---

## 1. Architectural Invariants & Constraints

When implementing these fixes, preserve the following non-negotiable project guardrails:

1. **Zero non-core dependencies**: Only standard Perl core modules (Perl ≥ 5.20) may be used in `lib/`. (`JSON::PP`, `HTTP::Tiny`, `IO::Compress::Gzip`, `File::Find`, `File::Copy`, `POSIX`, `Fcntl`, etc., are all in core).
2. **Command execution security**: All subprocess invocations must route through `ChangeTrack::Util::run_cmd()` using list-form arguments (no shell strings or shell interpolation). Redact credentials in logs/exceptions.
3. **Deterministic ordering**: Always sort file paths, config sections, and recipient lists for reproducible commits and report output.
4. **Metadata atomicity**: Any state updates in `ChangeTrack::Metadata` must write through a tempfile with mode `0600` and atomically rename into place.
5. **No breaking changes**: Keep existing configuration syntax, command-line arguments, and notifier schemas backward-compatible.

---

## 2. Phase 1: Directory Deletion Detection & VCS Removal Propagation

### Problem 1A: Directory Deletions Are Undetected (CORR-3)
* **Locations**: `lib/ChangeTrack/Runner.pm` (`_build_file_list`, lines 551–601, and `run`, lines 291–315)
* **Root Cause**: For `DIRECTORY /path` entries in `[track]`, `_build_file_list` uses `File::Find::find()` on the filesystem. If `/path/sub/file.conf` is deleted from disk, `find()` never encounters it. The path is omitted from `@entries`, so `_process_file()` is never called for it. The deletion check at line 389 (`unless (-e $real_path || -l $real_path)`) is only reachable for explicit single-file track entries.
* **Solution**:
  1. In `_build_file_list()` (or a helper `_reconcile_directory_deletions()`), record the set of all live discovered file paths in a hash `%live_paths`. Also extract active `DIRECTORY` paths into an array `@active_dirs`.
  2. Iterate through all recorded paths in `$md->{records}`:
     ```perl
     for my $stored_path (sort keys %{ $md->{records} }) {
         next if $live_paths{$stored_path};     # Still on disk
         next if -e $stored_path || -l $stored_path; # Double check live state

         # Verify the missing path falls within an actively tracked directory
         my $matched_dir;
         for my $dir (@active_dirs) {
             my $prefix = $dir =~ m{/$} ? $dir : "$dir/";
             if (index($stored_path, $prefix) == 0) {
                 $matched_dir = $dir;
                 last;
             }
         }
         next unless $matched_dir;

         # Skip if the path now matches ignore patterns
         next if _should_ignore($stored_path, basename($stored_path), $compiled_ignore);

         # Enqueue for removal processing
         push @entries, {
             path       => $stored_path,
             sensitive  => $dir_opt_sensitive{$matched_dir},
             recipients => $dir_recipients{$matched_dir} // [],
         };
     }
     ```
  3. This ensures deleted files enter `_process_file()` normally, trigger `$report->add_removed()`, update `$md->mark_removed()`, and get removed from VCS.

---

### Problem 1B: VCS Repositories Never Reflect File Deletions (CORR-4)
* **Locations**:
  * `lib/ChangeTrack/VCS/Base.pm` (lines 27–30, 115–126)
  * `lib/ChangeTrack/VCS/Git.pm`
  * `lib/ChangeTrack/VCS/SVN.pm`
  * `lib/ChangeTrack/VCS/Mercurial.pm`
  * `lib/ChangeTrack/VCS/Fossil.pm`
  * `lib/ChangeTrack/VCS/RCS.pm`
  * `lib/ChangeTrack/Runner.pm` (lines 388–399)
* **Root Cause**: When a file is removed, `Runner::_process_file()` calls `$report->add_removed()` and `$md->mark_removed($real_path)`, but never deletes the mirror file under `output_dir` and never informs the VCS. None of the VCS backends implement a `remove()` or `delete()` method. Thus, whole-repo `commit()` stages nothing, leaving the deleted file committed at HEAD forever.
* **Specification for `VCS::Base::remove($real_path)`**:
  * Declare `sub remove { _unimpl(shift, 'remove') }` in `ChangeTrack::VCS::Base`.
  * **Git** (`ChangeTrack::VCS::Git`):
    ```perl
    sub remove {
        my ($self, $real_path) = @_;
        my $mirror = $self->output_path($real_path);
        my $rel    = $self->_rel_path($mirror);
        if (-e $mirror || -l $mirror) {
            unlink($mirror) or croak "unlink '$mirror' failed: $!";
        }
        # Only git rm if tracked in Git
        my $in_head = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'cat-file', '-e', "HEAD:$rel"]);
        if ($in_head->{success}) {
            my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rm', '-f', '--', $mirror]);
            croak "git rm failed for '$mirror': $r->{stderr}" unless $r->{success};
        }
    }
    ```
  * **SVN** (`ChangeTrack::VCS::SVN`):
    ```perl
    sub remove {
        my ($self, $real_path) = @_;
        my $mirror = $self->output_path($real_path);
        my $rel    = $self->_rel_path($mirror);
        # svn rm --force handles unversioned/modified working files safely
        my $st = $self->_run('svn', 'status', $rel);
        if ($st->{stdout} =~ /^[ MA]/m) {
            my $r = $self->_run('svn', 'rm', '--force', $rel);
            croak "svn rm failed for '$rel': $r->{stderr}" unless $r->{success};
        } elsif (-e $mirror || -l $mirror) {
            unlink($mirror) or croak "unlink '$mirror' failed: $!";
        }
    }
    ```
  * **Mercurial** (`ChangeTrack::VCS::Mercurial`):
    ```perl
    sub remove {
        my ($self, $real_path) = @_;
        my $mirror = $self->output_path($real_path);
        my $st = $self->_hg('status', $mirror);
        if ($st->{stdout} =~ /^[ MARC]/m) {
            my $r = $self->_hg('rm', '--force', $mirror);
            croak "hg rm failed for '$mirror': $r->{stderr}" unless $r->{success};
        } elsif (-e $mirror || -l $mirror) {
            unlink($mirror) or croak "unlink '$mirror' failed: $!";
        }
    }
    ```
  * **Fossil** (`ChangeTrack::VCS::Fossil`):
    ```perl
    sub remove {
        my ($self, $real_path) = @_;
        my $mirror = $self->output_path($real_path);
        my $rel    = $self->_rel_path($mirror);
        my $r = $self->_run('fossil', 'rm', '--', $rel);
        # fossil rm removes from repo and working tree; ignore error if not tracked
        if (-e $mirror || -l $mirror) {
            unlink($mirror) or croak "unlink '$mirror' failed: $!";
        }
    }
    ```
  * **RCS** (`ChangeTrack::VCS::RCS`):
    ```perl
    sub remove {
        my ($self, $real_path) = @_;
        my $op = $self->output_path($real_path);
        unlink($op) if -e $op || -l $op;
        # For RCS, leave the ,v file intact for revision history, or rename to ,v.bak if desired.
        # Unlinking the working mirror file ensures dirty/diff checks don't see stale content.
    }
    ```
  * **Runner invocation**:
    In `ChangeTrack::Runner::_process_file()`:
    ```perl
    # File no longer on disk
    unless (-e $real_path || -l $real_path) {
        if (defined $existing) {
            $report->add_removed(path => $real_path, recipients => $recipients);
            $md->mark_removed($real_path);
            eval { $vcs->remove($real_path) unless $self->{dry_run} };
            if ($@) {
                my $err = $@;
                $err =~ s/\n$//;
                $self->_warn("VCS remove failed for $real_path: $err");
                $report->add_warning("VCS remove failed for $real_path: $err");
            }
            $self->_debug("Removed: $real_path");
            $self->_info("Removed: $real_path");
        } else {
            $self->_trace("$real_path: not on disk, no prior record");
        }
        return;
    }
    ```

---

## 3. Phase 2: File Type Transitions & Metadata Safety (CORR-5)

### Problem 2A: Non-Trackable to Trackable Transitions
* **Location**: `lib/ChangeTrack/Runner.pm` (lines 485–540)
* **Root Cause**: Files initially classified as `special` (device/FIFO), `binary`, or `unreadable` were recorded in metadata (`$md->{records}`), but skipped VCS checkin. When they later become readable text files:
  * Line 499: `if (!defined $existing)` is false.
  * It falls into the `else` branch, treating the file as an existing VCS-tracked file.
  * It invokes `$vcs->diff($real_path)`. Since the file is untracked in Git, `git diff HEAD` returns empty.
  * If mode/owner didn't change, `meta_changed = 0`, `diff = []`, so Runner treats it as unchanged and never checks it in!
* **Solution**:
  Compute `$is_tracked_in_vcs`:
  ```perl
  my $prev_vcs_eligible = ($prev_type eq 'file' || $prev_type eq 'symlink' || $prev_type eq 'empty');
  if (!defined $existing || !$prev_vcs_eligible) {
      # Treat as NEW file for VCS and Report
      $vcs->checkin($real_path, $commit_msg) unless $self->{dry_run};
      $report->add_change(
          path         => $real_path,
          is_new       => 1,
          is_sensitive => $is_sensitive,
          diff         => ($type eq 'empty' ? ['(new empty file)'] : ['(new file)']),
          meta_change  => ($existing ? "transition from $prev_type to $type" : ''),
          recipients   => $recipients,
          stat         => $rec,
      );
      ...
  } else {
      # Normal existing file change/diff processing
  }
  ```

---

### Problem 2B: Unsafe Skip Checks & Incomplete Type Change Reporting
* **Location**: `lib/ChangeTrack/Metadata.pm` (`can_skip_content_diff`, `changed_since_load`, `diff_summary`)
* **Root Cause**:
  1. `can_skip_content_diff()` line 225 has `return 1 if $otype eq 'special' || $otype eq 'directory';` without verifying whether the file on disk is still a special file or directory. If a FIFO was replaced by a text file, `can_skip_content_diff` returns 1!
  2. `changed_since_load()` only checks `mode`, `uid`, `gid`, and `target` (if symlink). It does NOT check if `type` changed (e.g. from `file` to `symlink` or `symlink` to `file`).
  3. `diff_summary()` only reports target change if `defined $orig->{target}`. If a regular file became a symlink, `$orig->{target}` was `undef`, so the summary omitted the target and type change.
* **Solution**:
  1. In `can_skip_content_diff($path)`:
     ```perl
     my @s = lstat($path);
     return 0 unless @s;
     my $cur_type = (-l _) ? 'symlink' : (-d _) ? 'directory' : (!-f _) ? 'special' : ($s[7] == 0) ? 'empty' : (-B $path) ? 'binary' : 'file';
     return 0 if $cur_type ne $otype;  # Type changed -> NEVER skip content diff
     ```
  2. In `changed_since_load($path)`:
     ```perl
     # Detect file type change (e.g. symlink replaced by file or vice versa)
     my $cur_type = (-l _) ? 'symlink' : (-d _) ? 'directory' : (-f _) ? 'file' : 'special';
     return 1 if $cur_type ne ($orig->{type} // '');
     ```
  3. In `diff_summary($path)`:
     ```perl
     if ($cur_type ne ($orig->{type} // '')) {
         push @parts, "type $orig->{type} -> $cur_type";
     }
     if (-l _ && ($cur_type eq 'symlink')) {
         my $new_tgt = readlink($path) // '';
         my $old_tgt = $orig->{target} // '(none)';
         if ($new_tgt ne ($orig->{target} // '')) {
             push @parts, "target $old_tgt -> $new_tgt";
         }
     }
     ```

---

## 4. Phase 3: CLI Subcommand Flags & Drop-in Security (OPS-5, SEC-5)

### Problem 3A: Debug & Trace Dropped in Subcommands
* **Location**: `bin/changetrack-ng` (lines 74–76, 164–253)
* **Root Cause**: `cmd_status`, `cmd_diff`, `cmd_log`, and `cmd_revert` construct `ChangeTrack::Runner->new` with only `config`, `quiet`, and `verbose`. They do not pass `debug` or `trace`. Furthermore, `ChangeTrack::Util::set_debug(1)` is only called inside `Runner::run()`.
* **Solution**:
  1. In `bin/changetrack-ng`, call `ChangeTrack::Util::set_debug(1)` immediately after option parsing when `$opts{debug}` is set.
  2. In `cmd_status`, `cmd_diff`, `cmd_log`, `cmd_revert`, pass `debug => $opts{debug}, trace => $opts{trace}` into `ChangeTrack::Runner->new`.

---

### Problem 3B: Insecure Permission Warnings Ignore Drop-ins
* **Location**: `lib/ChangeTrack/Runner.pm` (`_warn_insecure_config_permissions`, lines 1002–1041)
* **Root Cause**: Only `$self->{config_path}` is checked for `0004` permissions. If secrets are in `notifier.d/webhook.conf` or included files, world-readability on those files is never detected.
* **Solution**:
  1. In `ChangeTrack::Config`, record each loaded file path in `$self->{_loaded_files}`.
  2. In `_warn_insecure_config_permissions`, iterate over all loaded config files that contain notifier declarations or environment secret expansions, and inspect the file mode of each individual file.

---

## 5. Phase 4: Test Suite Hygiene & Cleanup

### Problem 4A: Missing Symlink Capability Probe (TEST-12)
* **Location**: `t/03-metadata.t` (line 212)
* **Root Cause**: Calls `symlink()` unconditionally. On environments lacking symlink creation rights, the test suite aborts with an unhandled exception.
* **Solution**: Wrap in `SKIP: { ... }` with:
  ```perl
  my $can_symlink = eval { symlink('', ''); 1 };
  skip 'symlink creation not available on this platform/user', 7 unless $can_symlink;
  ```

---

### Problem 4B: Gunzip Typo Warning (TEST-13)
* **Location**: `t/19-notify-otlp.t` (lines 119–122)
* **Root Cause**: `require IO::Compress::Gunzip;` and `$IO::Compress::Gunzip::GunzipError`.
* **Solution**: Change to `require IO::Uncompress::Gunzip;` and `$IO::Uncompress::Gunzip::GunzipError`.

---

## 6. Verification & Test Plan

On the Linux test machine, run:

```bash
# 1. Verify basic syntax & compilation
perl -c bin/changetrack-ng
perl -Ilib -MChangeTrack::Runner -e 1

# 2. Run targeted tests for each modified component
prove -l t/03-metadata.t
prove -l t/06-vcs-git.t
prove -l t/19-notify-otlp.t
prove -l t/21-report.t
prove -l t/22-verbose-debug.t

# 3. Add new unit & integration test files
#    - t/35-vcs-removal.t (verifies directory deletion reconciliation & VCS rm)
#    - t/36-type-transitions.t (verifies file <-> symlink, binary -> text)

# 4. Run documentation and configuration linters
make config-lint
make doc-lint

# 5. Full test suite
make test
```

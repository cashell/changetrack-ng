<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
-->

# changetrack-ng — Implementation Guide & Fix Specifications (Hand-Off)

> [!NOTE]
> **HISTORICAL ARCHIVE:** This specification was prepared as a task hand-off for
> addressing code review findings (CORR-3, CORR-4, CORR-5, SEC-5, OPS-5). All items were
> implemented, verified in test suites (`t/35-vcs-removal.t`, `t/36-type-transitions.t`),
> and closed in `TODO.md` on 2026-09-18.

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
* **Locations**: `lib/ChangeTrack/Runner.pm` (`_build_file_list`, lines 556–618, and `run`, lines 291–315)
* **Root Cause**: For `DIRECTORY /path` entries in `[track]`, `_build_file_list` uses `File::Find::find()` on the filesystem. If `/path/sub/file.conf` is deleted from disk, `find()` never encounters it. The path is omitted from `@entries`, so `_process_file()` is never called for it. The deletion check at line 389 (`unless (-e $real_path || -l $real_path)`) is only reachable for explicit single-file track entries.
* **Solution**:
  1. Pass the loaded `$md` object to `_build_file_list($tracks, $compiled_ignore, $exclude_paths, $md)` from `Runner::run()`.
  2. Inside `_build_file_list()`, record directory configurations into a lookup hash `%dir_opts` and track all discovered on-disk paths in `%live_paths`:
     ```perl
     my %live_paths;
     my %dir_opts; # $dir => { sensitive => $opt_sensitive, recipients => $recips }
     ```
     When processing `$track->{kind} eq 'directory'`:
     ```perl
     my $dir = $track->{path};
     $dir_opts{$dir} = {
         sensitive  => $opt_sensitive,
         recipients => $recips,
     };
     ```
     And inside the `File::Find::find()` `wanted` callback, record `$live_paths{$p} = 1;`.
  3. Reconcile deleted paths against `$md->{records}`:
     ```perl
     if ($md && $md->{records}) {
         for my $stored_path (sort keys %{ $md->{records} }) {
             next if $live_paths{$stored_path};             # Still on disk
             next if -e $stored_path || -l $stored_path;     # Double check live state

             # Verify the missing path falls within an actively tracked directory
             my $matched_dir;
             for my $dir (sort keys %dir_opts) {
                 my $prefix = $dir =~ m{/$} ? $dir : "$dir/";
                 if (index($stored_path, $prefix) == 0) {
                     $matched_dir = $dir;
                     last;
                 }
             }
             next unless $matched_dir;

             # Skip if the path now matches ignore or exclude patterns
             next if _should_ignore($stored_path, basename($stored_path), $ignore_pats);
             next if _is_excluded_path($stored_path, $exclude_paths);

             # Enqueue for removal processing
             push @entries, {
                 path       => $stored_path,
                 sensitive  => $dir_opts{$matched_dir}{sensitive},
                 recipients => $dir_opts{$matched_dir}{recipients},
             };
         }
     }
     ```
  4. **Whole-directory deletion handling**: If an entire tracked directory is deleted from disk, `next unless -d $dir;` (line 577) skips `find()`. None of the files under it are added to `%live_paths`, so the reconciliation loop matches all previously recorded files under that directory prefix and enqueues them for removal automatically without requiring specialized handling.

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
  * In `ChangeTrack::VCS::Base`:
    * Add `remove` to the POD interface list.
    * Declare `sub remove { _unimpl(shift, 'remove') }`.
  * **Git** (`ChangeTrack::VCS::Git`):
    Use repository-relative path `$rel` consistently for `cat-file` and `git rm`:
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
            my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rm', '-f', '--', $rel]);
            croak "git rm failed for '$rel': $r->{stderr}" unless $r->{success};
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
        # For RCS, leave the ,v archive file intact to preserve history.
        # Unlinking the working mirror file ensures dirty/diff checks don't see stale content.
    }
    ```
  * **Runner invocation & logging**:
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
            # _info prints user-visible output to STDOUT (suppressed by --quiet);
            # _debug prints diagnostics to STDERR (when --debug is active).
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

### Problem 2A: Non-Trackable / Trackable Transitions (Bidirectional)
* **Location**: `lib/ChangeTrack/Runner.pm` (lines 418–540)
* **Root Cause**:
  1. **Non-trackable → Trackable**: Files initially classified as `special` (device/FIFO), `binary`, or `unreadable` were recorded in metadata (`$md->{records}`), but skipped VCS checkin. When they later become readable text files:
     * Line 499: `if (!defined $existing)` is false.
     * It falls into the `else` branch, treating the file as an existing VCS-tracked file.
     * It invokes `$vcs->diff($real_path)`. Since the file is untracked in Git, `git diff HEAD` returns empty.
     * If mode/owner didn't change, `meta_changed = 0`, `diff = []`, so Runner treats it as unchanged and never checks it in.
  2. **Trackable → Non-trackable (Reverse Transition Gap)**: If a previously tracked file (`file`, `symlink`, or `empty`) is replaced on disk by a FIFO, socket, device, or binary file, the early-return branches for `special`, `unreadable`, or `binary` (lines 418–446) fire. The old file is left committed in the VCS mirror at HEAD indefinitely, and no VCS removal or transition change is recorded.
* **Solution**:
  1. Define explicit tracking state variables in `_process_file()`:
     ```perl
     my $existing          = $md->record_for($real_path);
     my $prev_type         = defined($existing) ? ($existing->{type} // '') : '';
     my $prev_vcs_eligible = ($prev_type eq 'file' || $prev_type eq 'symlink' || $prev_type eq 'empty');
     ```
  2. **Handle Non-trackable → Trackable (`special`/`binary`/`unreadable` → `file`/`symlink`/`empty`)**:
     ```perl
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
         $self->_debug("New: $real_path (type=$type, mode=" . ($rec->{mode} // '?') . ")");
         $self->_info("New: $real_path");
     } else {
         # Normal existing file change/diff processing
     }
     ```
  3. **Handle Trackable → Non-trackable (`file`/`symlink`/`empty` → `special`/`binary`/`unreadable`)**:
     In the early-return blocks for `special`, `unreadable`, and `binary`, if `$prev_vcs_eligible` is true, invoke `$vcs->remove()` and record the transition:
     ```perl
     if ($prev_vcs_eligible) {
         eval { $vcs->remove($real_path) unless $self->{dry_run} };
         if ($@) {
             my $err = $@;
             $err =~ s/\n$//;
             $self->_warn("VCS remove failed for $real_path: $err");
             $report->add_warning("VCS remove failed for $real_path: $err");
         }
         $report->add_change(
             path         => $real_path,
             is_new       => 0,
             is_removed   => 1,
             is_sensitive => 0,
             diff         => [],
             meta_change  => "transition from $prev_type to $type (removed from VCS)",
             recipients   => $recipients,
             stat         => $rec,
         );
         $self->_debug("Transitioned to non-trackable ($type), removed from VCS: $real_path");
         $self->_info("Removed from VCS (became $type): $real_path");
     }
     ```

---

### Problem 2B: Unsafe Skip Checks & Incomplete Type Change Reporting
* **Location**: `lib/ChangeTrack/Metadata.pm` (`can_skip_content_diff`, `changed_since_load`, `diff_summary`)
* **Root Cause**:
  1. `can_skip_content_diff()` line 225 has `return 1 if $otype eq 'special' || $otype eq 'directory';` without verifying whether the file on disk is still a special file or directory. If a FIFO was replaced by a text file, `can_skip_content_diff` returns 1.
  2. `changed_since_load()` only checks `mode`, `uid`, `gid`, and `target` (if symlink). It does NOT check if `type` changed (e.g. from `file` to `symlink` or `symlink` to `file`).
  3. `diff_summary()` only reports target change if `defined $orig->{target}`. If a regular file became a symlink, `$orig->{target}` was `undef`, so the summary omitted the target and type change.
* **Solution**:
  1. In `ChangeTrack::Metadata`, introduce a shared file classification helper so that `update_from_stat`, `can_skip_content_diff`, `changed_since_load`, and `diff_summary` share identical classification rules:
     ```perl
     sub _classify_file {
         my ($path, $stat_ref) = @_;
         return 'missing' unless $stat_ref && @$stat_ref;
         if    (-l _)          { return 'symlink'; }
         elsif (-d _)          { return 'directory'; }
         elsif (!-f _)         { return 'special'; }
         elsif (!-r $path)     { return 'unreadable'; }
         elsif ($stat_ref->[7] == 0) { return 'empty'; }
         elsif (-B $path)      { return 'binary'; }
         else                  { return 'file'; }
     }
     ```
  2. In `can_skip_content_diff($path)`, verify the live file type before any type-based early returns:
     ```perl
     my @s = lstat($path);
     return 0 unless @s;
     my $cur_type = _classify_file($path, \@s);
     return 0 if $cur_type ne $otype;  # Type changed -> NEVER skip content diff

     # Insert before existing special/directory check:
     return 1 if $otype eq 'special' || $otype eq 'directory';
     ```
  3. In `changed_since_load($path)`:
     ```perl
     my @s = lstat($path);
     return 1 unless @s;                  # vanished since last run

     my $cur_type = _classify_file($path, \@s);
     return 1 if $cur_type ne ($orig->{type} // '');
     ```
  4. In `diff_summary($path)`:
     Compute `$cur_type = _classify_file($path, \@s)` at the top of the method.
     Add type change reporting, and **replace** (not supplement) the existing `target` check block to avoid duplicate reporting:
     ```perl
     if ($cur_type ne ($orig->{type} // '')) {
         push @parts, "type " . ($orig->{type} // '(unknown)') . " -> $cur_type";
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
* **Location**: `bin/changetrack-ng` (lines 74–76, 164–253) and `lib/ChangeTrack/Runner.pm` (lines 139–144, 174)
* **Root Cause**: `cmd_status`, `cmd_diff`, `cmd_log`, and `cmd_revert` construct `ChangeTrack::Runner->new` with only `config`, `quiet`, and `verbose`. They do not pass `debug` or `trace`. Furthermore, `ChangeTrack::Util::set_debug(1)` is only called inside `Runner::run()` (line 174), which subcommands never invoke. (Note: `Runner::new()` lines 139–144 already enforces the implication chain `trace -> debug -> verbose`, but does not activate `set_debug(1)`).
* **Solution**:
  1. In `bin/changetrack-ng`, call `ChangeTrack::Util::set_debug(1)` immediately after option parsing when `$opts{debug}` is set.
  2. In `lib/ChangeTrack/Runner.pm`, also call `set_debug(1) if $self->{debug};` in `Runner::new()` so that any programmatic instantiation of `Runner` or method invocation outside `run()` (such as `status()`, `diff_path()`, `log_path()`, `revert_path()`) automatically activates debug logging in `ChangeTrack::Util::run_cmd()`.
  3. In `cmd_status`, `cmd_diff`, `cmd_log`, and `cmd_revert`, pass `debug => $opts{debug}, trace => $opts{trace}` into `ChangeTrack::Runner->new`.

---

### Problem 3B: Insecure Permission Warnings Ignore Drop-ins
* **Location**: `lib/ChangeTrack/Config.pm` and `lib/ChangeTrack/Runner.pm` (`_warn_insecure_config_permissions`, lines 1002–1041)
* **Root Cause**: Only `$self->{config_path}` is checked for `0004` permissions. If secrets are in `notifier.d/webhook.conf` or other drop-in files, world-readability on those files is never detected. Additionally, `ChangeTrack::Config` loads drop-in files via `_load_drop_ins()` but does not record which files were loaded.
* **Solution**:
  1. In `ChangeTrack::Config`:
     - In `_load_file()`, record every loaded file's absolute path in `$self->{_loaded_files}`:
       ```perl
       push @{ $self->{_loaded_files} ||= [] }, $abs;
       ```
     - Provide a public accessor method `loaded_files()`:
       ```perl
       sub loaded_files {
           my ($self) = @_;
           return wantarray ? @{ $self->{_loaded_files} // [] } : [ @{ $self->{_loaded_files} // [] } ];
       }
       ```
  2. In `lib/ChangeTrack/Runner.pm` (`_warn_insecure_config_permissions`):
     - **Broader scope check**: When the overall configuration contains notifier secrets (webhook URLs or OTLP headers), check **all** loaded config files (from `$cfg->loaded_files()`, falling back to `$path`), rather than attempting complex per-file AST provenance tracking. Any world-readable file in a secret-bearing configuration represents an insecure posture.
     - Inspect `$mode & 0004` on each file and warn if any config file in the loaded set is world-readable:
       ```perl
       sub _warn_insecure_config_permissions {
           my ($self, $cfg, $path) = @_;
           return unless defined $cfg;

           # Evaluate if secrets exist anywhere in the configuration
           my $all = $cfg->notifiers;
           my $has_secret = 0;
           for my $inst (@{ $all->{otlp} // [] }) {
               my $h = $inst->{headers} // '';
               $has_secret = 1 if !ref($h) && $h =~ /\S/;
               last if $has_secret;
           }
           unless ($has_secret) {
               for my $inst (@{ $all->{webhook} // [] }) {
                   my $u = $inst->{url};
                   if (ref $u eq 'ARRAY') {
                       $has_secret = 1 if grep { defined $_ && /\S/ } @$u;
                   } elsif (defined $u && !ref $u && $u =~ /\S/) {
                       $has_secret = 1;
                   }
                   last if $has_secret;
               }
           }
           return unless $has_secret;

           my @files = $cfg->can('loaded_files') ? $cfg->loaded_files : ();
           push @files, $path if defined $path && !grep { $_ eq $path } @files;

           for my $f (@files) {
               next unless defined $f && -e $f;
               my @st = stat($f);
               next unless @st;
               my $mode = $st[2] & 07777;
               if ($mode & 0004) { # world-readable
                   $self->_warn(sprintf(
                       'config %s is world-readable (%04o) and contains notifier secrets; set mode 0640 or stricter',
                       $f, $mode,
                   ));
               }
           }
       }
       ```

---

## 5. Phase 4: Test Suite Hygiene & Cleanup

### Problem 4A: Missing Symlink Capability Probe (TEST-12)
* **Location**: `t/03-metadata.t` (line 212) and `t/16-subcommands.t` (line 298)
* **Root Cause**: Calls `symlink()` unconditionally with `die` on failure. On environments lacking symlink creation rights (or restricted filesystems), the test suite aborts with an unhandled exception.
* **Solution**:
  1. In `t/03-metadata.t`, wrap the symlink lifecycle test block in `SKIP: { ... }`:
     ```perl
     SKIP: {
         my $can_symlink = eval { symlink('', ''); 1 };
         skip 'symlink creation not available on this platform/user', 6 unless $can_symlink;
         ...
     }
     ```
  2. In `t/16-subcommands.t`, wrap the symlink CLI revert test block (lines 285–316) in `SKIP: { ... }`:
     ```perl
     SKIP: {
         my $can_symlink = eval { symlink('', ''); 1 };
         skip 'symlink creation not available on this platform/user', 3 unless $can_symlink;
         ...
     }
     ```

---

### Problem 4B: Gunzip Typo Warning (TEST-13)
* **Location**: `t/19-notify-otlp.t` (lines 119–122)
* **Root Cause**: Test helper `read_json` uses `require IO::Compress::Gunzip;` and `$IO::Compress::Gunzip::GunzipError`. The module does not exist in Perl core (compression is `IO::Compress::Gzip`; decompression is `IO::Uncompress::Gunzip`). Under `eval`, the require failed silently, leaving compressed payloads undecoded and emitting a `possible typo` warning.
* **Solution**: Change to `require IO::Uncompress::Gunzip;` and `IO::Uncompress::Gunzip::gunzip(\$data, \$out) or die $IO::Uncompress::Gunzip::GunzipError;`.

---

## 6. Verification & Test Plan

On the Linux test machine, run:

```bash
# 1. Verify basic syntax & compilation
perl -c bin/changetrack-ng
perl -Ilib -MChangeTrack::Runner -e 1
perl -Ilib -MChangeTrack::Config -e 1
perl -Ilib -MChangeTrack::Metadata -e 1

# 2. Run targeted tests for each modified component
prove -l t/03-metadata.t
prove -l t/06-vcs-git.t
prove -l t/16-subcommands.t
prove -l t/18-integration-notifiers.t
prove -l t/19-notify-otlp.t
prove -l t/21-report.t
prove -l t/22-verbose-debug.t

# 3. Add new unit & integration test files
#    - t/35-vcs-removal.t (verifies directory deletion reconciliation & VCS rm across backends)
#    - t/36-type-transitions.t (verifies bidirectional file <-> symlink, special/binary <-> text)

# 4. Run documentation and configuration linters
make config-lint
make doc-lint

# 5. Full test suite
make test
```

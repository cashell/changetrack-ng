# Configurable Diff Truncation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-file `max_diff_bytes` config option (default `0` = unlimited) to both the OTLP and File notifiers. When a diff exceeds the cap it is truncated with a marker, and the record is flagged `config_change.diff_truncated`. Full diffs remain the default.

**Architecture:** A single shared helper `_truncate_diff` on `Notify/Base.pm` applies the cap and returns `($text, $was_truncated)`. Both notifiers call it at the point they already build the diff string. The cap is applied by character length (equal to bytes for single-byte/ASCII config content) and never splits a multibyte character.

**Tech Stack:** Perl 5.20+, core only. No new dependencies.

**Dependencies:** `2026-06-23-otel-attribute-model.md` (OTLP `config_change.diff` emission) AND `2026-06-23-file-notifier-otel-reshape.md` (File `config_change.diff` emission). Apply after both.

## Decisions

- **Default `0` = unlimited.** Full diffs are preserved unless an operator opts into a cap. `full_diff` (the on/off switch for emitting diffs at all) is unchanged and orthogonal.
- **Character-based cap.** `max_diff_bytes` caps the diff string length; for ASCII/single-byte config content this equals bytes. Truncation uses `substr`, which never splits a multibyte character. Documented as such — we do not split octets.
- **Marker present only when truncated.** `config_change.diff_truncated` is emitted (true) only when truncation occurred; its absence means the diff is complete. Keeps records lean.
- **Sensitive suppression wins.** Suppressed diffs (sensitive file, `sensitive_notify=suppress`) are replaced by a short placeholder *before* any truncation consideration and are never truncated.

## Global Constraints

- **Perl 5.20+, zero non-core dependencies.** Core only. No CPAN.
- **changetrack-ng is a SysAdmin config-change tracking tool, NOT a security/HIDS tool.** No hashes, no actor/detection fields.
- **OTel output is not yet deployed** — format changes are NOT breaking. Update affected tests in the same task.
- **Preserve sensitive-file diff suppression** (`sensitive_notify`, `_diff_text_for`, `_sensitive_notify_allowed`). Truncation must never expose suppressed content.
- **Never expose sensitive data** in logs/notifications/errors.
- **Test runner:** `prove -lv t/NN-name.t` from project root. `Test::More` + `done_testing()`.

### Canonical names used here

| Key | Type | Meaning |
|---|---|---|
| `max_diff_bytes` (config) | integer | per-file diff cap; `0` = unlimited (default) |
| `config_change.diff` | string (OTLP `stringValue` / File string) | the (possibly truncated) diff |
| `config_change.diff_truncated` | bool | present & true only when the diff was truncated |

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `lib/ChangeTrack/Notify/Base.pm` | `_truncate_diff` shared helper |
| Modify | `lib/ChangeTrack/Notify/OTLP.pm` (`new`, `config_keys`, diff emission) | Apply cap + marker |
| Modify | `lib/ChangeTrack/Notify/File.pm` (`new`, `config_keys`, diff emission) | Apply cap + marker |
| Test | `t/19-notify-otlp.t` | OTLP truncation + marker + default unlimited |
| Test | `t/09-notify-file.t` | File truncation + marker + default unlimited |

---

## Task 1: Shared `_truncate_diff` helper on Base

**Files:**
- Modify: `lib/ChangeTrack/Notify/Base.pm`
- Test: `t/19-notify-otlp.t` (helper exercised indirectly in Task 2; a direct unit check goes here)

**Interfaces:**
- Consumes: `$self->{max_diff_bytes}` (integer or undef).
- Produces: `($text, $truncated) = $self->_truncate_diff($diff_string)`. When `max_diff_bytes` is falsy/0 or the text is within the cap, returns `($diff_string, 0)`. Otherwise returns the first `max_diff_bytes` characters plus a marker line, and `1`.

- [ ] **Step 1: Write the failing test**

Append to `t/19-notify-otlp.t` before `done_testing()`:

```perl
########################################################################
# _truncate_diff Helper
########################################################################
{
    my $n = ChangeTrack::Notify::OTLP->new(max_diff_bytes => 0);
    my ($t, $tr) = $n->_truncate_diff('a' x 100);
    is(length($t), 100, 'unlimited (0): text unchanged');
    ok(!$tr,                'unlimited (0): not flagged truncated');

    my $n2 = ChangeTrack::Notify::OTLP->new(max_diff_bytes => 10);
    my ($t2, $tr2) = $n2->_truncate_diff('a' x 100);
    ok($tr2,                          'cap 10: flagged truncated');
    like($t2, qr/^a{10}\n\[diff truncated/, 'cap 10: keeps first 10 chars + marker');

    my ($t3, $tr3) = $n2->_truncate_diff('short');
    is($t3, 'short', 'under cap: unchanged');
    ok(!$tr3,        'under cap: not flagged');
}
```

- [ ] **Step 2: Run to verify failure**

Run: `prove -lv t/19-notify-otlp.t`
Expected: FAIL — `Can't locate object method "_truncate_diff"`.

- [ ] **Step 3: Implement the helper in Base.pm**

In `lib/ChangeTrack/Notify/Base.pm`, add before the final `1;`:

```perl
# _truncate_diff -- Cap a diff string at max_diff_bytes characters.
# Returns ($text, $was_truncated).  max_diff_bytes of 0 (or unset) means
# unlimited.  substr never splits a multibyte character.
sub _truncate_diff {
    my ($self, $text) = @_;
    my $limit = $self->{max_diff_bytes} // 0;
    return ($text, 0) unless $limit && $limit > 0;
    return ($text, 0) if length($text) <= $limit;
    my $cut = substr($text, 0, $limit);
    return ($cut . "\n[diff truncated -- exceeded max_diff_bytes ($limit)]", 1);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `prove -lv t/19-notify-otlp.t`
Expected: PASS (the helper block; other blocks unaffected).

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Notify/Base.pm t/19-notify-otlp.t
git commit -m "feat(notify): add shared _truncate_diff helper"
```

---

## Task 2: Apply cap + marker in the OTLP notifier

**Files:**
- Modify: `lib/ChangeTrack/Notify/OTLP.pm` (`new`, `config_keys`, the `config_change.diff` emission in `_build_payload`)
- Test: `t/19-notify-otlp.t`

**Interfaces:**
- Consumes: `_truncate_diff` from Task 1.
- Produces: `config_change.diff` carries the truncated text when capped; `config_change.diff_truncated` (boolValue true) is added only when truncation occurred. New config key `max_diff_bytes` (default 0).

- [ ] **Step 1: Write the failing test**

Append to `t/19-notify-otlp.t` before `done_testing()`:

```perl
########################################################################
# OTLP Diff Truncation
########################################################################
{
    delete local $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
    delete local $ENV{OTEL_EXPORTER_OTLP_LOGS_ENDPOINT};

    my $big = join("\n", map { "+line $_ padding padding" } 1..200);

    # default (0): not truncated, no marker
    {
        my $bf = File::Spec->catfile($tmpdir, 'notrunc.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/big.conf', diff => [split /\n/, $big]);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(endpoint => "http://127.0.0.1:$port/v1/logs")->send($r);
        waitpid($pid, 0);
        my %a = map { $_->{key} => $_->{value} }
            @{ read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0]{attributes} };
        ok(!exists $a{'config_change.diff_truncated'}, 'default: no truncation marker');
        is(length($a{'config_change.diff'}{stringValue}), length($big), 'default: full diff');
    }

    # cap 50: truncated + marker
    {
        my $bf = File::Spec->catfile($tmpdir, 'trunc.json');
        my ($port, $pid) = start_server(codes => [200], body_file => $bf);
        my $r = ChangeTrack::Report->new(start_time => 1_000_000_000);
        $r->add_change(path => '/etc/big.conf', diff => [split /\n/, $big]);
        $r->set_end_time(1_000_000_001);
        ChangeTrack::Notify::OTLP->new(
            endpoint => "http://127.0.0.1:$port/v1/logs", max_diff_bytes => 50)->send($r);
        waitpid($pid, 0);
        my %a = map { $_->{key} => $_->{value} }
            @{ read_payload($bf)->{resourceLogs}[0]{scopeLogs}[0]{logRecords}[0]{attributes} };
        ok($a{'config_change.diff_truncated'}{boolValue}, 'cap: truncation marker true');
        like($a{'config_change.diff'}{stringValue}, qr/diff truncated/, 'cap: marker text in diff');
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `prove -lv t/19-notify-otlp.t`
Expected: FAIL — diff is full-length even with `max_diff_bytes => 50`; no marker.

- [ ] **Step 3: Implement in OTLP.pm**

In `new`, add the default (next to the other `//=` defaults):

```perl
    $self->{max_diff_bytes}      //= 0;
```

Replace `config_keys` with (adding `max_diff_bytes`):

```perl
sub config_keys { qw(endpoint headers compression full_diff heartbeat timeout insecure resource_attributes emit_recipients max_diff_bytes) }
```

In `_build_payload`, replace the `config_change.diff` emission block (introduced by the attribute-model plan):

```perl
            if ($self->{full_diff}) {
                unless ($c->{is_sensitive} && !$self->_sensitive_notify_allowed) {
                    push @attrs, {
                        key   => 'config_change.diff',
                        value => { stringValue => join("\n", @{ $c->{diff} // [] }) },
                    };
                }
            }
```

with:

```perl
            if ($self->{full_diff}) {
                unless ($c->{is_sensitive} && !$self->_sensitive_notify_allowed) {
                    my ($diff_text, $truncated)
                        = $self->_truncate_diff(join("\n", @{ $c->{diff} // [] }));
                    push @attrs, {
                        key   => 'config_change.diff',
                        value => { stringValue => $diff_text },
                    };
                    push @attrs, {
                        key   => 'config_change.diff_truncated',
                        value => { boolValue => JSON::PP::true() },
                    } if $truncated;
                }
            }
```

- [ ] **Step 4: Run to verify pass**

Run: `prove -lv t/19-notify-otlp.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Notify/OTLP.pm t/19-notify-otlp.t
git commit -m "feat(otlp): configurable max_diff_bytes with diff_truncated marker"
```

---

## Task 3: Apply cap + marker in the File notifier

**Files:**
- Modify: `lib/ChangeTrack/Notify/File.pm` (`new`, `config_keys`, the `config_change.diff` emission in `_build_records`)
- Test: `t/09-notify-file.t`

**Interfaces:**
- Consumes: `_truncate_diff` from Task 1; `_diff_text_for` (sensitive handling) unchanged.
- Produces: `attributes.config_change.diff` truncated when capped; `attributes.config_change.diff_truncated` (JSON true) only when truncated. New config key `max_diff_bytes` (default 0).

- [ ] **Step 1: Write the failing test**

Append to `t/09-notify-file.t` before `done_testing()`:

```perl
########################################################################
# File Diff Truncation
########################################################################
{
    my $big = join("\n", map { "+line $_ padding" } 1..200);

    # default: full diff, no marker
    my $log1 = "$dir/notrunc.log";
    my $r1 = ChangeTrack::Report->new(start_time => 1000000000);
    $r1->add_change(path => '/etc/big.conf', diff => [split /\n/, $big]);
    ChangeTrack::Notify::File->new(path => $log1)->send($r1);
    my $rec1 = last_record($log1);
    ok(!exists $rec1->{attributes}{'config_change.diff_truncated'}, 'default: no marker');
    is(length($rec1->{attributes}{'config_change.diff'}), length($big), 'default: full diff');

    # cap 50: truncated + marker
    my $log2 = "$dir/trunc.log";
    my $r2 = ChangeTrack::Report->new(start_time => 1000000000);
    $r2->add_change(path => '/etc/big.conf', diff => [split /\n/, $big]);
    ChangeTrack::Notify::File->new(path => $log2, max_diff_bytes => 50)->send($r2);
    my $rec2 = last_record($log2);
    ok($rec2->{attributes}{'config_change.diff_truncated'}, 'cap: marker true');
    like($rec2->{attributes}{'config_change.diff'}, qr/diff truncated/, 'cap: marker text in diff');
}
```

- [ ] **Step 2: Run to verify failure**

Run: `prove -lv t/09-notify-file.t`
Expected: FAIL — diff full-length, no marker.

- [ ] **Step 3: Implement in File.pm**

In `new`, add:

```perl
    $self->{max_diff_bytes}   //= 0;
```

Replace `config_keys` with:

```perl
sub config_keys { qw(path heartbeat full_diff emit_recipients max_diff_bytes) }
```

In `_build_records`, replace the diff emission:

```perl
        if ($self->{full_diff}) {
            $attrs{'config_change.diff'} = join("\n", $self->_diff_text_for($c));
        }
```

with:

```perl
        if ($self->{full_diff}) {
            my ($diff_text, $truncated)
                = $self->_truncate_diff(join("\n", $self->_diff_text_for($c)));
            $attrs{'config_change.diff'} = $diff_text;
            $attrs{'config_change.diff_truncated'} = JSON::PP::true() if $truncated;
        }
```

- [ ] **Step 4: Run to verify pass**

Run: `prove -lv t/09-notify-file.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ChangeTrack/Notify/File.pm t/09-notify-file.t
git commit -m "feat(file): configurable max_diff_bytes with diff_truncated marker"
```

---

## Self-Review

- **Spec coverage:** F6 (configurable `max_diff_bytes`, default 0=unlimited, `full_diff` preserved, `config_change.diff_truncated` marker, per-file cap, both notifiers) — Tasks 1-3. ✔
- **Placeholder scan:** Helper, both emission edits, and tests are concrete. Marker text is fixed and asserted by regex.
- **Type consistency:** `_truncate_diff` returns `($text, $truncated)` in Task 1 and is consumed identically in Tasks 2-3. `config_change.diff_truncated` is boolValue (OTLP) / JSON true (File), emitted only when true in both.
- **Constraint check:** Sensitive diffs go through `_diff_text_for` (File) or the `unless sensitive && !allowed` guard (OTLP) before truncation — suppressed content is never exposed or truncated. Default behavior (unlimited) preserves full diffs.

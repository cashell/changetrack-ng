# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# ChangeTrack::Metadata - JSONL sidecar for per-file stat snapshots with
#   change tracking.
#

package ChangeTrack::Metadata;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Metadata - JSONL sidecar for per-file stat snapshots

=head1 SYNOPSIS

  my $meta = ChangeTrack::Metadata->load('/var/lib/changetrack-ng/.changetrack-metadata');
  my $snap  = $meta->record_for('/etc/passwd');   # hashref or undef
  $meta->update_from_stat('/etc/passwd');          # re-stat and update in-memory record
  $meta->save('/var/lib/changetrack-ng/.changetrack-metadata');

=head1 DESCRIPTION

Maintains a JSONL file (one JSON object per line) recording the last-known
stat snapshot for each tracked file.  Fields include mode, uid/gid,
ownership names, and for regular files mtime and size.  Symlinks also
store the link target.  Used to detect metadata and content changes
between runs without relying solely on VCS status.

The file is written atomically via a tempfile-plus-rename pattern.

=head1 CLASS METHODS

=over 4

=item ChangeTrack::Metadata->new(%args)

Construct a new Metadata object.  Initializes dirty state to 0.

=item ChangeTrack::Metadata->load($path, [%args])

Read the sidecar file at I<$path>.  Returns a new object; creates an
empty object if the file does not yet exist.  Corrupt lines are skipped
with a warning.  Sets dirty state to 0 if the file exists, or 1 if the
file does not exist.

=back

=head1 INSTANCE METHODS

=over 4

=item $meta->is_dirty()

Return true (1) if in-memory metadata records have been modified since
load or creation, false (0) otherwise.

=item $meta->record_for($path)

Return the in-memory snapshot hashref for I<$path>, or undef if the
path has no recorded metadata yet.

=item $meta->update_from_stat($path, [$stat_ref], [$max_file_size])

Re-stat I<$path> with C<lstat()> and update (or create) the in-memory
record.  An optional I<$stat_ref> arrayref (from C<[lstat($path)]>)
may be passed to avoid a redundant C<lstat()> call.  The optional
I<$max_file_size> parameter classifies regular files exceeding this
threshold as C<oversize> before binary checks.  The C<type> field
is set to one of: C<file>, C<symlink>, C<binary>, C<oversize>, C<empty>,
C<unreadable>, C<special>, C<directory>, C<missing>.

=item $meta->can_skip_content_diff($path, [$stat_ref], [$max_file_size])

Return true if the file's content cannot have changed since the loaded
snapshot.  Covers unchanged mtime+size for regular files, unchanged
symlink targets, and non-content types (binary/oversize/special/etc).
Accepts an optional I<$stat_ref> arrayref and optional I<$max_file_size>.

=item $meta->changed_since_load($path, [$stat_ref], [$max_file_size])

Return true if the file's mode, ownership, symlink target, or non-content
metadata has changed compared to the loaded snapshot.  Accepts an optional
I<$stat_ref> arrayref and optional I<$max_file_size>.

=item $meta->diff_summary($path, [$stat_ref], [$max_file_size])

Return a human-readable string describing what metadata changed vs the
loaded snapshot (e.g. C<"mode 0644 -> 0600, owner root -> nobody">).
Returns an empty string if nothing changed.  Accepts an optional I<$stat_ref>
arrayref and optional I<$max_file_size>.

=item $meta->mark_removed($path)

Remove the in-memory record for I<$path>.  Used when a tracked file
vanishes from disk.

=item $meta->rollback($path)

=item $meta->rollback_path($path)

Revert the in-memory record and dirty state for I<$path> to its state
prior to processing, or delete it if it was not present when loaded.

=item $meta->save($path)

Write the current in-memory records back to disk atomically (tempfile
then rename).  Resets dirty state to 0.  Missing-type records are not written.

=back

=cut

use feature qw(state);
use Carp qw(croak carp);
use JSON::PP ();
use File::Temp ();
use File::Basename qw(dirname);
use Fcntl qw(:mode);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

########################################################################
# Construction and Persistence
########################################################################

# new -- Construct a new Metadata object. Initializes dirty state to 0.
sub new {
    my ($class, %args) = @_;
    return bless {
        path          => $args{path},
        records       => $args{records} // {},
        original      => $args{original} // {},
        dirty         => 0,
        max_file_size => $args{max_file_size},
        _prev_dirty   => {},
        _prev_records => {},
    }, $class;
}

# load -- Read the JSONL sidecar file at $path.
# Returns a Metadata object with records indexed by file path.
# Records from the loaded file are also stored as the immutable
# 'original' snapshot, used later by changed_since_load().
sub load {
    my ($class, $path, %args) = @_;
    my %records;
    my $exists = -f $path;

    if ($exists) {
        open(my $fh, '<', $path) or croak "Cannot read metadata '$path': $!";
        my $lineno = 0;
        while (my $line = <$fh>) {
            $lineno++;
            chomp $line;
            next unless length $line;
            my $r = eval { JSON::PP::decode_json($line) };
            if ($@ || !ref $r || !defined $r->{path}) {
                carp "changetrack-ng: bad metadata line $lineno in '$path', skipping";
                next;
            }
            $records{ $r->{path} } = $r;
        }
        close($fh);
    }

    # Keep an immutable snapshot of the loaded state for change-detection
    my %original = map { $_ => { %{ $records{$_} } } } keys %records;

    return bless {
        path          => $path,
        records       => \%records,
        original      => \%original,
        dirty         => $exists ? 0 : 1,
        max_file_size => $args{max_file_size},
        _prev_dirty   => {},
        _prev_records => {},
    }, $class;
}

# is_dirty -- Return 1 if in-memory metadata was modified or newly created, 0 otherwise.
sub is_dirty {
    my ($self) = @_;
    return $self->{dirty} ? 1 : 0;
}

# record_for -- Return the current in-memory record for $path, or undef.
sub record_for {
    my ($self, $path) = @_;
    return $self->{records}{$path};
}

# save -- Write the in-memory records to $path atomically.
# Uses File::Temp (O_EXCL, mode 0600) in the destination directory plus a
# rename, so a partial write is never visible and a predictable/symlinked temp
# name cannot be used to clobber an arbitrary file.
# Records with type 'missing' are not persisted (they are transient).
sub save {
    my ($self, $path) = @_;
    $path //= $self->{path};
    croak "Cannot save metadata: no path specified" unless defined $path;

    my $dir = dirname($path);
    my ($fh, $tmp) = File::Temp::tempfile(
        '.changetrack-metadata.XXXXXXXX',
        DIR    => $dir,
        UNLINK => 0,
    );
    chmod 0600, $tmp;

    for my $rpath (sort keys %{ $self->{records} }) {
        my $rec = $self->{records}{$rpath};
        next if ($rec->{type} // '') eq 'missing';
        print $fh JSON::PP::encode_json($rec) . "\n";
    }

    close($fh) or do { unlink $tmp; croak "Error flushing metadata '$tmp': $!" };

    rename($tmp, $path) or do {
        unlink $tmp;
        croak "Cannot rename '$tmp' -> '$path': $!";
    };

    $self->{path}          = $path;
    $self->{dirty}         = 0;
    $self->{_prev_dirty}   = {};
    $self->{_prev_records} = {};
}

########################################################################
# Classification and State Inspection
########################################################################

# _classify_file -- Helper to determine file type from lstat results.
# Shared across update_from_stat, can_skip_content_diff, changed_since_load,
# and diff_summary to ensure uniform classification behavior.
# Accepts an optional $stat_ref; falls back to lstat($path) if omitted.
# Accepts an optional $max_file_size; classifies as oversize before binary check.
sub _classify_file {
    my ($path, $stat_ref, $max_file_size) = @_;
    my @s = ($stat_ref && @$stat_ref) ? @$stat_ref : lstat($path);
    return 'missing' unless @s;
    my $m = $s[2];
    if    (S_ISLNK($m))  { return 'symlink'; }
    elsif (S_ISDIR($m))  { return 'directory'; }
    elsif (!S_ISREG($m)) { return 'special'; }
    elsif (!-r $path)    { return 'unreadable'; }
    elsif ($s[7] == 0)   { return 'empty'; }
    elsif (defined $max_file_size && $max_file_size > 0 && $s[7] > $max_file_size) {
        return 'oversize';
    }
    elsif (-B $path)     { return 'binary'; }
    else                 { return 'file'; }
}

# update_from_stat -- Re-stat $path and update (or create) the in-memory record.
# Determines file type from lstat results; sets mtime/size for file-like types;
# records readlink() target for symlinks. Accepts an optional $stat_ref arrayref
# and an optional $max_file_size threshold.
sub update_from_stat {
    my ($self, $path, $stat_ref, $max_file_size) = @_;

    if (defined $stat_ref && !ref $stat_ref && !defined $max_file_size) {
        $max_file_size = $stat_ref;
        $stat_ref      = undef;
    }
    $max_file_size //= $self->{max_file_size};

    # Save prior state for rollback if not already saved for this path
    if (!exists $self->{_prev_dirty}{$path}) {
        $self->{_prev_dirty}{$path}   = $self->{dirty};
        $self->{_prev_records}{$path} = exists $self->{records}{$path}
            ? (defined $self->{records}{$path} ? { %{ $self->{records}{$path} } } : undef)
            : undef;
    }

    my @s = ($stat_ref && @$stat_ref) ? @$stat_ref : lstat($path);
    unless (@s) {
        my $rec = { path => $path, type => 'missing' };
        my $old = $self->{records}{$path};
        if (!defined $old || ($old->{type} // '') ne 'missing') {
            $self->{dirty} = 1;
        }
        $self->{records}{$path} = $rec;
        return;
    }

    my $type = _classify_file($path, \@s, $max_file_size);

    my $rec = {
        path  => $path,
        mode  => sprintf('%04o', $s[2] & 07777),
        uid   => $s[4] + 0,
        gid   => $s[5] + 0,
        user  => _username($s[4]),
        group => _groupname($s[5]),
        type  => $type,
    };
    if ($type eq 'file' || $type eq 'binary' || $type eq 'empty' || $type eq 'unreadable' || $type eq 'oversize') {
        $rec->{mtime} = $s[9] + 0;
        $rec->{ctime} = $s[10] + 0;
        $rec->{size}  = $s[7] + 0;
    }
    $rec->{target} = readlink($path) if $type eq 'symlink';

    # Compare fields with existing record to update dirty state
    my $old = $self->{records}{$path};
    if (!defined $old) {
        $self->{dirty} = 1;
    } else {
        for my $f (qw(type mode uid gid user group mtime size target)) {
            my $has_old = defined $old->{$f} ? 1 : 0;
            my $has_new = defined $rec->{$f} ? 1 : 0;
            if ($has_old != $has_new) {
                $self->{dirty} = 1;
                last;
            }
            if ($has_old && $old->{$f} ne $rec->{$f}) {
                $self->{dirty} = 1;
                last;
            }
        }
    }

    $self->{records}{$path} = $rec;
}

# can_skip_content_diff -- Return true if file content cannot have changed
# since the loaded snapshot. Covers mtime+size equality for regular files,
# symlink target equality, and non-content types (binary/oversize/special/etc).
# Avoids unnecessary VCS diff calls for stable files. Accepts optional $stat_ref
# and optional $max_file_size.
sub can_skip_content_diff {
    my ($self, $path, $stat_ref, $max_file_size) = @_;
    if (defined $stat_ref && !ref $stat_ref && !defined $max_file_size) {
        $max_file_size = $stat_ref;
        $stat_ref      = undef;
    }
    $max_file_size //= $self->{max_file_size};

    my $orig = $self->{original}{$path};
    return 0 unless defined $orig;

    my $otype = $orig->{type} // '';

    my @s = ($stat_ref && @$stat_ref) ? @$stat_ref : lstat($path);
    return 0 unless @s;

    my $cur_type = _classify_file($path, \@s, $max_file_size);
    return 0 if $cur_type ne $otype;  # Type changed -> NEVER skip content diff

    # Symlinks: compare stored target to live readlink -- no file I/O needed.
    if ($otype eq 'symlink') {
        my $cur_target = readlink($path);
        return 0 unless defined $cur_target;
        return ($cur_target eq ($orig->{target} // '')) ? 1 : 0;
    }

    # Non-content types: unchanged mtime+size means nothing to reprocess.
    # Regular files: unchanged mtime+size means content hasn't changed.
    if ($otype eq 'file' || $otype eq 'binary' || $otype eq 'empty' || $otype eq 'unreadable' || $otype eq 'oversize') {
        return 0 unless S_ISREG($s[2]);
        return 0 unless defined $orig->{mtime} && defined $orig->{size};

        my $cur_size  = $s[7] + 0;
        my $cur_mtime = $s[9] + 0;
        my $cur_ctime = $s[10] + 0;

        # Both empty: content is trivially identical regardless of mtime.
        return 1 if $cur_size == 0 && ($orig->{size} + 0) == 0;

        return 0 unless $cur_mtime == ($orig->{mtime} + 0) && $cur_size == ($orig->{size} + 0);

        # ctime additionally catches same-size edits that restore the old mtime
        # (a content tracker must not miss those). Older sidecar records may
        # lack ctime; fall back to mtime+size for them until the next save.
        return 1 unless defined $orig->{ctime};
        return ($cur_ctime == ($orig->{ctime} + 0)) ? 1 : 0;
    }

    # special/directory/missing: no content to diff.
    return 1 if $otype eq 'special' || $otype eq 'directory';

    return 0;
}

# changed_since_load -- Return true if the live file's mode, uid, gid,
# (for symlinks) target, or metadata attributes differ from the loaded snapshot.
# Accepts optional $stat_ref and optional $max_file_size.
sub changed_since_load {
    my ($self, $path, $stat_ref, $max_file_size) = @_;
    if (defined $stat_ref && !ref $stat_ref && !defined $max_file_size) {
        $max_file_size = $stat_ref;
        $stat_ref      = undef;
    }
    $max_file_size //= $self->{max_file_size};

    my $orig = $self->{original}{$path};
    return 0 unless defined $orig;       # not in prior metadata -> it's new, not changed

    my @s = ($stat_ref && @$stat_ref) ? @$stat_ref : lstat($path);
    return 1 unless @s;                  # vanished since last run

    my $cur_type = _classify_file($path, \@s, $max_file_size);
    return 1 if $cur_type ne ($orig->{type} // '');

    return 1 if sprintf('%04o', $s[2] & 07777) ne ($orig->{mode} // '');
    return 1 if ($s[4] + 0) != ($orig->{uid} // -1);
    return 1 if ($s[5] + 0) != ($orig->{gid} // -1);

    if ($cur_type eq 'symlink') {
        my $target = readlink($path) // '';
        return 1 if $target ne ($orig->{target} // '');
    }

    # For non-content types (binary, oversize, unreadable, special), metadata
    # changes also include size and mtime changes.
    if ($cur_type eq 'binary' || $cur_type eq 'oversize' || $cur_type eq 'unreadable' || $cur_type eq 'special') {
        if (defined $orig->{size} && ($s[7] + 0) != ($orig->{size} + 0)) {
            return 1;
        }
        if (defined $orig->{mtime} && ($s[9] + 0) != ($orig->{mtime} + 0)) {
            return 1;
        }
    }

    return 0;
}

# diff_summary -- Return a human-readable string describing what changed
# in mode/uid/gid/target/type/size/mtime vs the loaded snapshot. Returns '' if
# nothing changed. Accepts optional $stat_ref and optional $max_file_size.
sub diff_summary {
    my ($self, $path, $stat_ref, $max_file_size) = @_;
    if (defined $stat_ref && !ref $stat_ref && !defined $max_file_size) {
        $max_file_size = $stat_ref;
        $stat_ref      = undef;
    }
    $max_file_size //= $self->{max_file_size};

    my $orig = $self->{original}{$path};
    return '' unless defined $orig;

    my @s = ($stat_ref && @$stat_ref) ? @$stat_ref : lstat($path);
    return '(file vanished)' unless @s;

    my $cur_type = _classify_file($path, \@s, $max_file_size);
    my @parts;

    if ($cur_type ne ($orig->{type} // '')) {
        push @parts, "type " . ($orig->{type} // '(unknown)') . " -> $cur_type";
    }

    my $new_mode = sprintf('%04o', $s[2] & 07777);
    if ($new_mode ne ($orig->{mode} // '')) {
        push @parts, "mode $orig->{mode} -> $new_mode";
    }
    my ($new_uid, $new_gid) = ($s[4] + 0, $s[5] + 0);
    if ($new_uid != ($orig->{uid} // -1)) {
        my $ou = $orig->{user}  // $orig->{uid};
        push @parts, "owner $ou -> " . _username($new_uid);
    }
    if ($new_gid != ($orig->{gid} // -1)) {
        my $og = $orig->{group} // $orig->{gid};
        push @parts, "group $og -> " . _groupname($new_gid);
    }
    if ($cur_type eq 'symlink') {
        my $new_tgt = readlink($path) // '';
        my $old_tgt = $orig->{target} // '(none)';
        if ($new_tgt ne ($orig->{target} // '')) {
            push @parts, "target $old_tgt -> $new_tgt";
        }
    }
    if ($cur_type eq 'binary' || $cur_type eq 'oversize' || $cur_type eq 'unreadable' || $cur_type eq 'special') {
        if (defined $orig->{size} && ($s[7] + 0) != ($orig->{size} + 0)) {
            push @parts, "size $orig->{size} -> " . ($s[7] + 0);
        }
        if (defined $orig->{mtime} && ($s[9] + 0) != ($orig->{mtime} + 0)) {
            push @parts, "mtime $orig->{mtime} -> " . ($s[9] + 0);
        }
    }

    return join(', ', @parts);
}

# mark_removed -- Remove $path's record from memory (file gone from disk).
sub mark_removed {
    my ($self, $path) = @_;
    if (exists $self->{records}{$path}) {
        if (!exists $self->{_prev_dirty}{$path}) {
            $self->{_prev_dirty}{$path}   = $self->{dirty};
            $self->{_prev_records}{$path} = defined $self->{records}{$path}
                ? { %{ $self->{records}{$path} } }
                : undef;
        }
        $self->{dirty} = 1;
        delete $self->{records}{$path};
    }
}

# rollback_path -- Revert an in-memory record and dirty state for a specific path.
sub rollback_path {
    my ($self, $path) = @_;
    if (exists $self->{_prev_dirty}{$path}) {
        $self->{dirty} = $self->{_prev_dirty}{$path};
        delete $self->{_prev_dirty}{$path};
    }
    if (exists $self->{_prev_records}{$path}) {
        my $prev = $self->{_prev_records}{$path};
        if (defined $prev) {
            $self->{records}{$path} = $prev;
        } else {
            delete $self->{records}{$path};
        }
        delete $self->{_prev_records}{$path};
    } elsif (defined $self->{original}{$path}) {
        $self->{records}{$path} = { %{ $self->{original}{$path} } };
    } else {
        delete $self->{records}{$path};
    }
}

# rollback -- Alias for rollback_path.
sub rollback {
    my ($self, $path) = @_;
    return $self->rollback_path($path);
}


# _username / _groupname -- Resolve uid/gid to name strings; fall back to the numeric id.
sub _username { $^O eq 'MSWin32' ? $_[0] : ((getpwuid($_[0]))[0] // $_[0]) }
sub _groupname { $^O eq 'MSWin32' ? $_[0] : ((getgrgid($_[0]))[0] // $_[0]) }

1;

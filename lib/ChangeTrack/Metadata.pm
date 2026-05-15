# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
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

=item ChangeTrack::Metadata->load($path)

Read the sidecar file at I<$path>.  Returns a new object; creates an
empty object if the file does not yet exist.  Corrupt lines are skipped
with a warning.

=back

=head1 INSTANCE METHODS

=over 4

=item $meta->record_for($path)

Return the in-memory snapshot hashref for I<$path>, or undef if the
path has no recorded metadata yet.

=item $meta->update_from_stat($path)

Re-stat I<$path> with C<lstat()> and update (or create) the in-memory
record.  The C<type> field is set to one of: C<file>, C<symlink>,
C<binary>, C<empty>, C<unreadable>, C<special>, C<directory>, C<missing>.

=item $meta->can_skip_content_diff($path)

Return true if the file's content cannot have changed since the loaded
snapshot.  Covers unchanged mtime+size for regular files, unchanged
symlink targets, and non-content types (binary/special/etc).

=item $meta->changed_since_load($path)

Return true if the file's mode, ownership, or symlink target has changed
compared to the loaded snapshot.

=item $meta->diff_summary($path)

Return a human-readable string describing what metadata changed vs the
loaded snapshot (e.g. C<"mode 0644 -> 0600, owner root -> nobody">).
Returns an empty string if nothing changed.

=item $meta->mark_removed($path)

Remove the in-memory record for I<$path>.  Used when a tracked file
vanishes from disk.

=item $meta->save($path)

Write the current in-memory records back to disk atomically (tempfile
then rename).  Missing-type records are not written.

=back

=cut

use feature qw(state);
use Carp qw(croak carp);
use JSON::PP ();

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# load -- Read the JSONL sidecar file at $path.
# Returns a Metadata object with records indexed by file path.
# Records from the loaded file are also stored as the immutable
# 'original' snapshot, used later by changed_since_load().
sub load {
    my ($class, $path) = @_;
    my %records;

    if (-e $path) {
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
        records  => \%records,
        original => \%original,
    }, $class;
}

# record_for -- Return the current in-memory record for $path, or undef.
sub record_for {
    my ($self, $path) = @_;
    return $self->{records}{$path};
}

# update_from_stat -- Re-stat $path and update (or create) the in-memory record.
# Determines file type from lstat results; sets mtime/size for file-like types;
# records readlink() target for symlinks.
sub update_from_stat {
    my ($self, $path) = @_;

    my @s = lstat($path);
    unless (@s) {
        $self->{records}{$path} = { path => $path, type => 'missing' };
        return;
    }

    my $type;
    if    (-l _) { $type = 'symlink'   }
    elsif (-d _) { $type = 'directory' }
    elsif (!-f _) { $type = 'special'  }
    elsif (!-r $path) { $type = 'unreadable' }
    elsif ($s[7] == 0) { $type = 'empty' }
    elsif (-B $path)   { $type = 'binary' }
    else               { $type = 'file' }

    my $rec = {
        path  => $path,
        mode  => sprintf('%04o', $s[2] & 07777),
        uid   => $s[4] + 0,
        gid   => $s[5] + 0,
        user  => _username($s[4]),
        group => _groupname($s[5]),
        type  => $type,
    };
    if ($type eq 'file' || $type eq 'binary' || $type eq 'empty' || $type eq 'unreadable') {
        $rec->{mtime} = $s[9] + 0;
        $rec->{size}  = $s[7] + 0;
    }
    $rec->{target} = readlink($path) if $type eq 'symlink';

    $self->{records}{$path} = $rec;
}

# can_skip_content_diff -- Return true if file content cannot have changed
# since the loaded snapshot.  Covers mtime+size equality for regular files,
# symlink target equality, and non-content types (binary/special/etc).
# Avoids unnecessary VCS diff calls for stable files.
sub can_skip_content_diff {
    my ($self, $path) = @_;
    my $orig = $self->{original}{$path};
    return 0 unless defined $orig;

    my $otype = $orig->{type} // '';

    # Symlinks: compare stored target to live readlink  --  no file I/O needed.
    if ($otype eq 'symlink') {
        my $cur_target = readlink($path);
        return 0 unless defined $cur_target;
        return ($cur_target eq ($orig->{target} // '')) ? 1 : 0;
    }

    # Non-content types: unchanged mtime+size means nothing to reprocess.
    # Regular files: unchanged mtime+size means content hasn't changed.
    if ($otype eq 'file' || $otype eq 'binary' || $otype eq 'empty' || $otype eq 'unreadable') {
        my @s = lstat($path);
        return 0 unless @s;
        return 0 unless -f _;
        return 0 unless defined $orig->{mtime} && defined $orig->{size};

        my $cur_size  = $s[7] + 0;
        my $cur_mtime = $s[9] + 0;

        # Both empty: content is trivially identical regardless of mtime.
        return 1 if $cur_size == 0 && ($orig->{size} + 0) == 0;

        return ($cur_mtime == ($orig->{mtime} + 0) && $cur_size == ($orig->{size} + 0)) ? 1 : 0;
    }

    # special/directory/missing: no content to diff.
    return 1 if $otype eq 'special' || $otype eq 'directory';

    return 0;
}

# changed_since_load -- Return true if the live file's mode, uid, gid, or
# (for symlinks) target differs from the loaded snapshot.
sub changed_since_load {
    my ($self, $path) = @_;
    my $orig = $self->{original}{$path};
    return 0 unless defined $orig;       # not in prior metadata -> it's new, not changed

    my @s = lstat($path);
    return 1 unless @s;                  # vanished since last run

    return 1 if sprintf('%04o', $s[2] & 07777) ne ($orig->{mode} // '');
    return 1 if ($s[4] + 0) != ($orig->{uid} // -1);
    return 1 if ($s[5] + 0) != ($orig->{gid} // -1);

    if (-l _) {
        my $target = readlink($path) // '';
        return 1 if $target ne ($orig->{target} // '');
    }

    return 0;
}

# diff_summary -- Return a human-readable string describing what changed
# in mode/uid/gid/target vs the loaded snapshot.  Returns '' if nothing changed.
sub diff_summary {
    my ($self, $path) = @_;
    my $orig = $self->{original}{$path};
    return '' unless defined $orig;

    my @s = lstat($path);
    return '(file vanished)' unless @s;

    my @parts;
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
    if (-l _ && defined $orig->{target}) {
        my $new_tgt = readlink($path) // '';
        if ($new_tgt ne $orig->{target}) {
            push @parts, "target $orig->{target} -> $new_tgt";
        }
    }

    return join(', ', @parts);
}

# mark_removed -- Remove $path's record from memory (file gone from disk).
sub mark_removed {
    my ($self, $path) = @_;
    delete $self->{records}{$path};
}

# save -- Write the in-memory records to $path atomically.
# Uses a tmpfile+rename pattern so readers never see a partial write.
# Records with type 'missing' are not persisted (they are transient).
sub save {
    my ($self, $path) = @_;

    my $tmp = "$path.tmp.$$";
    open(my $fh, '>', $tmp) or croak "Cannot write metadata tmp '$tmp': $!";

    for my $rpath (sort keys %{ $self->{records} }) {
        my $rec = $self->{records}{$rpath};
        next if ($rec->{type} // '') eq 'missing';
        print $fh JSON::PP::encode_json($rec) . "\n";
    }

    close($fh) or croak "Error flushing metadata '$tmp': $!";

    rename($tmp, $path) or do {
        unlink $tmp;
        croak "Cannot rename '$tmp' -> '$path': $!";
    };
}

# import_from_v1_statistics -- Stub for future v1 .statistics format migration.
sub import_from_v1_statistics {
    my ($self, $dir) = @_;
    carp "changetrack-ng: import_from_v1_statistics not yet implemented";
}

# _username / _groupname -- Resolve uid/gid to name strings; fall back to the numeric id.
sub _groupname { $^O eq 'MSWin32' ? $_[0] : ((getgrgid($_[0]))[0] // $_[0]) }

1;

package ChangeTrack::Metadata;

=head1 NAME

ChangeTrack::Metadata - JSONL sidecar for per-file stat snapshots

=head1 SYNOPSIS

  my $meta = ChangeTrack::Metadata->load('/var/lib/changetrack-ng/.changetrack-metadata');
  my $snap  = $meta->get('/etc/passwd');   # hashref or undef
  $meta->set('/etc/passwd', { mtime => time(), size => 1234, mode => 0644, is_sensitive => 0 });
  $meta->save;

=head1 DESCRIPTION

Maintains a JSONL file (one JSON object per line) that records the last
known stat snapshot for each tracked file, including ownership/mode and
basic content fingerprint fields (mtime, size for regular files).  Used to
detect changes between runs without relying solely on VCS status.

=head1 CLASS METHODS

=over 4

=item ChangeTrack::Metadata->load($path)

Read the sidecar file at I<$path>.  Returns a new object; creates an
empty object if the file does not yet exist.

=back

=head1 INSTANCE METHODS

=over 4

=item $meta->get($path)

Return the snapshot hashref for I<$path>, or undef if not recorded.

=item $meta->set($path, \%snapshot)

Store or update the snapshot for I<$path>.

=item $meta->delete($path)

Remove the snapshot for I<$path>.

=item $meta->save

Write the current state back to disk atomically.

=back

=cut

use strict;
use warnings;
use feature qw(state);
use Carp qw(croak carp);
use JSON::PP ();

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# load($path) — reads JSONL; returns object indexed by file path.
# If the file does not exist, returns an empty object.
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

# record_for($path) — current in-memory record, undef if not tracked yet.
sub record_for {
    my ($self, $path) = @_;
    return $self->{records}{$path};
}

# update_from_stat($path) — repopulate the in-memory record by stat()ing the live file.
sub update_from_stat {
    my ($self, $path) = @_;

    my @s = lstat($path);
    unless (@s) {
        $self->{records}{$path} = { path => $path, type => 'missing' };
        return;
    }

    my $type;
    if    (-l _) { $type = 'symlink' }
    elsif (-f _) { $type = 'file'    }
    elsif (-d _) { $type = 'directory' }
    else          { $type = 'special'  }

    my $rec = {
        path  => $path,
        mode  => sprintf('%04o', $s[2] & 07777),
        uid   => $s[4] + 0,
        gid   => $s[5] + 0,
        user  => _username($s[4]),
        group => _groupname($s[5]),
        type  => $type,
    };
    if ($type eq 'file') {
        $rec->{mtime} = $s[9] + 0;
        $rec->{size}  = $s[7] + 0;
    }
    $rec->{target} = readlink($path) if $type eq 'symlink';

    $self->{records}{$path} = $rec;
}

# can_skip_content_diff($path) — true when a regular file has unchanged
# mtime+size compared to the loaded snapshot, so a VCS content diff can be
# safely skipped for this run.
sub can_skip_content_diff {
    my ($self, $path) = @_;
    my $orig = $self->{original}{$path};
    return 0 unless defined $orig;
    return 0 unless ($orig->{type} // '') eq 'file';

    my @s = lstat($path);
    return 0 unless @s;
    return 0 unless -f _;
    return 0 unless defined $orig->{mtime} && defined $orig->{size};

    my $cur_mtime = $s[9] + 0;
    my $cur_size  = $s[7] + 0;
    return ($cur_mtime == ($orig->{mtime} + 0) && $cur_size == ($orig->{size} + 0)) ? 1 : 0;
}

# changed_since_load($path) — bool: has the live file's metadata changed vs the loaded record?
sub changed_since_load {
    my ($self, $path) = @_;
    my $orig = $self->{original}{$path};
    return 0 unless defined $orig;       # not in prior metadata → it's new, not changed

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

# diff_summary($path) — human string describing what changed vs the loaded record.
sub diff_summary {
    my ($self, $path) = @_;
    my $orig = $self->{original}{$path};
    return '' unless defined $orig;

    my @s = lstat($path);
    return '(file vanished)' unless @s;

    my @parts;
    my $new_mode = sprintf('%04o', $s[2] & 07777);
    if ($new_mode ne ($orig->{mode} // '')) {
        push @parts, "mode $orig->{mode} \x{2192} $new_mode";
    }
    my ($new_uid, $new_gid) = ($s[4] + 0, $s[5] + 0);
    if ($new_uid != ($orig->{uid} // -1)) {
        my $ou = $orig->{user}  // $orig->{uid};
        push @parts, "owner $ou \x{2192} " . _username($new_uid);
    }
    if ($new_gid != ($orig->{gid} // -1)) {
        my $og = $orig->{group} // $orig->{gid};
        push @parts, "group $og \x{2192} " . _groupname($new_gid);
    }
    if (-l _ && defined $orig->{target}) {
        my $new_tgt = readlink($path) // '';
        if ($new_tgt ne $orig->{target}) {
            push @parts, "target $orig->{target} \x{2192} $new_tgt";
        }
    }

    return join(', ', @parts);
}

# mark_removed($path) — remove path from in-memory records (file vanished from disk).
sub mark_removed {
    my ($self, $path) = @_;
    delete $self->{records}{$path};
}

# save($path) — write JSONL sorted by path, atomic via tempfile + rename.
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
        croak "Cannot rename '$tmp' \x{2192} '$path': $!";
    };
}

# import_from_v1_statistics($dir) — one-shot migration from old .statistics format (stub).
sub import_from_v1_statistics {
    my ($self, $dir) = @_;
    carp "changetrack-ng: import_from_v1_statistics not yet implemented";
}

sub _username  { (getpwuid($_[0]))[0] // $_[0] }
sub _groupname { (getgrgid($_[0]))[0] // $_[0] }

1;

package ChangeTrack::Util;

=head1 NAME

ChangeTrack::Util - shared utility functions for changetrack-ng

=head1 SYNOPSIS

    use ChangeTrack::Util qw(hostname run_cmd sync_mirror_path restore_mirror_path);
  my $h   = hostname();
  my $res = run_cmd(['git', 'status', '--short']);
  die $res->{stderr} if $res->{exit_code};

=head1 DESCRIPTION

Provides utility functions used across changetrack-ng modules.

=head1 FUNCTIONS

=over 4

=item hostname()

Return the system hostname, falling back to C<'localhost'> if unavailable.
Result is cached after the first call.

=item run_cmd(\@cmd)

Execute I<@cmd> via C<IPC::Run> if available, otherwise via C<open3>.
Returns a hashref with keys C<stdout>, C<stderr>, and C<exit_code>.
Never uses shell interpolation; all arguments are passed as a list.

=item sync_mirror_path($src, $dst)

Copy I<$src> into mirror path I<$dst>.  For regular files this is a plain
copy.  For symlinks this writes a deterministic snapshot record containing the
link target.

=item restore_mirror_path($mirror, $dst)

Restore I<$dst> from mirror file I<$mirror>.  If I<$mirror> is a symlink
snapshot record, recreate a symlink with the recorded target.

=back

=cut

use strict;
use warnings;
use feature qw(state);
use Carp qw(croak carp);
use File::Copy qw(copy);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };
our @ISA     = qw(Exporter);
our @EXPORT_OK = qw(hostname fqdn run_cmd sync_mirror_path restore_mirror_path set_debug);

our $DEBUG = 0;

sub set_debug { $DEBUG = $_[0] ? 1 : 0 }

my $SYMLINK_SNAPSHOT_PREFIX = '__CHANGTRACK_NG_SYMLINK_TARGET__=';

# hostname() — short hostname, cached
sub hostname {
    state $h;
    return $h if defined $h;
    eval { require Sys::Hostname; $h = Sys::Hostname::hostname() };
    $h //= 'localhost';
    $h =~ s/\..*$//;    # trim to short name
    return $h;
}

# fqdn() — fully-qualified domain name, cached
# Tries: Sys::Hostname → DNS canonical lookup → Net::Domain → fallback short
sub fqdn {
    state $fqdn;
    return $fqdn if defined $fqdn;

    require Sys::Hostname;
    my $h = Sys::Hostname::hostname() // 'localhost';

    # Already FQDN?
    if ($h =~ /\./) {
        $fqdn = $h;
        return $fqdn;
    }

    # Try DNS canonical name lookup
    my $packed = gethostbyname($h);
    if ($packed) {
        my $canon = gethostbyaddr($packed, 2);  # AF_INET = 2
        if ($canon && $canon =~ /\./) {
            $fqdn = $canon;
            return $fqdn;
        }
    }

    # Try Net::Domain (core in older Perls, may not be available)
    eval {
        require Net::Domain;
        my $nd = Net::Domain::hostfqdn();
        $fqdn = $nd if $nd && $nd =~ /\./;
    };
    return $fqdn if defined $fqdn;

    # Fall back to short name
    $fqdn = $h;
    return $fqdn;
}

# run_cmd(%args) — run an external command safely
#
# Args:
#   cmd   => \@cmd_and_args   (required)
#   input => $stdin_string    (optional)
#   desc  => "human label"    (optional, for error messages)
#
# Returns: { success => bool, stdout => str, stderr => str, exit_code => int }
#
# Uses IO::Select to read stdout+stderr concurrently, avoiding pipe deadlocks.
# Never uses shell interpolation — cmd is always an arrayref.
sub run_cmd {
    my (%args) = @_;
    my $cmd   = $args{cmd}   or croak 'run_cmd: cmd required (arrayref)';
    my $input = $args{input} // '';
    my $desc  = $args{desc}  // join(' ', @$cmd);

    require IPC::Open3;
    require IO::Select;
    require Symbol;

    my $err_fh = Symbol::gensym();
    my ($in_fh, $out_fh);
    my $pid;

    eval { $pid = IPC::Open3::open3($in_fh, $out_fh, $err_fh, @$cmd) };
    if ($@) {
        if ($DEBUG) {
            my $cmd_str = join(' ', @$cmd);
            warn "[changetrack-ng][][DEBUG] exec failed: $cmd_str -- $@\n";
        }
        return { success => 0, stdout => '', stderr => "exec failed: $@", exit_code => -1 };
    }

    if ($DEBUG) {
        my $cmd_str = join(' ', @$cmd);
        warn "[changetrack-ng][][DEBUG] exec: $cmd_str\n";
    }

    if (length $input) {
        print $in_fh $input;
    }
    close($in_fh);

    my $sel = IO::Select->new($out_fh, $err_fh);
    my %buf;

    while (my @ready = $sel->can_read(30)) {
        for my $fh (@ready) {
            my $data;
            my $n = sysread($fh, $data, 8192);
            if (!defined $n || $n == 0) {
                $sel->remove($fh);
                next;
            }
            $buf{fileno($fh)} .= $data;
        }
    }

    waitpid($pid, 0);
    my $exit_code = $? >> 8;

    if ($DEBUG && $exit_code != 0) {
        my $err_out = $buf{fileno($err_fh)} // '';
        $err_out = substr($err_out, 0, 200) . '...' if length($err_out) > 200;
        $err_out =~ s/\n/ /g;
        my $cmd_str = join(' ', @$cmd);
        warn "[changetrack-ng][][DEBUG] exec failed (exit=$exit_code): $cmd_str -- $err_out\n";
    }

    return {
        success   => ($exit_code == 0),
        stdout    => $buf{fileno($out_fh)} // '',
        stderr    => $buf{fileno($err_fh)} // '',
        exit_code => $exit_code,
    };
}

sub sync_mirror_path {
    my ($src, $dst) = @_;
    croak 'sync_mirror_path: src required' unless defined $src;
    croak 'sync_mirror_path: dst required' unless defined $dst;

    if (-l $src) {
        my $target = readlink($src);
        croak "sync_mirror_path: readlink failed for '$src': $!" unless defined $target;

        unlink($dst) if -e $dst || -l $dst;
        open(my $fh, '>', $dst) or croak "sync_mirror_path: open '$dst' for write failed: $!";
        print $fh $SYMLINK_SNAPSHOT_PREFIX, $target, "\n";
        close($fh) or croak "sync_mirror_path: close '$dst' failed: $!";
        return 'symlink';
    }

    if (-l $dst) {
        unlink($dst) or croak "sync_mirror_path: cannot remove stale symlink '$dst': $!";
    }
    copy($src, $dst) or croak "sync_mirror_path: copy '$src' -> '$dst' failed: $!";
    return 'file';
}

sub restore_mirror_path {
    my ($mirror, $dst) = @_;
    croak 'restore_mirror_path: mirror required' unless defined $mirror;
    croak 'restore_mirror_path: dst required' unless defined $dst;

    my $target = _read_symlink_snapshot_target($mirror);
    if (defined $target) {
        unlink($dst) if -e $dst || -l $dst;
        symlink($target, $dst)
            or croak "restore_mirror_path: symlink '$dst' -> '$target' failed: $!";
        return 'symlink';
    }

    if (-l $dst) {
        unlink($dst) or croak "restore_mirror_path: cannot remove stale symlink '$dst': $!";
    }
    copy($mirror, $dst) or croak "restore_mirror_path: copy '$mirror' -> '$dst' failed: $!";
    return 'file';
}

sub _read_symlink_snapshot_target {
    my ($path) = @_;
    return undef unless -f $path;

    open(my $fh, '<', $path) or return undef;
    my $line = <$fh>;
    close($fh);
    return undef unless defined $line;
    chomp $line;
    return undef unless index($line, $SYMLINK_SNAPSHOT_PREFIX) == 0;
    return substr($line, length($SYMLINK_SNAPSHOT_PREFIX));
}

1;

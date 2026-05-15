# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Util - Shared utility functions: hostname, fqdn, run_cmd
#   (IPC::Open3), sync/restore mirror paths, set_debug flag.
#

package ChangeTrack::Util;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Util - shared utility functions for changetrack-ng

=head1 SYNOPSIS

    use ChangeTrack::Util qw(hostname fqdn run_cmd sync_mirror_path restore_mirror_path set_debug);

    my $h   = hostname();
    my $fqn = fqdn();
    my $res = run_cmd(cmd => ['git', 'status', '--short']);
    die $res->{stderr} if !$res->{success};

=head1 DESCRIPTION

Provides shared utility functions used across all changetrack-ng modules.
All external command execution goes through C<run_cmd()>, which uses
C<IPC::Open3> with list-form arguments to guarantee no shell interpolation.

=head1 FUNCTIONS

=over 4

=item hostname()

Return the short (non-qualified) system hostname, falling back to
C<'localhost'> if unavailable.  Result is cached after the first call.

=item fqdn()

Return the fully-qualified domain name of the local host.  Tries
C<Sys::Hostname> first, then a reverse DNS lookup, then C<Net::Domain>,
falling back to the short hostname.  Result is cached.

=item run_cmd(cmd => \@cmd [, input => $str] [, desc => $str])

Execute I<@cmd> safely using C<IPC::Open3> with concurrent
C<IO::Select>-based reading of stdout and stderr.  Arguments:

=over 4

=item C<cmd> (required) -- arrayref of command and arguments; never shell-interpolated.

=item C<input> (optional) -- string to send to the command's stdin.

=item C<desc> (optional) -- human-readable label used in debug/error messages.

=back

Returns a hashref with keys: C<success> (bool), C<stdout> (string),
C<stderr> (string), C<exit_code> (integer).

When C<$ChangeTrack::Util::DEBUG> is set, emits C<[DEBUG] exec:> lines
to STDERR for every command invoked.

=item sync_mirror_path($src, $dst)

Copy I<$src> into the mirror path I<$dst>.  For regular files this is a
plain file copy.  For symlinks this writes a deterministic text snapshot
record containing the link target (identified by the
C<__CHANGTRACK_NG_SYMLINK_TARGET__=> prefix).

=item restore_mirror_path($mirror, $dst)

Restore I<$dst> from the mirror file I<$mirror>.  If I<$mirror> is a
symlink snapshot record, recreates the symlink with the recorded target;
otherwise copies the file.

=item set_debug($bool)

Enable (1) or disable (0) debug-level command tracing.  Sets the module
global C<$ChangeTrack::Util::DEBUG> flag read by C<run_cmd()>.

=back

=cut

use feature qw(state);
use Carp qw(croak carp);
use File::Copy qw(copy);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };
our @ISA     = qw(Exporter);
our @EXPORT_OK = qw(hostname fqdn run_cmd sync_mirror_path restore_mirror_path set_debug);

our $DEBUG = 0;

# set_debug -- Enable or disable debug-level command tracing (sets $DEBUG).
sub set_debug { $DEBUG = $_[0] ? 1 : 0 }

# Prefix written to mirror files that represent tracked symlinks.
my $SYMLINK_SNAPSHOT_PREFIX = '__CHANGTRACK_NG_SYMLINK_TARGET__=';

# hostname -- Return the short hostname; cached after first call.
sub hostname {
    state $h;
    return $h if defined $h;
    eval { require Sys::Hostname; $h = Sys::Hostname::hostname() };
    $h //= 'localhost';
    $h =~ s/\..*$//;    # trim to short name
    return $h;
}

# fqdn -- Return the fully-qualified domain name; cached after first call.
# Resolution order: Sys::Hostname -> DNS canonical lookup -> Net::Domain -> short name.
sub fqdn {
    state $fqdn;
    return $fqdn if defined $fqdn;

    require Sys::Hostname;
    my $h = Sys::Hostname::hostname() // 'localhost';

    # If the hostname already contains a dot, treat it as already fully qualified.
    if ($h =~ /\./) {
        $fqdn = $h;
        return $fqdn;
    }

    # Try a DNS round-trip: forward lookup then reverse to get the canonical name.
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

########################################################################
# Command Execution
########################################################################

# run_cmd -- Execute an external command safely via IPC::Open3.
#
# Args (named):
#   cmd   => \@cmd_and_args   (required)
#   input => $stdin_string    (optional; defaults to empty string)
#   desc  => "human label"    (optional; used in debug/error messages)
#
# Returns: { success => bool, stdout => str, stderr => str, exit_code => int }
#
# Uses IO::Select to drain stdout and stderr concurrently, preventing
# pipe deadlocks on large output.  Never uses shell interpolation.
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

########################################################################
# Symlink-Aware Mirror Utilities
########################################################################

# sync_mirror_path -- Copy $src to the mirror path $dst.
# Regular files are copied directly.  Symlinks are written as a text
# snapshot file containing the link target, so the mirror tree stays
# all-regular-files regardless of what is being tracked.
# Returns: 'symlink' or 'file' indicating which branch was taken.
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

# restore_mirror_path -- Restore $dst from the mirror file $mirror.
# If $mirror is a symlink snapshot record, recreates the symlink;
# otherwise copies the file content.  Returns 'symlink' or 'file'.
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

# _read_symlink_snapshot_target -- Read the symlink target from a snapshot file.
# Returns the target string if $path contains a valid snapshot record, undef otherwise.
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

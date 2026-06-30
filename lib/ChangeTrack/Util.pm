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

=item run_cmd(cmd => \@cmd [, input => $str] [, desc => $str] [, timeout => $secs])

Execute I<@cmd> safely using C<IPC::Open3> with concurrent
C<IO::Select>-based reading of stdout and stderr.  Arguments:

=over 4

=item C<cmd> (required) -- arrayref of command and arguments; never shell-interpolated.

=item C<input> (optional) -- string to send to the command's stdin.

=item C<desc> (optional) -- human-readable label used in debug/error messages.

=item C<timeout> (optional) -- wall-clock seconds.  Acts as a watchdog: if it
expires the child is killed (C<TERM> then C<KILL>) and the result is flagged
C<timed_out>.  Defaults to C<$ChangeTrack::Util::DEFAULT_TIMEOUT> (120s) so a
hung command cannot hang a scheduled run; pass C<0> to disable the cap.
stdout/stderr are always drained until EOF so a slow-but-progressing command
is never truncated.

=back

Returns a hashref with keys: C<success> (bool), C<stdout> (string),
C<stderr> (string), C<exit_code> (integer; signal termination is reported as
C<128 + signal>), C<timed_out> (bool).

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

=item redact_secrets($string)

Return a copy of I<$string> with credentials masked for safe logging:
URI userinfo (C<scheme://user:pass@host> becomes C<scheme://***@host>) and
token-like C<key=value> parameters (C<token>, C<secret>, C<password>, etc.).
Host and path are preserved so diagnostics remain useful.

=item redact_url($url)

Return I<$url> reduced to C<scheme://host/...> (userinfo, path, and query
removed).  Use for URLs where the credential lives in the path or query, such
as Slack/Teams/Discord webhook endpoints.

=item set_default_timeout($seconds)

Set the default wall-clock timeout applied to C<run_cmd> when no explicit
C<timeout> argument is given (module global C<$DEFAULT_TIMEOUT>).  A value of
0 disables the cap.  Wired to the C<command_timeout> global config key.

=back

=cut

use feature qw(state);
use Carp qw(croak carp);
use File::Copy qw(copy);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };
our @ISA     = qw(Exporter);
our @EXPORT_OK = qw(hostname fqdn run_cmd sync_mirror_path restore_mirror_path set_debug redact_secrets redact_url set_default_timeout);

our $DEBUG = 0;

# set_debug -- Enable or disable debug-level command tracing (sets $DEBUG).
sub set_debug { $DEBUG = $_[0] ? 1 : 0 }

# Default wall-clock timeout (seconds) applied to run_cmd when no explicit
# timeout argument is given.  Bounds every external command so a hung or
# runaway tool cannot hang a scheduled (cron/systemd) run.  A value of 0 (or
# undef) disables the cap.  Overridable per-call via the run_cmd timeout arg
# or globally via set_default_timeout (wired to the command_timeout config).
our $DEFAULT_TIMEOUT = 120;

# set_default_timeout -- Set the default run_cmd wall-clock timeout (seconds).
sub set_default_timeout { $DEFAULT_TIMEOUT = $_[0] }

# Prefix written to mirror files that represent tracked symlinks.
my $SYMLINK_SNAPSHOT_PREFIX = '__CHANGETRACK_NG_SYMLINK_TARGET__=';

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
# Secret Redaction
########################################################################

# redact_secrets -- Mask credentials in a string before it reaches a log.
# Masks URI userinfo (scheme://user:pass@host -> scheme://***@host) and
# token-like key=value parameters.  Host and path are preserved so command
# traces and warnings remain diagnostically useful.
sub redact_secrets {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s{([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/?#\s@]+(@)}{${1}***${2}}g;
    $s =~ s{(?i)((?:access_token|api[_-]?key|apikey|token|secret|password|sig|key)=)[^&\s]+}{${1}***}g;
    return $s;
}

# redact_url -- Reduce a URL to scheme://host/... for logging.
# Drops userinfo, path, and query, because for some endpoints (e.g. Slack/
# Teams/Discord webhooks) the secret token lives in the path or query string.
sub redact_url {
    my ($u) = @_;
    return '(none)' unless defined $u && length $u;
    if ($u =~ m{^([a-zA-Z][a-zA-Z0-9+.\-]*://)(?:[^/?#\s@]*@)?([^/?#\s]+)}) {
        return "$1$2/...";
    }
    return '(redacted)';
}

########################################################################
# Command Execution
########################################################################

# run_cmd -- Execute an external command safely via IPC::Open3.
#
# Args (named):
#   cmd     => \@cmd_and_args   (required)
#   input   => $stdin_string    (optional; defaults to empty string)
#   desc    => "human label"    (optional; used in debug/error messages)
#   timeout => $seconds         (optional; wall-clock watchdog kills child;
#                                defaults to $DEFAULT_TIMEOUT (120s); 0 disables)
#
# Returns: { success => bool, stdout => str, stderr => str,
#            exit_code => int, timed_out => bool }
#
# Uses IO::Select to drain stdout and stderr concurrently until both reach
# EOF, preventing pipe deadlocks and output truncation on large or slow
# output.  Never uses shell interpolation.
sub run_cmd {
    my (%args) = @_;
    my $cmd     = $args{cmd}   or croak 'run_cmd: cmd required (arrayref)';
    my $input   = $args{input} // '';
    my $desc    = $args{desc}  // join(' ', @$cmd);
    my $timeout = exists $args{timeout} ? $args{timeout} : $DEFAULT_TIMEOUT;

    require IPC::Open3;
    require IO::Select;
    require Symbol;
    require POSIX;

    my $err_fh = Symbol::gensym();
    my ($in_fh, $out_fh);
    my $pid;

    eval { $pid = IPC::Open3::open3($in_fh, $out_fh, $err_fh, @$cmd) };
    if ($@) {
        if ($DEBUG) {
            my $cmd_str = join(' ', map { redact_secrets($_) } @$cmd);
            warn "[changetrack-ng][][DEBUG] exec failed: $cmd_str -- $@\n";
        }
        return { success => 0, stdout => '', stderr => "exec failed: $@", exit_code => -1, timed_out => 0 };
    }

    if ($DEBUG) {
        my $cmd_str = join(' ', map { redact_secrets($_) } @$cmd);
        warn "[changetrack-ng][][DEBUG] exec: $cmd_str\n";
    }

    if (length $input) {
        print $in_fh $input;
    }
    close($in_fh);

    # Drain stdout and stderr concurrently until both reach EOF.  An optional
    # wall-clock timeout acts as a watchdog: on expiry the child is killed and
    # the result is flagged timed_out.  Without a timeout, a quiet-but-running
    # command is drained to completion rather than abandoned (no truncation).
    # When an idle interval passes with no data, the child is reaped
    # non-blockingly; if it has exited we stop, which bounds the loop on
    # platforms where select() on pipes does not report EOF (e.g. Windows).
    my $sel = IO::Select->new($out_fh, $err_fh);
    my %buf;
    my $timed_out  = 0;
    my $child_done = 0;
    my $deadline   = (defined $timeout && $timeout > 0) ? time() + $timeout : undef;

    while ($sel->count) {
        my $wait = 1;
        if (defined $deadline) {
            my $remaining = $deadline - time();
            if ($remaining <= 0) { $timed_out = 1; last; }
            $wait = $remaining < 1 ? $remaining : 1;
        }

        my @ready = $sel->can_read($wait);
        if (@ready) {
            for my $fh (@ready) {
                my $data;
                my $n = sysread($fh, $data, 8192);
                if (!defined $n || $n == 0) {
                    $sel->remove($fh);
                    next;
                }
                $buf{fileno($fh)} .= $data;
            }
            next;
        }

        # Idle interval: keep waiting for a slow-but-running command, but stop
        # once the child has exited (and grab any final buffered output).
        if (waitpid($pid, POSIX::WNOHANG()) == $pid) {
            $child_done = 1;
            for my $fh ($sel->handles) {
                my $data;
                my $n = sysread($fh, $data, 8192);
                $buf{fileno($fh)} .= $data if defined $n && $n > 0;
            }
            last;
        }
    }

    if ($timed_out) {
        kill 'TERM', $pid;
        select(undef, undef, undef, 0.2);
        kill 'KILL', $pid;
    }

    waitpid($pid, 0) unless $child_done;
    my $status = $?;
    # Report signal termination as 128+signal so a killed child is not treated
    # as a clean (exit 0) success.
    my $exit_code = ($status & 127) ? 128 + ($status & 127) : ($status >> 8);

    if ($DEBUG && $exit_code != 0) {
        my $err_out = $buf{fileno($err_fh)} // '';
        $err_out = substr($err_out, 0, 200) . '...' if length($err_out) > 200;
        $err_out =~ s/\n/ /g;
        my $cmd_str = join(' ', map { redact_secrets($_) } @$cmd);
        warn "[changetrack-ng][][DEBUG] exec failed (exit=$exit_code): $cmd_str -- $err_out\n";
    }

    return {
        success   => (!$timed_out && $exit_code == 0),
        stdout    => $buf{fileno($out_fh)} // '',
        stderr    => $buf{fileno($err_fh)} // '',
        exit_code => $exit_code,
        timed_out => $timed_out,
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

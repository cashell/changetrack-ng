package ChangeTrack::Config;

=head1 NAME

ChangeTrack::Config - INI v2 config parser and v1 migration for changetrack-ng

=head1 SYNOPSIS

  my $cfg = ChangeTrack::Config->load('/etc/changetrack-ng/changetrack-ng.conf');
  my $vcs  = $cfg->global('vcs');          # 'git'
  my @urls = @{ $cfg->global('webhook_url') // [] };
  my @entries = $cfg->track_entries;

=head1 DESCRIPTION

Parses the changetrack-ng INI v2 config file.  Array-valued keys
(C<notify>, C<ignore>, C<webhook_url>, C<push_remote>, C<email_to>)
are split on whitespace and returned as arrayrefs.  All other keys
return scalar strings.

Global keys are validated against a strict schema.  Unsupported keys
raise a parse error to prevent silent misconfiguration.

Detects a legacy v1 config by the absence of a C<[global]> section and
auto-migrates via C<migrate_v1_to_v2()>.

=head1 CLASS METHODS

=over 4

=item ChangeTrack::Config->load($path)

Load and parse the config file at I<$path>.  Returns a new
C<ChangeTrack::Config> object.  Croaks on parse error.

=item ChangeTrack::Config->migrate_v1_to_v2($v1_path, $v2_path)

Read a legacy changetrack v1 config and write an equivalent v2 INI to
I<$v2_path>.  Croaks on read/write errors.

=back

=head1 INSTANCE METHODS

=over 4

=item $cfg->global($key)

Return the value of the named key in C<[global]>.  Array keys return an
arrayref; all others return a scalar or undef.

=item $cfg->track_entries

Return a list of hashrefs, one per C<[track]> line, each with keys
C<path>, C<type> (C<"file"> or C<"directory">), C<emails> (arrayref),
and C<options> (hashref).

=item $cfg->version

Return the config format version (integer).

=back

=cut

use strict;
use warnings;
use feature qw(say state);
use Carp qw(croak carp);

# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

# Keys whose values are split on whitespace into arrayrefs
my %ARRAY_KEYS = map { $_ => 1 } qw(
    notify ignore webhook_url push_remote email_to
);

my %KNOWN_GLOBAL_KEYS = map { $_ => 1 } qw(
    vcs output_dir notify
    email_from email_to sendmail_path
    push_remote
    webhook_url webhook_full_diff webhook_heartbeat webhook_insecure
    otlp_endpoint otlp_full_diff otlp_compression otlp_headers otlp_timeout
    otlp_insecure otlp_resource_attributes otlp_heartbeat
    notify_log_path file_heartbeat file_full_diff
    ignore
    sensitive_auto sensitive_notify
    warn_special_files
    interval
    lock_path lock_timeout
);

my %BOOL_KEYS = map { $_ => 1 } qw(
    webhook_full_diff webhook_heartbeat webhook_insecure
    otlp_full_diff otlp_insecure otlp_heartbeat
    file_heartbeat file_full_diff
    sensitive_auto
    warn_special_files
);

my %INT_KEYS = map { $_ => 1 } qw(
    lock_timeout otlp_timeout
);

my %PATH_KEYS = map { $_ => 1 } qw(
    output_dir notify_log_path lock_path
);

my %ENUM_KEYS = (
    vcs              => { map { $_ => 1 } qw(rcs git fossil svn hg mercurial) },
    sensitive_notify => { map { $_ => 1 } qw(suppress allow) },
    otlp_compression => { map { $_ => 1 } qw(gzip none) },
);

sub new {
    my ($class, %args) = @_;
    return bless {
        version => $args{version} // 2,
        global  => $args{global}  // {},
        tracks  => $args{tracks}  // [],
    }, $class;
}

# load($path) — auto-detects v1 vs v2; dies on parse error
sub load {
    my ($class, $path) = @_;
    open(my $fh, '<', $path) or croak "Cannot open config '$path': $!";
    my @lines = <$fh>;
    close($fh);
    chomp @lines;

    my $ver = _detect_version(\@lines);
    return $ver == 1
        ? $class->_parse_v1(\@lines, $path)
        : $class->_parse_v2(\@lines, $path);
}

sub _detect_version {
    my ($lines) = @_;
    for my $line (@$lines) {
        return 2 if $line =~ /^\s*\[(global|track)\]\s*$/i;
    }
    for my $line (@$lines) {
        next if $line =~ /^\s*(?:#.*)?$/;
        return 1 if $line =~ /^[\/\@~]/;
    }
    return 2;
}

sub _parse_v2 {
    my ($class, $lines, $src) = @_;

    my (%global, @tracks);
    my $section = '';
    my $lineno  = 0;

    for my $line (@$lines) {
        $lineno++;
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;

        if ($line =~ /^\s*\[(\w+)\]\s*$/) {
            my $sec = lc $1;
            if ($sec eq 'global' || $sec eq 'track') {
                $section = $sec;
            } else {
                carp "changetrack-ng: unknown section [$1] at $src line $lineno";
                $section = 'unknown';
            }
            next;
        }

        next if $section eq 'unknown';

        if ($section eq '') {
            croak "Config parse error at $src line $lineno: entry before any section: '$line'";
        }

        if ($section eq 'global') {
            if ($line =~ /^\s*(\w+)\s*=\s*(.*?)\s*$/) {
                my ($key, $val) = (lc $1, $2);
                croak "Config parse error at $src line $lineno: unsupported global key '$key'"
                    unless $KNOWN_GLOBAL_KEYS{$key};
                $global{$key} = $ARRAY_KEYS{$key}
                    ? (length $val ? [split /\s+/, $val] : [])
                    : $val;
            } else {
                croak "Config parse error at $src line $lineno: invalid global entry: '$line'";
            }
        } elsif ($section eq 'track') {
            my $entry = _parse_track_line($line, $src, $lineno);
            push @tracks, $entry if defined $entry;
        }
    }

    my $host = _config_hostname();
    for my $key (keys %global) {
        if (ref $global{$key} eq 'ARRAY') {
            my @vals;
            for my $item (@{ $global{$key} }) {
                my $v = $item;
                $v =~ s/\bHOSTNAME\b/$host/g;
                $v = _expand_env_vars($v, $src, $key);
                push @vals, $v;
            }
            $global{$key} = \@vals;
            next;
        }
        next if ref $global{$key};
        $global{$key} =~ s/\bHOSTNAME\b/$host/g;
        $global{$key} = _expand_env_vars($global{$key}, $src, $key);
        $global{$key} = _expand_home_path($global{$key}, $src, $key);
    }

    _validate_global_values(\%global, $src);

    return $class->new(version => 2, global => \%global, tracks => \@tracks);
}

sub _validate_global_values {
    my ($global, $src) = @_;

    if (defined(my $notify = $global->{notify})) {
        for my $n (@$notify) {
            next if $n =~ /^(?:email|webhook|otlp|file)$/;
            croak "Config parse error at $src: unsupported notify backend '$n'";
        }
    }

    for my $key (sort keys %$global) {
        my $val = $global->{$key};
        next if ref $val;
        next unless defined $val;

        if ($PATH_KEYS{$key}) {
            next if !$val;  # allow empty values; notifier validation will catch required ones
            croak "Config parse error at $src: key '$key' must be an absolute path, got '$val'"
                unless $val =~ m{^/};
        }

        if ($BOOL_KEYS{$key}) {
            next if $val =~ /^(?:1|0|true|false|yes|no|on|off)$/i;
            croak "Config parse error at $src: key '$key' must be boolean (0/1/true/false/yes/no/on/off), got '$val'";
        }

        if ($INT_KEYS{$key}) {
            croak "Config parse error at $src: key '$key' must be a non-negative integer, got '$val'"
                unless $val =~ /^\d+$/;
            next;
        }

        if (my $allowed = $ENUM_KEYS{$key}) {
            my $norm = lc $val;
            croak "Config parse error at $src: key '$key' has invalid value '$val'"
                unless $allowed->{$norm};
        }
    }
}

sub _expand_env_vars {
    my ($val, $src, $key) = @_;
    return $val unless defined $val && $val =~ /\$\{/;

    $val =~ s/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/_env_or_die($1, $src, $key)/ge;
    return $val;
}

sub _env_or_die {
    my ($name, $src, $key) = @_;
    croak "Config parse error at $src: key '$key' references undefined environment variable '$name'"
        unless exists $ENV{$name};
    return $ENV{$name} // '';
}

sub _home_dir {
    my $home = $ENV{HOME};
    if (!(defined($home) && $home =~ /\S/)) {
        my @pw = getpwuid($<);
        $home = $pw[7] if @pw;
    }
    return $home;
}

sub _expand_home_path {
    my ($val, $src, $key) = @_;
    return $val unless defined $val;
    return $val unless $val =~ m{^~(?:/|$)};

    my $home = _home_dir();
    croak "Config parse error at $src: key '$key' cannot expand '~' (HOME is unset)"
        unless defined($home) && $home =~ /\S/;

    $val =~ s{^~}{$home};
    return $val;
}

sub _parse_track_line {
    my ($line, $src, $lineno) = @_;
    return undef if $line =~ /^\s*$/;

    my ($kind, $path, $rest);

    if ($line =~ /^\s*DIRECTORY\s+(\S+)\s*(?::\s*)?(.*?)\s*$/) {
        ($kind, $path, $rest) = ('directory', $1, $2);
    } elsif ($line =~ /^\s*(\S+)\s*(?::\s*)?(.*?)\s*$/) {
        ($kind, $path, $rest) = ('file', $1, $2);
    } else {
        croak "Config parse error at $src line $lineno: unrecognized track entry: '$line'";
    }

    $path = _expand_track_path($path, $src, $lineno);

    my ($emails_ref, %options) = _parse_rest($rest);
    return { kind => $kind, path => $path, emails => $emails_ref, options => \%options };
}

sub _expand_track_path {
    my ($path, $src, $lineno) = @_;

    # Allow env expansion in track paths for parity with [global] values.
    $path = _expand_env_vars($path, "$src line $lineno", 'track.path');

    if ($path =~ m{^~(?:/|$)}) {
        my $home = _home_dir();
        croak "Config parse error at $src line $lineno: cannot expand '~' in track entry (HOME is unset)"
            unless defined($home) && $home =~ /\S/;
        $path =~ s{^~}{$home};
    }

    croak "Config parse error at $src line $lineno: track path must be absolute after expansion: '$path'"
        unless $path =~ m{^/};

    return $path;
}

sub _parse_rest {
    my ($rest) = @_;
    return ([], ()) unless defined $rest && length $rest;

    my (@emails, %options);
    for my $token (split /\s+/, $rest) {
        next unless length $token;
        if ($token =~ /^(\w+)=(.*)$/) {
            $options{$1} = $2;
        } else {
            push @emails, $token;
        }
    }
    return (\@emails, %options);
}

sub _parse_v1 {
    my ($class, $lines, $src) = @_;
    my @tracks;
    my $lineno = 0;

    for my $line (@$lines) {
        $lineno++;
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;

        # @find-expression [: emails]
        if ($line =~ /^@\s*(.*?)\s*(?::\s*(.*?))?\s*$/) {
            my ($expr, $emails_str) = ($1, $2 // '');
            my @emails = grep { length } split /\s+/, $emails_str;
            push @tracks, {
                kind    => 'directory',
                path    => $expr,
                emails  => \@emails,
                options => { _v1_find_expr => 1 },
            };
            next;
        }

        # [~]/path [: emails]
        if ($line =~ /^(~?\/\S*?)\s*(?::\s*(.*?))?\s*$/) {
            my ($path_raw, $emails_str) = ($1, $2 // '');
            my @emails  = grep { length } split /\s+/, $emails_str;
            my $negated = ($path_raw =~ s/^~//);
            push @tracks, {
                kind    => 'file',
                path    => $path_raw,
                emails  => \@emails,
                options => $negated ? { negated => 1 } : {},
            };
            next;
        }

        carp "changetrack-ng: cannot parse v1 line at $src:$lineno: '$line'";
    }

    return $class->new(version => 1, global => {}, tracks => \@tracks);
}

# global($key) — returns scalar or arrayref depending on key type
sub global {
    my ($self, $key) = @_;
    return $self->{global}{lc $key};
}

# tracks() — arrayref of { kind, path, emails, options }
sub tracks {
    my ($self) = @_;
    return $self->{tracks};
}

# version() — 1 or 2
sub version {
    my ($self) = @_;
    return $self->{version};
}

# dump_v2($path) — write this config as a v2 INI file
sub dump_v2 {
    my ($self, $path) = @_;
    open(my $fh, '>', $path) or croak "Cannot write config '$path': $!";

    say $fh "# changetrack-ng v2 config";
    say $fh "[global]";

    for my $key (sort keys %{ $self->{global} }) {
        my $val = $self->{global}{$key};
        $val = join(' ', @$val) if ref $val eq 'ARRAY';
        say $fh "$key = $val";
    }

    say $fh "";
    say $fh "[track]";

    for my $entry (@{ $self->{tracks} }) {
        my $line = $entry->{kind} eq 'directory'
            ? "DIRECTORY $entry->{path}"
            : $entry->{path};

        if (my @e = @{ $entry->{emails} // [] }) {
            $line .= ' : ' . join(' ', @e);
        }

        for my $opt (sort keys %{ $entry->{options} // {} }) {
            next if $opt =~ /^_/;
            $line .= " $opt=$entry->{options}{$opt}";
        }

        say $fh $line;
    }

    close($fh);
}

# migrate_v1_to_v2($v1_path, $v2_path) — one-shot v1→v2 migration
sub migrate_v1_to_v2 {
    my ($class, $v1_path, $v2_path) = @_;

    my $cfg = $class->load($v1_path);
    croak "Not a v1 config: $v1_path" unless $cfg->version == 1;

    open(my $fh, '>', $v2_path) or croak "Cannot write '$v2_path': $!";

    say $fh "# changetrack-ng v2 config";
    say $fh "# Migrated from v1: $v1_path";
    say $fh "# Review and adjust before use";
    say $fh "";
    say $fh "[global]";
    say $fh "vcs = rcs";
    say $fh "output_dir = /var/lib/changetrack-ng";
    say $fh "notify = email";
    say $fh "email_from = changetrack-ng\@HOSTNAME";
    say $fh "ignore = *.swp *~ *.bak *.dpkg-* *.rpmnew";
    say $fh "sensitive_auto = 1";
    say $fh "sensitive_notify = suppress";
    say $fh "";
    say $fh "[track]";

    for my $entry (@{ $cfg->tracks }) {
        if ($entry->{options}{_v1_find_expr}) {
            say $fh "# TODO: translate find expression manually:";
            say $fh "#   Original: \@ $entry->{path}";
            my $ep = @{ $entry->{emails} } ? ' : ' . join(' ', @{ $entry->{emails} }) : '';
            say $fh "# DIRECTORY /FILL_IN$ep";
        } else {
            my $line = $entry->{options}{negated} ? "# (negated in v1) $entry->{path}" : $entry->{path};
            if (!$entry->{options}{negated} && @{ $entry->{emails} }) {
                $line .= ' : ' . join(' ', @{ $entry->{emails} });
            }
            say $fh $line;
        }
    }

    close($fh);
}

sub _config_hostname {
    state $h;
    return $h if defined $h;
    require ChangeTrack::Util;
    $h = ChangeTrack::Util::fqdn();
    return $h;
}

1;

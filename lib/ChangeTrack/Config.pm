# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Config - INI config parser with subsection-based notifier
#   instances, drop-in directory support, and @include directives.
#
package ChangeTrack::Config;

use strict;
use warnings;

=head1 NAME

ChangeTrack::Config - configuration loader for changetrack-ng

=head1 DESCRIPTION

Parses changetrack-ng INI configuration files.  Supports:

=over 4

=item Sections

C<[global]>, C<[track]>, C<[notifier:E<lt>typeE<gt>]> (name defaults to
C<default>), and C<[notifier:E<lt>typeE<gt>:E<lt>nameE<gt>]>.

=item Drop-in directories

C<conf.d/> (global only), C<track.d/> (track only), C<notifier.d/>
(notifier only) -- siblings of the main config file; C<*.conf> files
processed in sorted order.

=item Include directives

C<@include E<lt>pathE<gt>>, C<@include-track E<lt>pathE<gt>>,
C<@include-notifier E<lt>pathE<gt>>; file or directory path; recursion-safe.

=item Comments

Full-line and inline comments using C<#> or C<;>.  Inline comments must
be preceded by whitespace (e.g. C<timeout = 10  # seconds>).

=back

=head1 METHODS

=over 4

=item ChangeTrack::Config->load($path)

Parse the config file at I<$path> (required), scan sibling drop-in
directories, process C<@include> directives, and return a
C<ChangeTrack::Config> object.  Croaks on any parse error, missing
required field, or I/O failure.

=item $cfg->global($key)

Return the value for a C<[global]> key.  Array-valued keys (C<ignore>,
C<push_remote>) return an arrayref.  All others return a scalar or undef.

=item $cfg->tracks

Return an arrayref of hashrefs, one per C<[track]> entry.  Each hashref
has keys: C<kind> (C<"file"> or C<"directory">), C<path> (absolute
string), C<emails> (arrayref), and C<options> (hashref).

=item $cfg->notifiers

Return a hashref keyed by notifier type, each value being an arrayref of
per-instance config hashrefs for enabled instances only:

  { email => [\%inst, ...], webhook => [...], otlp => [...], file => [...] }

Each instance hashref contains all keys from its C<[notifier:*]> section
plus C<instance_name>.

=back

=cut

use feature qw(say state);
use Carp    qw(croak carp);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

########################################################################
# Schema: allowed keys and their types
########################################################################

my %KNOWN_GLOBAL_KEYS = map { $_ => 1 } qw(
    vcs output_dir push_remote ignore
    sensitive_auto sensitive_notify
    warn_special_files interval
    lock_path lock_timeout command_timeout
);

# Global keys whose values are split into arrayrefs (append across files).
my %ARRAY_GLOBAL_KEYS = map { $_ => 1 } qw(ignore push_remote);

my %BOOL_GLOBAL_KEYS = map { $_ => 1 } qw(sensitive_auto warn_special_files);
my %INT_GLOBAL_KEYS  = map { $_ => 1 } qw(lock_timeout interval command_timeout);
my %PATH_GLOBAL_KEYS = map { $_ => 1 } qw(output_dir lock_path);
my %ENUM_GLOBAL_KEYS = (
    vcs              => { map { $_ => 1 } qw(rcs git fossil svn hg mercurial) },
    sensitive_notify => { map { $_ => 1 } qw(suppress allow) },
);

# Keys allowed in each notifier type.  'enabled' is universal (always required).
my %KNOWN_NOTIFIER_KEYS = (
    email => { map { $_ => 1 } qw(
        enabled to from sendmail_path
    ) },
    webhook => { map { $_ => 1 } qw(
        enabled url full_diff heartbeat insecure timeout max_diff_bytes
    ) },
    otlp => { map { $_ => 1 } qw(
        enabled endpoint headers compression full_diff
        heartbeat timeout insecure resource_attributes
        emit_recipients max_diff_bytes severity_change
        severity_heartbeat severity_warning
    ) },
    file => { map { $_ => 1 } qw(
        enabled path heartbeat full_diff
        emit_recipients max_diff_bytes severity_change
        severity_heartbeat severity_warning
    ) },
);

# Keys in a notifier section that hold space/comma-separated lists.
my %ARRAY_NOTIFIER_KEYS = (
    email   => { to  => 1 },
    webhook => { url => 1 },
    otlp    => {},
    file    => {},
);

my %BOOL_NOTIFIER_KEYS = (
    email   => { enabled => 1 },
    webhook => { map { $_ => 1 } qw(enabled full_diff heartbeat insecure) },
    otlp    => { map { $_ => 1 } qw(enabled full_diff heartbeat insecure emit_recipients) },
    file    => { map { $_ => 1 } qw(enabled heartbeat full_diff emit_recipients) },
);

my %INT_NOTIFIER_KEYS = (
    email   => {},
    webhook => { timeout => 1, max_diff_bytes => 1 },
    otlp    => { timeout => 1, max_diff_bytes => 1 },
    file    => { max_diff_bytes => 1 },
);

my %PATH_NOTIFIER_KEYS = (
    email   => { sendmail_path => 1 },
    webhook => {},
    otlp    => {},
    file    => { path => 1 },
);

my %ENUM_NOTIFIER_KEYS = (
    otlp => { compression => { map { $_ => 1 } qw(gzip none) } },
);

########################################################################
# Constructor and public loader
########################################################################

# new -- Internal constructor; use load() in production code.
sub new {
    my ($class, %args) = @_;
    return bless {
        global         => $args{global}    // {},
        tracks         => $args{tracks}    // [],
        notifiers      => $args{notifiers} // { email => [], webhook => [], otlp => [], file => [] },
        _global_src    => {},   # key => source file path, for cross-file conflict detection
        _notifier_seen => {},   # "type:name" => source path, for duplicate-instance detection
    }, $class;
}

# load -- Parse the main config file, scan sibling drop-in directories, and
# return a ChangeTrack::Config.  Croaks on I/O or parse errors.
sub load {
    my ($class, $path) = @_;

    -f $path or croak "Config file not found: $path";

    my $self    = $class->new;
    my %visited;

    $self->_load_file($path, undef, \%visited);

    # Scan sibling drop-in directories.
    (my $dir = $path) =~ s{/[^/]+$}{};
    $dir = '.' unless length $dir;
    $self->_scan_dropin_dir("$dir/conf.d",     'global',   \%visited);
    $self->_scan_dropin_dir("$dir/track.d",    'track',    \%visited);
    $self->_scan_dropin_dir("$dir/notifier.d", 'notifier', \%visited);

    return $self;
}

########################################################################
# Drop-in directory scanner
########################################################################

# _scan_dropin_dir -- Process *.conf files in $dir with the given section restriction.
sub _scan_dropin_dir {
    my ($self, $dir, $restrict, $visited) = @_;
    return unless -d $dir;

    opendir(my $dh, $dir) or return;
    my @files = sort grep { /\.conf$/ } readdir($dh);
    closedir($dh);

    for my $f (@files) {
        my $full = "$dir/$f";
        next unless -f $full;
        $self->_load_file($full, $restrict, $visited);
    }
}

########################################################################
# File parser
########################################################################

# _load_file -- Parse one config file and merge its content into $self.
# $restrict: undef (any section allowed), 'global', 'track', or 'notifier'.
# $visited:  hashref of absolute paths already loaded (prevents recursion).
sub _load_file {
    my ($self, $path, $restrict, $visited) = @_;

    my $abs = _abs_path($path);
    return if $visited->{$abs}++;

    open(my $fh, '<', $path)
        or croak "Cannot open config '$path': $!";

    # Parser state.
    my $section  = undef;   # 'global', 'track', or 'notifier'
    my $ntype    = undef;   # notifier type when $section eq 'notifier'
    my $nname    = undef;   # notifier instance name
    my %ncurrent;           # accumulator for current notifier section's key-value pairs
    my $lineno   = 0;

    # Flush the in-progress notifier section into $self->{notifiers}.
    my $flush_notifier = sub {
        return unless defined $ntype;
        $self->_flush_notifier_section(\%ncurrent, $ntype, $nname, $path);
        ($ntype, $nname, %ncurrent) = (undef, undef);
    };

    while (my $line = <$fh>) {
        $lineno++;
        chomp $line;
        $line =~ s/\s+$//;

        # Skip blank lines and full-line comments (# or ;).
        next if $line =~ /^\s*(?:[#;].*)?$/;

        # Strip inline comments: # or ; preceded by whitespace.
        $line =~ s/\s+[#;].*//;
        next unless $line =~ /\S/;

        # @include directives.
        if ($line =~ /^\@include(-track|-notifier)?\s+(\S.*?)\s*$/) {
            my ($variant, $inc_path) = ($1 // '', $2);
            $inc_path = _expand_env_vars($inc_path, $path, $lineno);
            $inc_path = _expand_home_path($inc_path, $path, $lineno);

            my $eff_restrict = _include_restrict($restrict, $variant, $path, $lineno);

            if (-d $inc_path) {
                $self->_scan_dropin_dir($inc_path, $eff_restrict, $visited);
            } elsif (-f $inc_path) {
                $self->_load_file($inc_path, $eff_restrict, $visited);
            } else {
                croak "Config error in $path line $lineno: \@include path not found: $inc_path";
            }
            next;
        }

        # Section headers.
        if ($line =~ /^\[(.+)\]\s*$/) {
            $flush_notifier->();
            my $hdr = $1;
            $hdr =~ s/^\s+|\s+$//g;

            if ($hdr eq 'global') {
                _check_section_allowed('global', $restrict, $path, $lineno);
                $section = 'global';
            } elsif ($hdr eq 'track') {
                _check_section_allowed('track', $restrict, $path, $lineno);
                $section = 'track';
            } elsif ($hdr =~ /^notifier:([a-zA-Z]+)(?::(\S*))?$/) {
                my ($t, $n) = (lc($1), $2);
                $n = 'default' if !defined($n) || $n eq '';
                _check_section_allowed('notifier', $restrict, $path, $lineno);
                unless (exists $KNOWN_NOTIFIER_KEYS{$t}) {
                    croak "Config error in $path line $lineno: unknown notifier type '$t'";
                }
                $section  = 'notifier';
                $ntype    = $t;
                $nname    = $n;
                %ncurrent = (instance_name => $nname);
            } else {
                croak "Config error in $path line $lineno: unknown section '[$hdr]'";
            }
            next;
        }

        unless (defined $section) {
            croak "Config error in $path line $lineno: entry appears before any section header: '$line'";
        }

        # Track entries are free-form lines; handle before the key=value check.
        if ($section eq 'track') {
            $self->_parse_and_add_track($line, $path, $lineno);
            next;
        }

        # Key = value pairs (global and notifier sections).
        if ($line =~ /^(\w+)\s*=\s*(.*?)\s*$/) {
            my ($key, $val) = (lc($1), $2);

            if ($section eq 'global') {
                unless ($KNOWN_GLOBAL_KEYS{$key}) {
                    croak "Config error in $path line $lineno: unknown global key '$key'";
                }
                my $host = _config_hostname();
                $val =~ s/\bHOSTNAME\b/$host/g;
                $val = _expand_env_vars($val, $path, $lineno);
                $val = _expand_home_path($val, $path, $lineno) if $PATH_GLOBAL_KEYS{$key};
                $self->_merge_global($key, $val, $path, $lineno);

            } elsif ($section eq 'notifier') {
                unless ($KNOWN_NOTIFIER_KEYS{$ntype}{$key}) {
                    croak "Config error in $path line $lineno: "
                        . "unknown key '$key' for notifier type '$ntype'";
                }
                my $host = _config_hostname();
                $val =~ s/\bHOSTNAME\b/$host/g;
                $val = _expand_env_vars($val, $path, $lineno);
                $val = _expand_home_path($val, $path, $lineno) if $PATH_NOTIFIER_KEYS{$ntype}{$key};

                if ($ARRAY_NOTIFIER_KEYS{$ntype}{$key}) {
                    my @items = grep { length } split /[\s,]+/, $val;
                    push @{ $ncurrent{$key} //= [] }, @items;
                } else {
                    $ncurrent{$key} = $val;
                }
            }
            next;
        }

        croak "Config error in $path line $lineno: unparseable line: '$line'";
    }

    close($fh);
    $flush_notifier->();
}

########################################################################
# Merge helpers
########################################################################

# _merge_global -- Set or append a global key, enforcing cross-file conflict
# rules for scalar keys (error if set in two different files).
sub _merge_global {
    my ($self, $key, $val, $path, $lineno) = @_;

    if ($ARRAY_GLOBAL_KEYS{$key}) {
        my @items = grep { length } split /[\s,]+/, $val;
        push @{ $self->{global}{$key} //= [] }, @items;
        return;
    }

    # Scalar: error on cross-file conflict (same file: last-wins).
    my $prev_src = $self->{_global_src}{$key};
    if (defined $prev_src && $prev_src ne $path) {
        croak "Config error in $path line $lineno: key '$key' was already set in "
            . "$prev_src; scalar global keys may not be set in multiple files";
    }

    $self->{global}{$key}      = _coerce_global_value($key, $val, $path, $lineno);
    $self->{_global_src}{$key} = $path;
}

# _coerce_global_value -- Apply type coercion to a raw string value.
sub _coerce_global_value {
    my ($key, $val, $path, $lineno) = @_;

    if ($BOOL_GLOBAL_KEYS{$key}) {
        return _parse_bool($val, $key, $path, $lineno);
    }
    if ($INT_GLOBAL_KEYS{$key}) {
        croak "Config error in $path line $lineno: '$key' must be an integer (got '$val')"
            unless $val =~ /^\d+$/;
        return $val + 0;
    }
    if (my $allowed = $ENUM_GLOBAL_KEYS{$key}) {
        croak "Config error in $path line $lineno: '$key' has invalid value '$val'"
            unless $allowed->{lc $val};
        return lc $val;
    }
    return $val;
}

# _flush_notifier_section -- Validate and store a completed [notifier:*] section.
# Discards disabled instances.  Croaks on missing 'enabled' or duplicate name.
sub _flush_notifier_section {
    my ($self, $data, $type, $name, $path) = @_;

    unless (exists $data->{enabled}) {
        croak "Config error in $path: [notifier:$type:$name] missing required 'enabled' key";
    }

    my $key = "$type:$name";

    # Coerce key types.
    my %inst = %$data;
    for my $k (keys %inst) {
        next if $k eq 'instance_name';
        next unless ref($inst{$k}) eq '';  # skip arrayrefs (already correct type)
        if ($BOOL_NOTIFIER_KEYS{$type}{$k}) {
            $inst{$k} = _parse_bool($inst{$k}, $k, $path, 0);
        } elsif ($INT_NOTIFIER_KEYS{$type}{$k}) {
            croak "Config error in $path: notifier '$key' key '$k' must be an integer"
                unless $inst{$k} =~ /^\d+$/;
            $inst{$k} += 0;
        } elsif (my $type_enums = $ENUM_NOTIFIER_KEYS{$type}) {
            if (my $allowed = $type_enums->{$k}) {
                croak "Config error in $path: notifier '$key' key '$k' has invalid value '$inst{$k}'"
                    unless $allowed->{lc $inst{$k}};
                $inst{$k} = lc $inst{$k};
            }
        }
    }

    return unless $inst{enabled};   # discard disabled instances; do not reserve the name

    # Reserve the name only for surviving (enabled) instances so a disabled
    # instance does not block a same-named enabled one elsewhere.
    if (exists $self->{_notifier_seen}{$key}) {
        croak "Config error in $path: duplicate notifier instance '$key' "
            . "(first seen in $self->{_notifier_seen}{$key})";
    }
    $self->{_notifier_seen}{$key} = $path;

    push @{ $self->{notifiers}{$type} }, \%inst;
}

########################################################################
# Track-entry parsing
########################################################################

# _parse_and_add_track -- Parse one [track] section line and append to tracks.
sub _parse_and_add_track {
    my ($self, $line, $src, $lineno) = @_;
    return if $line =~ /^\s*$/;
    my $entry = _parse_track_line($line, $src, $lineno);
    push @{ $self->{tracks} }, $entry if defined $entry;
}

# _parse_track_line -- Parse one track entry.
# Formats: "DIRECTORY /path [: emails opts]", "/path [: emails opts]".
# Returns {kind, path, emails, options} or undef.
sub _parse_track_line {
    my ($line, $src, $lineno) = @_;
    return undef if $line =~ /^\s*$/;

    my ($kind, $path, $rest);
    if ($line =~ /^\s*DIRECTORY\s+(\S+)\s*(?::\s*)?(.*?)\s*$/) {
        ($kind, $path, $rest) = ('directory', $1, $2);
    } elsif ($line =~ /^\s*(\S+)\s*(?::\s*)?(.*?)\s*$/) {
        ($kind, $path, $rest) = ('file', $1, $2);
    } else {
        croak "Config error in $src line $lineno: unrecognized track entry: '$line'";
    }

    $path = _expand_track_path($path, $src, $lineno);
    my ($emails_ref, %options) = _parse_rest($rest);
    return { kind => $kind, path => $path, emails => $emails_ref, options => \%options };
}

# _expand_track_path -- Expand env vars and ~ in a track path; enforce absolute.
sub _expand_track_path {
    my ($path, $src, $lineno) = @_;
    $path = _expand_env_vars($path, $src, $lineno);
    if ($path =~ m{^~(?:/|$)}) {
        my $home = _home_dir();
        croak "Config error in $src line $lineno: cannot expand '~' in track path (HOME unset)"
            unless defined($home) && $home =~ /\S/;
        $path =~ s{^~}{$home};
    }
    croak "Config error in $src line $lineno: track path must be absolute: '$path'"
        unless $path =~ m{^/};
    croak "Config error in $src line $lineno: track path may not contain '..': '$path'"
        if grep { $_ eq '..' } split m{/+}, $path;
    return $path;
}

# _parse_rest -- Parse trailing email/option tokens after ':' in a track line.
# Returns (emails_arrayref, %options_hash).
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

########################################################################
# Value expansion helpers
########################################################################

# _expand_env_vars -- Replace ${VAR} references with environment values.
# $src and $lineno are used only for error messages.
sub _expand_env_vars {
    my ($val, $src, $lineno) = @_;
    return $val unless defined $val && $val =~ /\$\{/;
    my $loc = (defined $src && defined $lineno && $lineno) ? "$src line $lineno" : ($src // '');
    $val =~ s/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/_env_or_die($1, $loc)/ge;
    return $val;
}

# _env_or_die -- Return the env var value or croak with context.
sub _env_or_die {
    my ($name, $loc) = @_;
    croak "Config error"
        . ($loc ? " at $loc" : '')
        . ": references undefined environment variable '\${$name}'"
        unless exists $ENV{$name};
    return $ENV{$name} // '';
}

# _expand_home_path -- Expand a leading ~ to the home directory.
sub _expand_home_path {
    my ($val, $src, $lineno) = @_;
    return $val unless defined $val && $val =~ m{^~(?:/|$)};
    my $home = _home_dir();
    my $loc = (defined $src && defined $lineno && $lineno) ? "$src line $lineno" : ($src // '');
    croak "Config error"
        . ($loc ? " at $loc" : '')
        . ": cannot expand '~' (HOME is unset)"
        unless defined($home) && $home =~ /\S/;
    $val =~ s{^~}{$home};
    return $val;
}

# _home_dir -- Return the current user's home directory.
sub _home_dir {
    my $home = $ENV{HOME};
    if (!(defined($home) && $home =~ /\S/)) {
        my @pw = getpwuid($<);
        $home = $pw[7] if @pw;
    }
    return $home;
}

# _config_hostname -- Return the FQDN for HOSTNAME substitution (cached).
sub _config_hostname {
    state $h;
    return $h if defined $h;
    require ChangeTrack::Util;
    $h = ChangeTrack::Util::fqdn();
    return $h;
}

########################################################################
# Type-coercion helpers
########################################################################

# _parse_bool -- Coerce a string to 1 or 0; croak on unrecognised value.
sub _parse_bool {
    my ($val, $key, $path, $lineno) = @_;
    return 1 if $val =~ /^(?:1|true|yes|on)$/i;
    return 0 if $val =~ /^(?:0|false|no|off)$/i;
    my $loc = ($lineno ? "$path line $lineno" : $path);
    croak "Config error in $loc: '$key' must be a boolean (true/false/yes/no/1/0), got '$val'";
}

########################################################################
# @include and section-restriction helpers
########################################################################

# _include_restrict -- Compute the effective section restriction for an
# @include directive.
# - Bare @include:        inherits the parent file's restriction.
# - @include-track:       restricts to 'track'; incompatible with non-track parent.
# - @include-notifier:    restricts to 'notifier'; incompatible with non-notifier parent.
sub _include_restrict {
    my ($parent_restrict, $variant, $path, $lineno) = @_;

    my $req = $variant eq '-track'    ? 'track'
            : $variant eq '-notifier' ? 'notifier'
            :                           undef;

    return $parent_restrict unless defined $req;

    if (defined $parent_restrict && $parent_restrict ne $req) {
        croak "Config error in $path line $lineno: "
            . "\@include-$req is not allowed inside a '$parent_restrict'-restricted file";
    }
    return $req;
}

# _check_section_allowed -- Croak if a section type is forbidden in this file context.
sub _check_section_allowed {
    my ($section_type, $restrict, $path, $lineno) = @_;
    return unless defined $restrict;
    return if $restrict eq $section_type;
    croak "Config error in $path line $lineno: "
        . "[$section_type] section is not allowed in a '$restrict'-restricted file";
}

########################################################################
# Path normalisation (for visited-paths guard only)
########################################################################

# _abs_path -- Return an absolute path string.  Uses Cwd only for relative paths.
sub _abs_path {
    my ($path) = @_;
    return $path if $path =~ m{^/};
    require Cwd;
    return Cwd::abs_path($path) // $path;
}

########################################################################
# Public accessors
########################################################################

# global -- Return the value of a [global] key (scalar or arrayref).
sub global {
    my ($self, $key) = @_;
    return $self->{global}{$key};
}

# tracks -- Return the arrayref of [track] entries.
sub tracks {
    my ($self) = @_;
    return $self->{tracks};
}

# notifiers -- Return the notifiers hashref (type => [\%instance, ...]).
# Only enabled instances are present.
sub notifiers {
    my ($self) = @_;
    return $self->{notifiers};
}

1;

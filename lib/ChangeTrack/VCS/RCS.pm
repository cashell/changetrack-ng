# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::VCS::RCS - Per-file model with colon-encoded flat layout
#   and immediate ci -l.
#

package ChangeTrack::VCS::RCS;

use strict;
use warnings;
=head1 NAME

ChangeTrack::VCS::RCS - RCS VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using RCS.  Stores per-file
C<,v> revision files in C<output_dir> using a colon-encoded flat layout
compatible with the original C<changetrack> format.

=cut

use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak carp);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'per-file' }

# output_path -- Map a real path to its flat mirror location.
# /etc/passwd -> $output_dir/etc:passwd  (colons replace path separators)
sub output_path {
    my ($self, $real_path) = @_;
    (my $flat = $real_path) =~ s{^/}{};
    $flat =~ s{/}{:}g;
    return "$self->{output_dir}/$flat";
}

# _rcs_file -- Return the expected ,v archive path for $real_path.
# $output_dir/RCS/etc:passwd,v
sub _rcs_file {
    my ($self, $real_path) = @_;
    my $op = $self->output_path($real_path);
    return dirname($op) . '/RCS/' . basename($op) . ',v';
}

# _ensure_output_dir -- Create the output directory for $real_path if needed.
sub _ensure_output_dir {
    my ($self, $real_path) = @_;
    my $dir = dirname($self->output_path($real_path));
    make_path($dir, { mode => 0700 }) unless -d $dir;
}

# init -- Create output_dir and RCS/ subdirectory.
sub init {
    my ($self) = @_;
    make_path($self->{output_dir},        { mode => 0700 }) unless -d $self->{output_dir};
    make_path("$self->{output_dir}/RCS",  { mode => 0700 }) unless -d "$self->{output_dir}/RCS";
}

# is_initialized -- Return true if output_dir and RCS/ both exist.
sub is_initialized {
    my ($self) = @_;
    return -d $self->{output_dir} && -d "$self->{output_dir}/RCS";
}

# checkin -- Copy real file to output_path and check in with ci -l.
# For a new file (no ,v yet) passes -t- to suppress the description prompt.
sub checkin {
    my ($self, $real_path, $msg) = @_;
    $msg //= 'changetrack-ng checkin';

    $self->_ensure_output_dir($real_path);
    my $op = $self->output_path($real_path);

    sync_mirror_path($real_path, $op);

    my @cmd = ('ci', '-l', "-m$msg");
    push @cmd, '-t-changetrack-ng' unless -e $self->_rcs_file($real_path);
    push @cmd, $op;

    my $r = run_cmd(cmd => \@cmd);
    croak "ci failed for $op: $r->{stderr}" unless $r->{success};
}

# add / commit -- No-ops for RCS (per-file model; ci does its own commit).
sub add    { }
sub commit { }

# diff -- Copy the real file to output_path and run rcsdiff.
# Returns [] if unchanged, arrayref of unified-diff lines if changed.
# Returns ['(new file)'] if no RCS history exists yet.
sub diff {
    my ($self, $real_path) = @_;

    unless (-e $self->_rcs_file($real_path)) {
        return ['(new file)'];
    }

    $self->_ensure_output_dir($real_path);
    my $op = $self->output_path($real_path);
    sync_mirror_path($real_path, $op);

    my $r = run_cmd(cmd => ['rcsdiff', '-u', $op]);
    return [] if $r->{exit_code} == 0;
    return [split /\n/, $r->{stdout}] if $r->{exit_code} == 1;
    croak "rcsdiff error for $op: $r->{stderr}";
}

# is_dirty -- Return true if the real file differs from the latest RCS revision.
sub is_dirty {
    my ($self, $real_path) = @_;
    return 1 unless -e $self->_rcs_file($real_path);

    $self->_ensure_output_dir($real_path);
    my $op = $self->output_path($real_path);
    sync_mirror_path($real_path, $op);

    my $r = run_cmd(cmd => ['rcsdiff', '-q', $op]);
    return $r->{exit_code} != 0;
}

# log_history -- Return rlog output lines for $real_path.
sub log_history {
    my ($self, $real_path) = @_;
    my $rcs_file = $self->_rcs_file($real_path);
    return ['(no history yet)'] unless -e $rcs_file;
    my $r = run_cmd(cmd => ['rlog', $rcs_file]);
    return [split /\n/, $r->{stdout}];
}

# revert -- Check out revision $rev of $real_path and restore the live file.
sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    my $op = $self->output_path($real_path);
    my $r = run_cmd(cmd => ['co', "-r$rev", '-l', $op]);
    croak "co failed: $r->{stderr}" unless $r->{success};
    restore_mirror_path($op, $real_path);
}

1;

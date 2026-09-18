# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::VCS::Mercurial - Whole-repo using hg -R flag (no chdir
#   needed).
#

package ChangeTrack::VCS::Mercurial;

use strict;
use warnings;
=head1 NAME

ChangeTrack::VCS::Mercurial - Mercurial VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using Mercurial (hg).
Tracked files are copied into a mirror tree under C<output_dir>, which is
an hg repository.

=cut

use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak carp);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

# output_path -- Map a real path to its mirror location.
# /etc/passwd -> $output_dir/etc/passwd  (mirror tree)
sub output_path {
    my ($self, $real_path) = @_;
    my $rel = $self->_mirror_rel($real_path);
    return "$self->{output_dir}/$rel";
}

# _hg -- Run a Mercurial command using -R <output_dir> so no chdir is needed.
sub _hg {
    my ($self, @cmd) = @_;
    return run_cmd(cmd => ['hg', '-R', $self->{output_dir}, @cmd]);
}

# init -- Create the hg repository and write an .hg/hgrc with a commit identity.
sub init {
    my ($self) = @_;
    make_path($self->{output_dir}, { mode => 0700 }) unless -d $self->{output_dir};
    my $r = run_cmd(cmd => ['hg', 'init', $self->{output_dir}]);
    croak "hg init failed: $r->{stderr}" unless $r->{success};

    # Write an hgrc so commits don't require a globally configured user.
    my $hgrc = "$self->{output_dir}/.hg/hgrc";
    open(my $fh, '>', $hgrc) or croak "open $hgrc: $!";
    print $fh "[ui]\nusername = changetrack-ng <changetrack-ng\@localhost>\n";
    close($fh) or croak "close $hgrc: $!";
}

# is_initialized -- Return true if an .hg directory exists in output_dir.
sub is_initialized {
    my ($self) = @_;
    return -d "$self->{output_dir}/.hg";
}

# add -- Copy the real file to the mirror and register it with hg add.
# Only runs 'hg add' for files that appear as untracked ('?') in hg status.
sub add {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);

    # Only invoke 'hg add' for untracked files ('?' prefix in hg status).
    my $st = $self->_hg('status', $mirror);
    if ($st->{stdout} =~ /^\?/m) {
        my $r = $self->_hg('add', $mirror);
        croak "hg add failed: $r->{stderr}" unless $r->{success};
    }
}

# checkin -- Stage the file for the next batch commit (whole-repo model).
sub checkin {
    my ($self, $real_path, $msg) = @_;
    $self->add($real_path);
}

# remove -- Unregister file from Mercurial and remove mirror file.
sub remove {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $st     = $self->_hg('status', $mirror);
    if ($st->{stdout} =~ /^[ MARC]/m) {
        my $r = $self->_hg('rm', '--force', $mirror);
        croak "hg rm failed for '$mirror': $r->{stderr}" unless $r->{success};
    } elsif (-e $mirror || -l $mirror) {
        unlink($mirror) or croak "unlink '$mirror' failed: $!";
    }
}

# commit -- Commit all pending changes with $msg.
# Pushes to any configured push_remote after a successful commit (best-effort).
sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    # Skip if nothing pending.
    my $st = $self->_hg('status', '-mard');
    return unless $st->{stdout} =~ /\S/;

    my $r = $self->_hg('commit', '-m', $msg);
    # hg commit exits 1 with "nothing changed" when everything is already committed.
    return if !$r->{success}
           && ($r->{stdout} =~ /nothing changed/i || $r->{stderr} =~ /nothing changed/i);
    croak "hg commit failed: $r->{stderr}" unless $r->{success};

    my $push_remote = $self->{options}{push_remote};
    return unless defined $push_remote;

    my @remotes = ref($push_remote) eq 'ARRAY' ? @$push_remote : ($push_remote);
    for my $remote (@remotes) {
        my $pr = $self->_hg('push', $remote);
        carp 'hg push ' . ChangeTrack::Util::redact_secrets($remote) . ' failed: ' . ChangeTrack::Util::redact_secrets($pr->{stderr}) unless $pr->{success};
    }
}

# diff -- Return unified diff lines for $real_path.
# Returns ['(new file)'] for untracked or newly-added files; [] if unchanged.
sub diff {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);

    my $st = $self->_hg('status', $mirror);
    return ['(new file)'] if $st->{stdout} =~ /^\?/m || $st->{stdout} =~ /^A/m;

    my $r = $self->_hg('diff', $mirror);
    return ['(new file)'] if $r->{stdout} =~ /^diff\s+-r\s+0{12}\b/m;
    return [] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# is_dirty -- Return true if $real_path has uncommitted changes.
sub is_dirty {
    my ($self, $real_path) = @_;
    return scalar(@{ $self->diff($real_path) }) > 0;
}

# log_history -- Return hg log lines for the mirror path of $real_path.
sub log_history {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    return ['(no history yet)'] unless -e $mirror;
    my $r = $self->_hg('log', $mirror);
    return ['(no history yet)'] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# revert -- Restore $real_path to revision $rev and copy back to live file.
sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    my $mirror = $self->output_path($real_path);
    my $r = $self->_hg('revert', '-r', $rev, '--no-backup', $mirror);
    croak "hg revert failed: $r->{stderr}" unless $r->{success};
    restore_mirror_path($mirror, $real_path);
}

1;

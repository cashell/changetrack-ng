# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
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
an hg repository.  Passes C<-A> during status checks to preserve mirror
isolation against in-tree F<.hgignore> files.  Reverting restores the
live file while keeping the Mercurial mirror clean at tip.

=cut

use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak carp);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

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
# Runs 'hg add' for untracked ('?') or .hgignore-matched ('I') files.
sub add {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);

    # Invoke 'hg add' for untracked ('?') or .hgignore-matched ('I') files.
    my $st = $self->_hg('status', '-A', '--', $mirror);
    if ($st->{stdout} =~ /^[?I]/m) {
        my $r = $self->_hg('add', '--', $mirror);
        croak "hg add failed: $r->{stderr}" unless $r->{success};
    }
}

# remove -- Unregister file from Mercurial and remove mirror file.
sub remove {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $st     = $self->_hg('status', $mirror);
    if ($st->{stdout} =~ /^[ MARC!]/m) {
        my $r = $self->_hg('rm', '--force', $mirror);
        croak "hg rm failed for '$mirror': $r->{stderr}" unless $r->{success};
    } elsif (-e $mirror || -l $mirror) {
        unlink($mirror) or croak "unlink '$mirror' failed: $!";
    }
}

# _normalize_rev -- Normalize rev:node strings (e.g. '1:8f3a9b2c1d4e' -> '8f3a9b2c1d4e').
sub _normalize_rev {
    my ($rev) = @_;
    return undef unless defined $rev;
    $rev =~ s/^\d+:([0-9a-f]+)$/$1/i;
    return $rev;
}

# commit -- Commit all pending changes with $msg.
# Pushes to any configured push_remote after a successful commit (best-effort).
# Returns { committed => 0, revision => undef, warnings => [] } when no changes,
# or { committed => 1, revision => $rev, warnings => \@warnings }.
sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    # Skip if nothing pending.
    my $st = $self->_hg('status', '-mard');
    return { committed => 0, revision => undef, warnings => [] } unless $st->{stdout} =~ /\S/;

    my $r = $self->_hg('commit', '-m', $msg);
    # hg commit exits 1 with "nothing changed" when everything is already committed.
    return { committed => 0, revision => undef, warnings => [] }
        if !$r->{success}
        && ($r->{stdout} =~ /nothing changed/i || $r->{stderr} =~ /nothing changed/i);
    croak "hg commit failed: $r->{stderr}" unless $r->{success};

    my $rev_r = $self->_hg('log', '-r', '.', '-T', '{node|short}');
    my $rev   = ($rev_r->{success} && $rev_r->{stdout} =~ /(\S+)/) ? $1 : undef;

    my @push_warnings;
    my $push_remote = $self->{options}{push_remote};
    if (defined $push_remote) {
        my @remotes = ref($push_remote) eq 'ARRAY' ? @$push_remote : ($push_remote);
        for my $remote (@remotes) {
            my $pr = $self->_hg('push', $remote);
            unless ($pr->{success}) {
                my $warn_msg = 'hg push ' . ChangeTrack::Util::redact_secrets($remote) . ' failed: ' . ChangeTrack::Util::redact_secrets($pr->{stderr});
                $warn_msg =~ s/\s+$//;
                carp $warn_msg;
                push @push_warnings, $warn_msg;
            }
        }
    }

    return { committed => 1, revision => $rev, warnings => \@push_warnings };
}

# diff -- Return unified diff lines for $real_path.
# Returns ['(new file)'] for untracked or newly-added files; [] if unchanged.
sub diff {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    return ['(new file)'] unless -e $mirror;

    my $st = $self->_hg('status', '-A', '--', $mirror);
    return ['(new file)'] if $st->{stdout} =~ /^[?IA]/m;

    return $self->_with_temp_mirror_sync($real_path, $mirror, sub {
        my $r = $self->_hg('diff', $mirror);
        croak "hg diff failed: $r->{stderr}" unless $r->{success};
        return ['(new file)'] if $r->{stdout} =~ /^diff\s+-r\s+0{12}\b/m;
        return [] unless $r->{stdout} =~ /\S/;
        return [split /\n/, $r->{stdout}];
    });
}

# log_history -- Return hg log lines for the mirror path of $real_path.
sub log_history {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $r = $self->_hg('log', $mirror);
    return ['(no history yet)'] unless $r->{success} && $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# revert -- Restore $real_path to revision $rev via hg cat,
# restoring to the live path while leaving the Mercurial mirror clean at tip.
sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    $rev = _normalize_rev($rev);
    croak "unsafe revision: $rev" if $rev =~ /^-/;

    my $mirror = $self->output_path($real_path);
    my $r = $self->_hg('cat', '-r', $rev, $mirror);
    croak "hg cat failed: $r->{stderr}" unless $r->{success};

    my ($tmp_fh, $tmp_file) = File::Temp::tempfile(CLEANUP => 1);
    binmode($tmp_fh);
    print {$tmp_fh} $r->{stdout};
    close($tmp_fh);

    restore_mirror_path($tmp_file, $real_path);
}

# metadata_at_revision -- Retrieve historical metadata record for $real_path
# at $rev from .changetrack-metadata in Mercurial history.
sub metadata_at_revision {
    my ($self, $real_path, $rev) = @_;
    return undef unless defined $rev && length $rev;
    $rev = _normalize_rev($rev);
    return undef if $rev =~ /^-/;

    my $target = "$self->{output_dir}/.changetrack-metadata";
    my $r = $self->_hg('cat', '-r', $rev, $target);
    return undef unless $r->{success};
    return $self->_parse_metadata_jsonl($r->{stdout}, $real_path);
}

1;

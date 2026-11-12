# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher+github@zyp.org>
#######################################################################
# ChangeTrack::VCS::Git - Whole-repo mirror model with batch commits and
#   optional push_remote.
#

package ChangeTrack::VCS::Git;

use strict;
use warnings;
=head1 NAME

ChangeTrack::VCS::Git - Git VCS backend for changetrack-ng

=head1 DESCRIPTION

Implements the L<ChangeTrack::VCS::Base> interface using Git.  Tracked files
are copied into a mirror tree under C<output_dir> and committed as a batch.
Mirror isolation protections ensure tracked attributes (via F<.git/info/attributes>
neutralization) and ignore rules (via C<git add -f>) do not suppress tracking.
Supports optional push to one or more remotes after each commit.
Reverting restores the live file while keeping the Git mirror and index clean at HEAD.

=cut

use parent 'ChangeTrack::VCS::Base';
use Carp qw(croak carp);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use ChangeTrack::Util qw(run_cmd sync_mirror_path restore_mirror_path);

our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

sub model { 'whole-repo' }

# init -- Initialize a new git repository in output_dir and configure a
# minimal user identity so commits succeed without a global git config.
sub init {
    my ($self) = @_;
    make_path($self->{output_dir}, { mode => 0700 }) unless -d $self->{output_dir};
    my $r = run_cmd(cmd => ['git', 'init', $self->{output_dir}]);
    croak "git init failed: $r->{stderr}" unless $r->{success};
    my $name  = $self->{options}{git_user}  // 'changetrack-ng';
    my $email = $self->{options}{git_email} // 'changetrack-ng@localhost';
    my $cn = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'config', 'user.name',  $name]);
    carp "git config user.name failed: $cn->{stderr}"  unless $cn->{success};
    my $ce = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'config', 'user.email', $email]);
    carp "git config user.email failed: $ce->{stderr}" unless $ce->{success};
    $self->_ensure_attributes_neutralized;
}

# is_initialized -- Return true if a .git directory exists in output_dir.
sub is_initialized {
    my ($self) = @_;
    return -d "$self->{output_dir}/.git";
}

# _ensure_attributes_neutralized -- Write .git/info/attributes so mirrored
# .gitattributes files cannot alter stored bytes (eol/ident/filter) or hide diffs.
sub _ensure_attributes_neutralized {
    my ($self) = @_;
    return if $self->{_attrs_ok};
    my $git_dir = "$self->{output_dir}/.git";
    return unless -d $git_dir;
    my $info_dir   = "$git_dir/info";
    my $attrs_file = "$info_dir/attributes";
    my $rule       = '* !text !eol !ident !filter !diff';
    if (-f $attrs_file && open(my $rfh, '<', $attrs_file)) {
        my $cur = do { local $/; <$rfh> } // '';
        close($rfh);
        if (index($cur, $rule) >= 0) {
            $self->{_attrs_ok} = 1;
            return;
        }
    }
    make_path($info_dir, { mode => 0700 }) unless -d $info_dir;
    open(my $wfh, '>>', $attrs_file) or do {
        carp "Cannot write $attrs_file: $!";
        return;
    };
    print {$wfh} "$rule\n";
    close($wfh) or carp "Cannot close $attrs_file: $!";
    $self->{_attrs_ok} = 1;
}

# add -- Copy the real file to the mirror tree and stage it with git add.
sub add {
    my ($self, $real_path) = @_;
    $self->_ensure_attributes_neutralized;
    my $mirror = $self->output_path($real_path);
    make_path(dirname($mirror), { mode => 0700 }) unless -d dirname($mirror);
    sync_mirror_path($real_path, $mirror);
    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'add', '-f', '--', $mirror]);
    croak "git add failed: $r->{stderr}" unless $r->{success};
}

# remove -- Unlink mirror file and stage removal from Git.
sub remove {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    if (-e $mirror || -l $mirror) {
        unlink($mirror) or croak "unlink '$mirror' failed: $!";
    }
    my $in_head = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'cat-file', '-e', "HEAD:$rel"]);
    if ($in_head->{success}) {
        my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rm', '-f', '--', $rel]);
        croak "git rm failed for '$rel': $r->{stderr}" unless $r->{success};
    }
}

# commit -- Commit all staged changes with $msg.
# No-ops and returns { committed => 0, revision => undef, warnings => [] }
# if nothing is staged.  After a successful commit, pushes to each configured
# push_remote (best-effort; failures warn and append to warnings arrayref).
# Returns { committed => 1, revision => $rev, warnings => \@warnings }.
sub commit {
    my ($self, $msg) = @_;
    $msg //= 'changetrack-ng commit';

    my $staged = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'diff', '--cached', '--quiet']);
    # 'git diff --quiet' exits 0 (no staged changes) or 1 (staged changes);
    # anything else (or an exec failure) is a real error, not "has changes".
    croak "git diff --cached failed: $staged->{stderr}"
        unless $staged->{exit_code} == 0 || $staged->{exit_code} == 1;
    return { committed => 0, revision => undef, warnings => [] } if $staged->{exit_code} == 0;

    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'commit', '-m', $msg]);
    croak "git commit failed: $r->{stderr}" unless $r->{success};
    $self->{_has_head} = 1;

    my $rev_r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rev-parse', '--short=12', 'HEAD']);
    my $rev   = ($rev_r->{success} && $rev_r->{stdout} =~ /(\S+)/) ? $1 : undef;

    my @push_warnings;
    my $push_remote = $self->{options}{push_remote};
    if (defined $push_remote) {
        my @remotes = ref($push_remote) eq 'ARRAY' ? @$push_remote : ($push_remote);
        my $branch_r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rev-parse', '--abbrev-ref', 'HEAD']);
        my $branch   = ($branch_r->{success} && $branch_r->{stdout} =~ /(\S+)/) ? $1 : 'main';

        for my $remote (@remotes) {
            my $pr = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'push', $remote, "HEAD:refs/heads/$branch"]);
            unless ($pr->{success}) {
                my $warn_msg = 'git push ' . ChangeTrack::Util::redact_secrets($remote) . ' failed: ' . ChangeTrack::Util::redact_secrets($pr->{stderr});
                $warn_msg =~ s/\s+$//;
                carp $warn_msg;
                push @push_warnings, $warn_msg;
            }
        }
    }

    return { committed => 1, revision => $rev, warnings => \@push_warnings };
}

# _has_head -- Return true if the repository has at least one commit (cached).
sub _has_head {
    my ($self) = @_;
    return 1 if $self->{_has_head};
    my $head = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'rev-parse', '--verify', 'HEAD']);
    if ($head->{success}) {
        $self->{_has_head} = 1;
        return 1;
    }
    return 0;
}

# diff -- Return unified diff lines for $real_path vs HEAD.
# Returns ['(new file)'] if the file has no prior commit; [] if unchanged.
sub diff {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    return ['(new file)'] unless -e $mirror;
    return ['(new file)'] unless $self->_has_head;

    my $rel     = $self->_rel_path($mirror);
    my $in_head = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'cat-file', '-e', "HEAD:$rel"]);
    return ['(new file)'] unless $in_head->{success};

    return $self->_with_temp_mirror_sync($real_path, $mirror, sub {
        my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'diff', '--no-color', 'HEAD', '--', $mirror]);
        croak "git diff failed: $r->{stderr}" unless $r->{success};
        return [] unless $r->{stdout} =~ /\S/;
        return [split /\n/, $r->{stdout}];
    });
}

# log_history -- Return git log lines for the mirror path of $real_path.
sub log_history {
    my ($self, $real_path) = @_;
    my $mirror = $self->output_path($real_path);
    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'log', '--no-color', '--', $mirror]);
    return ['(no history yet)'] unless $r->{stdout} =~ /\S/;
    return [split /\n/, $r->{stdout}];
}

# revert -- Restore $real_path to revision $rev via git show,
# restoring to the live path while leaving the mirror tree and index clean at HEAD.
sub revert {
    my ($self, $real_path, $rev) = @_;
    croak 'revert: revision required' unless defined $rev;
    croak "unsafe revision: $rev" if $rev =~ /^-/;

    my $mirror = $self->output_path($real_path);
    my $rel    = $self->_rel_path($mirror);
    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'show', "$rev:$rel"]);
    croak "git show failed: $r->{stderr}" unless $r->{success};

    my ($tmp_fh, $tmp_file) = File::Temp::tempfile(CLEANUP => 1);
    binmode($tmp_fh);
    print {$tmp_fh} $r->{stdout};
    close($tmp_fh);

    restore_mirror_path($tmp_file, $real_path);
}

# metadata_at_revision -- Retrieve historical metadata record for $real_path
# at $rev from .changetrack-metadata in Git history.
sub metadata_at_revision {
    my ($self, $real_path, $rev) = @_;
    return undef unless defined $rev && length $rev;
    return undef if $rev =~ /^-/;

    my $r = run_cmd(cmd => ['git', '-C', $self->{output_dir}, 'show', "$rev:.changetrack-metadata"]);
    return undef unless $r->{success};
    return $self->_parse_metadata_jsonl($r->{stdout}, $real_path);
}

1;

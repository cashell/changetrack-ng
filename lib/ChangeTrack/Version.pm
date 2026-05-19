# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# ChangeTrack::Version - Single-source version authority for all modules.
#

package ChangeTrack::Version;

use strict;
use warnings;
=head1 NAME

ChangeTrack::Version - single-source version authority for changetrack-ng

=head1 DESCRIPTION

Defines C<$ChangeTrack::Version::VERSION>, the authoritative version string
for all ChangeTrack:: modules.  Every other module derives its C<$VERSION>
from this file via:

    our $VERSION = do { require ChangeTrack::Version; $ChangeTrack::Version::VERSION };

When bumping the version, update this file, C<Makefile>, C<CHANGELOG.md>,
C<packaging/>, and C<PRODUCT.md> in sync.  See C<CLAUDE.md> for the full
list of files to keep in sync.

=cut

# Single authoritative version string for all ChangeTrack:: modules.
# The Makefile VERSION variable is the build-system authority; keep in sync.
our $VERSION = '0.6.0';

1;

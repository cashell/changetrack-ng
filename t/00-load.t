use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Config');
use_ok('ChangeTrack::Util');
use_ok('ChangeTrack::Report');
use_ok('ChangeTrack::Metadata');
use_ok('ChangeTrack::Lock');
use_ok('ChangeTrack::Notify::Base');
use_ok('ChangeTrack::Notify::Email');
use_ok('ChangeTrack::Notify::File');
use_ok('ChangeTrack::Notify::Webhook');

# Verify exports from Util
can_ok('ChangeTrack::Util', 'hostname');
can_ok('ChangeTrack::Util', 'run_cmd');

# Verify Config API surface
can_ok('ChangeTrack::Config', 'load');
can_ok('ChangeTrack::Config', 'migrate_v1_to_v2');

my $cfg = ChangeTrack::Config->new;
isa_ok($cfg, 'ChangeTrack::Config');
can_ok($cfg, 'global');
can_ok($cfg, 'tracks');
can_ok($cfg, 'version');
can_ok($cfg, 'dump_v2');

is($cfg->version, 2, 'default version is 2');
is_deeply($cfg->tracks, [], 'default tracks is empty arrayref');

# Notify::Base API surface
can_ok('ChangeTrack::Notify::Base', 'new');
can_ok('ChangeTrack::Notify::Base', 'send');
can_ok('ChangeTrack::Notify::Base', 'send_changes');
can_ok('ChangeTrack::Notify::Base', 'send_heartbeat');
can_ok('ChangeTrack::Notify::Base', 'heartbeat_enabled');
can_ok('ChangeTrack::Notify::Base', 'name');

# Lock API surface
can_ok('ChangeTrack::Lock', 'new');
can_ok('ChangeTrack::Lock', 'acquire');
can_ok('ChangeTrack::Lock', 'release');

# Email heartbeat contract
my $email = ChangeTrack::Notify::Email->new;
ok(!$email->heartbeat_enabled, 'Email heartbeat always off');

# File heartbeat contract
my $file_n = ChangeTrack::Notify::File->new(log_path => '/dev/null');
ok(!$file_n->heartbeat_enabled, 'File heartbeat off by default');
my $file_hb = ChangeTrack::Notify::File->new(log_path => '/dev/null', file_heartbeat => 1);
ok($file_hb->heartbeat_enabled, 'File heartbeat on when configured');

# Webhook heartbeat contract
my $wh = ChangeTrack::Notify::Webhook->new(webhook_url => '');
ok(!$wh->heartbeat_enabled, 'Webhook heartbeat off by default');
my $wh_hb = ChangeTrack::Notify::Webhook->new(webhook_url => '', webhook_heartbeat => 1);
ok($wh_hb->heartbeat_enabled, 'Webhook heartbeat on when configured');

done_testing();

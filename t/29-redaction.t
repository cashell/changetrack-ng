# vim: ts=4 sw=4 et sm ai smd sc bg=dark
# perltidy -i=4 -vt=1 -vtc=0 -lp -cti=1 -cab=1 -nbbc -csc -b
#######################################################################
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
#######################################################################
# 29-redaction.t - Tests for secret redaction in logs (CTNG-02..05) and
#   OTLP header CRLF-injection stripping (CTNG-10).
#
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Spec;
use lib File::Spec->catdir($RealBin, '..', 'lib');

use_ok('ChangeTrack::Util', qw(redact_secrets redact_url run_cmd set_debug));
use_ok('ChangeTrack::Notify::OTLP');

########################################################################
# redact_secrets: URI userinfo and token-like parameters
########################################################################

is(
    redact_secrets('git push https://alice:s3cr3t@github.com/o/r.git'),
    'git push https://***@github.com/o/r.git',
    'redact_secrets masks URI userinfo but keeps host and path'
);

is(
    redact_secrets('https://host/p?token=ABC123&page=2'),
    'https://host/p?token=***&page=2',
    'redact_secrets masks token query parameter'
);

like(
    redact_secrets('curl -H x https://h/?access_token=zzz&password=pw'),
    qr/access_token=\*\*\*.*password=\*\*\*/,
    'redact_secrets masks multiple secret parameters'
);

is(redact_secrets('plain value, no secret'), 'plain value, no secret',
    'redact_secrets leaves non-secret text unchanged');
is(redact_secrets(undef), undef, 'redact_secrets passes undef through');

unlike(redact_secrets('https://u:tok@h/r'), qr/tok/,
    'redact_secrets removes the secret token entirely');

########################################################################
# redact_url: drop userinfo, path, and query (path-embedded secrets)
########################################################################

is(redact_url('https://hooks.slack.com/services/T1/B2/SECRETTOKEN'),
    'https://hooks.slack.com/...',
    'redact_url drops the secret-bearing webhook path');

is(redact_url('https://user:pass@host:8443/path?token=q'),
    'https://host:8443/...',
    'redact_url drops userinfo, path, and query');

is(redact_url(''),    '(none)',     'redact_url handles empty string');
is(redact_url(undef), '(none)',     'redact_url handles undef');
unlike(redact_url('https://h/services/SECRETTOKEN'), qr/SECRETTOKEN/,
    'redact_url removes path-embedded secret');

########################################################################
# run_cmd debug trace must not leak credentials in command arguments
########################################################################

{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    set_debug(1);
    # Command almost certainly fails to exec; the redacted trace is emitted
    # regardless of whether the binary exists.
    run_cmd(cmd => ['definitely-not-a-real-binary-xyz', 'push',
            'https://bob:tok3n@example.com/repo.git']);
    set_debug(0);
    my $all = join('', @warnings);
    like($all, qr/\[DEBUG\]/, 'debug trace was emitted');
    unlike($all, qr/tok3n/, 'run_cmd debug trace does not leak the token');
    like($all, qr{https://\*\*\*\@example\.com}, 'run_cmd debug trace masks userinfo');
}

########################################################################
# OTLP header parsing strips CR/LF/NUL (CRLF injection defense)
########################################################################

{
    my %h = ChangeTrack::Notify::OTLP::_parse_env_headers(
        "Authorization=Bearer abc%0D%0AX-Injected: evil,Other=ok");
    ok(exists $h{Authorization}, 'env header parsed');
    unlike($h{Authorization}, qr/[\r\n]/,
        'env header value has no CR/LF after percent-decode');
    is($h{Authorization}, 'Bearer abcX-Injected: evil',
        'CRLF removed, remaining text folded into the single value');
    ok(!exists $h{'X-Injected'}, 'no injected header key created');
}

{
    my %h = ChangeTrack::Notify::OTLP::_parse_config_headers(
        "Authorization=Bearer\rzzz");
    unlike($h{Authorization} // '', qr/[\r\n]/,
        'config header value has no CR/LF');
}

done_testing();

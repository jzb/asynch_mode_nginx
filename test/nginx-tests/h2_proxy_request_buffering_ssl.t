#!/usr/bin/perl

# Copyright (C) Intel, Inc.
# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for HTTP/2 protocol with unbuffered request body to ssl backend.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_ssl http_v2 proxy/)
	->has_daemon('openssl');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080 http2;
        server_name  localhost;
        %%PROXY_ASYNCH_ENABLE%%

        location / {
            proxy_request_buffering off;
            proxy_pass https://127.0.0.1:8082;
            client_body_buffer_size 512;
        }
        location /chunked {
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_pass https://127.0.0.1:8082;
            client_body_buffer_size 512;
        }
    }

    server {
        listen       127.0.0.1:8082 ssl %%SSL_ASYNCH%%;
        server_name  localhost;

        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;

        location / {
            proxy_request_buffering off;
            proxy_pass http://127.0.0.1:8081/;
            client_body_buffer_size 1k;
        }
        location /chunked {
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_pass http://127.0.0.1:8081/;
            client_body_buffer_size 1k;
        }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->run();
$t->plan(40);

###############################################################################

# unbuffered request body

my $f = get_body('/', 'content-length' => 10);
ok($f->{headers}, 'request');
is($f->{upload}('01234', body_more => 1), '01234', 'part');
is($f->{upload}('56789'), '56789', 'part 2');
is($f->{http_end}(), 200, 'response');

$f = get_body('/', 'content-length' => 1536);
ok($f->{headers}, 'buffer');
is($f->{upload}('0123' x 128, body_more => 1), '0123' x 128, 'buffer - below');
is($f->{upload}('4567' x 128, body_more => 1), '4567' x 128, 'buffer - equal');
is($f->{upload}('89AB' x 128), '89AB' x 128, 'buffer - above');
is($f->{http_end}(), 200, 'buffer - response');

$f = get_body('/', 'content-length' => 18);
ok($f->{headers}, 'many');
is($f->{upload}('01234many', body_split => [ 5 ], body_more => 1),
	'01234many', 'many - part');
is($f->{upload}('56789many', body_split => [ 5 ]),
	'56789many', 'many - part 2');
is($f->{http_end}(), 200, 'many - response');

$f = get_body('/', 'content-length' => 0);
ok($f->{headers}, 'empty');
is($f->{upload}('', body_more => 1, wait => 0.2), '', 'empty - part');
is($f->{upload}('', wait => 0.2), '', 'empty - part 2');
is($f->{http_end}(), 200, 'empty - response');

$f = get_body('/', 'content-length' => 10);
ok($f->{headers}, 'split');
is($f->{upload}('0123456789', split => [ 14 ]), '0123456789', 'split');
is($f->{http_end}(), 200, 'split - response');

# unbuffered request body, chunked transfer-encoding

$f = get_body('/chunked');
ok($f->{headers}, 'chunk');
is($f->{upload}('01234', body_more => 1), '5' . CRLF . '01234' . CRLF,
	'chunked - part');
is($f->{upload}('56789'), '5' . CRLF . '56789' . CRLF . '0' . CRLF . CRLF,
	'chunked - part 2');
is($f->{http_end}(), 200, 'chunked - response');

$f = get_body('/chunked');
ok($f->{headers}, 'chunked buffer');
is($f->{upload}('0123' x 64, body_more => 1),
	'100' . CRLF . '0123' x 64 . CRLF, 'chunked buffer - below');
is($f->{upload}('4567' x 64, body_more => 1),
	'100' . CRLF . '4567' x 64 . CRLF, 'chunked buffer - equal');
is($f->{upload}('89AB' x 64),
	'100' . CRLF . '89AB' x 64 . CRLF . '0' . CRLF . CRLF,
	'chunked buffer - above');
is($f->{http_end}(), 200, 'chunked buffer - response');

$f = get_body('/chunked');
ok($f->{headers}, 'chunked many');
is($f->{upload}('01234many', body_split => [ 5 ], body_more => 1),
	'9' . CRLF . '01234many' . CRLF, 'chunked many - part');
is($f->{upload}('56789many', body_split => [ 5 ]),
	'9' . CRLF . '56789many' . CRLF . '0' . CRLF . CRLF,
	'chunked many - part 2');
is($f->{http_end}(), 200, 'chunked many - response');

$f = get_body('/chunked');
ok($f->{headers}, 'chunked empty');
is($f->{upload}('', body_more => 1, wait => 0.2), '', 'chunked empty - part');
is($f->{upload}(''), '0' . CRLF . CRLF, 'chunked empty - part 2');
is($f->{http_end}(), 200, 'chunked empty - response');

$f = get_body('/chunked');
ok($f->{headers}, 'chunked split');
is(http_content($f->{upload}('0123456789', split => [ 14 ])),
	'0123456789', 'chunked split');
is($f->{http_end}(), 200, 'chunked split - response');

###############################################################################

sub http_content {
	my ($body) = @_;
	my $content = '';

	while ($body =~ /\G\x0d?\x0a?([0-9a-f]+)\x0d\x0a?/gcmsi) {
		my $len = hex($1);
		$content .= substr($body, pos($body), $len);
		pos($body) += $len;
	}

	return $content;
}

sub get_body {
	my ($url, %extra) = @_;
	my ($server, $client, $f);

	$server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1',
		LocalPort => port(8081),
		Listen => 5,
		Timeout => 3,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	my $s = Test::Nginx::HTTP2->new();
	my $sid = exists $extra{'content-length'}
		? $s->new_stream({ headers => [
			{ name => ':method', value => 'GET' },
			{ name => ':scheme', value => 'http' },
			{ name => ':path', value => $url, },
			{ name => ':authority', value => 'localhost' },
			{ name => 'content-length',
				value => $extra{'content-length'} }],
			body_more => 1 })
		: $s->new_stream({ path => $url, body_more => 1 });

	$client = $server->accept() or return;

	log2c("(new connection $client)");

	$f->{headers} = backend_read($client);

	my $chunked = $f->{headers} =~ /chunked/;

	$f->{upload} = sub {
		my ($body, %extra) = @_;
		my $len = length($body);
		my $wait = $extra{wait};

		$s->h2_body($body, { %extra });

		$body = '';

		for (1 .. 10) {
			my $buf = backend_read($client, $wait) or return '';
			$body .= $buf;

			my $got = 0;
			$got += $chunked ? hex $_ : $_ for $chunked
				? $body =~ /(\w+)\x0d\x0a?\w+\x0d\x0a?/g
				: length($body);
			next if $chunked && !$extra{body_more}
				&& $buf !~ /^0\x0d\x0a?/m;
			last if $got >= $len;
		}

		return $body;
	};
	$f->{http_end} = sub {
		$client->write(<<EOF);
HTTP/1.1 200 OK
Connection: close

EOF

		$client->close;

		my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
		my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
		return $frame->{headers}->{':status'};
	};
	return $f;
}

sub backend_read {
	my ($s, $timo) = @_;
	my $buf = '';

	if (IO::Select->new($s)->can_read($timo || 8)) {
		$s->sysread($buf, 16384) or return;
		log2i($buf);
	}
	return $buf;
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################

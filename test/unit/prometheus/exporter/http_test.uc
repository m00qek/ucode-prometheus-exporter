'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { inflate } from 'zlib';
import * as http from 'prometheus.exporter.http';

const TEXT = 'node_load1 0.75\nnode_load5 0.5\n';
const OK = { status: '200 OK', content_type: 'text/plain; version=0.0.4; charset=utf-8', body: TEXT };

const CODING = gen.elements('gzip', 'x-gzip', 'GZIP', 'deflate', 'br', 'identity', 'zstd', '*');
const Q = gen.elements(null, '0', '0.0', '0.000', '0.5', '1', '1.0', '0.001', 'x', '2');

// What RFC 9110 says of a coding's q: not 0, and a qvalue.
function q_ok(q) {
	return q == null || (match(q, /^(0(\.[0-9]{0,3})?|1(\.0{0,3})?)$/) && !match(q, /^0(\.0*)?$/));
}

describe('http.accepts_gzip', () => {
	it('takes what Prometheus, vmagent and curl send', () => {
		assert.match([ true, true, true, true ], map([
			'gzip', 'gzip, deflate', 'gzip, deflate, br', 'deflate, gzip;q=1.0, *;q=0.5',
		], http.accepts_gzip));
	});

	it('refuses no header, other codings, gzip;q=0, and a q that is not a qvalue', () => {
		assert.match([ false, false, false, false, false, false, false ], map([
			null, '', 'identity', 'deflate, br', 'gzip;q=0', 'gzip;q=0.000, *', 'gzip;q=high',
		], http.accepts_gzip));
	});

	it('takes * unless gzip is named, and x-gzip as gzip', () => {
		assert.match([ true, false, true, false ], map([ '*', 'gzip;q=0, *', 'x-gzip', '*;q=0' ], http.accepts_gzip));
	});

	prop('takes gzip exactly when a coding for it, or * without one, has a q that is not 0',
		gen.array(gen.tuple(CODING, Q), { min_len: 0, max_len: 4 }), (parts) => {
			let header = join(', ', map(parts, (p) => p[0] + (p[1] != null ? `;q=${p[1]}` : '')));
			let named = filter(parts, (p) => lc(p[0]) in [ 'gzip', 'x-gzip' ]);
			let star = filter(parts, (p) => p[0] == '*');
			let want = length(named) ? length(filter(named, (p) => q_ok(p[1]))) > 0 : length(filter(star, (p) => q_ok(p[1]))) > 0;

			assert.match(want, http.accepts_gzip(header), header);
		});
});

describe('http.header', () => {
	it('reads a header of uhttpd-mod-ucode\'s env, named in lower case', () => {
		let env = { headers: { 'accept-encoding': 'gzip', 'x-list': [ 'a' ] } };

		assert.match([ 'gzip', null, null, null ],
			[ http.header(env, 'accept-encoding'), http.header(env, 'authorization'), http.header(env, 'x-list'), http.header(null, 'a') ]);
	});
});

describe('http.scrape_reply', () => {
	it('gzips a scrape the scraper takes gzip for, and says the reply varies by Accept-Encoding', () => {
		let r = http.scrape_reply(OK, 'gzip', true);

		assert.match({ status: '200 OK', headers: [
			[ 'Content-Type', OK.content_type ], [ 'Vary', 'Accept-Encoding' ], [ 'Content-Encoding', 'gzip' ],
		] }, { status: r.status, headers: r.headers });
		assert.match([ '\x1f\x8b', TEXT ], [ substr(r.body, 0, 2), inflate(r.body) ]);
	});

	it('sends it plain when not asked, and still varies', () => {
		assert.match({ status: '200 OK', headers: [ [ 'Content-Type', OK.content_type ], [ 'Vary', 'Accept-Encoding' ] ], body: TEXT },
			http.scrape_reply(OK, null, true));
	});

	it('never compresses with compress off, nor says it varies', () => {
		assert.match({ status: '200 OK', headers: [ [ 'Content-Type', OK.content_type ] ], body: TEXT },
			http.scrape_reply(OK, 'gzip', false));
	});

	it('sends an error plain', () => {
		let bad = { ...OK, status: '400 Bad Request', body: 'COLLECTOR_INVALID\n' };

		assert.match('COLLECTOR_INVALID\n', http.scrape_reply(bad, 'gzip', true).body);
	});

	prop('gives back the text, gzipped or not', gen.tuple(gen.ascii({ min_len: 0, max_len: 300 }), gen.bool(), gen.bool()), (t) => {
		let r = http.scrape_reply({ ...OK, body: t[0] }, t[1] ? 'gzip' : 'identity', t[2]);

		assert.match(t[0], (t[1] && t[2]) ? inflate(r.body) : r.body);
	});
});

describe('http.head', () => {
	it('writes the Status line and the headers as CGI does, then a blank line', () => {
		assert.match('Status: 401 Unauthorized\r\nContent-Type: text/plain; charset=utf-8\r\nWWW-Authenticate: Basic realm="x"\r\n\r\n',
			http.head(http.text_reply('401 Unauthorized', 'Unauthorized.\n', [ [ 'WWW-Authenticate', 'Basic realm="x"' ] ])));
	});
});

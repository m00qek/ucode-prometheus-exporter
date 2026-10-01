'use strict';

// HTTP for uhttpd's handler: what a request's headers ask (uhttpd-mod-ucode
// hands them as env.headers, named in lower case), a scrape's reply
// gzip-compressed when the scraper takes it (as node_exporter does), and the
// head uhttpd reads off what the handler sends: CGI's, a Status line and the
// headers.
//
// A reply is { status, headers: [ [ name, value ] ], body }.

import { deflate } from 'zlib';

// zlib's level: 1, the fastest. A scrape's text shrinks almost as much at the
// default level, 6, which takes longer.
export const GZIP_LEVEL = 1;

// A request header's value, or null; `name` in lower case.
export function header(env, name) {
	let v = env?.headers?.[name];

	return (type(v) == 'string') ? v : null;
};

// A qvalue that is not 0 (RFC 9110, 12.4.2); null for one that is not a qvalue.
function positive(q) {
	if (!match(q, /^(0(\.[0-9]{0,3})?|1(\.0{0,3})?)$/))
		return null;

	return !match(q, /^0(\.0*)?$/);
}

// Whether an Accept-Encoding takes gzip (RFC 9110, 12.5.3): gzip, or x-gzip,
// with a q that is not 0; or * with one, when it names neither. A coding with a
// q that is not a qvalue is not taken.
export function accepts_gzip(value) {
	if (type(value) != 'string')
		return false;

	let named = null, any = null;

	for (let part in split(value, ',')) {
		let params = split(part, ';');
		let coding = lc(trim(params[0]));
		let ok = true;

		for (let i = 1; i < length(params); i++) {
			let m = match(trim(params[i]), /^[qQ][ \t]*=[ \t]*(.*)$/);

			if (m)
				ok = positive(m[1]) == true;
		}

		if (coding == 'gzip' || coding == 'x-gzip')
			named = named || ok;
		else if (coding == '*')
			any = any || ok;
	}

	return (named != null) ? named : (any == true);
};

// gzip of `text`.
export function gzip(text) {
	return deflate(text, true, GZIP_LEVEL);
};

// The reply of a scrape ({ status, content_type, body }), for a request whose
// Accept-Encoding is `accept`: gzip-compressed when `compress` is on, the
// scrape succeeded and the scraper takes gzip. While compress is on, the reply
// varies by Accept-Encoding, and says so.
export function scrape_reply(res, accept, compress) {
	let headers = [ [ 'Content-Type', res.content_type ] ];
	let body = res.body;

	if (compress) {
		push(headers, [ 'Vary', 'Accept-Encoding' ]);

		if (substr(res.status, 0, 3) == '200' && accepts_gzip(accept)) {
			body = gzip(body);
			push(headers, [ 'Content-Encoding', 'gzip' ]);
		}
	}

	return { status: res.status, headers, body };
};

// A reply with a plain text body, and `extra` headers.
export function text_reply(status, body, extra) {
	return { status, headers: [ [ 'Content-Type', 'text/plain; charset=utf-8' ], ...(extra ?? []) ], body };
};

// The head of a reply, as the handler sends it before the body.
export function head(reply) {
	let out = `Status: ${reply.status}\r\n`;

	for (let h in reply.headers)
		out += `${h[0]}: ${h[1]}\r\n`;

	return out + '\r\n';
};

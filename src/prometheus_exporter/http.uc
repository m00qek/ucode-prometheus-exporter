/**
 * HTTP for uhttpd's handler: what a request's headers ask (uhttpd-mod-ucode
 * hands them as env.headers, named in lower case), a scrape's reply
 * gzip-compressed when the scraper takes it (as node_exporter does), and the
 * head uhttpd reads off what the handler sends: CGI's, a Status line and the
 * headers.
 *
 * A reply is { status, headers: [ [ name, value ] ], body }.
 *
 * @module prometheus_exporter_http
 */

'use strict';

/**
 * A reply, as the module's top comment says: its status line, its headers
 * as [ name, value ] pairs, and its body.
 *
 * @typedef {{ status: string, headers: string[][], body: string }} HttpReply
 */

/**
 * zlib's level: 1, the fastest. A scrape's text shrinks almost as much at the
 * default level, 6, which takes longer.
 *
 * @type {int}
 */
export const GZIP_LEVEL = 1;

/**
 * A request header's value, or null; `name` in lower case.
 *
 * @param {?Object} env uhttpd-mod-ucode's env of the request: its headers
 *   are env.headers.
 * @param {string} name the header's name, in lower case.
 * @returns {?string} its value.
 */
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

/**
 * Whether an Accept-Encoding takes gzip (RFC 9110, 12.5.3): gzip, or x-gzip,
 * with a q that is not 0; or * with one, when it names neither. A coding with a
 * q that is not a qvalue is not taken.
 *
 * @param {?string} value the Accept-Encoding header's value, or null.
 * @returns {boolean} whether it takes gzip.
 */
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

// zlib's deflate, loaded the first time a reply is compressed, in the
// request's process: uhttpd, which every request is forked from and which
// holds what it loads for as long as it runs, holds none of it. Some 0.1 ms
// of a scrape in the devenv. False once it did not load.
let deflate = null;

/**
 * gzip of `text`, or null when zlib does not load.
 *
 * @param {string} text the text.
 * @returns {?string} its gzip.
 */
export function gzip(text) {
	if (deflate == null) {
		try {
			deflate = loadstring("import { deflate } from 'zlib';\nreturn deflate;", { raw_mode: true })();
		} catch (e) {
			deflate = false;
		}
	}

	return deflate ? deflate(text, true, GZIP_LEVEL) : null;
};

/**
 * The reply of a scrape ({ status, content_type, body }), for a request whose
 * Accept-Encoding is `accept`: gzip-compressed when `compress` is on, the
 * scrape succeeded and the scraper takes gzip, and plain should zlib not
 * load. While compress is on, the reply varies by Accept-Encoding, and says
 * so.
 *
 * @param {ScrapeReply} res the scrape's reply.
 * @param {?string} accept the request's Accept-Encoding, or null.
 * @param {boolean} compress the main section's compress.
 * @returns {HttpReply} the reply.
 */
export function scrape_reply(res, accept, compress) {
	let headers = [ [ 'Content-Type', res.content_type ] ];
	let body = res.body;

	if (compress) {
		push(headers, [ 'Vary', 'Accept-Encoding' ]);

		let gzipped = (substr(res.status, 0, 3) == '200' && accepts_gzip(accept)) ? gzip(body) : null;

		if (gzipped != null) {
			body = gzipped;
			push(headers, [ 'Content-Encoding', 'gzip' ]);
		}
	}

	return { status: res.status, headers, body };
};

/**
 * A reply with a plain text body, and `extra` headers.
 *
 * @param {string} status the status line, as '403 Forbidden'.
 * @param {string} body the body.
 * @param {?string[][]} extra more headers, [ name, value ] pairs.
 * @returns {HttpReply} the reply.
 */
export function text_reply(status, body, extra) {
	return { status, headers: [ [ 'Content-Type', 'text/plain; charset=utf-8' ], ...(extra ?? []) ], body };
};

/**
 * The head of a reply, as the handler sends it before the body.
 *
 * @param {HttpReply} reply the reply.
 * @returns {string} its Status line and headers, each ended by CRLF, and
 *   the empty line.
 */
export function head(reply) {
	let out = `Status: ${reply.status}\r\n`;

	for (let h in reply.headers)
		out += `${h[0]}: ${h[1]}\r\n`;

	return out + '\r\n';
};

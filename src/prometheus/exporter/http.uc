/**
 * HTTP for uhttpd's handler: request headers, gzip, and the reply's head.
 *
 * @module prometheus_exporter_http
 */

'use strict';

/**
 * A reply: its status line, its headers as [ name, value ] pairs, and its body.
 *
 * @typedef {{ status: string, headers: string[][], body: string }} HttpReply
 */

/** zlib's level: 1, the fastest. */
export const GZIP_LEVEL = 1;

/**
 * A request header's value, or null; `name` in lower case.
 *
 * @param {?Object} env
 * @param {string} name
 * @returns {?string}
 */
export function header(env, name) {
	let v = env?.headers?.[name];

	return (type(v) == 'string') ? v : null;
};

function positive(q) {
	if (!match(q, /^(0(\.[0-9]{0,3})?|1(\.0{0,3})?)$/))
		return null;

	return !match(q, /^0(\.0*)?$/);
}

/**
 * Whether an Accept-Encoding takes gzip (RFC 9110, 12.5.3).
 *
 * @param {?string} value
 * @returns {boolean}
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

let deflate = null;

/**
 * gzip of `text`, or null when zlib does not load.
 *
 * @param {string} text
 * @returns {?string}
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
 * The reply of a scrape, gzip-compressed when `compress` is on and the scraper takes it.
 *
 * @param {ScrapeReply} res
 * @param {?string} accept
 * @param {boolean} compress
 * @returns {HttpReply}
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
 * @param {string} status
 * @param {string} body
 * @param {?string[][]} extra
 * @returns {HttpReply}
 */
export function text_reply(status, body, extra) {
	return { status, headers: [ [ 'Content-Type', 'text/plain; charset=utf-8' ], ...(extra ?? []) ], body };
};

/**
 * The head of a reply, as the handler sends it before the body.
 *
 * @param {HttpReply} reply
 * @returns {string}
 */
export function head(reply) {
	let out = `Status: ${reply.status}\r\n`;

	for (let h in reply.headers)
		out += `${h[0]}: ${h[1]}\r\n`;

	return out + '\r\n';
};

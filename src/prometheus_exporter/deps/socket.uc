'use strict';

// The socket capability: a request to a Unix stream socket's server, and
// ucode-mod-socket, loaded by name at run time.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

// What recv() fails with (errno) once SO_RCVTIMEO passes without data: EAGAIN,
// 11 on every architecture OpenWrt builds for.
const EAGAIN = 11;

// A Unix stream socket's exchange: the message sent whole, then the reply read
// until the server closes. Every wait (connect, send, each recv) is bounded by
// `tv`; a failure is `path: <the socket module's error>`.
function exchange(mod, sock, path, message, tv, timeout_ms) {
	let failed = () => Result.err(errors.SOCKET_FAILED, `${path}: ${mod.error()}`);

	if (!sock.setopt(mod.SOL_SOCKET, mod.SO_RCVTIMEO, tv) || !sock.setopt(mod.SOL_SOCKET, mod.SO_SNDTIMEO, tv))
		return failed();

	if (!sock.connect({ family: mod.AF_UNIX, path }))
		return failed();

	// MSG_NOSIGNAL: a server gone before the message is sent is an EPIPE, not a
	// SIGPIPE that would end uhttpd.
	for (let sent = 0; sent < length(message);) {
		let n = sock.send(substr(message, sent), mod.MSG_NOSIGNAL);

		if (n == null)
			return failed();
		sent += n;
	}

	let chunks = [];

	while (true) {
		let chunk = sock.recv(4096);

		if (chunk == null)
			return mod.error(true) == EAGAIN
				? Result.err(errors.SOCKET_FAILED, `${path}: no reply for ${timeout_ms} ms`)
				: failed();

		if (chunk == '')
			return Result.ok(join('', chunks));

		push(chunks, chunk);
	}
}

// unix_request(path, message, timeout_ms): the whole reply of the server on the
// Unix stream socket `path` to `message`, as a Result: SOCKET_FAILED when the
// socket is missing or refuses, or no more of the reply comes for timeout_ms
// (a positive integer). The socket is closed either way.
export function socket_channel(mod) {
	return {
		unix_request: function(path, message, timeout_ms) {
			if (type(timeout_ms) != 'int' || timeout_ms <= 0)
				return Result.err(errors.SOCKET_FAILED, `${path}: timeout ${timeout_ms} is not a positive number of ms`);

			let sock = mod.create(mod.AF_UNIX, mod.SOCK_STREAM);
			if (!sock)
				return Result.err(errors.SOCKET_FAILED, `${path}: ${mod.error()}`);

			let tv = { sec: timeout_ms / 1000, usec: (timeout_ms % 1000) * 1000 };
			let res = exchange(mod, sock, path, '' + message, tv, timeout_ms);

			sock.close();
			return res;
		},
	};
};

// ucode-mod-socket by name at run time too: only the collectors that need it
// (unbound) depend on its package, so a static import would stop the exporter
// loading where it is not installed. Null then. Lint loads it on 25.12.
export function load_socket() {
	try {
		return loadstring(
			"import { create, error, AF_UNIX, SOCK_STREAM, SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO, MSG_NOSIGNAL } from 'socket';\n" +
			'return { create, error, AF_UNIX, SOCK_STREAM, SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO, MSG_NOSIGNAL };',
			{ raw_mode: true })();
	} catch (e) {
		return null;
	}
};

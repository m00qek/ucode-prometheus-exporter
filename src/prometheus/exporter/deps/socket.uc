/**
 * The socket capability, and ucode-mod-socket loaded by name at run time.
 *
 * @module prometheus_exporter_deps_socket
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';

/**
 * deps.socket: socket_channel's object.
 *
 * @typedef {{ unix_request: (path: string, message: string, timeout_ms: int) => Result<string> }} SocketCapability
 */

const EAGAIN = 11;

const EACCES = 13;

function exchange(mod, sock, path, message, tv, timeout_ms) {
	let failed = () => Result.err(errors.SOCKET_FAILED, `${path}: ${mod.error()}`);

	if (!sock.setopt(mod.SOL_SOCKET, mod.SO_RCVTIMEO, tv) || !sock.setopt(mod.SOL_SOCKET, mod.SO_SNDTIMEO, tv))
		return failed();

	if (!sock.connect({ family: mod.AF_UNIX, path }))
		return (mod.error(true) == EACCES)
			? Result.err(errors.PERMISSION_DENIED, `${path}: ${mod.error()}: the service's user is not in a group it is opened to (meta.groups), which the service joins it to when it starts`)
			: failed();

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

/**
 * deps.socket: unix_request(path, message, timeout_ms), a Unix stream socket's whole reply.
 *
 * @param {module:socket} mod load_socket()'s module, or a test's.
 * @returns {SocketCapability} deps.socket.
 */
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

/**
 * ucode-mod-socket, loaded by name at run time; null when it is not installed.
 *
 * @returns {?module:socket} create, error and the constants used; null when it is not installed.
 */
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

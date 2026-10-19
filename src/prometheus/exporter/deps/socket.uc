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
 * @typedef {{
 *   unix_request: (path: string, message: string, timeout_ms: int) => Result<string>,
 *   tcp_request: (address: string, port: int, message: string, timeout_ms: int) => Result<string>
 * }} SocketCapability
 */

const EAGAIN = 11;

const EACCES = 13;

const EADDRNOTAVAIL = 99;

function exchange(mod, sock, name, message, timeout_ms) {
	let failed = () => Result.err(errors.SOCKET_FAILED, `${name}: ${mod.error()}`);

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
				? Result.err(errors.SOCKET_FAILED, `${name}: no reply for ${timeout_ms} ms`)
				: failed();

		if (chunk == '')
			return Result.ok(join('', chunks));

		push(chunks, chunk);
	}
}

function bounded(mod, sock, name, timeout_ms) {
	let tv = { sec: timeout_ms / 1000, usec: (timeout_ms % 1000) * 1000 };

	if (!sock.setopt(mod.SOL_SOCKET, mod.SO_RCVTIMEO, tv) || !sock.setopt(mod.SOL_SOCKET, mod.SO_SNDTIMEO, tv))
		return Result.err(errors.SOCKET_FAILED, `${name}: ${mod.error()}`);

	return null;
}

function with_socket(mod, family, name, cb) {
	let sock = mod.create(family, mod.SOCK_STREAM);

	if (!sock)
		return Result.err(errors.SOCKET_FAILED, `${name}: ${mod.error()}`);

	let res = cb(sock);

	sock.close();
	return res;
}

function unix_connect(mod, sock, path) {
	if (sock.connect({ family: mod.AF_UNIX, path }))
		return null;

	return (mod.error(true) == EACCES)
		? Result.err(errors.PERMISSION_DENIED, `${path}: ${mod.error()}: the service's user is not in a group it is opened to (meta.groups), which the service joins it to when it starts`)
		: Result.err(errors.SOCKET_FAILED, `${path}: ${mod.error()}`);
}

function tcp_connect(mod, sock, family, address, port, name) {
	if (!sock.bind({ family, address, port: 0 }))
		return (mod.error(true) == EADDRNOTAVAIL)
			? Result.err(errors.SOCKET_FAILED, `${name}: ${address} is not an address of this device, and a collector connects to the device's own ports alone`)
			: Result.err(errors.SOCKET_FAILED, `${name}: ${mod.error()}`);

	if (!sock.connect({ family, address, port }))
		return Result.err(errors.SOCKET_FAILED, `${name}: ${mod.error()}`);

	return null;
}

function bad_timeout(name, timeout_ms) {
	return (type(timeout_ms) != 'int' || timeout_ms <= 0)
		? Result.err(errors.SOCKET_FAILED, `${name}: timeout ${timeout_ms} is not a positive number of ms`)
		: null;
}

function endpoint(address, port) {
	return (index(`${address}`, ':') >= 0) ? `[${address}]:${port}` : `${address}:${port}`;
}

/**
 * deps.socket: unix_request(), a Unix stream socket's whole reply, and tcp_request(), a TCP port's of the device itself.
 *
 * @param {module:socket} mod load_socket()'s module, or a test's.
 * @returns {SocketCapability} deps.socket.
 */
export function socket_channel(mod) {
	return {
		unix_request: function(path, message, timeout_ms) {
			let bad = bad_timeout(path, timeout_ms);

			if (bad)
				return bad;

			return with_socket(mod, mod.AF_UNIX, path, (sock) =>
				bounded(mod, sock, path, timeout_ms) ?? unix_connect(mod, sock, path) ??
					exchange(mod, sock, path, '' + message, timeout_ms));
		},

		tcp_request: function(address, port, message, timeout_ms) {
			let name = endpoint(address, port);
			let bad = bad_timeout(name, timeout_ms);

			if (bad)
				return bad;

			let ip = (type(address) == 'string') ? iptoarr(address) : null;

			if (ip == null)
				return Result.err(errors.SOCKET_FAILED, `${name}: ${sprintf('%J', address)} is not an IPv4 or IPv6 address`);
			if (type(port) != 'int' || port < 1 || port > 65535)
				return Result.err(errors.SOCKET_FAILED, `${name}: ${sprintf('%J', port)} is not a port from 1 to 65535`);

			let family = (length(ip) == 4) ? mod.AF_INET : mod.AF_INET6;

			return with_socket(mod, family, name, (sock) =>
				bounded(mod, sock, name, timeout_ms) ?? tcp_connect(mod, sock, family, address, port, name) ??
					exchange(mod, sock, name, '' + message, timeout_ms));
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
			"import { create, error, AF_UNIX, AF_INET, AF_INET6, SOCK_STREAM, SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO, MSG_NOSIGNAL } from 'socket';\n" +
			'return { create, error, AF_UNIX, AF_INET, AF_INET6, SOCK_STREAM, SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO, MSG_NOSIGNAL };',
			{ raw_mode: true })();
	} catch (e) {
		return null;
	}
};

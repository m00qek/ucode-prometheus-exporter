'use strict';

import { describe, it, prop, gen, assert, mock, spy } from 'utest';
import * as deps_socket from 'prometheus.exporter.deps.socket';

function brief(res) {
	return res.ok ? { ok: true, data: res.data } : { ok: false, error: res.error, details: res.details };
}

const CTL = '/run/unbound.ctl';

// The calls the socket mock recorded: `create`, and 'sock.<method>' on sockets.
function calls(socket, name) {
	return spy(socket).calls[name] ?? [];
}

describe('deps.socket.socket_channel', () => {
	it('sends the message, reads the reply until the server closes, and closes the socket', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: (req) => req == 'UBCT1 stats_noreset\n' ? 'a=1\nb=2\n' : 'error\n' } }, (socket) => {
			let res = deps_socket.socket_channel(socket).unix_request(CTL, 'UBCT1 stats_noreset\n', 1500);

			assert.match({ ok: true, data: 'a=1\nb=2\n' }, brief(res));
			assert.match([ [ socket.AF_UNIX, socket.SOCK_STREAM ] ], calls(socket, 'create'));
			assert.match([ [ { family: socket.AF_UNIX, path: CTL } ] ], calls(socket, 'sock.connect'));
			assert.match([ [ 'UBCT1 stats_noreset\n', socket.MSG_NOSIGNAL ] ], calls(socket, 'sock.send'));
			assert.match(1, length(calls(socket, 'sock.close')));
		});
	});

	it('bounds every wait by the timeout', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: '' } }, (socket) => {
			deps_socket.socket_channel(socket).unix_request(CTL, 'x', 1500);

			assert.match([
				[ socket.SOL_SOCKET, socket.SO_RCVTIMEO, { sec: 1, usec: 500000 } ],
				[ socket.SOL_SOCKET, socket.SO_SNDTIMEO, { sec: 1, usec: 500000 } ],
			], calls(socket, 'sock.setopt'));
		});
	});

	it('fails with SOCKET_FAILED where the socket is missing or refuses, and closes it', () => {
		mock.inject('socket', { errors: { '/run/refusing.ctl': 'connect(): Connection refused' } }, (socket) => {
			let ch = deps_socket.socket_channel(socket);

			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: connect(): No such file or directory` },
				brief(ch.unix_request(CTL, 'x', 1000)));
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: '/run/refusing.ctl: connect(): Connection refused' },
				brief(ch.unix_request('/run/refusing.ctl', 'x', 1000)));
			assert.match([ 2, 2, 0 ], [ length(calls(socket, 'create')), length(calls(socket, 'sock.close')), length(calls(socket, 'sock.send')) ]);
		});
	});

	// srw-rw---- unbound:unbound, the service's user not in unbound's group.
	it('fails with PERMISSION_DENIED on a socket the process may not connect to', () => {
		mock.inject('socket', { errors: { [CTL]: 'connect(): Permission denied' } }, (socket) => {
			let res = deps_socket.socket_channel(socket).unix_request(CTL, 'x', 1000);

			assert.match([ 'PERMISSION_DENIED', 1 ], [ res.error, length(calls(socket, 'sock.close')) ]);
			assert.match(true, index(res.details, `${CTL}: connect(): Permission denied: `) == 0, res.details);
		});
	});

	it('fails with SOCKET_FAILED when the reply stops coming before the server closes', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: 'a=1\n' }, hangs: { [CTL]: true, '/run/silent.ctl': true } }, (socket) => {
			let ch = deps_socket.socket_channel(socket);

			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: no reply for 250 ms` }, brief(ch.unix_request(CTL, 'x', 250)));
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: '/run/silent.ctl: no reply for 1000 ms' },
				brief(ch.unix_request('/run/silent.ctl', 'x', 1000)));
			assert.match(2, length(calls(socket, 'sock.close')));
		});
	});

	it('fails with SOCKET_FAILED when no socket can be made', () => {
		mock.inject('socket', {
			strict: true,
			behavior: { create: () => null, error: () => 'socket(): Too many open files' },
		}, (socket) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: socket(): Too many open files` },
				brief(deps_socket.socket_channel(socket).unix_request(CTL, 'x', 1000)));
		});
	});

	it('refuses a timeout that is not a positive integer, which would wait forever', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: 'a=1\n' } }, (socket) => {
			let ch = deps_socket.socket_channel(socket);

			assert.match([ 'SOCKET_FAILED', 'SOCKET_FAILED', 'SOCKET_FAILED' ],
				map([ 0, -5, '1000' ], (t) => ch.unix_request(CTL, 'x', t).error));
			assert.match([], calls(socket, 'create'));
		});
	});

	prop('gives back any reply whole, however many reads it takes',
		gen.string({ charset: 'abc=.0123456789\n', min_len: 0, max_len: 10000 }), (reply) => {
			mock.inject('socket', { strict: true, data: { [CTL]: reply } }, (socket) => {
				assert.match({ ok: true, data: reply }, brief(deps_socket.socket_channel(socket).unix_request(CTL, 'x', 1000)));
				assert.match(1, length(calls(socket, 'sock.close')));
			});
		});
});

describe('devkit/proxies/socket', () => {
	it('reads a reply in chunks of the size asked, then gives EOF', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: 'abcde' } }, (socket) => {
			let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);

			assert.match(true, s.connect(CTL));
			assert.match([ 'ab', 'cd', 'e', '', '' ], [ s.recv(2), s.recv(2), s.recv(2), s.recv(2), s.recv(2) ]);
		});
	});

	it('answers what was sent before the first read', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: (req) => `got ${req}` } }, (socket) => {
			let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);

			s.connect({ family: socket.AF_UNIX, path: CTL });
			s.send('UBCT1 ', 0);
			s.send('stats', 0);
			assert.match('got UBCT1 stats', s.recv(100));
		});
	});

	it('reports a failure by message and errno, as the real module', () => {
		mock.inject('socket', { hangs: { [CTL]: true } }, (socket) => {
			let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);

			assert.match([ null, 'connect(): No such file or directory', 2 ],
				[ socket.create(socket.AF_UNIX, socket.SOCK_STREAM).connect('/run/nope.ctl'), socket.error(), socket.error(true) ]);

			s.setopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, { sec: 0, usec: 1000 });
			s.connect(CTL);
			assert.match([ null, 'recv(): Resource temporarily unavailable', 11 ], [ s.recv(10), socket.error(), socket.error(true) ]);
		});
	});

	it('dies where the real module would block forever or the test is wrong', () => {
		mock.inject('socket', { strict: true, hangs: { [CTL]: true } }, (socket) => {
			let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);

			s.connect(CTL);
			assert.throws(() => s.recv(10), 'would block forever');
			s.close();
			assert.throws(() => s.recv(10), 'closed socket');
			assert.throws(() => socket.create(socket.AF_UNIX, socket.SOCK_STREAM).connect('/run/other.ctl'), 'not mocked');
			assert.throws(() => socket.create(socket.AF_INET ?? 2, socket.SOCK_STREAM), 'only AF_UNIX');
		});
	});
});

describe('deps.socket.load_socket', () => {
	// ucode-mod-socket exports no `const`, so its shim compiles and it loads.
	it('loads socket by name: the functions and constants socket_channel uses', () => {
		let m = deps_socket.load_socket();

		assert.match([ 'function', 'function' ], [ type(m.create), type(m.error) ]);
		assert.match([ 'int', 'int', 'int', 'int', 'int', 'int' ],
			map([ 'AF_UNIX', 'SOCK_STREAM', 'SOL_SOCKET', 'SO_RCVTIMEO', 'SO_SNDTIMEO', 'MSG_NOSIGNAL' ], (k) => type(m[k])));
	});
});

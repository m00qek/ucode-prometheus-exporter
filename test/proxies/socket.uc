// A proxy for ucode-mod-socket, which utest does not ship. Loaded in program
// mode, hence the bare `return`. Its constants are the real module's.
//
// It models the Unix stream sockets deps.socket_channel opens: create(), then
// setopt(), connect(), send(), recv() and close() on the socket, and error().
// A server answers once the client reads: whatever was sent by then is the
// request. Keys are socket paths.
// data:   path -> the server's reply, or a function of the request that returns
//         one; recv() reads it in chunks of at most the size it asks for, then
//         the server closes (recv() gives '').
// errors: path -> the message error() reports after connect() fails there, as
//         'connect(): Connection refused'.
// hangs:  path -> true: the server sends its reply but never closes, so the
//         recv() after it fails as one whose SO_RCVTIMEO passed (EAGAIN). With
//         no receive timeout set that recv() would block forever: the proxy
//         dies instead.
// Any other path fails connect() as a missing socket file does (ENOENT), or
// dies when the mock is strict. Socket calls are recorded as 'sock.<method>'.

// The errno of the messages a Unix socket gives, for error(true).
const ERRNO = {
	'Resource temporarily unavailable': 11,
	'No such file or directory': 2,
	'Permission denied': 13,
	'Connection refused': 111,
	'Broken pipe': 32,
};

// Linux's values, for when the real module is not installed.
const CONSTANTS = {
	AF_UNIX: 1, SOCK_STREAM: 1, SOL_SOCKET: 1, SO_RCVTIMEO: 20, SO_SNDTIMEO: 21, MSG_NOSIGNAL: 0x4000,
};

return {
	channels: [ 'errors', 'hangs' ],

	create: function(name, real, ctx) {
		let proxy = ctx.base();
		let last = { message: null, errno: 0 };

		for (let k, v in CONSTANTS)
			proxy[k] ??= v;

		function fail(message) {
			let m = match(message, /: ([^:]+)$/);

			last = { message, errno: (m ? ERRNO[m[1]] : null) ?? 0 };
			return null;
		}

		function open_socket() {
			let st = { path: null, request: '', reply: null, pos: 0, rcvtimeo: null, closed: false };

			function live(method, args) {
				ctx.record_call('sock.' + method, args);
				if (st.closed)
					die(`socket mock: ${method}() on a closed socket`);
			}

			return {
				setopt: function(level, option, value) {
					live('setopt', [ level, option, value ]);
					if (level == proxy.SOL_SOCKET && option == proxy.SO_RCVTIMEO)
						st.rcvtimeo = value;
					return true;
				},

				connect: function(addr) {
					live('connect', [ addr ]);
					let path = type(addr) == 'string' ? addr : addr?.path;

					if (ctx.has('errors', path))
						return fail(ctx.get('errors', path));

					if (!ctx.has_data(path) && !ctx.has('hangs', path)) {
						if (ctx.is_strict())
							die(sprintf("strict mock: socket connect(%J) is not mocked", path));
						return fail('connect(): No such file or directory');
					}

					st.path = path;
					return true;
				},

				send: function(data, flags) {
					live('send', [ data, flags ]);
					if (st.path == null)
						return fail('send(): Transport endpoint is not connected');

					st.request += data;
					return length(data);
				},

				recv: function(size) {
					live('recv', [ size ]);
					if (st.path == null)
						return fail('recv(): Transport endpoint is not connected');

					if (st.reply == null) {
						let v = ctx.get_data(st.path);
						st.reply = '' + ((type(v) == 'function' ? v(st.request) : v) ?? '');
					}

					if (st.pos < length(st.reply)) {
						let chunk = substr(st.reply, st.pos, size);
						st.pos += length(chunk);
						return chunk;
					}

					if (!ctx.get('hangs', st.path))
						return '';

					let tv = st.rcvtimeo;
					if (!tv || (!tv.sec && !tv.usec))
						die(`socket mock: recv() from ${st.path}, which never closes, without SO_RCVTIMEO would block forever`);

					return fail('recv(): Resource temporarily unavailable');
				},

				close: function() {
					live('close', []);
					st.closed = true;
					return true;
				},
			};
		}

		proxy.create = function(domain, socktype) {
			ctx.record_call('create', [ domain, socktype ]);

			let override = ctx.get_behavior('create');
			if (override)
				return override(domain, socktype);

			if (domain != proxy.AF_UNIX || socktype != proxy.SOCK_STREAM)
				die('socket mock: only AF_UNIX stream sockets are modeled');

			return open_socket();
		};

		proxy.error = function(numeric) {
			ctx.record_call('error', [ numeric ]);

			let override = ctx.get_behavior('error');
			if (override)
				return override(numeric);

			return numeric ? last.errno : last.message;
		};

		return proxy;
	},
};

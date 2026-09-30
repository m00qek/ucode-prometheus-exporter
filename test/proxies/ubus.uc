// utest's ubus proxy plus what OpenWrt 25.12's ubus connections have and it
// lacks: list() and error(). Loaded in program mode, hence the bare `return`.
//
// data:   'object:method' or 'object' -> a reply, or a function of the call's
//         args that returns one (as the built-in proxy).
// errors: 'object:method' or 'object' -> the message error() reports after a
//         call that fails with a null reply, as a real failed call does.
// list() names every object the data channel mentions.
return {
	channels: [ 'errors' ],

	create: function(name, real, ctx) {
		let proxy = ctx.base();

		proxy.connect = function() {
			ctx.record_call('connect', []);
			let f = ctx.get_behavior('connect');
			if (f)
				return f();

			let calls = { call: [], list: [], error: [], disconnect: [] };
			let last_error = null;

			return {
				__utest__: { calls },

				call: function(obj, method, args) {
					push(calls.call, [ obj, method, args ]);
					last_error = null;

					let override = ctx.get_behavior('call');
					if (override)
						return override(obj, method, args);

					for (let key in [ obj + ':' + method, obj ]) {
						if (ctx.has('errors', key)) {
							last_error = ctx.get('errors', key);
							return null;
						}

						if (ctx.has_data(key)) {
							let v = ctx.get_data(key);
							return type(v) === 'function' ? v(args) : ctx.clone(v);
						}
					}

					if (ctx.is_strict())
						die(sprintf("strict mock: ubus.call('%s', '%s') is not mocked", obj, method));

					last_error = 'Not found';
					return null;
				},

				list: function(path) {
					push(calls.list, [ path ]);

					let override = ctx.get_behavior('list');
					if (override)
						return override(path);

					if (path != null)
						die('ubus mock: list(path), which answers method signatures, is not modeled');

					let names = {};
					for (let key in ctx.get_all_data_keys())
						names[split(key, ':')[0]] = true;

					return sort(keys(names));
				},

				error: function() {
					push(calls.error, []);

					let override = ctx.get_behavior('error');
					return override ? override() : last_error;
				},

				disconnect: function() {
					push(calls.disconnect, []);

					let override = ctx.get_behavior('disconnect');
					if (override)
						return override();
				},
			};
		};

		return proxy;
	},
};

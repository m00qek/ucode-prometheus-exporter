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

					let names = {};

					if (path != null) {
						last_error = null;
						if (ctx.has('errors', 'list:' + path))
							return [];

						for (let key in ctx.get_all_data_keys())
							names[split(key, ':')[0]] = true;

						if (path == 'system' || names[path])
							return [ {} ];

						last_error = 'Not found';
						return null;
					}

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

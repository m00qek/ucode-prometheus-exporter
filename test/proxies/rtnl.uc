// A proxy for ucode-mod-rtnl, which utest does not ship. Loaded in program
// mode, hence the bare `return`. `const` is the real module's.
//
// Keys name the command as rtnl's constants do, with the device when the
// request has one: 'RTM_GETLINK:eth0', else 'RTM_GETLINK' (a dump of every link).
// data:   key -> a reply, or a function of (flags, attrs) that returns one.
// errors: key -> the message error() reports after that request fails.
return {
	channels: [ 'errors' ],

	create: function(name, real, ctx) {
		let proxy = ctx.base();
		let last_error = null;

		function command(cmd) {
			for (let k, v in real?.const ?? {})
				if (v === cmd && match(k, /^RTM_/))
					return k;
			return '' + cmd;
		}

		proxy.request = function(cmd, flags, attrs) {
			ctx.record_call('request', [ cmd, flags, attrs ]);
			last_error = null;

			let override = ctx.get_behavior('request');
			if (override)
				return override(cmd, flags, attrs);

			let c = command(cmd);
			let keys = attrs?.dev != null ? [ c + ':' + attrs.dev, c ] : [ c ];

			for (let key in keys) {
				if (ctx.has('errors', key)) {
					last_error = ctx.get('errors', key);
					return null;
				}

				if (ctx.has_data(key)) {
					let v = ctx.get_data(key);
					return type(v) === 'function' ? v(flags, attrs) : ctx.clone(v);
				}
			}

			if (ctx.is_strict())
				die(sprintf("strict mock: rtnl.request(%s) is not mocked", keys[0]));

			last_error = 'No such device';
			return null;
		};

		proxy.error = function() {
			ctx.record_call('error', []);

			let override = ctx.get_behavior('error');
			return override ? override() : last_error;
		};

		return proxy;
	},
};

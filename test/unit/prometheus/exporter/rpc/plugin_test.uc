'use strict';

// The ubus object as rpcd holds it: rpcd collects its plugin's garbage after
// every call, a pass over all the plugin holds, so the sources' methods,
// which the collectors call at each scrape, are held alone, and the rest of
// the object is compiled when it is called and let go when idle.

import { describe, it, assert } from 'utest';
import * as plugin from 'prometheus.exporter.rpc.plugin';

// A program of the object's other methods, `made` counting each compiled.
function program(counts) {
	return function() {
		counts.made++;

		let n = counts.made;

		return {
			object: 'prometheus-exporter',
			methods: {
				status: { args: {}, call: (req) => ({ program: n, args: req?.args }) },
				validate: { args: { main: {}, collectors: {} }, call: () => ({ program: n }) },
				wireless: { args: {}, call: () => die('the light method is the one served') },
			},
		};
	};
}

// uloop's timer, which the test fires.
function timers() {
	let armed = [];

	return {
		armed,
		timer: function(ms, cb) {
			let t = { ms, cb, cancelled: false };

			push(armed, t);
			return { cancel: () => { t.cancelled = true; } };
		},
		fire: function() {
			for (let t in armed)
				if (!t.cancelled) {
					t.cancelled = true;
					t.cb();
				}
		},
	};
}

const LIGHT = { wireless: { args: {}, call: () => ({ radios: {} }) } };

describe('rpc.plugin.object', () => {
	it('serves the light methods and every other of the program, with its arguments, under its name', () => {
		let counts = { made: 0 };
		let obj = plugin.object(program(counts), LIGHT, null, 60);
		let m = obj['prometheus-exporter'];

		assert.match([ 'prometheus-exporter' ], keys(obj));
		assert.match([ 'status', 'validate', 'wireless' ], sort(keys(m)));
		assert.match({ main: {}, collectors: {} }, m.validate.args);
		assert.match(LIGHT.wireless, m.wireless);
	});

	it('compiles the program to know its methods, and holds none of it until one is called', () => {
		let counts = { made: 0 }, t = timers();
		let m = plugin.object(program(counts), LIGHT, t.timer, 60)['prometheus-exporter'];

		assert.match([ 1, [] ], [ counts.made, t.armed ]);
		assert.match({ radios: {} }, m.wireless.call({}));
		assert.match(1, counts.made);
		assert.match({ program: 2, args: { x: 1 } }, m.status.call({ args: { x: 1 } }));
		assert.match({ program: 2 }, m.validate.call({}));
		assert.match(2, counts.made);
	});

	it('lets the program go when no other method was called for its seconds, and compiles it again for the next call', () => {
		let counts = { made: 0 }, t = timers();
		let m = plugin.object(program(counts), LIGHT, t.timer, 120)['prometheus-exporter'];

		m.status.call({});
		m.status.call({});
		assert.match([ 120000, 120000 ], map(t.armed, (x) => x.ms));
		assert.match([ true, false ], map(t.armed, (x) => x.cancelled));
		t.fire();
		m.wireless.call({});
		assert.match(2, counts.made);
		assert.match({ program: 3 }, m.validate.call({}));
	});

	it('holds what it compiled while a status scrape may run', () => {
		assert.match(true, plugin.IDLE_SECONDS >= 60);
	});
});

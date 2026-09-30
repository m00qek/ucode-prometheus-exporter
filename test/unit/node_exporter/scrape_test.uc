'use strict';

import { describe, it, prop, gen, assert, contains, regex } from 'utest';
import * as scrape from 'node_exporter.scrape';
import * as loader from 'node_exporter.loader';
import * as deps from 'node_exporter.deps';
import * as exposition from 'node_exporter.exposition';
import * as Result from 'node_exporter.result';
import { with_mods } from 'context';

function collector(name, collect, meta) {
	return loader.validate(loader.id_of(name), { meta: { name, help: 'Test.', needs: [], ...(meta ?? {}) }, collect }).data;
}

function gauge_of(name, value) {
	return (d, out) => { out.gauge(name)(null, value); return Result.ok(); };
}

const A = collector('a', gauge_of('a_value', 1));
const B = collector('b-two', gauge_of('b_value', 2));
const C = collector('c', gauge_of('c_value', 3));

function names(res) {
	return map(res.data, (c) => c.meta.name);
}

// The scrape env over the mocks, with a clock that advances by 250ms a reading.
function env_for(mods, logs) {
	let t = 0;
	return {
		session: () => deps.session(mods),
		clock: () => { t += 250000000; return [ int(t / 1000000000), t % 1000000000 ]; },
		log: (m) => push(logs, m),
	};
}

function lines(text) {
	return split(rtrim(text, '\n'), '\n');
}

describe('scrape.select', () => {
	it('selects every collector when the query names none', () => {
		assert.match([ 'a', 'b-two', 'c' ], names(scrape.select([ A, B, C ], '')));
	});

	it('keeps the order the query names them in, once each, by name or module name', () => {
		assert.match([ 'c', 'b-two' ], names(scrape.select([ A, B, C ], 'collect[]=c&collect[]=b_two&collect=b-two')));
	});

	it('leaves out the excluded', () => {
		assert.match([ 'a', 'c' ], names(scrape.select([ A, B, C ], 'exclude[]=b-two')));
	});

	it('refuses an unknown name', () => {
		let res = scrape.select([ A ], 'collect[]=nope');
		assert.match({ ok: false, details: "unknown collector 'nope'" }, { ok: res.ok, details: res.details });
	});
});

describe('scrape.run_one', () => {
	function run(c, cfg) {
		let out;
		with_mods(cfg ?? {}, (mods) => {
			let logs = [];
			let r = scrape.run_one(env_for(mods, logs), deps.session(mods), c);
			out = { ...r, logs, text: exposition.render(r.families) };
		}, c.id);
		return out;
	}

	it('times a collector and keeps what it recorded', () => {
		let r = run(A);

		assert.match({ name: 'a', ok: true, duration: 0.25 }, { name: r.name, ok: r.result.ok, duration: r.duration });
		assert.match('# TYPE a_value gauge\na_value 1\n', r.text);
	});

	it('keeps what a failing collector recorded before it failed, and logs why', () => {
		let r = run(collector('half', (d, out) => {
			out.gauge('half_done')(null, 1);
			return Result.err('SOURCE_UNREADABLE', '/proc/x');
		}));

		assert.match([ false, "collector 'half': SOURCE_UNREADABLE (/proc/x)" ], [ r.result.ok, r.logs[0] ]);
		assert.match('# TYPE half_done gauge\nhalf_done 1\n', r.text);
	});

	it('turns a crash into COLLECTOR_CRASHED', () => {
		let r = run(collector('boom', () => die('kaput')));
		assert.match({ error: 'COLLECTOR_CRASHED', details: 'kaput' }, { error: r.result.error, details: r.result.details });
	});

	it('turns anything but a Result into COLLECTOR_NO_RESULT', () => {
		let r = run(collector('sloppy', () => true));
		assert.match({ error: 'COLLECTOR_NO_RESULT', details: 'returned bool' }, { error: r.result.error, details: r.result.details });
	});

	it('passes the typed options, and does not call a collector whose options are invalid', () => {
		let seen = [];
		let c = collector('opt', (d, out, config) => { push(seen, config); return Result.ok(); }, { options: { stations: true } });

		run(c, { options: { stations: 'off' } });
		let bad = run(c, { options: { stations: 'maybe' } });

		assert.match([ { stations: false } ], seen);
		assert.match('CONFIG_INVALID', bad.result.error);
	});

	it('does not call a collector whose needs are missing', () => {
		let called = false;
		let r = run(collector('wifi', () => { called = true; return Result.ok(); }, { needs: [ 'nl80211' ] }), { no_nl80211: true });

		assert.match([ false, 'NEED_MISSING' ], [ called, r.result.error ]);
	});

	it('logs a family declared with two types', () => {
		let r = run(collector('mixed', (d, out) => { out.gauge('m')(null, 1); out.counter('m')(null, 2); return Result.ok(); }));
		assert.match(contains([ "collector 'mixed': 'm' declared with two types; later samples dropped" ]), r.logs);
	});
});

describe('scrape.scrape', () => {
	function scrape_with(collectors, query_string, cfg) {
		let out;
		with_mods(cfg ?? {}, (mods) => {
			let logs = [];
			out = { ...scrape.scrape(env_for(mods, logs), collectors, query_string), logs };
		});
		return out;
	}

	it('writes each family once, then durations, then outcomes', () => {
		let r = scrape_with([ A, collector('failing', () => Result.err('SOURCE_INVALID')) ], '');

		assert.match([ '200 OK', scrape.CONTENT_TYPE ], [ r.status, r.content_type ]);
		assert.match([
			'# TYPE a_value gauge',
			'a_value 1',
			'# HELP node_scrape_collector_duration_seconds node_exporter: Duration of a collector scrape.',
			'# TYPE node_scrape_collector_duration_seconds gauge',
			'node_scrape_collector_duration_seconds{collector="a"} 0.25',
			'node_scrape_collector_duration_seconds{collector="failing"} 0.25',
			'# HELP node_scrape_collector_success node_exporter: Whether a collector succeeded.',
			'# TYPE node_scrape_collector_success gauge',
			'node_scrape_collector_success{collector="a"} 1',
			'node_scrape_collector_success{collector="failing"} 0',
		], lines(r.body));
	});

	it('merges a family two collectors share', () => {
		let r = scrape_with([ collector('x', gauge_of('shared', 1)), collector('y', (d, out) => {
			out.gauge('shared')({ by: 'y' }, 2);
			return Result.ok();
		}) ], 'collect[]=x&collect[]=y');

		assert.match(contains([ '# TYPE shared gauge\nshared 1\nshared{by="y"} 2\n' ]), [ substr(r.body, 0, index(r.body, '# HELP')) ]);
	});

	it('answers 400 for an unknown collector', () => {
		let r = scrape_with([ A ], 'collect[]=nope');
		assert.match([ '400 Bad Request', "COLLECTOR_INVALID (unknown collector 'nope')\n" ], [ r.status, r.body ]);
	});

	it('omits zero counters when the main section says so', () => {
		let zeros = collector('z', (d, out) => { out.counter('z_total')(null, 0); return Result.ok(); });

		assert.match(true, index(scrape_with([ zeros ], '').body, 'z_total') >= 0);
		assert.match(-1, index(scrape_with([ zeros ], '', { main: { omit_zero_values: '1' } }).body, 'z_total'));
	});

	it('logs an invalid main section and goes on with its defaults', () => {
		let r = scrape_with([ A ], '', { main: { omit_zero_values: 'maybe' } });

		assert.match('200 OK', r.status);
		assert.match([ 'main: CONFIG_INVALID (omit_zero_values: expected a boolean, got "maybe")' ], r.logs);
	});

	it('closes the ubus connection its collectors opened', () => {
		let conns = [];
		let pinger = collector('pinger', (d) => d.ubus.call('system', 'board'), { needs: [ 'ubus' ] });

		with_mods({ ubus: { data: { 'system:board': {} } } }, (mods) => {
			let connect = mods.ubus.connect;
			let wrapped = { ...mods, ubus: { connect: () => { let c = connect(); push(conns, c); return c; } } };
			scrape.scrape(env_for(wrapped, []), [ pinger ], '');
		});

		assert.match([ 1 ], map(conns, (c) => length(c.__utest__.calls.disconnect)));
	});

	prop('reports each selected collector once, in the order asked, as valid exposition text',
		gen.array(gen.elements('a', 'b-two', 'c', 'b_two'), { min_len: 0, max_len: 6 }), (asked) => {
			let r = scrape_with([ A, B, C ], join('&', map(asked, (n) => 'collect[]=' + n)));
			let expected = length(asked) ? uniq(map(asked, (n) => n == 'b_two' ? 'b-two' : n)) : [ 'a', 'b-two', 'c' ];
			let parsed = exposition.parse(r.body);
			let success = filter(parsed.data, (f) => f.name == 'node_scrape_collector_success')[0];

			assert.match(true, parsed.ok);
			assert.match(expected, map(success.samples, (s) => s.labels[0][1]));
		});
});

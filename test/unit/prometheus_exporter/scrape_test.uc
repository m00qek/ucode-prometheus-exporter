'use strict';

import { describe, it, prop, gen, assert, contains, regex } from 'utest';
import * as scrape from 'prometheus_exporter.scrape';
import * as loader from 'prometheus_exporter.loader';
import * as deps from 'prometheus_exporter.deps';
import * as exposition from 'prometheus_exporter.exposition';
import * as Result from 'prometheus_exporter.result';
import * as ledger from 'prometheus_exporter.ledger';
import * as commands from 'lib.commands';
import { with_mods } from 'context';

function collector(name, collect, meta) {
	return loader.validate(loader.id_of(name), { meta: { name, title: 'Test', help: 'Test.', needs: [], ...(meta ?? {}) }, collect }).data;
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

// The scrape env over the mocks, with a clock that advances by 250ms a reading;
// `levels`, when given, gets the level of each line `logs` gets.
function env_for(mods, logs, levels) {
	let t = 0;
	return {
		session: () => deps.session(mods),
		clock: () => { t += 250000000; return [ int(t / 1000000000), t % 1000000000 ]; },
		log: (level, m) => { push(logs, m); push(levels ?? [], level); },
		version: '0.1.0-r1',
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

	it('leaves the disabled out of every collector', () => {
		assert.match([ 'a', 'c' ], names(scrape.select([ A, B, C ], '', [ 'b_two' ])));
		assert.match([ 'c' ], names(scrape.select([ A, B, C ], 'exclude[]=a&exclude[]=b-two', [ 'b_two' ])));
	});

	it('refuses to collect a disabled one, by name or module name', () => {
		assert.match([
			"COLLECTOR_INVALID (collector 'b-two' is disabled)",
			"COLLECTOR_INVALID (collector 'b_two' is disabled)",
		], map([ 'collect[]=a&collect[]=b-two', 'collect[]=b_two' ], (q) => Result.describe(scrape.select([ A, B, C ], q, [ 'b_two' ]))));
	});

	prop('never selects a disabled collector',
		gen.array(gen.elements('a', 'b_two', 'c'), { min_len: 0, max_len: 3 }), (disabled) => {
			let res = scrape.select([ A, B, C ], '', disabled);
			assert.match([], filter(res.data, (c) => c.id in disabled));
			assert.match(3 - length(uniq(disabled)), length(res.data));
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

	it('keeps nothing of a collector with nothing to observe, logs nothing, and carries its reason', () => {
		let r = run(collector('radio', (d, out) => {
			out.gauge('radio_started')(null, 1);
			return Result.none('no wireless radios');
		}));

		assert.match({ ok: true, none: 'no wireless radios', logs: [], text: '' },
			{ ok: r.result.ok, none: r.result.none, logs: r.logs, text: r.text });
		assert.match(true, Result.is_none(r.result));
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
		let c = collector('opt', (d, out, config) => { push(seen, config); return Result.ok(); }, { options: { stations: { default: true, title: 'T', help: 'Stations.' } } });

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

	it('gives a collector\'s programs the seconds of its section\'s timeout, then its meta.timeout, then exec_timeout', () => {
		let seen = [];
		let fs = { behavior: { popen: function(cmd) { push(seen, commands.parse(cmd).seconds); return null; } } };
		let runner = (extra) => collector('runner', (d) => d.exec.run([ 'nft' ]), { needs: [ 'exec' ], commands: [ 'nft' ], ...(extra ?? {}) });

		run(runner(), { fs, main: { exec_timeout: '8' } });
		run(runner({ timeout: 12 }), { fs, main: { exec_timeout: '8' } });
		run(runner({ timeout: 12 }), { fs, main: { exec_timeout: '8' }, options: { timeout: '3' } });
		run(runner(), { fs, options: { timeout: '4' } });
		run(runner(), { fs });

		assert.match([ 8, 12, 3, 4, deps.EXEC_SECONDS ], seen);
	});

	it('kills a program once the seconds of the collector\'s own timeout are spent', () => {
		let c = collector('runner', (d) => d.exec.run([ 'nft' ]), { needs: [ 'exec' ], commands: [ 'nft' ] });
		let t = clock(true);
		let r = run(c, { fs: commands.fs({ [commands.line([ 'nft' ])]: { run: [ 'sh', '-c', 'sleep 3079; :' ] } }), options: { timeout: '1' } });
		let took = (clock(true)[0] - t[0]);

		assert.match({ error: 'COMMAND_TIMEOUT', details: 'nft: still running after 1 s, killed' }, { error: r.result.error, details: r.result.details });
		assert.match(true, took < deps.EXEC_SECONDS, `took ${took} s`);
		assert.match([], commands.running('sleep 3079'));
	});

	it('does not run a collector whose timeout is not 1 to 30 seconds', () => {
		let called = false;
		let c = collector('runner', () => { called = true; return Result.ok(); }, { needs: [ 'exec' ], commands: [ 'nft' ] });
		let r = run(c, { options: { timeout: '31' } });

		assert.match([ false, 'CONFIG_INVALID (timeout: expected an integer from 1 to 30, got 31)' ], [ called, Result.describe(r.result) ]);
	});

	it('stops a collector at its max_samples, keeps none of its samples, and says how far it got', () => {
		let wrote = 0;
		let c = collector('runaway', function(d, out) {
			let g = out.gauge('runaway_value');

			for (let i = 0; i < 1000000; i++, wrote++)
				g({ i }, i);
			return Result.ok();
		});
		let r = run(c, { options: { max_samples: '100' } });

		assert.match([ 100, 0, [] ], [ wrote, r.samples, r.families ]);
		assert.match('SAMPLE_LIMIT (more than its max_samples of 100: stopped at 101 samples, in runaway_value)', Result.describe(r.result));
		assert.match([ "collector 'runaway': SAMPLE_LIMIT (more than its max_samples of 100: stopped at 101 samples, in runaway_value)" ], r.logs);
	});

	it('fails a collector over its max_samples though it caught what stopped it, and counts what parse() adds', () => {
		let stubborn = collector('stubborn', function(d, out) {
			let g = out.gauge('x');

			for (let i = 0; i < 20; i++)
				try { g({ i }, i); } catch (e) { }
			return Result.ok();
		}, { max_samples: 10 });
		let parsed = collector('parsed', (d, out) => out.parse('a 1\nb 2\nc 3\n'), { max_samples: 2 });

		assert.match('SAMPLE_LIMIT', run(stubborn).result.error);
		assert.match('SAMPLE_LIMIT (more than its max_samples of 2: stopped at 3 samples, in c)', Result.describe(run(parsed).result));
	});

	prop('keeps every sample of a collector at or under its max_samples, and none over',
		gen.tuple(gen.int(0, 40), gen.int(1, 30)), (t) => {
			let r = run(collector('n', function(d, out) {
				let g = out.gauge('n_value');

				for (let i = 0; i < t[0]; i++)
					g({ i }, i);
				return Result.ok();
			}, { max_samples: t[1] }));

			assert.match(t[0] <= t[1] ? [ true, t[0] ] : [ false, 0 ], [ r.result.ok, r.samples ]);
		});

	it('fails a collector that wrote what Prometheus would refuse the scrape for with EXPOSITION_INVALID, alone, keeping none of its samples', () => {
		let latin1 = run(collector('wifi', function(d, out) {
			out.gauge('wifi_up')(null, 1);
			out.gauge('wifi_ssid')({ ssid: 'caf\xe9' }, 1);
			return Result.ok();
		}));
		let raw = run(collector('raw', function(d, out) {
			try { out.gauge('raw_x')('eth0 up', 1); } catch (e) { }
			return Result.ok();
		}));

		assert.match([ 'EXPOSITION_INVALID (in wifi_ssid, label \'ssid\': its value is not valid UTF-8)', 0, [] ],
			[ Result.describe(latin1.result), latin1.samples, latin1.families ]);
		assert.match([ "collector 'wifi': EXPOSITION_INVALID (in wifi_ssid, label 'ssid': its value is not valid UTF-8)" ], latin1.logs);
		assert.match('EXPOSITION_INVALID (in raw_x: labels must be an object, or what out.labels() made, not a string of its own)',
			Result.describe(raw.result));
	});

	it('logs a family declared with two types', () => {
		let r = run(collector('mixed', (d, out) => { out.gauge('m')(null, 1); out.counter('m')(null, 2); return Result.ok(); }));
		assert.match(contains([ "collector 'mixed': 'm' declared with two types; later samples dropped" ]), r.logs);
	});
});

describe('scrape.scrape', () => {
	function scrape_with(collectors, query_string, cfg, opts) {
		let out;
		with_mods(cfg ?? {}, (mods) => {
			let logs = [];
			let levels = [];
			out = { ...scrape.scrape(env_for(mods, logs, levels), collectors, query_string, opts), logs, levels };
		});
		return out;
	}

	// The clock reads 0.25 s, then 0.5 s, and so on: A starts at 0.25 and is
	// done at 0.75; at 1.0 the deadline of 0.9 is past.
	it('starts no collector once the deadline is past: each fails with SCRAPE_DEADLINE, logged once, all together', () => {
		let r = scrape_with([ A, B, C ], '', {}, { deadline: 0.9, budget: 0.9 });

		assert.match(contains([
			'a_value 1',
			'node_scrape_collector_duration_seconds{collector="c"} 0',
			'node_scrape_collector_success{collector="a"} 1',
			'node_scrape_collector_success{collector="b-two"} 0',
			'node_scrape_collector_success{collector="c"} 0',
		]), lines(r.body));
		assert.match([ -1, -1 ], [ index(r.body, 'b_value'), index(r.body, 'c_value') ]);
		assert.match([ 'scrape deadline: 2 collectors not served in its 0.9 s: b-two, c' ], r.logs);
		assert.match([ 'warning' ], r.levels);
	});

	it('serves every collector without a deadline, or before it', () => {
		for (let opts in [ null, { deadline: 100, budget: 100 } ]) {
			let r = scrape_with([ A, B, C ], '', {}, opts);

			assert.match([ [], 3 ], [ r.logs, length(filter(lines(r.body), (l) => match(l, /^node_scrape_collector_success\{.*\} 1$/))) ], opts);
		}
	});

	// The instance's state, in memory: a ledger as `text`.
	function memory_state(text) {
		let st = { text, updates: 0 };

		st.read = (name) => (name == ledger.NAME) ? st.text : null;
		st.update = function(name, fn) {
			let out = fn(st.text);

			st.updates++;
			if (type(out) == 'string')
				st.text = out;
			return true;
		};
		return st;
	}

	// A collector that says when it ran.
	function noting(name, ran) {
		return collector(name, function(d, out) {
			push(ran, name);
			out.gauge(`${replace(name, '-', '_')}_value`)(null, 1);
			return Result.ok();
		});
	}

	function ledger_of(durations) {
		return ledger.serialize(ledger.record(ledger.empty(),
			map(keys(durations), (id) => ({ id, duration: durations[id], samples: 1, result: Result.ok() })), null, keys(durations)));
	}

	it('runs the exporter\'s own collectors first when none was timed, light before heavy, then the others', () => {
		let ran = [];
		let heavy = (name) => collector(name, function(d, out) { push(ran, name); return Result.ok(); }, { cost: 'heavy' });

		scrape_with([ noting('aaa', ran), heavy('abc'), heavy('nat_traffic'), noting('loadavg', ran), noting('zz', ran) ], '', {},
			{ state: memory_state(null) });
		assert.match([ 'loadavg', 'nat_traffic', 'aaa', 'zz', 'abc' ], ran);
	});

	it('runs the collectors fastest first by the ledger, and writes them in the order selected', () => {
		let ran = [];
		let r = scrape_with([ noting('a', ran), noting('b-two', ran), noting('c', ran) ], '', {},
			{ state: memory_state(ledger_of({ a: 3, b_two: 0.1, c: 1 })) });

		assert.match([ 'b-two', 'c', 'a' ], ran);
		assert.match([ 'a', 'b-two', 'c' ], map(filter(lines(r.body), (l) => index(l, 'node_scrape_collector_success{') == 0),
			(l) => match(l, /collector="([^"]+)"/)[1]));
	});

	prop('writes the same reply whatever order the ledger runs the collectors in',
		gen.tuple(gen.int(0, 9), gen.int(0, 9), gen.int(0, 9)), (t) => {
			let plain = scrape_with([ A, B, C ], '').body;
			let ordered = scrape_with([ A, B, C ], '', {}, { state: memory_state(ledger_of({ a: t[0], b_two: t[1], c: t[2] })) }).body;

			assert.match(plain, ordered);
		});

	it('records each collector\'s duration and samples in the ledger, and the scrape', () => {
		let st = memory_state(null);

		scrape_with([ A, collector('two', (d, out) => { out.gauge('x')({ i: '1' }, 1)({ i: '2' }, 2); return Result.ok(); }) ], '', {}, { state: st });

		let l = ledger.parse(st.text);

		assert.match([ 1, 1, { d: 0.25, n: 1 }, { d: 0.25, n: 2 } ], [ st.updates, l.scrapes, l.c.a, l.c.two ]);
		assert.match('double', type(l.k));
	});

	// The clock reads 0.25 s, then 0.5 s: at 0.25, 0.5 s left before 0.75.
	it('leaves out a collector the ledger expects to take longer than is left', () => {
		let ran = [];
		let r = scrape_with([ noting('slow', ran), noting('quick', ran) ], '', {},
			{ deadline: 0.75, budget: 0.75, state: memory_state(ledger_of({ slow: 0.6, quick: 0.1 })) });

		assert.match([ 'quick' ], ran);
		assert.match(contains([ 'node_scrape_collector_success{collector="slow"} 0', 'node_scrape_collector_success{collector="quick"} 1' ]),
			lines(r.body));
		assert.match([ 'scrape deadline: 1 collector not served in its 0.8 s: slow' ], r.logs);
	});

	// A clock that stands still: no collector's run uses up the time, so
	// what leaves one out is the ledger's estimate alone.
	function still(collectors, deadline, durations) {
		let out;

		with_mods({}, (mods) => {
			let logs = [];
			let env = { ...env_for(mods, logs), clock: () => [ 0, 0 ] };

			out = { ...scrape.scrape(env, collectors, '', { deadline, budget: deadline, state: memory_state(ledger_of(durations)) }), logs };
		});

		return out;
	}

	it('leaves out a collector whose estimate does not fit the time left, and runs one whose does, on the estimate alone', () => {
		let ran = [];
		let r = still([ noting('slow', ran), noting('quick', ran), noting('fits', ran) ], 1.0, { slow: 1.5, quick: 0.1, fits: 0.9 });

		assert.match([ 'quick', 'fits' ], ran);
		assert.match([ 'scrape deadline: 1 collector not served in its 1.0 s: slow' ], r.logs);
		assert.match(contains([ 'node_scrape_collector_success{collector="slow"} 0' ]), lines(r.body));
	});

	it('logs once a scrape it could not record in the state, and still answers', () => {
		let st = memory_state(null);

		st.update = (name, fn) => { fn(null); return false; };

		let r = scrape_with([ A, B ], '', {}, { state: st });

		assert.match([ "the scrape could not be recorded in the instance's state: its ledger is as the last scrape left it" ], r.logs);
		assert.match(contains([ 'a_value 1', 'b_value 2' ]), lines(r.body));
	});

	it('keeps back the time the reply is expected to take to write, by the samples', () => {
		let ran = [];
		let l = ledger.record(ledger.empty(), [ { id: 'big', duration: 0.1, samples: 1000, result: Result.ok() } ],
			{ seconds: 1, samples: 1000 }, [ 'big' ]);

		scrape_with([ noting('big', ran) ], '', {}, { deadline: 1.2, budget: 1.2, state: memory_state(ledger.serialize(l)) });
		assert.match([], ran);
	});

	// The programs' clock is the real one.
	it('runs a program for no more than the whole seconds left before the deadline, and logs it with the others', () => {
		let seen = [];
		let fs = { behavior: { popen: function(cmd) { push(seen, commands.parse(cmd).seconds); return { read: () => '', close: () => deps.EXEC_KILLED }; } } };
		let runner = collector('runner', (d) => d.exec.run([ 'nft' ]), { needs: [ 'exec' ], commands: [ 'nft' ] });
		let t = clock(true);
		let r = scrape_with([ runner ], '', { fs }, { deadline: t[0] + t[1] / 1000000000.0 + 3.7, budget: 3.7 });

		assert.match([ 3 ], seen);
		assert.match(contains([ 'node_scrape_collector_success{collector="runner"} 0' ]), lines(r.body));
		assert.match([ 'scrape deadline: 1 collector not served in its 3.7 s: runner' ], r.logs);
	});

	it('logs a collector that fails at warning, and a main section it cannot read at err', () => {
		let r = scrape_with([ A, collector('failing', () => Result.err('SOURCE_INVALID')) ], '', { main: { omit_zero_values: 'maybe' } });

		assert.match([ 'err', 'warning' ], r.levels);
		assert.match([ 'main: CONFIG_INVALID (omit_zero_values: expected a boolean, got "maybe")', "collector 'failing': SOURCE_INVALID" ], r.logs);
	});

	it('writes each family once, then durations, then outcomes, then the build', () => {
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
			'# HELP node_scrape_collector_observing Whether a collector had something to observe: 0 when its hardware, kernel feature or service is not there.',
			'# TYPE node_scrape_collector_observing gauge',
			'node_scrape_collector_observing{collector="a"} 1',
			'node_scrape_collector_observing{collector="failing"} 1',
			'# HELP ucode_prometheus_exporter_collector_quarantined Whether a collector is quarantined: its circuit breaker tripped, and it is not run until its cool-down is over.',
			'# TYPE ucode_prometheus_exporter_collector_quarantined gauge',
			'ucode_prometheus_exporter_collector_quarantined{collector="a"} 0',
			'ucode_prometheus_exporter_collector_quarantined{collector="failing"} 0',
			"# HELP ucode_prometheus_exporter_build_info A metric with a constant '1' value labeled by the version of ucode-prometheus-exporter.",
			'# TYPE ucode_prometheus_exporter_build_info gauge',
			'ucode_prometheus_exporter_build_info{version="0.1.0-r1"} 1',
		], lines(r.body));
	});

	it('answers a collector with nothing to observe as a success without samples, observing 0, and logs nothing', () => {
		let idle = collector('idle', (d, out) => { out.gauge('idle_value')(null, 1); return Result.none('dnsmasq is disabled'); });
		let r = scrape_with([ A, idle ], '');

		assert.match([], r.logs);
		assert.match(-1, index(r.body, 'idle_value'));
		assert.match(contains([
			'node_scrape_collector_success{collector="idle"} 1',
			'node_scrape_collector_observing{collector="a"} 1',
			'node_scrape_collector_observing{collector="idle"} 0',
		]), lines(r.body));
		assert.match([ 'node_scrape_collector_duration_seconds{collector="idle"}', 'node_scrape_collector_observing{collector="idle"}',
			'node_scrape_collector_success{collector="idle"}', 'ucode_prometheus_exporter_collector_quarantined{collector="idle"}' ],
			sort(map(filter(lines(r.body), (l) => index(l, 'idle') >= 0), (l) => split(l, ' ')[0])));
	});

	it('writes the build whatever the query selects', () => {
		for (let q in [ '', 'collect[]=a', 'exclude[]=a' ])
			assert.match(contains([ 'ucode_prometheus_exporter_build_info{version="0.1.0-r1"} 1' ]),
				lines(scrape_with([ A ], q).body), q);
	});

	it('holds the collectors of a reply to max_scrape_samples in all: past it one fails with SAMPLE_LIMIT, and none starts once it is reached', () => {
		let two = collector('two', (d, out) => { out.gauge('two_value')({ i: '1' }, 1)({ i: '2' }, 2); return Result.ok(); });
		let st = memory_state(null);
		let over = scrape_with([ A, two, C ], '', { main: { max_scrape_samples: '2' } }, { state: st });
		let full = scrape_with([ A, two, C ], '', { main: { max_scrape_samples: '3' } });

		assert.match(contains([ 'a_value 1', 'c_value 3', 'node_scrape_collector_success{collector="two"} 0' ]), lines(over.body));
		assert.match([ -1 ], [ index(over.body, 'two_value') ]);
		assert.match([ "collector 'two': SAMPLE_LIMIT (more than the 1 samples left of the reply's max_scrape_samples: stopped at 2 samples, in two_value)" ], over.logs);
		assert.match([ null, { SAMPLE_LIMIT: 1 } ], [ ledger.parse(st.text).c.two.f, ledger.parse(st.text).c.two.fails ], 'neither a failure of its own nor a success');

		assert.match(contains([ 'a_value 1', 'two_value{i="2"} 2', 'node_scrape_collector_success{collector="c"} 0' ]), lines(full.body));
		assert.match([ -1, [ "collector 'c': SAMPLE_LIMIT (not run: the reply has its max_scrape_samples of 3)" ] ], [ index(full.body, 'c_value'), full.logs ]);
	});

	it('serves the others when one collector writes what Prometheus refuses, and the reply stays valid', () => {
		let bad = collector('bad', (d, out) => { out.gauge('bad_value')({ 'if-name': 'a', if_name: 'b' }, 1); return Result.ok(); });
		let r = scrape_with([ A, bad, C ], '');

		assert.match(true, exposition.parse(r.body).ok);
		assert.match(contains([ 'a_value 1', 'c_value 3', 'node_scrape_collector_success{collector="bad"} 0' ]), lines(r.body));
		assert.match(-1, index(r.body, 'bad_value'));
	});

	it('gives a family to the first collector of the reply that writes it, and fails the next that does, alone', () => {
		let y = collector('y', (d, out) => {
			out.gauge('y_value')(null, 7);
			out.gauge('shared')({ by: 'y' }, 2);
			return Result.ok();
		});
		let r = scrape_with([ collector('x', gauge_of('shared', 1)), y, C ], '');

		assert.match(contains([ '# TYPE shared gauge', 'shared 1', 'c_value 3',
			'node_scrape_collector_success{collector="x"} 1', 'node_scrape_collector_success{collector="y"} 0',
			'node_scrape_collector_success{collector="c"} 1' ]), lines(r.body));
		assert.match([ -1, -1 ], [ index(r.body, 'by="y"'), index(r.body, 'y_value') ]);
		assert.match([ "collector 'y': FAMILY_CONFLICT (shared belongs to collector x)" ], r.logs);
	});

	it('gives it by the order of the reply, not the order they ran in', () => {
		let st = memory_state(ledger_of({ x: 3, y: 0.1 }));
		let r = scrape_with([ collector('x', gauge_of('shared', 1)), collector('y', gauge_of('shared', 2)) ], '', {}, { state: st });

		assert.match(contains([ 'shared 1', 'node_scrape_collector_success{collector="y"} 0' ]), lines(r.body));
		r = scrape_with([ collector('x', gauge_of('shared', 1)), collector('y', gauge_of('shared', 2)) ], 'collect[]=y&collect[]=x');
		assert.match(contains([ 'shared 2', 'node_scrape_collector_success{collector="x"} 0' ]), lines(r.body));
	});

	it('gives a family one of the exporter\'s own collectors writes to it, before any other\'s', () => {
		let r = scrape_with([ collector('aaa', gauge_of('node_load1', 42)), collector('loadavg', gauge_of('node_load1', 1)) ], '');

		assert.match(contains([ 'node_load1 1', 'node_scrape_collector_success{collector="aaa"} 0',
			'node_scrape_collector_success{collector="loadavg"} 1' ]), lines(r.body));
		assert.match([ "collector 'aaa': FAMILY_CONFLICT (node_load1 belongs to collector loadavg)" ], r.logs);
	});

	it('keeps the scrape\'s own families and the exporter\'s to themselves', () => {
		let r = scrape_with([ A, collector('mimic', (d, out) => {
			out.gauge('node_scrape_collector_success')({ collector: 'a' }, 0);
			return Result.ok();
		}), collector('self', gauge_of('ucode_prometheus_exporter_scrapes_total', 9)) ], '');

		assert.match(contains([ 'node_scrape_collector_success{collector="a"} 1', 'node_scrape_collector_success{collector="mimic"} 0',
			'node_scrape_collector_success{collector="self"} 0' ]), lines(r.body));
		assert.match([
			"collector 'mimic': FAMILY_CONFLICT (node_scrape_collector_success belongs to the scrape itself)",
			"collector 'self': FAMILY_CONFLICT (ucode_prometheus_exporter_scrapes_total belongs to the exporter itself)",
		], r.logs);
		assert.match(-1, index(r.body, 'ucode_prometheus_exporter_scrapes_total'));
	});

	it('gives back the families a collector took before the one it may not write', () => {
		let two = (d, out) => { out.gauge('mine')(null, 1); out.gauge('shared')(null, 2); return Result.ok(); };
		let r = scrape_with([ collector('x', gauge_of('shared', 1)), collector('y', two), collector('z', gauge_of('mine', 3)) ], '');

		assert.match(contains([ 'shared 1', 'mine 3', 'node_scrape_collector_success{collector="y"} 0',
			'node_scrape_collector_success{collector="z"} 1' ]), lines(r.body));
		assert.match([ "collector 'y': FAMILY_CONFLICT (shared belongs to collector x)" ], r.logs);
	});

	it('lets a collector that describes the exporter write the exporter\'s families', () => {
		let r = scrape_with([ collector('self', gauge_of('ucode_prometheus_exporter_scrapes_total', 9), { needs: [ 'exporter' ] }) ], '');

		assert.match(contains([ 'ucode_prometheus_exporter_scrapes_total 9', 'node_scrape_collector_success{collector="self"} 1' ]), lines(r.body));
	});

	prop('serves each family once, from one collector, whatever they write',
		gen.array(gen.elements('f1', 'f2', 'f3'), { min_len: 1, max_len: 6 }), (writes) => {
			let made = map(writes, (f, i) => collector(`w${i}`, gauge_of(f, i)));
			let r = scrape_with(made, '');
			let parsed = exposition.parse(r.body);
			let first = {};

			assert.match(true, parsed.ok, r.body);
			for (let i, f in writes) {
				first[f] ??= i;
				assert.match(first[f] == i, `node_scrape_collector_success{collector="w${i}"} 1` in lines(r.body), f);
			}
			for (let f in uniq(writes))
				assert.match(1, length(filter(parsed.data, (x) => x.name == f)[0].samples), f);
		});

	it('answers 400 for an unknown collector', () => {
		let r = scrape_with([ A ], 'collect[]=nope');
		assert.match([ '400 Bad Request', "COLLECTOR_INVALID (unknown collector 'nope')\n" ], [ r.status, r.body ]);
	});

	// Each collector's settings default to the main section's: read for each,
	// as 0.2.0 did, it cost a scrape a sixth of its time on QEMU's 24Kc.
	it('reads the main section as often for many collectors as for one', () => {
		function reads(collectors) {
			let n = 0;

			with_mods({ main: { collector_budget: '7', max_samples: '500', exec_timeout: '3' } }, (mods) => {
				let counted = { ...mods, uci: { cursor: function() {
					let c = mods.uci.cursor();

					return proto({ get_all: function(name, section) {
						if (section == 'main')
							n++;
						return c.get_all(name, section);
					} }, c);
				} } };

				assert.match('200 OK', scrape.scrape(env_for(counted, []), collectors, '').status);
			});

			return n;
		}

		let many = map([ 'm0', 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7' ], (n) => collector(n, gauge_of(`${n}_value`, 1), { needs: [ 'exec' ], commands: [ 'true' ] }));

		assert.match(reads([ A ]), reads(many));
	});

	it('leaves out a collector its section disables, and answers 400 when the query names it', () => {
		let cfg = { uci: { data: { 'prometheus-exporter': { b_two: { '.type': 'collector', enabled: '0' } } } } };
		let all = scrape_with([ A, B, C ], '', cfg);
		let named = scrape_with([ A, B, C ], 'collect[]=b-two', cfg);

		assert.match([ 'a', 'c' ], map(filter(split(all.body, '\n'), (l) => index(l, 'node_scrape_collector_success{') == 0),
			(l) => match(l, /collector="([^"]+)"/)[1]));
		assert.match([ '400 Bad Request', "COLLECTOR_INVALID (collector 'b-two' is disabled)\n" ], [ named.status, named.body ]);
	});

	it('runs a collector whose enabled is not a boolean, which fails saying why', () => {
		let r = scrape_with([ A ], '', { uci: { data: { 'prometheus-exporter': { a: { '.type': 'collector', enabled: 'maybe' } } } } });

		assert.match(contains([ 'node_scrape_collector_success{collector="a"} 0' ]), split(r.body, '\n'));
		assert.match([ "collector 'a': CONFIG_INVALID (enabled: expected a boolean, got \"maybe\")" ], r.logs);
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
		let pinger = collector('pinger', (d) => d.ubus.call('system', 'board'), { needs: [ 'ubus' ], ubus: { system: [ 'board' ] } });

		with_mods({ ubus: { data: { 'system:board': {} } } }, (mods) => {
			let connect = mods.ubus.connect;
			let wrapped = { ...mods, ubus: { connect: () => { let c = connect(); push(conns, c); return c; } } };
			scrape.scrape(env_for(wrapped, []), [ pinger ], '');
		});

		assert.match([ 1 ], map(conns, (c) => length(c.__utest__.calls.disconnect)));
	});

	prop('never logs nor writes a sample of a collector with nothing to observe, and counts it a success',
		gen.array(gen.elements('ok', 'none', 'err'), { min_len: 1, max_len: 5 }), (kinds) => {
			let made = map(kinds, (k, i) => collector(`c${i}`, function(d, out) {
				out.gauge(`c${i}_value`)(null, 1);
				return k == 'ok' ? Result.ok() : (k == 'none' ? Result.none(`c${i} is disabled`) : Result.err('SOURCE_INVALID'));
			}));
			let r = scrape_with(made, '');
			let body = lines(r.body);

			assert.match(length(filter(kinds, (k) => k == 'err')), length(r.logs));
			for (let i, k in kinds) {
				assert.match(k != 'none', `c${i}_value 1` in body, k);
				assert.match(`node_scrape_collector_success{collector="c${i}"} ${k == 'err' ? 0 : 1}` in body, true, k);
				assert.match(`node_scrape_collector_observing{collector="c${i}"} ${k == 'none' ? 0 : 1}` in body, true, k);
			}
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

describe('scrape.scrape, with circuit breakers', () => {
	// The instance's state, in memory, scrapes after scrapes.
	function memory_state() {
		let st = { text: null };

		st.read = (name) => (name == ledger.NAME) ? st.text : null;
		st.update = function(name, fn) {
			let out = fn(st.text);

			if (type(out) == 'string')
				st.text = out;
			return true;
		};
		return st;
	}

	// Scrapes with `query_string` on one state, `n` times: what each answered
	// and logged, and which collectors ran.
	function scrapes(collectors, n, query_string, st, extra) {
		let out = [];

		st ??= memory_state();
		for (let i = 0; i < n; i++)
			with_mods({}, (mods) => {
				let logs = [];
				let levels = [];
				let r = scrape.scrape({ ...env_for(mods, logs, levels), ...(extra ?? {}) }, collectors, query_string ?? '', { state: st });

				push(out, { body: lines(r.body), logs, levels });
			});

		return out;
	}

	function flaky(name, plan, ran) {
		let i = 0;

		return collector(name, function(d, out) {
			let ok = plan[min(i++, length(plan) - 1)];

			push(ran, name);
			out.gauge(`${name}_value`)(null, 1);
			return ok ? Result.ok() : Result.err('SOURCE_INVALID', 'garbled');
		});
	}

	function quarantined(r, name) {
		return `ucode_prometheus_exporter_collector_quarantined{collector="${name}"} 1` in r.body;
	}

	function succeeded(r, name) {
		return `node_scrape_collector_success{collector="${name}"} 1` in r.body;
	}

	it('quarantines a collector after three failures in a row, logs it once, and leaves it out for a scrape', () => {
		let ran = [];
		let rs = scrapes([ A, flaky('f', [ false ], ran) ], 5);

		assert.match([ 'f', 'f', 'f', 'f' ], ran, 'runs 1 to 3, then 5: its trial');
		assert.match([ false, false, false, true, false ], map(rs, (r) => quarantined(r, 'f')));
		assert.match([ "collector 'f': SOURCE_INVALID (garbled)", "collector 'f' quarantined for 1 scrape: SOURCE_INVALID (garbled)" ], rs[2].logs);
		assert.match([ [], [ 'warning', 'warning' ] ], [ rs[3].logs, rs[4].levels ]);
		assert.match(contains([ 'node_scrape_collector_success{collector="a"} 1', 'node_scrape_collector_success{collector="f"} 0' ]),
			slice(rs[3].body, 0));
		assert.match(-1, index(join('\n', rs[3].body), 'f_value'));
	});

	it('keeps a quarantined collector out even when the query names it', () => {
		let ran = [];
		let st = memory_state();

		scrapes([ A, flaky('f', [ false ], ran) ], 3, '', st);
		let r = scrapes([ A, flaky('f', [ false ], ran) ], 1, 'collect[]=f', st)[0];

		assert.match([ true, false, 3 ], [ quarantined(r, 'f'), succeeded(r, 'f'), length(ran) ]);
	});

	it('serves a collector again once its trial succeeds, and says so', () => {
		let ran = [];
		let rs = scrapes([ flaky('f', [ false, false, false, true ], ran) ], 6);

		assert.match([ true, false, false ], [ quarantined(rs[3], 'f'), quarantined(rs[4], 'f'), quarantined(rs[5], 'f') ]);
		assert.match([ "collector 'f' served again: its trial succeeded" ], rs[4].logs);
		assert.match([ 'notice' ], rs[4].levels);
		assert.match(true, succeeded(rs[5], 'f'));
	});

	// The clock reads 0.25 s apart: a collector takes 0.25 s.
	it('quarantines a collector that takes longer than its budget, though it succeeded', () => {
		let main = { main: { collector_budget: '1' } };

		with_mods(main, (mods) => {
			let logs = [];
			let env = env_for(mods, logs);
			let tick = env.clock;

			// 1.25 s between two readings.
			env.clock = () => { tick(); tick(); tick(); tick(); return tick(); };
			let r = scrape.scrape(env, [ A ], '', { state: memory_state() });

			assert.match(contains([ 'node_scrape_collector_success{collector="a"} 1' ]), lines(r.body));
			assert.match([ "collector 'a' quarantined for 1 scrape: COLLECTOR_OVERRUN (took 1.25 s, over its budget of 1 s)" ], logs);
		});
	});

	it('quarantines the collector a dead scrape process was running, says so, and runs the others', () => {
		let ran = [];
		let st = memory_state();
		let claimed = [];

		st.dead = () => [ { file: '1-1.p9_9', running: 'f', child: { pid: 77, start: '9' } }, { file: '1-1.p8_8', running: null } ];
		st.claim = function(f) {
			if (f in claimed)
				return false;
			push(claimed, f);
			return true;
		};

		let killed = [];
		let rs = scrapes([ A, flaky('f', [ true ], ran) ], 2, '', st, { kill: (pid) => push(killed, pid) });

		assert.match([ 77 ], killed, 'the child it ran in, left behind');

		assert.match([ [ 'f' ], [ '1-1.p9_9', '1-1.p8_8' ] ], [ ran, claimed ], 'run once: the second scrape is its trial');
		assert.match([ true, false ], [ quarantined(rs[0], 'f'), quarantined(rs[1], 'f') ]);
		assert.match([ "collector 'f' was running when a scrape process died",
			"collector 'f' quarantined for 1 scrape: COLLECTOR_KILLED (its scrape process died while it ran: out of memory, a crash, or killed)" ], rs[0].logs);
		assert.match([ "collector 'f' served again: its trial succeeded" ], rs[1].logs);
	});

	prop('never runs a quarantined collector, and always answers every selected one, in order',
		gen.array(gen.elements(true, false), { min_len: 1, max_len: 12 }), (plan) => {
			let ran = [];
			let st = memory_state();
			let f = flaky('f', plan, ran);
			let runs = 0;

			for (let i = 0; i < length(plan); i++) {
				let before = length(ran);
				let r = scrapes([ A, f, C ], 1, '', st)[0];
				let names = map(filter(r.body, (l) => index(l, 'node_scrape_collector_success{') == 0), (l) => match(l, /collector="([^"]+)"/)[1]);

				assert.match([ 'a', 'f', 'c' ], names);
				assert.match(quarantined(r, 'f'), length(ran) == before);
				runs++;
			}

			assert.match(length(plan), runs);
		});
});

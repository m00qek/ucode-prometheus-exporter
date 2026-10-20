'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { popen } from 'fs';
import * as deps from 'prometheus.exporter.deps';
import * as deps_exec from 'prometheus.exporter.deps.exec';
import { with_mods } from 'prometheus.exporter.devkit.collector';
import * as commands from 'prometheus.exporter.devkit.commands';

// clock() gives these, in ms from 0, one per call.
function clock_times(times) {
	let i = 0;
	return () => { let ms = times[min(i++, length(times) - 1)]; return [ 1000 + ms / 1000, (ms % 1000) * 1000000 ]; };
}

function brief(res) {
	return res.ok ? { ok: true, data: res.data } : { ok: false, error: res.error, details: res.details };
}

// A popen whose handles answer `outputs[command line]` = { out, status }, the
// command line taken out of exec's script: utest's fs mock closes a popen handle
// without the exit status real ucode gives.
function popen_answering(outputs, seen) {
	return function(cmd, mode) {
		push(seen, cmd);
		let o = outputs[commands.parse(cmd)?.line];
		return o == null ? null : { read: () => o.out, close: () => o.status };
	};
}

describe('deps.exec.exec_channel', () => {
	it('runs an allowed program with quoted arguments, under the watchdog with the default seconds', () => {
		let seen = [];
		let ch = deps_exec.exec_channel(popen_answering({ "'nft' '--json' 'list counters'": { out: '{}', status: 0 } }, seen), [ 'nft' ]);

		assert.match({ ok: true, data: '{}' }, brief(ch.run([ 'nft', '--json', 'list counters' ])));
		assert.match([ { seconds: 5, line: "'nft' '--json' 'list counters'" } ], map(seen, commands.parse));
		assert.match(deps_exec.EXEC_SECONDS, 5);
	});

	it('refuses a program not in the allowlist, without running anything', () => {
		let seen = [];
		let ch = deps_exec.exec_channel(popen_answering({}, seen), [ 'nft' ]);

		assert.match({ ok: false, error: 'COMMAND_NOT_ALLOWED', details: 'sh' }, brief(ch.run([ 'sh', '-c', 'reboot' ])));
		assert.match([], seen);
	});

	it('fails on a non-zero exit status, and on a program that cannot start', () => {
		let ch = deps_exec.exec_channel(popen_answering({ "'mmcli' '-L'": { out: '', status: 1 } }, []), [ 'mmcli', 'nope' ]);

		assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'mmcli: exit status 1' }, brief(ch.run([ 'mmcli', '-L' ])));
		assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'nope: cannot start' }, brief(ch.run([ 'nope' ])));
		assert.match([ { status: 1 }, { status: null } ], [ ch.run([ 'mmcli', '-L' ]).data, ch.run([ 'nope' ]).data ]);
	});

	it('fails with COMMAND_TIMEOUT when the watchdog killed the program', () => {
		let ch = deps_exec.exec_channel(popen_answering({ "'ubnt-manager' '-l'": { out: 'partial', status: deps_exec.EXEC_KILLED } }, []), [ 'ubnt-manager' ]);
		let res = ch.run([ 'ubnt-manager', '-l' ]);

		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'ubnt-manager: still running after 5 s, killed' }, brief(res));
		assert.match({ status: null, timed_out: true }, res.data);
	});

	it('spends one allowance of seconds across the programs it runs, from the first', () => {
		let seen = [];
		let ch = deps_exec.exec_channel(popen_answering({ "'mmcli' '-L'": { out: '', status: 0 } }, seen), [ 'mmcli' ], 5,
			clock_times([ 0, 3500, 4999, 5000, 9000 ]));

		let ran = map([ 1, 2, 3, 4, 5 ], () => ch.run([ 'mmcli', '-L' ]));

		assert.match([ 5, 2, 1 ], map(seen, (s) => commands.parse(s).seconds));
		assert.match([ true, true, true, false, false ], map(ran, (r) => r.ok));
		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: "mmcli: not run, the collector's 5 s for commands are spent" }, brief(ran[3]));
		assert.match({ status: null, timed_out: true }, ran[4].data);
	});

	it('gives the seconds it is made with', () => {
		let seen = [];
		deps_exec.exec_channel(popen_answering({}, seen), [ 'nft' ], 12, clock_times([ 0 ])).run([ 'nft' ]);

		assert.match([ 12 ], map(seen, (s) => commands.parse(s).seconds));
	});

	it('gives a program no more than the whole seconds left before the scrape\'s cutoff', () => {
		let seen = [];
		let ch = deps_exec.exec_channel(popen_answering({ "'nft'": { out: '', status: 0 } }, seen), [ 'nft' ], 5, clock_times([ 0, 2500 ]), 1003.7);

		ch.run([ 'nft' ]);
		ch.run([ 'nft' ]);
		assert.match([ 3, 1 ], map(seen, (s) => commands.parse(s).seconds));
	});

	it('runs no program with less than a second left before the cutoff: SCRAPE_DEADLINE', () => {
		let seen = [];
		let res = deps_exec.exec_channel(popen_answering({}, seen), [ 'nft' ], 5, clock_times([ 0 ]), 1000.9).run([ 'nft' ]);

		assert.match({ ok: false, error: 'SCRAPE_DEADLINE', details: "nft: not run, less than a second is left before the scrape's deadline" }, brief(res));
		assert.match({ status: null, timed_out: true, deadline: true }, res.data);
		assert.match([], seen);
	});

	it('tells a program killed at the cutoff from one killed at its own seconds', () => {
		let killed = popen_answering({ "'ubnt-manager'": { out: '', status: deps_exec.EXEC_KILLED } }, []);

		assert.match({ ok: false, error: 'SCRAPE_DEADLINE', details: "ubnt-manager: still running at the scrape's deadline, after 2 s, killed" },
			brief(deps_exec.exec_channel(killed, [ 'ubnt-manager' ], 5, clock_times([ 0 ]), 1002.5).run([ 'ubnt-manager' ])));
		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'ubnt-manager: still running after 5 s, killed' },
			brief(deps_exec.exec_channel(killed, [ 'ubnt-manager' ], 5, clock_times([ 0 ]), 1009).run([ 'ubnt-manager' ])));
	});

	prop('never gives a program more than its own seconds, nor a second past the cutoff',
		gen.tuple(gen.int(1, 30), gen.int(0, 40000), gen.int(0, 40000)), (t) => {
			let seen = [];
			let res = deps_exec.exec_channel(popen_answering({ "'nft'": { out: '', status: 0 } }, seen), [ 'nft' ], t[0], clock_times([ t[1] ]),
				1000 + t[2] / 1000.0).run([ 'nft' ]);
			let given = length(seen) ? commands.parse(seen[0]).seconds : 0;

			assert.match(true, given <= t[0]);
			assert.match(true, t[1] + given * 1000 <= max(t[2], t[1]));
			assert.match(given == 0, res.error == 'SCRAPE_DEADLINE');
		});

	prop('quotes any argument so a real shell passes it on unchanged', gen.ascii({ min_len: 0, max_len: 24 }), (arg) => {
		let p = popen("printf '%s' " + deps_exec.shell_quote(arg), 'r');
		let out = p.read('all');
		p.close();

		assert.match(arg, out);
	});
});

function seconds_since(t) {
	let now = clock(true);
	return (now[0] - t[0]) + (now[1] - t[1]) / 1000000000.0;
}

// Real programs under the real watchdog script, through /bin/sh.
describe('deps.exec.exec_channel, running programs', () => {
	it('gives a program\'s whole output, without its stderr, and its exit status', () => {
		let ch = deps_exec.exec_channel(popen, [ 'sh' ]);
		let big = ch.run([ 'sh', '-c', 'i=0; while [ $i -lt 20000 ]; do echo 0123456789; i=$((i+1)); done' ]);

		assert.match({ ok: true, data: 'out\n' }, brief(ch.run([ 'sh', '-c', 'echo out; echo err >&2' ])));
		assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'sh: exit status 3' }, brief(ch.run([ 'sh', '-c', 'exit 3' ])));
		assert.match([ true, 220000 ], [ big.ok, length(big.data) ]);
	});

	it('gives the shell\'s 127 for a program that is not there', () => {
		assert.match({ status: 127 }, deps_exec.exec_channel(popen, [ 'prometheus-exporter-no-such-program' ]).run([ 'prometheus-exporter-no-such-program' ]).data);
	});

	it('does not hold a program that is done to its seconds', () => {
		let t = clock(true);
		let res = deps_exec.exec_channel(popen, [ 'printf' ], 5).run([ 'printf', '%s', 'x' ]);

		assert.match({ ok: true, data: 'x' }, brief(res));
		assert.match(true, seconds_since(t) < 1);
	});

	it('kills a program still running when its seconds are spent, and what it started', () => {
		let t = clock(true);
		let res = deps_exec.exec_channel(popen, [ 'sh' ], 1).run([ 'sh', '-c', 'echo partial; sleep 3061 & x=$(sh -c "sleep 3062; :"); wait' ]);

		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'sh: still running after 1 s, killed' }, brief(res));
		assert.match({ status: null, timed_out: true }, res.data);
		assert.match(true, seconds_since(t) < 3);
		assert.match([], commands.running('sleep 306'));
	});

	it('does not start a program once the seconds are spent', () => {
		let ch = deps_exec.exec_channel(popen, [ 'sleep', 'printf' ], 1);

		assert.match('COMMAND_TIMEOUT', ch.run([ 'sleep', '3063' ]).error);
		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: "printf: not run, the collector's 1 s for commands are spent" },
			brief(ch.run([ 'printf', 'x' ])));
		assert.match([], commands.running('sleep 3063'));
	});

	prop('passes any argument on unchanged', gen.ascii({ min_len: 0, max_len: 24 }), (arg) => {
		assert.match({ ok: true, data: arg }, brief(deps_exec.exec_channel(popen, [ 'printf' ]).run([ 'printf', '%s', arg ])));
	});
});

// Several programs in one watchdog: each one's output and exit status, as run() gives them.
describe('deps.exec.exec_channel, run_all', () => {
	it('runs the allowed programs one after the other in one script, and refuses the others without running them', () => {
		let seen = [];
		let answer = commands.fs({
			"'nft' '-j'": { out: '{}' }, "'tc' 'x'": { out: 'no\n', status: 2 },
		}).behavior.popen;
		let popen_fn = (cmd, mode) => { push(seen, cmd); return answer(cmd, mode); };
		let res = deps_exec.exec_channel(popen_fn, [ 'nft', 'tc' ]).run_all([ [ 'nft', '-j' ], [ 'sh', '-c', 'reboot' ], [ 'tc', 'x' ] ]);

		assert.match([
			{ ok: true, data: '{}' },
			{ ok: false, error: 'COMMAND_NOT_ALLOWED', details: 'sh' },
			{ ok: false, error: 'COMMAND_FAILED', details: 'tc: exit status 2' },
		], map(res, brief));
		assert.match([ { seconds: 5, lines: [ "'nft' '-j'", "'tc' 'x'" ] } ], map(seen, (c) => { let b = commands.parse_batch(c); return { seconds: b.seconds, lines: b.lines }; }));
	});

	it('runs nothing for no programs, nor for none allowed', () => {
		let seen = [];
		let ch = deps_exec.exec_channel((c) => { push(seen, c); return null; }, [ 'nft' ]);

		assert.match([ [], [ 'COMMAND_NOT_ALLOWED' ] ], [ ch.run_all([]), map(ch.run_all([ [ 'sh' ] ]), (r) => r.error) ]);
		assert.match([], seen);
	});

	it('fails each program when the batch cannot start', () => {
		let res = deps_exec.exec_channel(() => null, [ 'nft', 'tc' ]).run_all([ [ 'nft' ], [ 'tc' ] ]);

		assert.match([ 'nft: cannot start', 'tc: cannot start' ], map(res, (r) => r.details));
		assert.match([ { status: null }, { status: null } ], map(res, (r) => r.data));
	});

	it('spends the collector\'s seconds as run() does, and runs nothing once they are spent', () => {
		let seen = [];
		let answer = commands.fs({ "'nft'": { out: '' } }).behavior.popen;
		let ch = deps_exec.exec_channel((c, m) => { push(seen, c); return answer(c, m); }, [ 'nft' ], 5, clock_times([ 0, 3500, 5000 ]));

		ch.run([ 'nft' ]);
		ch.run_all([ [ 'nft' ], [ 'nft' ] ]);
		let spent = ch.run_all([ [ 'nft' ], [ 'nft' ] ]);

		assert.match([ 5, 2 ], [ commands.parse(seen[0]).seconds, commands.parse_batch(seen[1]).seconds ]);
		assert.match([ "nft: not run, the collector's 5 s for commands are spent", "nft: not run, the collector's 5 s for commands are spent" ],
			map(spent, (r) => r.details));
		assert.match(2, length(seen));
	});

	it('runs nothing with less than a second left before the cutoff: SCRAPE_DEADLINE', () => {
		let res = deps_exec.exec_channel(() => die('ran'), [ 'nft' ], 5, clock_times([ 0 ]), 1000.9).run_all([ [ 'nft' ] ]);

		assert.match([ { ok: false, error: 'SCRAPE_DEADLINE', details: "nft: not run, less than a second is left before the scrape's deadline" } ], map(res, brief));
	});

	it('gives each real program its whole output, without its stderr, and its exit status', () => {
		let res = deps_exec.exec_channel(popen, [ 'sh', 'printf', 'prometheus-exporter-no-such-program' ]).run_all([
			[ 'sh', '-c', 'echo out; echo err >&2' ],
			[ 'printf', '%s', 'no newline' ],
			[ 'sh', '-c', 'exit 3' ],
			[ 'printf', '' ],
			[ 'prometheus-exporter-no-such-program' ],
			[ 'printf', '\n\n' ],
		]);

		assert.match([
			{ ok: true, data: 'out\n' }, { ok: true, data: 'no newline' },
			{ ok: false, error: 'COMMAND_FAILED', details: 'sh: exit status 3' }, { ok: true, data: '' },
			{ ok: false, error: 'COMMAND_FAILED', details: 'prometheus-exporter-no-such-program: exit status 127' },
			{ ok: true, data: '\n\n' },
		], map(res, brief));
	});

	it('kills the batch at its seconds: what ran before is kept, the program running and the rest fail', () => {
		let t = clock(true);
		let res = deps_exec.exec_channel(popen, [ 'sh', 'printf' ], 1).run_all([
			[ 'printf', 'first' ],
			[ 'sh', '-c', 'echo partial; sleep 3071 & x=$(sh -c "sleep 3072; :"); wait' ],
			[ 'printf', 'never' ],
		]);

		assert.match([
			{ ok: true, data: 'first' },
			{ ok: false, error: 'COMMAND_TIMEOUT', details: 'sh: still running after 1 s, killed' },
			{ ok: false, error: 'COMMAND_TIMEOUT', details: "printf: not run, the collector's 1 s for commands are spent" },
		], map(res, brief));
		assert.match(true, seconds_since(t) < 3);
		assert.match([], commands.running('sleep 307'));
	});

	prop('passes any arguments on unchanged, each program\'s output its own',
		gen.array(gen.ascii({ min_len: 0, max_len: 16 }), { min_len: 1, max_len: 5 }), (args) => {
			let res = deps_exec.exec_channel(popen, [ 'printf' ]).run_all(map(args, (a) => [ 'printf', '%s', a ]));

			assert.match(map(args, (a) => ({ ok: true, data: a })), map(res, brief));
		});
});

describe('devkit.commands', () => {
	it('fakes what exec runs, exit status included', () => {
		with_mods({ fs: commands.fs({ [commands.line([ 'nft', '-j' ])]: { out: '{}', status: 0 }, [commands.line([ 'nft', 'x' ])]: { out: '', status: 2 } }) }, (mods) => {
			let exec = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec;

			assert.match([ true, '{}', 'nft: exit status 2', 'nft: cannot start' ],
				[ exec.run([ 'nft', '-j' ]).ok, exec.run([ 'nft', '-j' ]).data, exec.run([ 'nft', 'x' ]).details, exec.run([ 'nft', 'y' ]).details ]);
		});
	});

	it('fakes a program that hangs', () => {
		with_mods({ fs: commands.fs({ [commands.line([ 'nft', '-j' ])]: { hangs: true } }) }, (mods) => {
			let res = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec.run([ 'nft', '-j' ]);

			assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'nft: still running after 5 s, killed' }, brief(res));
		});
	});

	it('runs a real program in a fake one\'s place, with its own seconds', () => {
		with_mods({ fs: commands.fs({ [commands.line([ 'nft', '-j' ])]: { run: [ 'sh', '-c', 'sleep 3064' ], seconds: 1 } }) }, (mods) => {
			let t = clock(true);
			let res = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec.run([ 'nft', '-j' ]);

			assert.match([ 'COMMAND_TIMEOUT', true ], [ res.error, seconds_since(t) < 3 ]);
			assert.match([], commands.running('sleep 3064'));
		});
	});

	it('takes apart the scripts exec runs, and nothing else', () => {
		assert.match({ seconds: 7, line: "'a b' 'c\n'" }, commands.parse(deps_exec.exec_script([ 'a b', 'c\n' ], 7)));
		assert.match([ null, null ], [ commands.parse("'nft' 2>/dev/null"), commands.parse('set -- 1 x') ]);
		assert.match(null, commands.parse(deps_exec.batch_script([ [ 'nft' ] ], 7, 'm')));
	});

	it('takes apart the scripts run_all runs, and nothing else', () => {
		assert.match({ seconds: 3, mark: 'x-1', lines: [ "'a b' 'c\n'", "'nft'" ] },
			commands.parse_batch(deps_exec.batch_script([ [ 'a b', 'c\n' ], [ 'nft' ] ], 3, 'x-1')));
		assert.match([ null, null ], [ commands.parse_batch(deps_exec.exec_script([ 'nft' ], 3)), commands.parse_batch('nft') ]);
	});

	it('fakes the programs of a batch, one that hangs stopping it there', () => {
		let fake = { [commands.line([ 'nft', '-j' ])]: { out: '{}' }, [commands.line([ 'nft', 'x' ])]: { hangs: true }, [commands.line([ 'nft', 'y' ])]: { status: 2 } };

		with_mods({ fs: commands.fs(fake) }, (mods) => {
			let exec = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec;

			assert.match([ { ok: true, data: '{}' }, { ok: false, error: 'COMMAND_FAILED', details: 'nft: exit status 2' } ],
				map(exec.run_all([ [ 'nft', '-j' ], [ 'nft', 'y' ] ]), brief));
			assert.match([ 'nft: still running after 5 s, killed', "nft: not run, the collector's 5 s for commands are spent" ],
				map(slice(exec.run_all([ [ 'nft', '-j' ], [ 'nft', 'x' ], [ 'nft', 'y' ] ]), 1), (r) => r.details));
			assert.match([ 'nft: cannot start', 'nft: cannot start' ], map(exec.run_all([ [ 'nft', '-j' ], [ 'nft', 'z' ] ]), (r) => r.details));
		});
	});
});

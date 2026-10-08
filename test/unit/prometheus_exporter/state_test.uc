'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as state from 'prometheus_exporter.state';
import * as auth from 'prometheus_exporter.auth';

const DIR = '/state';

// A filesystem of `files` ({ path: { data, mode } }) and `dirs` ({ path: mode }),
// with /proc/self/stat as `stat`; `broken` names the calls that fail (`lock`
// a lock not taken). `locks` has what happened to locks, in order: [ 'x', path ]
// when one is taken, [ 'close', path ] when its file is closed; `held`, the
// path of the lock held, or null.
function filesystem(files, dirs, broken, stat, procs) {
	let fails = (name) => (name in (broken ?? []));
	let fs = null;

	fs = {
		files, dirs,
		locks: [],
		held: null,
		open: function(p, mode) {
			if (fails('open') || mode != 'a')
				return null;
			files[p] ??= { data: '', mode: 0o644 };
			return {
				lock: function(op) {
					if (fails('lock')) return false;
					push(fs.locks, [ op, p ]);
					fs.held = p;
					return true;
				},
				close: function() { push(fs.locks, [ 'close', p ]); if (fs.held == p) fs.held = null; return true; },
				write: function(text) { files[p].data += text; return length(text); },
				flush: () => true,
			};
		},
		error: () => 'Permission denied',
		stat: (p) => (p in keys(files) || p in keys(dirs)) ? { type: (p in keys(dirs)) ? 'directory' : 'file' } : null,
		mkdir: function(p, mode) { if (fails('mkdir')) return null; dirs[p] = mode; return true; },
		chmod: function(p, mode) {
			if (fails('chmod')) return null;
			if (p in keys(dirs)) dirs[p] = mode; else files[p].mode = mode;
			return true;
		},
		unlink: function(p) { if (fails('unlink') || !(p in keys(files))) return null; delete files[p]; return true; },
		rename: function(a, b) { if (fails('rename')) return null; files[b] = files[a]; delete files[a]; return true; },
		readfile: function(p, size) {
			if (p == '/proc/self/stat')
				return stat;
			if (match(p, /^\/proc\/[0-9]+\/stat$/))
				return procs?.[split(p, '/')[2]];
			return (p in keys(files)) ? substr(files[p].data, 0, size) : null;
		},
		lsdir: function(d) {
			let out = [];

			for (let p in keys(files))
				if (substr(p, 0, length(d) + 1) == d + '/')
					push(out, substr(p, length(d) + 1));
			return (d in keys(dirs)) ? out : null;
		},
		writefile: function(p, d) {
			if (fails('writefile')) return null;
			if (fs.held == null) die(`${p} written without the lock`);
			files[p] = { data: d, mode: 0o644 };
			return fails('short') ? length(d) - 1 : length(d);
		},
	};

	return fs;
}

function stat_of(pid, comm, start) {
	return `${pid} (${comm}) S 1 ${pid} ${pid} 0 -1 4194560 719 0 0 0 3 0 0 0 20 0 1 0 ${start} 1257472 230 18446744073709551615\n`;
}

describe('state.instance_id', () => {
	it('is the pid and the start time of the process', () => {
		assert.match('1234-5678', state.instance_id(filesystem({}, {}, [], stat_of(1234, 'uhttpd', 5678))));
	});

	it('reads past a command that holds spaces and parentheses', () => {
		assert.match('7-99', state.instance_id(filesystem({}, {}, [], stat_of(7, 'a) (b c', 99))));
	});

	it('is null when /proc does not say', () => {
		assert.match([ null, null, null ], map([ null, '', '12 (x) S 1' ], (s) => state.instance_id(filesystem({}, {}, [], s))));
	});

	prop('tells apart processes of another pid or start time, whatever the command', gen.tuple(gen.int(1, 99999), gen.int(1, 99999), gen.int(0, 9999999),
		gen.int(0, 9999999), gen.string({ min_len: 1, max_len: 15, charset: 'ab )(' })), (t) => {
		let id = (pid, start) => state.instance_id(filesystem({}, {}, [], stat_of(pid, t[4], start)));

		assert.match([ `${t[0]}-${t[2]}`, (t[0] == t[1] && t[2] == t[3]) ], [ id(t[0], t[2]), id(t[0], t[2]) == id(t[1], t[3]) ]);
	});
});

describe('state.make', () => {
	it('makes the run directory and the state directory, both closed to their owner', () => {
		let fs = filesystem({}, {});

		assert.match({ ok: true, problem: null }, state.make(fs));
		assert.match({ [state.RUN_DIR]: 0o700, [state.DIR]: 0o700 }, fs.dirs);
	});

	it('closes directories there already', () => {
		let fs = filesystem({}, { [state.RUN_DIR]: 0o755, [state.DIR]: 0o777 });

		state.make(fs);
		assert.match({ [state.RUN_DIR]: 0o700, [state.DIR]: 0o700 }, fs.dirs);
	});

	it('says what it could not make', () => {
		assert.match({ ok: false, problem: `cannot make ${state.RUN_DIR}: Permission denied` }, state.make(filesystem({}, {}, [ 'mkdir' ])));
	});

	it('lives beside uhttpd\'s file of basic auth, never under /etc', () => {
		assert.match([ auth.DIR, `${auth.DIR}/state`, false ], [ state.RUN_DIR, state.DIR, substr(state.DIR, 0, 5) == '/etc/' ]);
	});
});

describe('state.open', () => {
	it('reads back what it writes, from a file of the instance, mode 0600', () => {
		let fs = filesystem({}, { [DIR]: 0o700 });
		let st = state.open(fs, DIR, '1-2');

		assert.match([ null, true, 'abc' ], [ st.read('auth'), st.write('auth', 'abc'), st.read('auth') ]);
		assert.match({ data: 'abc', mode: 0o600 }, fs.files[`${DIR}/1-2.auth`]);
		assert.match([ `${DIR}/1-2.auth`, `${DIR}/1-2.lock` ], sort(keys(fs.files)));
	});

	it('writes holding the instance\'s lock, and lets go of it', () => {
		let fs = filesystem({}, { [DIR]: 0o700 });

		state.open(fs, DIR, '1-2').write('auth', 'abc');
		assert.match([ [ 'x', `${DIR}/1-2.lock` ], [ 'close', `${DIR}/1-2.lock` ] ], fs.locks);
		assert.match(null, fs.held);
	});

	it('writes nothing when it cannot take the lock', () => {
		for (let broken in [ 'open', 'lock' ]) {
			let fs = filesystem({}, { [DIR]: 0o700 }, [ broken ]);
			let st = state.open(fs, DIR, '1-2');

			assert.match([ false, false, null ], [ st.write('auth', 'abc'), st.update('auth', () => 'abc'), st.read('auth') ], broken);
			assert.match(null, fs.held, broken);
		}
	});

	it('updates under the lock: what is there, changed by fn, written whole', () => {
		let fs = filesystem({}, { [DIR]: 0o700 });
		let st = state.open(fs, DIR, '1-2');
		let seen = [];
		let count = function(old) {
			push(seen, [ old, fs.held ]);
			return '' + (+(old ?? 0) + 1);
		};

		assert.match([ true, true, '2' ], [ st.update('scrape', count), st.update('scrape', count), st.read('scrape') ]);
		assert.match([ [ null, `${DIR}/1-2.lock` ], [ '1', `${DIR}/1-2.lock` ] ], seen);
		assert.match(0o600, fs.files[`${DIR}/1-2.scrape`].mode);
	});

	it('writes nothing for an update whose fn gives no string, or too long a one', () => {
		let fs = filesystem({ [`${DIR}/1-2.scrape`]: { data: 'kept', mode: 0o600 } }, { [DIR]: 0o700 });
		let st = state.open(fs, DIR, '1-2');

		assert.match([ false, false, false, 'kept', null ],
			[ st.update('scrape', () => null), st.update('scrape', () => 3), st.update('scrape', () => sprintf(`%0${state.SIZE_MAX + 1}d`, 0)),
				st.read('scrape'), fs.held ]);
	});

	it('keeps the lock\'s name for the lock', () => {
		let st = state.open(filesystem({}, { [DIR]: 0o700 }), DIR, '1-2');

		assert.match([ false, false, null ], [ st.write('lock', 'x'), st.update('lock', () => 'x'), st.read('lock') ]);
	});

	it('replaces what it wrote before, whole', () => {
		let fs = filesystem({}, { [DIR]: 0o700 });
		let st = state.open(fs, DIR, '1-2');

		st.write('auth', 'a longer one');
		st.write('auth', 'short');
		assert.match('short', st.read('auth'));
	});

	it('removes the files of every other instance, and only state files', () => {
		let fs = filesystem({
			[`${DIR}/1-2.auth`]: { data: 'old' },
			[`${DIR}/1-2.auth.new`]: { data: 'half' },
			[`${DIR}/1-2.lock`]: { data: '' },
			[`${DIR}/1-3.breaker`]: { data: 'mine' },
			[`${DIR}/notes.txt`]: { data: 'not ours' },
		}, { [DIR]: 0o700 });
		let st = state.open(fs, DIR, '1-3');

		assert.match([ `${DIR}/1-3.breaker`, `${DIR}/notes.txt` ], sort(keys(fs.files)));
		assert.match([ null, 'mine' ], [ st.read('auth'), st.read('breaker') ]);
	});

	it('keeps nothing without an instance id, and removes nothing', () => {
		let fs = filesystem({ [`${DIR}/1-2.auth`]: { data: 'old' } }, { [DIR]: 0o700 });
		let st = state.open(fs, DIR, null);

		assert.match([ false, false, null, [ `${DIR}/1-2.auth` ] ], [ st.write('auth', 'x'), st.update('auth', () => 'x'), st.read('auth'), keys(fs.files) ]);
	});

	it('takes names of lowercase letters, digits and _, and data of at most SIZE_MAX bytes', () => {
		let st = state.open(filesystem({}, { [DIR]: 0o700 }), DIR, '1-2');
		let big = sprintf(`%0${state.SIZE_MAX}d`, 0);

		assert.match([ false, false, false, false, false, true, false ], [
			st.write('../auth', 'x'), st.write('a.b', 'x'), st.write('', 'x'), st.write(null, 'x'), st.write('auth', null),
			st.write('auth', big), st.write('auth', big + '0'),
		]);
		assert.match(null, st.read('../auth'));
	});

	it('leaves no half-written file when it cannot write, and says so', () => {
		let write = (broken) => {
			let fs = filesystem({}, { [DIR]: 0o700 }, broken);
			return [ state.open(fs, DIR, '1-2').write('auth', 'x'), keys(fs.files) ];
		};

		let none = [ false, [ `${DIR}/1-2.lock` ] ];

		assert.match([ none, none, none, none ], [ write([ 'writefile' ]), write([ 'short' ]), write([ 'chmod' ]), write([ 'rename' ]) ]);
	});

	it('reads nothing when the directory is not there', () => {
		let st = state.open(filesystem({}, {}), DIR, '1-2');

		assert.match(null, st.read('auth'));
	});

	prop('reads back the last of any writes, and another instance starts without them',
		gen.array(gen.tuple(gen.elements('auth', 'breaker'), gen.string({ min_len: 0, max_len: 64 })), { min_len: 1, max_len: 6 }), (writes) => {
		let fs = filesystem({}, { [DIR]: 0o700 });
		let st = state.open(fs, DIR, '10-20');
		let last = {};

		for (let w in writes) {
			st.write(w[0], w[1]);
			last[w[0]] = w[1];
		}

		assert.match([ last.auth, last.breaker ], [ st.read('auth'), st.read('breaker') ]);

		let next = state.open(fs, DIR, '11-25');

		assert.match([ null, null, [] ], [ next.read('auth'), next.read('breaker'), keys(fs.files) ]);
	});

	prop('counts every update, in any order of instances and names', gen.array(gen.elements('a', 'b'), { min_len: 1, max_len: 20 }), (names) => {
		let fs = filesystem({}, { [DIR]: 0o700 });
		let st = state.open(fs, DIR, '3-4');
		let want = { a: 0, b: 0 };

		for (let n in names) {
			st.update(n, (old) => '' + (+(old ?? 0) + 1));
			want[n]++;
		}

		assert.match([ want.a || null, want.b || null ], map([ 'a', 'b' ], (n) => st.read(n) == null ? null : +st.read(n)));
		assert.match(null, fs.held);
	});
});

describe('state, a scrape\'s progress', () => {
	const ID = '7-100';

	function opened(files, procs) {
		let fs = filesystem(files ?? {}, { [DIR]: 0o700 }, [], stat_of(42, 'uhttpd', 555), procs);

		return { fs, st: state.open(fs, DIR, ID) };
	}

	it('appends a line for each collector it starts, and removes the file once the reply is written', () => {
		let o = opened(null, { '42': stat_of(42, 'ucode', 555) });
		let p = o.st.progress();

		p.start('cpu');
		p.start('nat_traffic', 42);
		assert.match("start cpu\nstart nat_traffic 42-555\n", o.fs.files[`${DIR}/${ID}.p42_555`].data);
		p.collected();
		p.finish();
		assert.match([], keys(o.fs.files));
	});

	it('reads a child\'s start time once for the collectors it runs one after another, and again for a new child', () => {
		let o = opened(null, { '42': stat_of(42, 'ucode', 555), '43': stat_of(43, 'ucode', 556) });
		let reads = 0;
		let readfile = o.fs.readfile;

		o.fs.readfile = function(p, n) {
			if (p == '/proc/42/stat' || p == '/proc/43/stat')
				reads++;
			return readfile(p, n);
		};

		let p = o.st.progress();

		p.start('cpu', 42);
		p.start('loadavg', 42);
		p.start('nat_traffic', 43);
		p.start('uname');
		assert.match("start cpu 42-555\nstart loadavg 42-555\nstart nat_traffic 43-556\nstart uname\n", o.fs.files[`${DIR}/${ID}.p42_555`].data);
		assert.match(2, reads);
	});

	it('finds the progress of a scrape process that is gone, and the collector it was running', () => {
		let o = opened({
			[`${DIR}/${ID}.p50_600`]: { data: 'start cpu 60-700\nstart oom 61-701\n' },
			[`${DIR}/${ID}.p53_603`]: { data: 'start loop 62-702\n' },
			[`${DIR}/${ID}.p51_601`]: { data: 'start cpu\ncollected\n' },
			[`${DIR}/${ID}.p52_602`]: { data: 'start cpu\n' },
			[`${DIR}/${ID}.scrape`]: { data: '{}' },
		}, { '52': stat_of(52, 'uhttpd', 602), '50': stat_of(50, 'uhttpd', 999), '62': stat_of(62, 'uhttpd', 702) });

		assert.match([
			{ file: `${ID}.p50_600`, running: 'oom', child: null },
			{ file: `${ID}.p51_601`, running: null, child: null },
			{ file: `${ID}.p53_603`, running: 'loop', child: { pid: 62, start: '702' } },
		], sort(o.st.dead(), (a, b) => (a.file < b.file) ? -1 : 1));
	});

	it('lets one scrape claim a dead one\'s file', () => {
		let o = opened({ [`${DIR}/${ID}.p50_600`]: { data: 'start oom\n' } });

		assert.match([ true, false, false ], [ o.st.claim(`${ID}.p50_600`), o.st.claim(`${ID}.p50_600`), o.st.claim('9-9.p1_1') ]);
	});

	it('removes another instance\'s progress with its state', () => {
		let o = opened({ [`${DIR}/1-1.p50_600`]: { data: 'start oom\n' } });

		assert.match([ [], [] ], [ keys(o.fs.files), o.st.dead() ]);
	});
});

describe('state.pid_of', () => {
	it('is the pid of an instance id', () => {
		assert.match([ 1234, null, null ], [ state.pid_of('1234-5678'), state.pid_of('x-1'), state.pid_of(null) ]);
	});
});

describe('state.latest', () => {
	it('reads the instance that started last, removing nothing', () => {
		let files = {
			[`${DIR}/9-100.scrape`]: { data: 'older' },
			[`${DIR}/2-300.scrape`]: { data: 'newer' },
			[`${DIR}/2-300.lock`]: { data: '' },
			[`${DIR}/notes.txt`]: { data: 'not ours' },
		};
		let fs = filesystem(files, { [DIR]: 0o700 });
		let st = state.latest(fs, DIR);

		assert.match([ '2-300', 'newer', null ], [ st.id, st.read('scrape'), st.read('auth') ]);
		assert.match(4, length(fs.files));
		assert.match(null, st.write);
	});

	it('is null when no instance has state, or there is no directory', () => {
		assert.match([ null, null ], [ state.latest(filesystem({}, { [DIR]: 0o700 }), DIR), state.latest(filesystem({}, {}), DIR) ]);
	});
});

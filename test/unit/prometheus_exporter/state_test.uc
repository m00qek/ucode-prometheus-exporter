'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as state from 'prometheus_exporter.state';
import * as auth from 'prometheus_exporter.auth';

const DIR = '/state';

// A filesystem of `files` ({ path: { data, mode } }) and `dirs` ({ path: mode }),
// with /proc/self/stat as `stat`; `broken` names the calls that fail.
function filesystem(files, dirs, broken, stat) {
	let fails = (name) => (name in (broken ?? []));
	let fs = {
		files, dirs,
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
		assert.match({ [`${DIR}/1-2.auth`]: { data: 'abc', mode: 0o600 } }, fs.files);
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

		assert.match([ false, null, [ `${DIR}/1-2.auth` ] ], [ st.write('auth', 'x'), st.read('auth'), keys(fs.files) ]);
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

		assert.match([ [ false, [] ], [ false, [] ], [ false, [] ], [ false, [] ] ], [ write([ 'writefile' ]), write([ 'short' ]), write([ 'chmod' ]), write([ 'rename' ]) ]);
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
});

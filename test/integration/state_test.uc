'use strict';

// The state on a real filesystem, written by processes at once, as uhttpd's
// requests are: every update counted, and no reader ever sees a torn file.

import { describe, it, assert } from 'utest';
import * as state from 'prometheus.exporter.state';
import * as deps from 'prometheus.exporter.deps';

// The real fs: under utest, an import of fs reaches whatever mock is patched in.
const fs = require('fs');
const SRC = fs.realpath(`${fs.dirname(sourcepath())}/../../src`);

// Processes that each update `name` `times` times, adding 1 to its count and
// padding it to `pad` bytes, and read it back between updates; each prints the
// reads that were not a whole file.
const WRITER = `
import * as fs from 'fs';
import * as state from 'prometheus.exporter.state';
let dir = ARGV[0], id = ARGV[1], times = +ARGV[2], pad = +ARGV[3];
let st = state.open(fs, dir, id);
let torn = 0;
for (let i = 0; i < times; i++) {
	st.update('count', function(old) {
		let n = (old == null) ? 0 : json(old).n;
		return sprintf('%J', { n: n + 1, pad: sprintf('%0' + pad + 'd', 0) });
	});
	let seen = st.read('count');
	try { json(seen); } catch (e) { torn++; }
}
print(torn, '\\n');
`;

function scratch() {
	let dir = fs.mkdtemp('/tmp/state-test-XXXXXX');

	fs.chmod(dir, 0o700);
	return dir;
}

function remove(dir) {
	for (let f in fs.lsdir(dir) ?? [])
		fs.unlink(`${dir}/${f}`);
	fs.rmdir(dir);
}

describe('state, written by processes at once', () => {
	it('counts every update of every process, and no read is torn', () => {
		let dir = scratch();
		let script = `${dir}/writer.uc`;
		let procs = [];

		fs.writefile(script, WRITER);

		// Each process's file is larger than a pipe's or a page's atomic write.
		for (let i = 0; i < 6; i++)
			push(procs, fs.popen(`ucode -L '${SRC}' '${script}' '${dir}' 7-42 40 9000`, 'r'));

		let torn = map(procs, function(p) {
			let out = p.read('all');

			p.close();
			return +trim(out);
		});

		let st = state.latest(fs, dir);

		assert.match([ 0, 0, 0, 0, 0, 0 ], torn);
		assert.match(240, json(st.read('count')).n);
		assert.match([ '7-42.count', '7-42.lock', 'writer.uc' ], sort(fs.lsdir(dir)));
		remove(dir);
	});

	// What root reads of the state, which the service's user owns: a FIFO in
	// place of the ledger must not block it, nor a link take it elsewhere.
	it('reads neither a FIFO nor a link in place of a state file, without blocking', () => {
		let dir = scratch();
		let secret = `${dir}.secret`;

		fs.writefile(secret, '{"secret":true}');
		assert.match(0, system([ 'mkfifo', `${dir}/5-50.scrape` ]));
		assert.match([ '5-50', null ], [ state.latest(fs, dir).id, state.latest(fs, dir).read('scrape') ]);

		fs.unlink(`${dir}/5-50.scrape`);
		fs.symlink(secret, `${dir}/5-50.scrape`);
		assert.match([ '5-50', null ], [ state.latest(fs, dir).id, state.latest(fs, dir).read('scrape') ]);

		fs.unlink(`${dir}/5-50.scrape`);
		fs.writefile(`${dir}/5-50.scrape`, '{"n":1}');
		assert.match('{"n":1}', state.latest(fs, dir).read('scrape'));
		// As check, status and the trial read it: with the modules deps gives the core.
		assert.match('{"n":1}', state.latest(deps.modules().fs, dir).read('scrape'));

		fs.unlink(secret);
		remove(dir);
	});

	it('removes the files of the instance before, its lock too', () => {
		let dir = scratch();
		let old = state.open(fs, dir, '1-10');

		old.write('scrape', '{}');
		state.open(fs, dir, '2-20').write('scrape', '{"new":true}');

		assert.match([ '2-20.lock', '2-20.scrape' ], sort(fs.lsdir(dir)));
		remove(dir);
	});
});

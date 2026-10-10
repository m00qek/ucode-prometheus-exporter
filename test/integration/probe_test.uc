'use strict';

// prometheus.exporter.probe for real: modules loaded in forked child
// processes, one that does not load in time stopped with its process.

import { describe, it, assert } from 'utest';
import * as probe from 'prometheus.exporter.probe';
import * as loader from 'prometheus.exporter.loader';
import { seconds } from 'prometheus.exporter.deadline';
import * as fs from 'fs';

function now() {
	return seconds(clock(true));
}

// The probe of a directory's module `big`, as uhttpd's handler probes, and
// what checking it here gives: its arguments, the directory.
const PINNED = `'use strict';

import * as probe from 'prometheus.exporter.probe';
import * as loader from 'prometheus.exporter.loader';
import * as collection from 'prometheus.exporter.collection';
import * as fs from 'fs';

const dir = ARGV[0];
const import_fn = (id) => collection.import_path(dir + '/' + id + '.uc');
const res = probe.probe([ 'big', 'after' ], (id) => (id == 'big') ? loader.check_module(fs, dir, id, import_fn) : { meta: 'small' }, 5, null, true);

print(sprintf('%J', { res, want: loader.check_module(fs, dir, 'big', import_fn) }));
`;

describe('probe.probe', () => {
	it('loads each module in a child, and stops one that does not load in time', () => {
		let t = now();
		let res = probe.probe([ 'a', 'stuck', 'broken', 'b' ], function(id) {
			if (id == 'stuck')
				while (true)
					;
			if (id == 'broken')
				die('Unable to compile module\nmore');
			return {};
		}, 1);
		let took = now() - t;

		assert.match({ a: true, stuck: false, broken: false, b: true }, { a: res.a.ok, stuck: res.stuck.ok, broken: res.broken.ok, b: res.b.ok });
		assert.match([ true, 'still loading after 1 s: stopped' ], [ res.stuck.hung, res.stuck.error ]);
		assert.match([ false, 'Unable to compile module' ], [ res.broken.hung, res.broken.error ]);
		assert.match(true, took < 2.5, `took ${took} s`);
	});

	it('says a module whose loading ended its process did not load', () => {
		let res = probe.probe([ 'quits', 'b' ], (id) => (id == 'quits') ? exit(1) : {}, 1);

		assert.match([ false, true ], [ res.quits.ok, res.b.ok ]);
	});

	// uloop takes SIGTERM while the probe waits: what procd sends an
	// instance still loading its collectors, in an upgrade of several
	// packages. Each module not loaded then says so, and its signal.
	it('says which modules it did not load when this process was asked to stop', () => {
		let me = fs.readlink('/proc/self');
		let res = probe.probe([ 'a', 'b', 'c' ], function(id) {
			if (id == 'b')
				system([ 'kill', '-TERM', me ]);
			sleep(300);
			return {};
		}, 5, null, true);

		assert.match([ true, null ], [ res.a.ok, res.a.stopped ]);
		assert.match([ false, 15, 'not loaded: this process was asked to stop (signal 15)' ], [ res.b.ok, res.b.stopped, res.b.error ]);
		assert.match([ false, 15 ], [ res.c.ok, res.c.stopped ]);
	});

	// ucode's uloop reads its pipe without blocking, and loses a message whose
	// rest is not there yet. A message past what a pipe holds, 64 kB, is
	// written in parts, and on one CPU the reader empties the pipe before the
	// writer runs again: it is lost every time. A meta's fingerprint is its
	// JSON, as long as its options' help: these 40 options, 2 kB each, make
	// 90 kB. The probe runs in a process of its own, held to one CPU.
	it('hands back what it checked of a collector whose meta is longer than a pipe holds, whole', () => {
		let dir = fs.mkdtemp('/tmp/probe-big-XXXXXX');
		let options = {};

		for (let i = 0; i < 40; i++)
			options[`option_${i}`] = { default: i, title: `Option ${i}`, help: `It does "${i}" \\ and é: ${join(' ', split(sprintf('%01990d', i), ''))}.` };

		fs.writefile(`${dir}/big.uc`, sprintf(`'use strict';

import { Result } from 'prometheus.exporter';

export const meta = { name: 'big', title: 'Big', help: 'A long meta.', needs: [], options: %J };

export function collect() {
	return Result.ok();
};
`, options));

		fs.writefile(`${dir}/probe.uc`, PINNED);

		let p = fs.popen(sprintf("taskset 1 ucode -L '%s' '%s/probe.uc' '%s'", fs.realpath('src'), dir, dir), 'r');
		let out = json(p.read('all'));

		p.close();
		for (let f in [ 'big.uc', 'probe.uc' ])
			fs.unlink(`${dir}/${f}`);
		fs.rmdir(dir);

		assert.match(true, length(out.want.meta) > 65536, `${length(out.want.meta)} bytes`);
		assert.match([ true, false, null, out.want ], [ out.res.big.ok, out.res.big.hung, out.res.big.error, out.res.big.data ]);
		assert.match([ true, { meta: 'small' } ], [ out.res.after.ok, out.res.after.data ]);
	});

	it('loads the real collectors', () => {
		let ids = loader.discover(fs, 'src/prometheus/collectors');
		let res = probe.probe(ids, loader.import_module);

		assert.match([], filter(ids, (id) => !res[id]?.ok));
	});
});

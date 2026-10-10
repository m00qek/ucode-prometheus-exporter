'use strict';

// The prometheus-exporter command for real, in a process of its own.

import { describe, it, assert } from 'utest';
import { seconds } from 'prometheus.exporter.deadline';
import * as fs from 'fs';

function now() {
	return seconds(clock(true));
}

function alive(pid) {
	let rest = split(fs.readfile(`/proc/${pid}/stat`) ?? '', ') ')[1];

	return rest != null && split(rest, ' ')[0] != 'Z';
}

// A collector that writes, to `ready`, the pid of the process it runs in and
// its parent's, the scrape's, and then never returns.
function spinner(ready) {
	return sprintf(`'use strict';

import { Result } from 'prometheus.exporter';

export const meta = { name: 'spin', title: 'Spin', help: 'Never returns.', needs: [ 'fs' ] };

export function collect(deps) {
	let stat = deps.fs.readfile('/proc/self/stat');
	let f = deps.fs.open(%J, 'w');

	f.write(split(split(stat, ') ')[1], ' ')[1] + ' ' + split(stat, ' ')[0]);
	f.close();
	while (true)
		;
	return Result.ok();
};
`, ready);
}

describe('prometheus-exporter scrape', () => {
	// Ctrl-C signals the terminal's foreground group: the command and the
	// child its collectors run in. The test's own process ignores SIGINT, as
	// a job started in the background does, and its children with it: the
	// command is started with SIGINT as a terminal leaves it, in a session of
	// its own, and the group is signalled once its collector runs.
	it('ends at Ctrl-C while a collector runs: at once, with 130, its child gone', () => {
		let tmp = fs.mkdtemp('/tmp/cli-test-XXXXXX');
		let dir = `${tmp}/prometheus/collectors`;
		let ready = `${tmp}/ready`;

		fs.mkdir(`${tmp}/prometheus`);
		fs.mkdir(dir);
		fs.writefile(`${dir}/spin.uc`, spinner(ready));

		let was = signal('SIGINT');

		signal('SIGINT', 'default');

		let p = fs.popen(sprintf("setsid ucode -L '%s' -L '%s' '%s' scrape --dir='%s' 2>&1; echo \"status=$?\"",
			tmp, fs.realpath('src'), fs.realpath('files/usr/bin/prometheus-exporter'), dir), 'r');
		let pids = null;

		for (let end = now() + 10; pids == null && now() < end;) {
			let text = fs.readfile(ready);

			if (text != null && length(split(text, ' ')) == 2)
				pids = split(text, ' ');
		}

		let t = now();

		if (pids != null)
			system([ 'kill', '-INT', `-${pids[0]}` ]);

		let out = p.read('all');
		let took = now() - t;

		p.close();
		signal('SIGINT', was);

		for (let f in [ ready, `${dir}/spin.uc` ])
			fs.unlink(f);
		fs.rmdir(dir);
		fs.rmdir(`${tmp}/prometheus`);
		fs.rmdir(tmp);

		assert.match(true, pids != null, 'the collector ran');
		assert.match('asked to stop (signal 2) while it ran the collectors: stopping\nstatus=130\n', out);
		assert.match(true, took < 2, `took ${took} s`);
		assert.match(false, alive(pids[1]), 'its child is gone');
	});
});

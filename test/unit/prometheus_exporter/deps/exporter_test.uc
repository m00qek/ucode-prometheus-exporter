'use strict';

import { describe, it, assert, mock } from 'utest';
import * as deps_exporter from 'prometheus_exporter.deps.exporter';

describe('deps.exporter.exporter_channel', () => {
	const FILES = {
		'/proc/42/stat': '42 (uhttpd) S 1', '/proc/42/status': 'Name:\tuhttpd\n', '/proc/42/limits': 'Max open files 1024 4096 files\n',
		'/proc/42/fd/0': '', '/proc/42/fd/1': '', '/proc/42/fd/3': '', '/proc/42/environ': 'SECRET=1',
		'/proc/stat': 'btime 1700000000\n', '/proc/self/auxv': 'x', '/proc/self/stat': '7 (ucode) R 1', '/etc/shadow': 'root:x',
	};

	function with_channel(view, cb) {
		mock.inject('fs', { strict: true, data: FILES }, (fs) => cb(deps_exporter.exporter_channel(fs, view)));
	}

	it('reads the serving process\'s stat, status and limits, and counts its descriptors', () => {
		with_channel({ pid: 42 }, (ch) => {
			assert.match([ '42 (uhttpd) S 1', 'Name:\tuhttpd\n', 'Max open files 1024 4096 files\n', 3 ],
				[ ch.process('stat'), ch.process('status'), ch.process('limits'), ch.fds() ]);
		});
	});

	it('reads nothing else of it, nor of the system but the boot time\'s and the auxiliary vector\'s files', () => {
		with_channel({ pid: 42 }, (ch) => {
			assert.match([ null, null, null, 'btime 1700000000\n', 'x', null, null ],
				[ ch.process('environ'), ch.process('../../etc/shadow'), ch.process('fd/0'), ch.system('/proc/stat'), ch.system('/proc/self/auxv'),
					ch.system('/etc/shadow'), ch.system('/proc/42/environ') ]);
		});
	});

	it('is this process, without counters, outside a scrape of the handler', () => {
		with_channel(null, (ch) => {
			assert.match([ '7 (ucode) R 1', null, {} ], [ ch.process('stat'), ch.counters(), ch.samples() ]);
		});
	});

	it('gives the scrape\'s counters and samples', () => {
		with_channel({ pid: 42, counters: { scrapes: 3 }, samples: { cpu: 9 } }, (ch) => {
			assert.match([ { scrapes: 3 }, { cpu: 9 } ], [ ch.counters(), ch.samples() ]);
		});
	});
});

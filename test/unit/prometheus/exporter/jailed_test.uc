'use strict';

import { describe, it, assert } from 'utest';
import * as jailed from 'prometheus.exporter.jailed';
import * as loader from 'prometheus.exporter.loader';
import * as config from 'prometheus.exporter.config';
import * as Result from 'prometheus.exporter.result';
import { with_mods } from 'prometheus.exporter.devkit.collector';

const NFT = loader.validate('nft_counters', { meta: { name: 'nft-counters', title: 'N', help: 'N.', needs: [ 'exec' ], commands: [ 'nft' ] },
	collect: () => Result.ok() }).data;
const OPENWRT = loader.validate('openwrt', { meta: { name: 'openwrt', title: 'O', help: 'O.', needs: [ 'ubus' ], ubus: { system: [ 'board' ] } }, collect: () => Result.ok() }).data;
const LOADAVG = loader.validate('loadavg', { meta: { name: 'loadavg', title: 'L', help: 'L.', needs: [ 'fs' ] }, collect: () => Result.ok() }).data;

// A system of `files` (path: text), every other path there as a directory,
// whose popen gives `out`; `cmds` gets each command run.
function sys_of(mods, files, out, cmds) {
	return {
		uci: mods.uci.cursor(),
		path: '/usr/bin',
		fs: {
			stat: (p) => (p in keys(files)) ? { type: 'file' } : ((p == '/usr/bin/nft') ? { type: 'file' } : null),
			readfile: (p) => files[p],
			glob: (pattern) => (pattern == '/usr/lib/ucode/*.so') ? [ '/usr/lib/ucode/fs.so', '/usr/lib/ucode/ubus.so' ] : [],
			popen: function(cmd) { push(cmds, cmd); return { read: () => out, close: () => 0 }; },
		},
	};
}

function filter_null(o) {
	let out = {};

	for (let k, v in o)
		if (v != null)
			out[k] = v;

	return out;
}

const ROOT = { '/sbin/ujail': '', '/proc/self/status': 'Name:\tucode\nUid:\t0\t0\t0\t0\n', '/proc/meminfo': 'MemTotal: 131072 kB\n' };

describe('jailed.command', () => {
	it('runs trial.uc in ujail with the service\'s mounts, priority and memory limit', () => {
		with_mods({}, (mods) => {
			let cmd = jailed.command(sys_of(mods, ROOT, '', []), [ NFT, LOADAVG ], [ 'scrape', 'collect[]=a b' ]);

			assert.match(0, index(cmd, "ulimit -d 32768 && exec nice -n 10 /sbin/ujail -n 'prometheus-exporter-trial' -U 'prometheus-exporter' -G 'prometheus-exporter' -c -p -s -l -r "), cmd);
			for (let m in [ '/etc/config/prometheus-exporter', '/bin/sh', '/usr/bin/nft', '/usr/share/ucode/prometheus', jailed.TRIAL, '/usr/lib/ucode/ubus.so' ])
				assert.match(true, index(cmd, `-r '${m}'`) >= 0, m);
			assert.match(true, index(cmd, "-w '/var/run/prometheus-exporter/state' -- /usr/bin/ucode /usr/libexec/prometheus-exporter/trial.uc 'scrape' 'collect[]=a b' 2>/dev/null") > 0, cmd);
		});
	});

	it('mounts the ubus socket, by ujail\'s -u, only when a collector needs ubus', () => {
		with_mods({}, (mods) => {
			let without = jailed.command(sys_of(mods, ROOT, '', []), [ NFT, LOADAVG ], [ 'runs' ]);
			let with_ubus = jailed.command(sys_of(mods, ROOT, '', []), [ LOADAVG, OPENWRT ], [ 'runs' ]);

			assert.match([ -1, -1 ], [ index(without, ' -u '), index(without, 'ubus.sock') ]);
			assert.match(true, index(with_ubus, ' -c -p -s -l -u -r ') > 0, with_ubus);
			// The socket is the option's, never a -r of its own.
			assert.match(-1, index(with_ubus, 'ubus.sock'));
		});
	});

	it('leaves the ubus socket out when the collector that needs ubus is disabled', () => {
		with_mods({ uci: { data: { [config.NAME]: { openwrt: { '.type': 'collector', enabled: '0' } } } } }, (mods) => {
			assert.match(-1, index(jailed.command(sys_of(mods, ROOT, '', []), [ LOADAVG, OPENWRT ], [ 'runs' ]), ' -u '));
		});
	});

	it('runs as the service\'s user, with the capabilities the service has while it runs', () => {
		with_mods({}, (mods) => {
			let caps = jailed.command(sys_of(mods, { ...ROOT, '/var/run/prometheus-exporter/capabilities.json': '{}' }, '', []), [ NFT ], [ 'runs' ]);

			assert.match(true, index(caps, " -U 'prometheus-exporter' -G 'prometheus-exporter' -C '/var/run/prometheus-exporter/capabilities.json' -c ") > 0, caps);
			assert.match(-1, index(jailed.command(sys_of(mods, ROOT, '', []), [ NFT ], [ 'runs' ]), ' -C '));
		});
	});

	it('takes memory_limit when it is set', () => {
		with_mods({ main: { memory_limit: '12' } }, (mods) => {
			assert.match(12288, jailed.data_kb(sys_of(mods, ROOT, '', [])));
		});
	});
});

describe('jailed.output', () => {
	it('leaves out ujail\'s own lines', () => {
		assert.match({ runs: [] }, jailed.output('jail: exec-ing /usr/bin/ucode\n{"runs":[]}\njail: jail (12) exited with exit: 0\njail: ubus request failed\n'));
	});

	it('is null for no reply, or one that is not an object', () => {
		assert.match([ null, null, null ], [ jailed.output(''), jailed.output('jail: Connection to ubus failed\n'), jailed.output('[ 1 ]') ]);
	});
});

describe('jailed.trial', () => {
	it('runs the chosen collectors in the jail, in their order, as trial.uc found them', () => {
		with_mods({}, (mods) => {
			let cmds = [];
			let out = '{"runs":[{"name":"loadavg","id":"loadavg","duration":0.1,"samples":3,"result":{"ok":true}}]}';
			let t = jailed.trial(sys_of(mods, ROOT, out, cmds), [ NFT, LOADAVG ], [ NFT, LOADAVG ], () => die('not here'));

			assert.match([ true, [ 'nft-counters', 'loadavg' ] ], [ t.jailed, map(t.runs, (r) => r.name) ]);
			assert.match({ ok: false, error: 'COLLECTOR_INVALID', details: 'not loaded in the jail' }, t.runs[0].result);
			assert.match([ 1, true ], [ length(cmds), index(cmds[0], " 'runs' 2>/dev/null") > 0 ]);
		});
	});

	it('runs them here where there is no ujail, the process is not root\'s, or ujail fails', () => {
		with_mods({}, (mods) => {
			for (let files in [
				{ ...ROOT, '/sbin/ujail': null },
				{ ...ROOT, '/proc/self/status': 'Uid:\t1000\t1000\t1000\t1000\n' },
				ROOT,
			]) {
				let t = jailed.trial(sys_of(mods, filter_null(files), 'jail: Connection to ubus failed\n', []), [ LOADAVG ], [ LOADAVG ], () => [ 'here' ]);

				assert.match({ jailed: false, runs: [ 'here' ] }, t);
			}
		});
	});
});


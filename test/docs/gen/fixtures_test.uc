'use strict';

import { describe, it, assert } from 'utest';
import * as fixtures from 'docs_gen.fixtures';
import { exec_script, batch_script } from 'prometheus.exporter.deps';

const FILES = [
	'ethtool_S_lan.txt', 'ethtool_S_lan2.txt', 'ethtool_S_ifb4vlan-guest.txt',
	'chronyc_c_tracking.txt', 'chronyc_c_tracking_unsynchronised.txt',
	'mmcli-L-J.json', 'mmcli-m-0-J.json', 'mmcli-m-0-signal-get-J.json',
	'nft_json_list_counters.txt',
];

describe('docs_gen.fixtures.command_file', () => {
	it('finds the capture with the very words of a command line', () => {
		assert.match([ 'ethtool_S_lan.txt', 'ethtool_S_lan2.txt', 'ethtool_S_ifb4vlan-guest.txt', 'nft_json_list_counters.txt' ], [
			fixtures.command_file(FILES, [ 'ethtool', '-S', 'lan' ]),
			fixtures.command_file(FILES, [ 'ethtool', '-S', 'lan2' ]),
			fixtures.command_file(FILES, [ 'ethtool', '-S', 'ifb4vlan-guest' ]),
			fixtures.command_file(FILES, [ 'nft', '--json', 'list', 'counters' ]),
		]);
	});

	it('reads a path as its last part', () => {
		assert.match('mmcli-m-0-J.json',
			fixtures.command_file(FILES, [ 'mmcli', '-m', '/org/freedesktop/ModemManager1/Modem/0', '-J' ]));
		assert.match('mmcli-m-0-signal-get-J.json',
			fixtures.command_file(FILES, [ 'mmcli', '-m', '/org/freedesktop/ModemManager1/Modem/0', '--signal-get', '-J' ]));
	});

	it('takes a capture named without an option the command line has', () => {
		assert.match('chronyc_c_tracking.txt', fixtures.command_file(FILES, [ 'chronyc', '-u', 'root', '-c', 'tracking' ]));
	});

	it('finds nothing for a program without a capture', () => {
		assert.match([ null, null ], [
			fixtures.command_file(FILES, [ 'ethtool', '-S', 'wan' ]),
			fixtures.command_file(FILES, [ 'tc', '-s', 'qdisc' ]),
		]);
	});
});

describe('docs_gen.fixtures.script_argv', () => {
	it('reads back the argv of the script deps runs, quotes and all', () => {
		assert.match([ 'ethtool', '-S', "it's" ], fixtures.script_argv(exec_script([ 'ethtool', '-S', "it's" ], 5)));
	});

	it('is null for any other script', () => {
		assert.match(null, fixtures.script_argv('echo hi'));
	});
});

describe('docs_gen.fixtures.modules', () => {
	let mods = fixtures.modules('test/fixtures/synthetic', {});

	it('answers files at their paths, under the set', () => {
		assert.match(true, mods.fs.readfile('/sys/fs/selinux/enforce') != null);
		assert.match(null, mods.fs.readfile('/no/such/file'));
	});

	it('answers a ubus call from its capture, and a missing object as libubus does', () => {
		let conn = mods.ubus.connect();

		assert.match(true, type(conn.call('dsl', 'metrics')) == 'object');
		assert.match([ null, 'Not found' ], [ conn.call('nothing', 'here'), conn.error() ]);
	});

	it('has rc list an enabled init script for each object it has a capture of, and nothing else', () => {
		let conn = mods.ubus.connect();

		assert.match({ mwan3: { start: 19, enabled: true } }, conn.call('rc', 'list', { name: 'mwan3', skip_running_check: true }));
		assert.match({}, conn.call('rc', 'list', { name: 'dnsmasq', skip_running_check: true }));
	});

	it('runs a program as the cat of its capture, and fails one without', () => {
		let p = mods.fs.popen(exec_script([ 'nft', '--json', 'list', 'counters' ], 5), 'r');

		assert.match(true, length(p.read('all')) > 0);
		assert.match(0, p.close());
		assert.match(1, mods.fs.popen(exec_script([ 'nft', 'list', 'ruleset' ], 5), 'r').close());
	});

	it('runs a batch of programs as run_all does, each the cat of its capture or a failure', () => {
		let nft = mods.fs.popen(exec_script([ 'nft', '--json', 'list', 'counters' ], 5), 'r').read('all');
		let p = mods.fs.popen(batch_script([ [ 'nft', '--json', 'list', 'counters' ], [ 'nft', 'list', 'ruleset' ] ], 5, 'end'), 'r');

		assert.match(`${nft}\nend 0\n\nend 1\n`, p.read('all'));
		assert.match(0, p.close());
	});

	it('serves the exporter\'s own config from the overlay', () => {
		let m = fixtures.modules('test/fixtures/synthetic', { 'prometheus-exporter': { wifi: { '.type': 'collector', stations: '0' } } });
		let c = m.uci.cursor();

		assert.match([ '0', 'collector', null ], [
			c.get('prometheus-exporter', 'wifi', 'stations'),
			c.get('prometheus-exporter', 'wifi'),
			c.get_all('prometheus-exporter', 'main'),
		]);
	});
});

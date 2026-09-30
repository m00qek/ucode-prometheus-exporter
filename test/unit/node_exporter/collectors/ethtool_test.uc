'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as commands from 'lib.commands';
import * as exposition from 'node_exporter.exposition';
import * as ethtool from 'node_exporter.collectors.ethtool';

// The links of a device, as an rtnl dump names them, in /proc/net/dev's order.
function links(device) {
	let names = [];

	for (let line in split(fixtures.file(device, '/proc/net/dev'), '\n')) {
		let m = match(line, /^[ \t]*([^ \t:]+):/);
		if (m)
			push(names, m[1]);
	}

	return map(names, (dev) => ({ dev, ifname: dev }));
}

function run(dev) {
	return commands.line([ 'ethtool', '-S', dev ]);
}

// `ethtool -S` of each link: the capture where its driver has statistics, else
// what ethtool does without them: "no stats available" and exit status 94.
function outputs(device, with_stats) {
	let out = {};

	for (let l in links(device))
		out[run(l.dev)] = l.dev in with_stats
			? { out: fixtures.file(device, `/commands/ethtool_S_${l.dev}.txt`), status: 0 }
			: { out: '', status: 94 };

	return out;
}

const ROUTER = { links: links('caju-router'), outputs: outputs('caju-router', [ 'eth0', 'eth1', 'ifb4vlan-guest', 'ifb4eth1' ]) };
const AP = { links: links('caju-ap'), outputs: outputs('caju-ap', [ 'eth0', 'lan', 'wan', 'phy0-ap0', 'phy1-ap0', 'phy1-ap1' ]) };

function with_ethtool(links, outputs, cb) {
	with_collector(ethtool, { rtnl: { data: { RTM_GETLINK: links } }, fs: commands.fs(outputs) }, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function stat(name, value) {
	return `NIC statistics:\n     ${name}: ${value}\n`;
}

describe('collectors.ethtool', () => {
	it("exports the caju router's driver statistics, leaving out the links without", () => {
		with_ethtool(ROUTER.links, ROUTER.outputs, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_ethtool_transmitted_packets_total Driver statistic tx_packets, from ethtool -S.',
				'# TYPE node_ethtool_transmitted_packets_total untyped',
				'node_ethtool_transmitted_packets_total{device="eth0"} 588369',
				'node_ethtool_transmitted_packets_total{device="eth1"} 243879',
				'# HELP node_ethtool_received_packets_total Driver statistic rx_packets, from ethtool -S.',
				'# TYPE node_ethtool_received_packets_total untyped',
				'node_ethtool_received_packets_total{device="eth0"} 239002',
				'node_ethtool_received_packets_total{device="eth1"} 596237',
				'# HELP node_ethtool_transmitted_errors_total Driver statistic tx_errors, from ethtool -S.',
				'# TYPE node_ethtool_transmitted_errors_total untyped',
				'node_ethtool_transmitted_errors_total{device="eth0"} 0',
				'node_ethtool_transmitted_errors_total{device="eth1"} 0',
				'# HELP node_ethtool_received_errors_total Driver statistic rx_errors, from ethtool -S.',
				'# TYPE node_ethtool_received_errors_total untyped',
				'node_ethtool_received_errors_total{device="eth0"} 0',
				'node_ethtool_received_errors_total{device="eth1"} 0',
				'# HELP node_ethtool_received_missed Driver statistic rx_missed, from ethtool -S.',
				'# TYPE node_ethtool_received_missed untyped',
				'node_ethtool_received_missed{device="eth0"} 0',
				'node_ethtool_received_missed{device="eth1"} 2253',
				'# HELP node_ethtool_align_errors Driver statistic align_errors, from ethtool -S.',
				'# TYPE node_ethtool_align_errors untyped',
				'node_ethtool_align_errors{device="eth0"} 0',
				'node_ethtool_align_errors{device="eth1"} 0',
				'# HELP node_ethtool_transmitted_single_collisions Driver statistic tx_single_collisions, from ethtool -S.',
				'# TYPE node_ethtool_transmitted_single_collisions untyped',
				'node_ethtool_transmitted_single_collisions{device="eth0"} 0',
				'node_ethtool_transmitted_single_collisions{device="eth1"} 0',
				'# HELP node_ethtool_transmitted_multi_collisions Driver statistic tx_multi_collisions, from ethtool -S.',
				'# TYPE node_ethtool_transmitted_multi_collisions untyped',
				'node_ethtool_transmitted_multi_collisions{device="eth0"} 0',
				'node_ethtool_transmitted_multi_collisions{device="eth1"} 0',
				'# HELP node_ethtool_unicast Driver statistic unicast, from ethtool -S.',
				'# TYPE node_ethtool_unicast untyped',
				'node_ethtool_unicast{device="eth0"} 236331',
				'node_ethtool_unicast{device="eth1"} 585606',
				'# HELP node_ethtool_broadcast Driver statistic broadcast, from ethtool -S.',
				'# TYPE node_ethtool_broadcast untyped',
				'node_ethtool_broadcast{device="eth0"} 744',
				'node_ethtool_broadcast{device="eth1"} 8451',
				'# HELP node_ethtool_multicast Driver statistic multicast, from ethtool -S.',
				'# TYPE node_ethtool_multicast untyped',
				'node_ethtool_multicast{device="eth0"} 1927',
				'node_ethtool_multicast{device="eth1"} 2180',
				'# HELP node_ethtool_transmitted_aborted Driver statistic tx_aborted, from ethtool -S.',
				'# TYPE node_ethtool_transmitted_aborted untyped',
				'node_ethtool_transmitted_aborted{device="eth0"} 0',
				'node_ethtool_transmitted_aborted{device="eth1"} 0',
				'# HELP node_ethtool_transmitted_underrun Driver statistic tx_underrun, from ethtool -S.',
				'# TYPE node_ethtool_transmitted_underrun untyped',
				'node_ethtool_transmitted_underrun{device="eth0"} 0',
				'node_ethtool_transmitted_underrun{device="eth1"} 0',
				'# HELP node_ethtool_received_queue_0_packets Driver statistic rx_queue_0_packets, from ethtool -S.',
				'# TYPE node_ethtool_received_queue_0_packets untyped',
				'node_ethtool_received_queue_0_packets{device="ifb4vlan-guest"} 2005',
				'node_ethtool_received_queue_0_packets{device="ifb4eth1"} 596010',
				'# HELP node_ethtool_received_queue_0_bytes Driver statistic rx_queue_0_bytes, from ethtool -S.',
				'# TYPE node_ethtool_received_queue_0_bytes untyped',
				'node_ethtool_received_queue_0_bytes{device="ifb4vlan-guest"} 360001',
				'node_ethtool_received_queue_0_bytes{device="ifb4eth1"} 653366727',
				'# HELP node_ethtool_transmitted_queue_0_packets Driver statistic tx_queue_0_packets, from ethtool -S.',
				'# TYPE node_ethtool_transmitted_queue_0_packets untyped',
				'node_ethtool_transmitted_queue_0_packets{device="ifb4vlan-guest"} 2005',
				'node_ethtool_transmitted_queue_0_packets{device="ifb4eth1"} 596010',
				'# HELP node_ethtool_transmitted_queue_0_bytes Driver statistic tx_queue_0_bytes, from ethtool -S.',
				'# TYPE node_ethtool_transmitted_queue_0_bytes untyped',
				'node_ethtool_transmitted_queue_0_bytes{device="ifb4vlan-guest"} 360001',
				'node_ethtool_transmitted_queue_0_bytes{device="ifb4eth1"} 653366727',
			], r.lines);
		});
	});

	it("exports the caju AP's switch ports and radios, names with ':' and '-' made metric names", () => {
		with_ethtool(AP.links, AP.outputs, (r) => {
			assert.match(true, r.result.ok);
			// Sorted: contains() wants a subsequence.
			assert.match(contains(sort([
				'node_ethtool_received_bytes_total{device="eth0"} 649085195',
				'node_ethtool_p06_txdrop{device="eth0"} 0',
				'node_ethtool_p06_rxunicast{device="eth0"} 236538',
				'node_ethtool_txunicast{device="lan"} 0',
				'node_ethtool_transmitted_ampdu_len_0_1{device="phy0-ap0"} 18968',
				'node_ethtool_transmitted_ampdu_len_224_247{device="phy0-ap0"} 0',
				'node_ethtool_received_dropped_total{device="phy0-ap0"} 36',
				'node_ethtool_ch_time_busy{device="phy0-ap0"} 7874624',
				// An unsigned 64-bit -1: no reading.
				'node_ethtool_ch_time_ext_busy{device="phy0-ap0"} 18446744073709551615',
			])), sort([ ...r.lines ]));

			// Every statistic of every link, once.
			let n = 0;
			for (let key, o in AP.outputs)
				n += length(ethtool.statistics(o.out));
			assert.match(n, length(samples(r.lines)));
		});
	});

	it('names statistics as the Lua collector', () => {
		assert.match([
			'node_ethtool_received_bytes_total',
			'node_ethtool_transmitted_packets_total',
			'node_ethtool_received_crc_errors',
			'node_ethtool_p06_txdrop',
			'node_ethtool_transmitted_ampdu_len_0_1',
			'node_ethtool_weird_name_',
			'node_ethtool_received_frames_received',
			'node_ethtool_rxq0',
		], map([ 'rx_bytes', 'tx_packets', 'rx_crc_errors', 'p06_TxDrop', 'tx_ampdu_len:0-1', '__weird name!', 'RX-Frames rx', 'rxq0' ],
			ethtool.fqname));
	});

	it('reads names that hold ": " themselves', () => {
		assert.match([ [ 'tx_ampdu_len:0-1', '18968' ], [ 'q: 0: drops', '5' ] ],
			ethtool.statistics('NIC statistics:\n     tx_ampdu_len:0-1: 18968\n     q: 0: drops: 5\n\n'));
	});

	it('keeps the first of two statistics that make one name', () => {
		with_ethtool([ { dev: 'eth0' } ], { [run('eth0')]: { out: 'NIC statistics:\n     rx-crc: 1\n     rx_crc: 2\n' } }, (r) => {
			assert.match([ 'node_ethtool_received_crc{device="eth0"} 1' ], samples(r.lines));
		});
	});

	it('skips values that are not numbers', () => {
		with_ethtool([ { dev: 'eth0' } ], { [run('eth0')]: { out: stat('mode', 'auto') + '     rx_x: 3\n' } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_ethtool_received_x{device="eth0"} 3' ], samples(r.lines));
		});
	});

	it('exports nothing where no link has statistics', () => {
		with_ethtool([ { dev: 'lo' } ], { [run('lo')]: { out: '', status: 94 } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('fails with COMMAND_FAILED when ethtool is missing, keeping what it read', () => {
		let links = [ { dev: 'eth0' }, { dev: 'eth1' } ];
		let out = { [run('eth0')]: { out: stat('rx_packets', 7) }, [run('eth1')]: { out: '', status: 127 } };

		with_ethtool(links, out, (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'ethtool: exit status 127' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([ 'node_ethtool_received_packets_total{device="eth0"} 7' ], samples(r.lines));
		});
	});

	it('fails with COMMAND_FAILED when ethtool cannot start', () => {
		with_ethtool([ { dev: 'eth0' } ], {}, (r) => {
			assert.match({ error: 'COMMAND_FAILED', details: 'ethtool: cannot start' }, { error: r.result.error, details: r.result.details });
		});
	});

	it('passes a failed link dump on', () => {
		with_collector(ethtool, { rtnl: { errors: { RTM_GETLINK: 'Operation not permitted' } }, fs: commands.fs({}) }, (r) => {
			assert.match({ ok: false, error: 'RTNL_FAILED', details: 'Operation not permitted' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	prop('names every statistic a valid metric name, which the exposition keeps as it is',
		gen.string({ charset: 'abrxtRXT09_:-. ()/[]#', min_len: 0, max_len: 24 }), (s) => {
			let name = ethtool.fqname(s);

			assert.match(true, match(name, /^node_ethtool_[a-z0-9_]*$/) != null, name);
			assert.match(name, exposition.sanitize(name));
		});

	prop('reads back every statistic of an ethtool -S listing',
		gen.array(gen.tuple(gen.string({ charset: 'abrx_:-. 09', min_len: 1, max_len: 16 }), gen.int(0, 1000000000)),
			{ min_len: 0, max_len: 8 }), (rows) => {
			// Names as drivers write them: no whitespace at either end.
			let stats = map(rows, (r) => [ 'x' + rtrim(r[0]), '' + r[1] ]);
			let text = 'NIC statistics:\n' + join('', map(stats, (s) => `     ${s[0]}: ${s[1]}\n`));

			assert.match(stats, ethtool.statistics(text));
		});
});

'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as commands from 'lib.commands';
import * as exposition from 'prometheus_exporter.exposition';
import * as ethtool from 'prometheus_exporter.collectors.ethtool';

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

// The links a device backs (/sys/class/net/<link>/device), as the kernel makes
// them: the router's two NICs; the AP's switch, its DSA ports and its radios.
// Not the bridges, VLANs, WireGuard, ifb or loopback. The router's ifb links
// have statistics (their queues' counts, netdev's own), which are left out.
const ROUTER = {
	links: links('caju-router'),
	outputs: outputs('caju-router', [ 'eth0', 'eth1', 'ifb4vlan-guest', 'ifb4eth1' ]),
	backed: [ 'eth0', 'eth1' ],
};
const AP = {
	links: links('caju-ap'),
	outputs: outputs('caju-ap', [ 'eth0', 'lan', 'wan', 'phy0-ap0', 'phy1-ap0', 'phy1-ap1' ]),
	backed: [ 'eth0', 'lan', 'wan', 'phy0-ap0', 'phy1-ap0', 'phy1-ap1' ],
};

// An fs mock's stat that finds /sys/class/net/<link>/device for the `backed` links.
function devices(backed) {
	return (p) => {
		let m = match(p, /^\/sys\/class\/net\/([^\/]+)\/device$/);
		return (m && m[1] in backed) ? { type: 'directory' } : null;
	};
}

// A device backs every link unless `backed` says which.
function with_ethtool(links, outputs, cb, backed) {
	let stat = devices(backed ?? map(links, (l) => l.dev));

	with_collector(ethtool, { rtnl: { data: { RTM_GETLINK: links } }, fs: commands.fs(outputs, { behavior: { stat } }) }, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function stat(name, value) {
	return `NIC statistics:\n     ${name}: ${value}\n`;
}

describe('collectors.ethtool', () => {
	it("exports the caju router's driver statistics, sorted by name per link, leaving out the links without, and those no device backs", () => {
		with_ethtool(ROUTER.links, ROUTER.outputs, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_ethtool_align_errors Network interface align_errors',
				'# TYPE node_ethtool_align_errors untyped',
				'node_ethtool_align_errors{device="eth0"} 0',
				'node_ethtool_align_errors{device="eth1"} 0',
				'# HELP node_ethtool_broadcast Network interface broadcast',
				'# TYPE node_ethtool_broadcast untyped',
				'node_ethtool_broadcast{device="eth0"} 744',
				'node_ethtool_broadcast{device="eth1"} 8451',
				'# HELP node_ethtool_multicast Network interface multicast',
				'# TYPE node_ethtool_multicast untyped',
				'node_ethtool_multicast{device="eth0"} 1927',
				'node_ethtool_multicast{device="eth1"} 2180',
				'# HELP node_ethtool_received_errors_total Number of received frames with errors',
				'# TYPE node_ethtool_received_errors_total untyped',
				'node_ethtool_received_errors_total{device="eth0"} 0',
				'node_ethtool_received_errors_total{device="eth1"} 0',
				'# HELP node_ethtool_received_missed Network interface rx_missed',
				'# TYPE node_ethtool_received_missed untyped',
				'node_ethtool_received_missed{device="eth0"} 0',
				'node_ethtool_received_missed{device="eth1"} 2253',
				'# HELP node_ethtool_received_packets_total Network interface packets received',
				'# TYPE node_ethtool_received_packets_total untyped',
				'node_ethtool_received_packets_total{device="eth0"} 239002',
				'node_ethtool_received_packets_total{device="eth1"} 596237',
				'# HELP node_ethtool_transmitted_aborted Network interface tx_aborted',
				'# TYPE node_ethtool_transmitted_aborted untyped',
				'node_ethtool_transmitted_aborted{device="eth0"} 0',
				'node_ethtool_transmitted_aborted{device="eth1"} 0',
				'# HELP node_ethtool_transmitted_errors_total Number of sent frames with errors',
				'# TYPE node_ethtool_transmitted_errors_total untyped',
				'node_ethtool_transmitted_errors_total{device="eth0"} 0',
				'node_ethtool_transmitted_errors_total{device="eth1"} 0',
				'# HELP node_ethtool_transmitted_multi_collisions Network interface tx_multi_collisions',
				'# TYPE node_ethtool_transmitted_multi_collisions untyped',
				'node_ethtool_transmitted_multi_collisions{device="eth0"} 0',
				'node_ethtool_transmitted_multi_collisions{device="eth1"} 0',
				'# HELP node_ethtool_transmitted_packets_total Network interface packets sent',
				'# TYPE node_ethtool_transmitted_packets_total untyped',
				'node_ethtool_transmitted_packets_total{device="eth0"} 588369',
				'node_ethtool_transmitted_packets_total{device="eth1"} 243879',
				'# HELP node_ethtool_transmitted_single_collisions Network interface tx_single_collisions',
				'# TYPE node_ethtool_transmitted_single_collisions untyped',
				'node_ethtool_transmitted_single_collisions{device="eth0"} 0',
				'node_ethtool_transmitted_single_collisions{device="eth1"} 0',
				'# HELP node_ethtool_transmitted_underrun Network interface tx_underrun',
				'# TYPE node_ethtool_transmitted_underrun untyped',
				'node_ethtool_transmitted_underrun{device="eth0"} 0',
				'node_ethtool_transmitted_underrun{device="eth1"} 0',
				'# HELP node_ethtool_unicast Network interface unicast',
				'# TYPE node_ethtool_unicast untyped',
				'node_ethtool_unicast{device="eth0"} 236331',
				'node_ethtool_unicast{device="eth1"} 585606',
			], r.lines);
		}, ROUTER.backed);
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
		}, AP.backed);
	});

	it('names statistics as node_exporter', () => {
		assert.match([
			'node_ethtool_received_bytes',
			'node_ethtool_transmitted_packets',
			'node_ethtool_received_crc_errors',
			'node_ethtool_p06_txdrop',
			'node_ethtool_transmitted_ampdu_len_0_1',
			'node_ethtool_weird_name_',
			'node_ethtool_received_frames_received',
			'node_ethtool_rxq0',
			'node_ethtool_rx0_x',
			'node_ethtool_received_rx_x',
		], map([ 'rx_bytes', 'tx_packets', 'rx_crc_errors', 'p06_TxDrop', 'tx_ampdu_len:0-1', '__weird name!', 'RX-Frames rx', 'rxq0',
			'rx0_x', 'rx_rx_x' ], ethtool.fqname));
	});

	it("gives the common statistics node_exporter's names and help, the others the sanitized statistic", () => {
		assert.match([
			[ 'node_ethtool_received_bytes_total', 'Network interface bytes received' ],
			[ 'node_ethtool_transmitted_errors_total', 'Number of sent frames with errors' ],
			[ 'node_ethtool_received_bytes', 'Network interface RX_bytes' ],
			[ 'node_ethtool_transmitted_ampdu_len_0_1', 'Network interface tx_ampdu_len_0_1' ],
		], map([ 'rx_bytes', 'tx_errors', 'RX-bytes', 'tx_ampdu_len:0-1' ], ethtool.family));
	});

	it('reads names that hold ": " themselves', () => {
		assert.match([ [ 'tx_ampdu_len:0-1', '18968' ], [ 'q: 0: drops', '5' ] ],
			ethtool.statistics('NIC statistics:\n     tx_ampdu_len:0-1: 18968\n     q: 0: drops: 5\n\n'));
	});

	it('leaves out every statistic of a name two of them make, as node_exporter', () => {
		let text = 'NIC statistics:\n     rx-crc: 1\n     rx_crc: 2\n     RX_CRC: 3\n     tx_crc: 4\n';

		with_ethtool([ { dev: 'eth0' } ], { [run('eth0')]: { out: text } }, (r) => {
			assert.match([ 'node_ethtool_transmitted_crc{device="eth0"} 4' ], samples(r.lines));
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

	it('stops at an ethtool still running when its seconds are spent, keeping what it read', () => {
		let links = [ { dev: 'eth0' }, { dev: 'eth1' }, { dev: 'eth2' } ];
		let out = { [run('eth0')]: { out: stat('rx_packets', 7) }, [run('eth1')]: { hangs: true }, [run('eth2')]: { out: stat('rx_packets', 9) } };

		with_ethtool(links, out, (r) => {
			assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'ethtool: still running after 5 s, killed' },
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

	prop('runs ethtool on the links a device backs, in their order, and on no other',
		gen.array(gen.tuple(gen.elements('eth0', 'eth1', 'lan', 'wan', 'br-lan', 'wg0', 'ifb0', 'phy0-ap0', 'lo'), gen.bool()),
			{ min_len: 0, max_len: 9 }), (rows) => {
			let seen = {};
			let links = [];
			let backed = [];
			let ran = [];

			for (let row in rows) {
				if (seen[row[0]])
					continue;
				seen[row[0]] = true;
				push(links, { dev: row[0], ifname: row[0] });
				if (row[1])
					push(backed, row[0]);
			}

			let fs = { behavior: {
				stat: devices(backed),
				popen: function(cmd) {
					push(ran, commands.parse(cmd).line);
					return { read: () => '', close: () => 94 };
				},
			} };

			with_collector(ethtool, { rtnl: { data: { RTM_GETLINK: links } }, fs }, (r) => {
				assert.match(true, r.result.ok);
			});
			assert.match(map(backed, run), ran);
		});

	it('asks sysfs whether a device backs a link', () => {
		let asked = [];
		let fs = { stat: (p) => { push(asked, p); return (p == '/sys/class/net/eth0/device') ? { type: 'directory' } : null; } };

		assert.match([ true, false ], [ ethtool.backed(fs, 'eth0'), ethtool.backed(fs, 'br-lan') ]);
		assert.match([ '/sys/class/net/eth0/device', '/sys/class/net/br-lan/device' ], asked);
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

	// statistics() takes lines apart without a regex, for speed; it must
	// read any line as the regex would.
	const LINE = /^(.+):[ \t]+([^ \t]+)$/;

	prop('reads any line as /^(.+):[ \\t]+([^ \\t]+)$/ does',
		gen.string({ charset: 'ab: \t\r5', min_len: 0, max_len: 14 }), (line) => {
			let m = match(trim(line), LINE);

			assert.match(m ? [ [ m[1], m[2] ] ] : [], ethtool.statistics(line), sprintf('%J', line));
		});

	it('names a statistic as it did the first time, from what it keeps', () => {
		let first = map([ 'rx_bytes', 'mmc_tx_64_octets_gb', 'q0_rx_pkt_n' ], ethtool.family);

		assert.match(first, map([ 'rx_bytes', 'mmc_tx_64_octets_gb', 'q0_rx_pkt_n' ], ethtool.family));
		assert.match([ 'node_ethtool_mmc_transmitted_64_octets_gb', 'Network interface mmc_tx_64_octets_gb' ], first[1]);
	});
});

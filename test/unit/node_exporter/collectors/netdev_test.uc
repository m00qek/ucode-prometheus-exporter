'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, with_mods } from 'context';
import * as fixtures from 'lib.fixtures';
import * as netdev from 'node_exporter.collectors.netdev';

// `ucode -e 'import {request,"const" as c} from "rtnl"; print(request(c.RTM_GETLINK, c.NLM_F_DUMP, {}))'`
// on each device, without af_spec and with the MAC addresses replaced.
const ROUTER = json(fixtures.file('caju-router', '/rtnl/RTM_GETLINK.json'));
const AP = json(fixtures.file('caju-ap', '/rtnl/RTM_GETLINK.json'));


const STATS64 = [
	'rx_packets', 'tx_packets', 'rx_bytes', 'tx_bytes', 'rx_errors', 'tx_errors', 'rx_dropped', 'tx_dropped',
	'multicast', 'collisions', 'rx_length_errors', 'rx_over_errors', 'rx_crc_errors', 'rx_frame_errors',
	'rx_fifo_errors', 'rx_missed_errors', 'tx_aborted_errors', 'tx_carrier_errors', 'tx_fifo_errors',
	'tx_heartbeat_errors', 'tx_window_errors', 'rx_compressed', 'tx_compressed', 'rx_nohandler',
];

function links(reply) {
	return { rtnl: { data: { RTM_GETLINK: reply } } };
}

function of_device(lines, dev) {
	return filter(lines, (l) => index(l, `{device="${dev}"}`) >= 0);
}

// The columns of /proc/net/dev from a link's stats64, as the kernel's
// dev_seq_printf_stats() computes them, and rx_nohandler, as node_exporter adds it.
function proc_net_dev(s) {
	return {
		receive_bytes: s.rx_bytes,
		receive_packets: s.rx_packets,
		receive_errs: s.rx_errors,
		receive_drop: s.rx_dropped + s.rx_missed_errors,
		receive_fifo: s.rx_fifo_errors,
		receive_frame: s.rx_length_errors + s.rx_over_errors + s.rx_crc_errors + s.rx_frame_errors,
		receive_compressed: s.rx_compressed,
		receive_multicast: s.multicast,
		transmit_bytes: s.tx_bytes,
		transmit_packets: s.tx_packets,
		transmit_errs: s.tx_errors,
		transmit_drop: s.tx_dropped,
		transmit_fifo: s.tx_fifo_errors,
		transmit_colls: s.collisions,
		transmit_carrier: s.tx_carrier_errors + s.tx_aborted_errors + s.tx_window_errors + s.tx_heartbeat_errors,
		transmit_compressed: s.tx_compressed,
		receive_nohandler: s.rx_nohandler,
	};
}

describe('collectors.netdev', () => {
	it('exports the sixteen /proc/net/dev counters and receive_nohandler of each caju router link', () => {
		with_collector(netdev, links(ROUTER), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_network_receive_bytes_total', 'node_network_receive_packets_total',
				'node_network_receive_errs_total', 'node_network_receive_drop_total',
				'node_network_receive_fifo_total', 'node_network_receive_frame_total',
				'node_network_receive_compressed_total', 'node_network_receive_multicast_total',
				'node_network_transmit_bytes_total', 'node_network_transmit_packets_total',
				'node_network_transmit_errs_total', 'node_network_transmit_drop_total',
				'node_network_transmit_fifo_total', 'node_network_transmit_colls_total',
				'node_network_transmit_carrier_total', 'node_network_transmit_compressed_total',
				'node_network_receive_nohandler_total',
			], map(r.families, (f) => f.name));
			assert.match([ 'counter' ], uniq(map(r.families, (f) => f.type)));
			assert.match([
				'# HELP node_network_receive_bytes_total Network device statistic receive_bytes.',
				'# TYPE node_network_receive_bytes_total counter',
				'node_network_receive_bytes_total{device="lo"} 73782819',
			], slice(r.lines, 0, 3));
			assert.match(17 * 11, length(filter(r.lines, (l) => substr(l, 0, 1) != '#')));

			// eth1's receive_drop adds rx_missed_errors (2253) to rx_dropped (4056).
			assert.match([
				'node_network_receive_bytes_total{device="eth1"} 667029180',
				'node_network_receive_packets_total{device="eth1"} 610704',
				'node_network_receive_errs_total{device="eth1"} 0',
				'node_network_receive_drop_total{device="eth1"} 6309',
				'node_network_receive_fifo_total{device="eth1"} 0',
				'node_network_receive_frame_total{device="eth1"} 0',
				'node_network_receive_compressed_total{device="eth1"} 0',
				'node_network_receive_multicast_total{device="eth1"} 2186',
				'node_network_transmit_bytes_total{device="eth1"} 102896372',
				'node_network_transmit_packets_total{device="eth1"} 253814',
				'node_network_transmit_errs_total{device="eth1"} 0',
				'node_network_transmit_drop_total{device="eth1"} 2',
				'node_network_transmit_fifo_total{device="eth1"} 0',
				'node_network_transmit_colls_total{device="eth1"} 0',
				'node_network_transmit_carrier_total{device="eth1"} 0',
				'node_network_transmit_compressed_total{device="eth1"} 0',
				'node_network_receive_nohandler_total{device="eth1"} 0',
			], of_device(r.lines, 'eth1'));
		});
	});

	it('labels the samples with the caju AP links, in the order the kernel lists them', () => {
		with_collector(netdev, links(AP), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'lo', 'eth0', 'lan', 'wan', 'br-lan', 'vlan-guest', 'vlan-iot', 'vlan-main', 'vlan-mgmt',
				'phy1-ap0', 'phy0-ap0', 'phy1-ap1',
			], map(r.families[0].samples, (s) => s.labels[0][1]));
		});
	});

	it('asks for a dump of every link', () => {
		let seen = [];
		let reply = function(flags, attrs) {
			push(seen, [ flags, attrs ]);
			return ROUTER;
		};
		let dump;

		with_mods({}, (mods) => { dump = mods.rtnl.const.NLM_F_DUMP; });
		assert.match(true, type(dump) == 'int');

		with_collector(netdev, links(reply), (r) => {
			assert.match(true, r.result.ok);
			assert.match([ [ dump, {} ] ], seen);
		});
	});

	it('passes a failed request on as the collector result', () => {
		with_collector(netdev, { rtnl: { errors: { RTM_GETLINK: 'Operation not permitted' } } }, (r) => {
			assert.match({ ok: false, error: 'RTNL_FAILED', details: 'Operation not permitted' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
			assert.match([ "collector 'netdev': RTNL_FAILED (Operation not permitted)" ], r.logs);
		});
	});

	it('fails with NEED_MISSING without ucode-mod-rtnl', () => {
		with_collector(netdev, { no_rtnl: true }, (r) => assert.match('NEED_MISSING', r.result.error));
	});

	it('fails with SOURCE_INVALID for a reply that is not a list of links', () => {
		with_collector(netdev, links({ dev: 'lo' }), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: 'RTM_GETLINK: not a list of links' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_INVALID when no link has statistics', () => {
		with_collector(netdev, links([ { dev: 'lo' }, { stats64: {} } ]), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: 'RTM_GETLINK: no link with statistics' },
				{ error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('leaves out the links without statistics, and the counters whose fields are missing', () => {
		with_collector(netdev, links([ { dev: 'dummy0' }, { dev: 'eth0', stats64: { rx_bytes: 5, rx_dropped: 1 } } ]), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_network_receive_bytes_total Network device statistic receive_bytes.',
				'# TYPE node_network_receive_bytes_total counter',
				'node_network_receive_bytes_total{device="eth0"} 5',
			], r.lines);
		});
	});

	prop('exports for any link what /proc/net/dev would show for it, and receive_nohandler',
		gen.array(gen.int(0, 1 << 48), { len: length(STATS64) }), (values) => {
			let stats = {};
			for (let i, name in STATS64)
				stats[name] = values[i];

			with_collector(netdev, links([ { dev: 'eth0', stats64: stats } ]), (r) => {
				let want = [];
				for (let col, v in proc_net_dev(stats))
					push(want, `node_network_${col}_total{device="eth0"} ${v}`);

				assert.match(true, r.result.ok);
				assert.match(want, of_device(r.lines, 'eth0'));
			});
		});
});

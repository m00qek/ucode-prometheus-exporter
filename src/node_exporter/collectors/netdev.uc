'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/netdev.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'netdev',
	help: 'Network device statistics, as /proc/net/dev shows them, from rtnetlink.',
	needs: [ 'rtnl' ],
};

// Each counter as the sum of the link's stats64 fields that /proc/net/dev adds
// up for its column (dev_seq_printf_stats in net/core/net-procfs.c), as
// node_exporter's netdev collector reads them from netlink (its legacy names,
// the default), and receive_nohandler, which it adds.
const STATS = [
	[ 'receive_bytes', [ 'rx_bytes' ] ],
	[ 'receive_packets', [ 'rx_packets' ] ],
	[ 'receive_errs', [ 'rx_errors' ] ],
	[ 'receive_drop', [ 'rx_dropped', 'rx_missed_errors' ] ],
	[ 'receive_fifo', [ 'rx_fifo_errors' ] ],
	[ 'receive_frame', [ 'rx_length_errors', 'rx_over_errors', 'rx_crc_errors', 'rx_frame_errors' ] ],
	[ 'receive_compressed', [ 'rx_compressed' ] ],
	[ 'receive_multicast', [ 'multicast' ] ],
	[ 'transmit_bytes', [ 'tx_bytes' ] ],
	[ 'transmit_packets', [ 'tx_packets' ] ],
	[ 'transmit_errs', [ 'tx_errors' ] ],
	[ 'transmit_drop', [ 'tx_dropped' ] ],
	[ 'transmit_fifo', [ 'tx_fifo_errors' ] ],
	[ 'transmit_colls', [ 'collisions' ] ],
	[ 'transmit_carrier', [ 'tx_carrier_errors', 'tx_aborted_errors', 'tx_window_errors', 'tx_heartbeat_errors' ] ],
	[ 'transmit_compressed', [ 'tx_compressed' ] ],
	[ 'receive_nohandler', [ 'rx_nohandler' ] ],
];

// The sum of the fields, or null when one is not a number: the sample is then left out.
function sum(stats, fields) {
	let total = 0;

	for (let f in fields) {
		if (!(type(stats[f]) in [ 'int', 'double' ]))
			return null;
		total += stats[f];
	}

	return total;
}

export function collect(deps, out) {
	let c = deps.rtnl.const;
	let res = deps.rtnl.request(c.RTM_GETLINK, c.NLM_F_DUMP, {});

	if (!res.ok)
		return res;

	let links = res.data;
	if (type(links) != 'array')
		return Result.err(errors.SOURCE_INVALID, 'RTM_GETLINK: not a list of links');

	// A link without a name or statistics is not one /proc/net/dev would show.
	links = filter(links, (l) => type(l?.dev) == 'string' && type(l.stats64) == 'object');
	if (!length(links))
		return Result.err(errors.SOURCE_INVALID, 'RTM_GETLINK: no link with statistics');

	for (let s in STATS) {
		let m = out.counter(`node_network_${s[0]}_total`, `Network device statistic ${s[0]}.`);

		for (let l in links)
			m({ device: l.dev }, sum(l.stats64, s[1]));
	}

	return Result.ok();
};

'use strict';

import { Result, errors } from 'prometheus_exporter.api';

export const meta = {
	name: 'netdev',
	title: 'Network device statistics',
	help: 'Network device statistics, as /proc/net/dev shows them, from rtnetlink.',
	needs: [ 'rtnl' ],
};

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

function sum(stats, fields) {
	let total = 0;

	for (let f in fields) {
		let v = stats[f], t = type(v);

		if (t != 'int' && t != 'double')
			return null;
		total += v;
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

	links = filter(links, (l) => type(l?.dev) == 'string' && type(l.stats64) == 'object');
	if (!length(links))
		return Result.err(errors.SOURCE_INVALID, 'RTM_GETLINK: no link with statistics');

	let labels = map(links, (l) => out.labels({ device: l.dev }));

	for (let s in STATS) {
		let m = out.counter(`node_network_${s[0]}_total`, `Network device statistic ${s[0]}.`);
		let one = (length(s[1]) == 1) ? s[1][0] : null;

		for (let i, l in links) {
			if (one == null) {
				m(labels[i], sum(l.stats64, s[1]));
				continue;
			}

			let v = l.stats64[one], t = type(v);

			m(labels[i], (t == 'int' || t == 'double') ? v : null);
		}
	}

	return Result.ok();
};

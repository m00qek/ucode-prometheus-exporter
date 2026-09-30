'use strict';

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'wireguard',
	help: 'WireGuard interfaces and peers, from ubus wireguard status and the network config.',
	needs: [ 'ubus', 'uci' ],
};

// ubus hands 16- and 32-bit integers on as signed ones: a listen port of 51820
// arrives as -13716.
function unsigned(v, bits) {
	return type(v) == 'int' && v < 0 ? v + (1 << bits) : v;
}

// { public key: description } of an interface's peers in /etc/config/network.
function descriptions(uci, loaded, iface) {
	let by_key = {};

	if (loaded)
		uci.foreach('network', `wireguard_${iface}`, (s) => {
			if (s.public_key != null && s.description != null)
				by_key[s.public_key] = s.description;
		});

	return by_key;
}

export function collect(deps, out) {
	let res = deps.ubus.call('wireguard', 'status');

	if (!res.ok)
		return res;
	if (type(res.data) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'wireguard status: not an object');

	let loaded = deps.uci.load('network');

	let iface_info = out.gauge('wireguard_interface_info', 'A WireGuard interface.');
	let peer_info = out.gauge('wireguard_peer_info', 'A WireGuard peer.');
	let handshake = out.gauge('wireguard_latest_handshake_seconds',
		'Unix time of the latest handshake with a peer; 0 for none.');
	let rx = out.counter('wireguard_received_bytes_total', 'Bytes received from a peer.');
	let tx = out.counter('wireguard_sent_bytes_total', 'Bytes sent to a peer.');

	for (let iface, wc in res.data) {
		if (type(wc) != 'object')
			continue;

		// NaN for an unset fwmark or keepalive, as the exporter this replaces labels them.
		iface_info({
			name: iface,
			public_key: wc.public_key,
			listen_port: unsigned(wc.listen_port, 16),
			fwmark: unsigned(wc.fwmark, 32) || NaN,
		}, 1);

		let desc = descriptions(deps.uci, loaded, iface);

		for (let key, pc in wc.peers) {
			if (type(pc) != 'object')
				continue;

			peer_info({
				interface: iface,
				public_key: key,
				description: desc[key],
				endpoint: pc.endpoint,
				persistent_keepalive_interval: unsigned(pc.persistent_keepalive_interval, 16) || NaN,
			}, 1);

			let labels = { interface: iface, public_key: key };
			handshake(labels, pc.last_handshake);
			rx(labels, pc.rx_bytes);
			tx(labels, pc.tx_bytes);
		}
	}

	return Result.ok();
};

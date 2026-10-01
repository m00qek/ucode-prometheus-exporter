'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/wireguard.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The peers' traffic and handshakes as prometheus_wireguard_exporter
// (github.com/MindFlavor/prometheus_wireguard_exporter) names and labels them,
// so its dashboards work: {interface, public_key, allowed_ips, friendly_name},
// the friendly name being the peer's description in /etc/config/network, and
// its help texts. The interfaces and the rest of each peer are info metrics.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'wireguard',
	help: 'WireGuard interfaces and peers, from ubus wireguard status and the network config.',
	needs: [ 'ubus', 'uci' ],
	configs: [ 'network' ],
};

// ubus hands 16- and 32-bit integers on as signed ones: a listen port of 51820
// arrives as -13716.
function unsigned(v, bits) {
	return type(v) == 'int' && v < 0 ? v + (1 << bits) : v;
}

// { public key: description } of an interface's peers in /etc/config/network.
function descriptions(network, loaded, iface) {
	let by_key = {};

	if (loaded)
		network.foreach(`wireguard_${iface}`, (s) => {
			if (s.public_key != null && s.description != null)
				by_key[s.public_key] = s.description;
		});

	return by_key;
}

// A peer's allowed IPs as the standalone exporter labels them: joined by commas.
export function allowed_ips(list) {
	list = filter(type(list) == 'array' ? list : [], (ip) => type(ip) == 'string');

	return length(list) ? join(',', list) : null;
};

export function collect(deps, out) {
	let res = deps.ubus.call('wireguard', 'status');

	if (!res.ok)
		return res;
	if (type(res.data) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'wireguard status: not an object');

	let loaded = deps.uci.network.loaded();

	let iface_info = out.gauge('wireguard_interface_info', 'A WireGuard interface.');
	let peer_info = out.gauge('wireguard_peer_info', 'A WireGuard peer.');
	let tx = out.counter('wireguard_sent_bytes_total', 'Bytes sent to the peer');
	let rx = out.counter('wireguard_received_bytes_total', 'Bytes received from the peer');
	let handshake = out.gauge('wireguard_latest_handshake_seconds', 'Seconds from the last handshake');

	for (let iface, wc in res.data) {
		if (type(wc) != 'object')
			continue;

		// An unset fwmark or keepalive (0) is left out.
		iface_info({
			interface: iface,
			public_key: wc.public_key,
			listen_port: unsigned(wc.listen_port, 16),
			fwmark: unsigned(wc.fwmark, 32) || null,
		}, 1);

		let desc = descriptions(deps.uci.network, loaded, iface);

		for (let key, pc in wc.peers) {
			if (type(pc) != 'object')
				continue;

			peer_info({
				interface: iface,
				public_key: key,
				friendly_name: desc[key],
				endpoint: pc.endpoint,
				persistent_keepalive_interval: unsigned(pc.persistent_keepalive_interval, 16) || null,
			}, 1);

			let labels = {
				interface: iface,
				public_key: key,
				allowed_ips: allowed_ips(pc.allowed_ips),
				friendly_name: desc[key],
			};
			tx(labels, pc.tx_bytes);
			rx(labels, pc.rx_bytes);
			handshake(labels, pc.last_handshake);
		}
	}

	return Result.ok();
};

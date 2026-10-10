'use strict';

import { Result, errors, services, u16, u32 } from 'prometheus_exporter.api';

export const meta = {
	name: 'wireguard',
	title: 'WireGuard',
	help: 'WireGuard interfaces and peers, from ubus wireguard status.',
	needs: [ 'ubus' ],
	ubus: { wireguard: [ 'status' ], uci: (options) => options.peer_names ? [ 'get' ] : [] },
	options: {
		peer_names: {
			default: false,
			title: 'Peer names',
			help: 'Label each peer with its description in the network config (friendly_name), asked of rpcd: the peer sections alone, never the private keys.',
		},
	},
};

function descriptions(ubus, iface) {
	let by_key = {};
	let kind = `wireguard_${iface}`;
	let res = ubus.call('uci', 'get', { config: 'network', type: kind });

	if (res.ok && type(res.data?.values) == 'object')
		for (let name, s in res.data.values)
			if (type(s) == 'object' && s['.type'] == kind && type(s.public_key) == 'string' && type(s.description) == 'string')
				by_key[s.public_key] = s.description;

	return by_key;
}

export function allowed_ips(list) {
	list = filter(type(list) == 'array' ? list : [], (ip) => type(ip) == 'string');

	return length(list) ? join(',', list) : null;
};

export function collect(deps, out, options) {
	let res = deps.ubus.call('wireguard', 'status');

	if (services.object_missing(res))
		return Result.none('rpcd has no wireguard object: rpcd-mod-wireguard is not installed');
	if (!res.ok)
		return res;
	if (type(res.data) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'wireguard status: not an object');

	let iface_info = out.gauge('wireguard_interface_info', 'A WireGuard interface.');
	let peer_info = out.gauge('wireguard_peer_info', 'A WireGuard peer.');
	let tx = out.counter('wireguard_sent_bytes_total', 'Bytes sent to the peer');
	let rx = out.counter('wireguard_received_bytes_total', 'Bytes received from the peer');
	let handshake = out.gauge('wireguard_latest_handshake_seconds', 'Seconds from the last handshake');

	for (let iface, wc in res.data) {
		if (type(wc) != 'object')
			continue;

		iface_info({
			interface: iface,
			public_key: wc.public_key,
			listen_port: u16(wc.listen_port),
			fwmark: u32(wc.fwmark) || null,
		}, 1);

		let desc = options.peer_names ? descriptions(deps.ubus, iface) : {};

		for (let key, pc in wc.peers) {
			if (type(pc) != 'object')
				continue;

			peer_info({
				interface: iface,
				public_key: key,
				friendly_name: desc[key],
				endpoint: pc.endpoint,
				persistent_keepalive_interval: u16(pc.persistent_keepalive_interval) || null,
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

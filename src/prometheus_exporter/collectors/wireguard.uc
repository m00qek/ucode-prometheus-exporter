'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/wireguard.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The peers' traffic and handshakes as prometheus_wireguard_exporter
// (github.com/MindFlavor/prometheus_wireguard_exporter) names and labels them,
// so its dashboards work: {interface, public_key, allowed_ips, friendly_name},
// and its help texts. The interfaces and the rest of each peer are info metrics.
//
// The friendly name is the peer's description in /etc/config/network, only
// with peer_names. That file holds the interfaces' private keys, so it is not
// read, nor in the jail: rpcd's uci object hands over the interface's peer
// sections alone, and all but each one's public key and description is let go.
//
// rpcd-mod-wireguard sends the listen port and the keepalive interval with
// blobmsg_add_u16(), and the fwmark with blobmsg_add_u32() (src/api.c), which
// ucode's ubus gives signed: u16() and u32() undo it.

import { Result, errors, services, u16, u32 } from 'prometheus_exporter.api';

export const meta = {
	name: 'wireguard',
	title: 'WireGuard',
	help: 'WireGuard interfaces and peers, from ubus wireguard status.',
	needs: [ 'ubus' ],
	options: {
		peer_names: {
			default: false,
			title: 'Peer names',
			help: 'Label each peer with its description in the network config (friendly_name), asked of rpcd: the peer sections alone, never the private keys.',
		},
	},
};

// { public key: description } of an interface's peers in /etc/config/network,
// as rpcd's uci object gives its `wireguard_<iface>` sections. Without them
// (no such section, rpcd failing) the peers have no friendly name.
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

// A peer's allowed IPs as the standalone exporter labels them: joined by commas.
export function allowed_ips(list) {
	list = filter(type(list) == 'array' ? list : [], (ip) => type(ip) == 'string');

	return length(list) ? join(',', list) : null;
};

export function collect(deps, out, options) {
	let res = deps.ubus.call('wireguard', 'status');

	// rpcd's wireguard object comes with rpcd-mod-wireguard, which a device
	// that uses WireGuard has (luci-proto-wireguard depends on it).
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

		// An unset fwmark or keepalive (0) is left out.
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

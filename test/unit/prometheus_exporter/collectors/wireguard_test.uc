'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as wireguard from 'prometheus_exporter.collectors.wireguard';

// The caju router's two WireGuard interfaces, keys and endpoints redacted; its
// network config (uci show network) as the uci mock takes it, private keys left out.
const STATUS = fixtures.ubus('caju-router', 'wireguard', 'status');
const NETWORK = json(fixtures.file('caju-router', '/uci/network.json'));

const MESH = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';
const SITE_B = 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=';
const MESH_HUB = 'AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=';
const PLAYGROUND = 'BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=';
const HUB = 'BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU=';

function cfg(status, network) {
	return {
		ubus: { data: { 'wireguard:status': status } },
		uci: { data: network ? { network } : {} },
	};
}

describe('collectors.wireguard', () => {
	it('exports the interfaces and peers of the caju router, the peer descriptions of its config as friendly names', () => {
		with_collector(wireguard, cfg(STATUS, NETWORK), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP wireguard_interface_info A WireGuard interface.',
				'# TYPE wireguard_interface_info gauge',
				`wireguard_interface_info{interface="wg_mesh",public_key="${MESH}",listen_port="51820"} 1`,
				`wireguard_interface_info{interface="lan2playground",public_key="${PLAYGROUND}",listen_port="51831"} 1`,
				'# HELP wireguard_peer_info A WireGuard peer.',
				'# TYPE wireguard_peer_info gauge',
				`wireguard_peer_info{interface="wg_mesh",public_key="${SITE_B}",endpoint="192.0.2.12:51820"} 1`,
				`wireguard_peer_info{interface="wg_mesh",public_key="${MESH_HUB}",endpoint="[2001:db8::1]:51820",persistent_keepalive_interval="25"} 1`,
				`wireguard_peer_info{interface="lan2playground",public_key="${HUB}",friendly_name="hub",endpoint="203.0.113.22:51830",persistent_keepalive_interval="25"} 1`,
				'# HELP wireguard_sent_bytes_total Bytes sent to the peer',
				'# TYPE wireguard_sent_bytes_total counter',
				`wireguard_sent_bytes_total{interface="wg_mesh",public_key="${SITE_B}",allowed_ips="10.251.224.12/32,10.197.0.0/16"} 0`,
				`wireguard_sent_bytes_total{interface="wg_mesh",public_key="${MESH_HUB}",allowed_ips="10.251.224.1/32"} 33356`,
				`wireguard_sent_bytes_total{interface="lan2playground",public_key="${HUB}",allowed_ips="10.251.223.0/24",friendly_name="hub"} 35873200`,
				'# HELP wireguard_received_bytes_total Bytes received from the peer',
				'# TYPE wireguard_received_bytes_total counter',
				`wireguard_received_bytes_total{interface="wg_mesh",public_key="${SITE_B}",allowed_ips="10.251.224.12/32,10.197.0.0/16"} 0`,
				`wireguard_received_bytes_total{interface="wg_mesh",public_key="${MESH_HUB}",allowed_ips="10.251.224.1/32"} 8740`,
				`wireguard_received_bytes_total{interface="lan2playground",public_key="${HUB}",allowed_ips="10.251.223.0/24",friendly_name="hub"} 7236360`,
				'# HELP wireguard_latest_handshake_seconds Seconds from the last handshake',
				'# TYPE wireguard_latest_handshake_seconds gauge',
				`wireguard_latest_handshake_seconds{interface="wg_mesh",public_key="${SITE_B}",allowed_ips="10.251.224.12/32,10.197.0.0/16"} 0`,
				`wireguard_latest_handshake_seconds{interface="wg_mesh",public_key="${MESH_HUB}",allowed_ips="10.251.224.1/32"} 1790806557`,
				`wireguard_latest_handshake_seconds{interface="lan2playground",public_key="${HUB}",allowed_ips="10.251.223.0/24",friendly_name="hub"} 1790806578`,
			], r.lines);
		});
	});

	it('exports peers without friendly names when there is no network config', () => {
		with_collector(wireguard, cfg(STATUS, null), (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, index(r.text, 'friendly_name=') >= 0);
			assert.match(contains([
				`wireguard_peer_info{interface="lan2playground",public_key="${HUB}",endpoint="203.0.113.22:51830",persistent_keepalive_interval="25"} 1`,
			]), r.lines);
		});
	});

	it('labels a set fwmark with its unsigned value', () => {
		let status = { wg0: { public_key: MESH, listen_port: 51820, fwmark: -2147483648, peers: {} } };

		with_collector(wireguard, cfg(status, null), (r) => {
			assert.match([
				`wireguard_interface_info{interface="wg0",public_key="${MESH}",listen_port="51820",fwmark="2147483648"} 1`,
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('exports an interface without peers', () => {
		with_collector(wireguard, cfg({ wg0: { public_key: MESH, listen_port: 1234 } }, null), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP wireguard_interface_info A WireGuard interface.',
				'# TYPE wireguard_interface_info gauge',
				`wireguard_interface_info{interface="wg0",public_key="${MESH}",listen_port="1234"} 1`,
			], r.lines);
		});
	});

	it('exports nothing for a router without WireGuard interfaces', () => {
		with_collector(wireguard, cfg({}, NETWORK), (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('passes on the ubus error when rpcd has no wireguard object', () => {
		with_collector(wireguard, { ubus: { errors: { 'wireguard:status': 'Not found' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'wireguard status: Not found' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for a reply that is not an object', () => {
		with_collector(wireguard, cfg('x', null), (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});

	// ubus gives u16 values back as signed 16-bit integers.
	prop('labels every listen port with its unsigned value', gen.int(1, 65535), (port) => {
		let signed = port > 32767 ? port - 65536 : port;
		let status = { wg0: { public_key: MESH, listen_port: signed, peers: {} } };

		with_collector(wireguard, cfg(status, null), (r) => {
			assert.match(true, index(r.text, `listen_port="${port}"`) >= 0);
		});
	});

	it('joins the allowed IPs with commas, and has none for a peer without', () => {
		assert.match([ '10.0.0.1/32,fd00::/64', '10.0.0.1/32', null, null ],
			map([ [ '10.0.0.1/32', 'fd00::/64' ], [ '10.0.0.1/32' ], [], null ], wireguard.allowed_ips));
	});
});

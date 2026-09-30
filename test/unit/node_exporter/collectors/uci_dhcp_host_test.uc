'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as fixtures from 'lib.fixtures';
import { with_collector } from 'context';
import * as uci_dhcp_host from 'node_exporter.collectors.uci_dhcp_host';

// caju-router's /etc/config/dhcp, with fake names, MACs and addresses.
const ROUTER_DHCP = json(fixtures.file('caju-router', '/uci/dhcp.json'));

function cfg(hosts) {
	let dhcp = { lan: { '.type': 'dhcp', interface: 'lan', start: '100', limit: '150' } };

	for (let i, h in hosts)
		dhcp[`cfg${i}`] = { '.type': 'host', ...h };

	return { uci: { data: { dhcp } } };
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.uci_dhcp_host', () => {
	it('exports every static lease of the caju router, one per MAC of the AP', () => {
		with_collector(uci_dhcp_host, { uci: { data: { dhcp: ROUTER_DHCP } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP dhcp_host_info A static DHCP lease from /etc/config/dhcp.',
				'# TYPE dhcp_host_info gauge',
				'dhcp_host_info{name="amplifier",mac="02:00:00:00:00:01",ip="192.168.17.33"} 1',
				'dhcp_host_info{name="chromecast",mac="02:00:00:00:00:02",ip="192.168.17.79"} 1',
				'dhcp_host_info{name="speaker",mac="02:00:00:00:00:03",ip="192.168.17.71"} 1',
				'dhcp_host_info{name="homeassistant",mac="02:00:00:00:00:04",ip="192.168.17.60"} 1',
				'dhcp_host_info{name="phone-a",mac="02:00:00:00:00:05",ip="192.168.17.35"} 1',
				'dhcp_host_info{name="display",mac="02:00:00:00:00:06",ip="192.168.17.70"} 1',
				'dhcp_host_info{name="phone-b",mac="02:00:00:00:00:07",ip="192.168.17.30"} 1',
				'dhcp_host_info{name="bulb",mac="02:00:00:00:00:08",ip="192.168.17.92"} 1',
				'dhcp_host_info{name="fan",mac="02:00:00:00:00:09",ip="192.168.17.91"} 1',
				'dhcp_host_info{name="ap",mac="02:00:00:00:00:10",ip="192.168.11.10"} 1',
				'dhcp_host_info{name="ap",mac="02:00:00:00:00:11",ip="192.168.11.10"} 1',
				'dhcp_host_info{name="switch",mac="02:00:00:00:00:12",ip="192.168.11.2"} 1',
			], r.lines);
		});
	});

	it('splits a MAC option that holds several, space-separated', () => {
		with_collector(uci_dhcp_host, cfg([ { name: 'nas', mac: ' 02:00:00:00:00:21  02:00:00:00:00:22 ', ip: '10.0.0.5' } ]), (r) => {
			assert.match([
				'dhcp_host_info{name="nas",mac="02:00:00:00:00:21",ip="10.0.0.5"} 1',
				'dhcp_host_info{name="nas",mac="02:00:00:00:00:22",ip="10.0.0.5"} 1',
			], samples(r.lines));
		});
	});

	it('leaves out the labels of options a host lacks', () => {
		with_collector(uci_dhcp_host, cfg([ { name: 'printer', ip: '10.0.0.9' }, { mac: '02:00:00:00:00:31' } ]), (r) => {
			assert.match([
				'dhcp_host_info{name="printer",ip="10.0.0.9"} 1',
				'dhcp_host_info{mac="02:00:00:00:00:31"} 1',
			], samples(r.lines));
		});
	});

	it('writes a lease configured twice once', () => {
		let h = { name: 'tv', mac: '02:00:00:00:00:41', ip: '10.0.0.4' };

		with_collector(uci_dhcp_host, cfg([ h, h ]), (r) => {
			assert.match([ 'dhcp_host_info{name="tv",mac="02:00:00:00:00:41",ip="10.0.0.4"} 1' ], samples(r.lines));
		});
	});

	it('exports nothing, successfully, without static leases', () => {
		with_collector(uci_dhcp_host, cfg([]), (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_UNREADABLE without /etc/config/dhcp', () => {
		with_collector(uci_dhcp_host, {}, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/etc/config/dhcp' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	prop('has a sample for every MAC, however the option holds them',
		gen.tuple(gen.array(gen.int(1, 99), { min_len: 1, max_len: 5 }), gen.bool()), (t) => {
			let all = uniq(map(t[0], (n) => sprintf('02:00:00:00:01:%02d', n)));
			let mac = t[1] ? all : join(' ', all);

			assert.match(all, uci_dhcp_host.macs(mac));

			with_collector(uci_dhcp_host, cfg([ { name: 'h', mac, ip: '10.0.0.1' } ]), (r) => {
				assert.match(map(all, (m) => `dhcp_host_info{name="h",mac="${m}",ip="10.0.0.1"} 1`), samples(r.lines));
			});
		});
});

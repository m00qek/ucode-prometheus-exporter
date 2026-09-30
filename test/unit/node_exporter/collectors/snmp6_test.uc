'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as snmp6 from 'node_exporter.collectors.snmp6';

const ROUTER_DEVICES = [ 'eth0', 'eth1', 'ifb4eth1', 'ifb4vlan-guest', 'lan2playground', 'lo',
	'vlan-guest', 'vlan-iot', 'vlan-main', 'vlan-mgmt' ];
const AP_DEVICES = [ 'br-lan', 'eth0', 'lan', 'lo', 'phy0-ap0', 'phy1-ap0', 'phy1-ap1',
	'vlan-guest', 'vlan-iot', 'vlan-main', 'vlan-mgmt', 'wan' ];

function capture(device, devices) {
	return fixtures.files(device, [ '/proc/net/snmp6', ...map(devices, (d) => `/proc/net/dev_snmp6/${d}`) ]);
}

const ROUTER = capture('caju-router', ROUTER_DEVICES);
const AP = capture('caju-ap', AP_DEVICES);

function head(text, n) {
	return join('\n', slice(split(text, '\n'), 0, n)) + '\n';
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

// The "<name> <value>" lines of every file.
function values_of(data) {
	let n = 0;

	for (let path, text in data)
		n += length(filter(split(text, '\n'), (l) => length(split(trim(l), /\s+/)) >= 2));

	return n;
}

describe('collectors.snmp6', () => {
	it('exports the caju router counters, for all and per device, one family each', () => {
		let data = {
			'/proc/net/snmp6': head(ROUTER['/proc/net/snmp6'], 2),
			'/proc/net/dev_snmp6/eth1': head(ROUTER['/proc/net/dev_snmp6/eth1'], 3),
			'/proc/net/dev_snmp6/eth0': head(ROUTER['/proc/net/dev_snmp6/eth0'], 3),
		};

		with_collector(snmp6, { fs: { data } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP snmp6_Ip6InReceives IPv6 statistic Ip6InReceives.',
				'# TYPE snmp6_Ip6InReceives counter',
				'snmp6_Ip6InReceives{device="all"} 5536',
				'snmp6_Ip6InReceives{device="eth0"} 0',
				'snmp6_Ip6InReceives{device="eth1"} 5144',
				'# HELP snmp6_Ip6InHdrErrors IPv6 statistic Ip6InHdrErrors.',
				'# TYPE snmp6_Ip6InHdrErrors counter',
				'snmp6_Ip6InHdrErrors{device="all"} 0',
				'snmp6_Ip6InHdrErrors{device="eth0"} 0',
				'snmp6_Ip6InHdrErrors{device="eth1"} 0',
				'# HELP snmp6_ifIndex IPv6 statistic ifIndex.',
				'# TYPE snmp6_ifIndex counter',
				'snmp6_ifIndex{device="eth0"} 2',
				'snmp6_ifIndex{device="eth1"} 3',
			], r.lines);
		});
	});

	it('exports every line of the caju router and AP captures', () => {
		for (let data in [ ROUTER, AP ]) {
			with_collector(snmp6, { fs: { data } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(values_of(data), length(samples(r.lines)));
			});
		}
	});

	it('exports the AP radios by their device names', () => {
		with_collector(snmp6, { fs: { data: AP } }, (r) => {
			assert.match(contains([ 'snmp6_ifIndex{device="phy0-ap0"} ' + trim(split(split(AP['/proc/net/dev_snmp6/phy0-ap0'], '\n')[0], /\s+/)[1]) ]),
				r.lines);
		});
	});

	it('exports the system counters where there is no dev_snmp6 directory', () => {
		with_collector(snmp6, { fs: { data: { '/proc/net/snmp6': 'Ip6InReceives 7\n' }, behavior: { lsdir: () => null } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'snmp6_Ip6InReceives{device="all"} 7' ], samples(r.lines));
		});
	});

	it('leaves out a device that goes away before it is read', () => {
		let data = { '/proc/net/snmp6': 'Ip6InReceives 7\n', '/proc/net/dev_snmp6/eth0': 'Ip6InReceives 3\n', '/proc/net/dev_snmp6/gone': null };

		with_collector(snmp6, { fs: { data, behavior: { lsdir: () => [ 'gone', 'eth0' ] } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'snmp6_Ip6InReceives{device="all"} 7', 'snmp6_Ip6InReceives{device="eth0"} 3' ], samples(r.lines));
		});
	});

	it('skips lines without a value', () => {
		let data = { '/proc/net/snmp6': 'Ip6InReceives 7\nIp6Lonely\n\n', '/proc/net/dev_snmp6/none': null };

		with_collector(snmp6, { fs: { data } }, (r) => {
			assert.match([ 'snmp6_Ip6InReceives{device="all"} 7' ], samples(r.lines));
		});
	});

	it('fails with SOURCE_UNREADABLE without /proc/net/snmp6 (IPv6 disabled)', () => {
		with_collector(snmp6, { fs: { data: { '/proc/net/snmp6': null } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/net/snmp6' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	prop('exports every name and value of the system file',
		gen.array(gen.tuple(gen.alphanumeric({ min_len: 1, max_len: 12 }), gen.int(0, 1000000000)), { min_len: 1, max_len: 10 }), (rows) => {
			// Names made unique, as the kernel's are.
			let text = join('', map(rows, (r, i) => sprintf('Ip6%s%d%s\t%d\n', r[0], i, '  ', r[1])));
			let want = map(rows, (r, i) => sprintf('snmp6_Ip6%s%d{device="all"} %d', r[0], i, r[1]));

			with_collector(snmp6, { fs: { data: { '/proc/net/snmp6': text, '/proc/net/dev_snmp6/none': null } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(want, samples(r.lines));
			});
		});
});

'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as snmp6 from 'prometheus.collectors.snmp6';

const ROUTER_DEVICES = [ 'eth0', 'eth1', 'ifb4eth1', 'ifb4vlan-guest', 'lan2playground', 'lo',
	'vlan-guest', 'vlan-iot', 'vlan-main', 'vlan-mgmt' ];
const AP_DEVICES = [ 'br-lan', 'eth0', 'lan', 'lo', 'phy0-ap0', 'phy1-ap0', 'phy1-ap1',
	'vlan-guest', 'vlan-iot', 'vlan-main', 'vlan-mgmt', 'wan' ];

function capture(device, devices) {
	return fixtures.files(device, map(devices, (d) => `/proc/net/dev_snmp6/${d}`));
}

const ROUTER = capture('caju-router', ROUTER_DEVICES);
const AP = capture('caju-ap', AP_DEVICES);

function head(text, n) {
	return join('\n', slice(split(text, '\n'), 0, n)) + '\n';
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

// Every field, as before the `fields` option.
const ALL = { fields: '.*' };

// The "<name> <value>" lines of every file.
function values_of(data) {
	let n = 0;

	for (let path, text in data)
		n += length(filter(split(text, '\n'), (l) => length(split(trim(l), /\s+/)) >= 2));

	return n;
}

describe('collectors.snmp6', () => {
	it('exports the caju router counters per device, one family each, and the interface index', () => {
		let data = {
			'/proc/net/dev_snmp6/eth1': head(ROUTER['/proc/net/dev_snmp6/eth1'], 3),
			'/proc/net/dev_snmp6/eth0': head(ROUTER['/proc/net/dev_snmp6/eth0'], 3),
		};

		with_collector(snmp6, { fs: { data }, options: ALL }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_snmp6_ifindex Interface index of the device.',
				'# TYPE node_snmp6_ifindex gauge',
				'node_snmp6_ifindex{device="eth0"} 2',
				'node_snmp6_ifindex{device="eth1"} 3',
				'# HELP node_snmp6_Ip6_InReceives_total IPv6 statistic Ip6InReceives of the device.',
				'# TYPE node_snmp6_Ip6_InReceives_total counter',
				'node_snmp6_Ip6_InReceives_total{device="eth0"} 0',
				'node_snmp6_Ip6_InReceives_total{device="eth1"} 5144',
				'# HELP node_snmp6_Ip6_InHdrErrors_total IPv6 statistic Ip6InHdrErrors of the device.',
				'# TYPE node_snmp6_Ip6_InHdrErrors_total counter',
				'node_snmp6_Ip6_InHdrErrors_total{device="eth0"} 0',
				'node_snmp6_Ip6_InHdrErrors_total{device="eth1"} 0',
			], r.lines);
		});
	});

	it('exports every line of the caju router and AP captures with every field', () => {
		for (let data in [ ROUTER, AP ]) {
			with_collector(snmp6, { fs: { data }, options: ALL }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(values_of(data), length(samples(r.lines)));
				assert.match(true, index(r.text, 'device="all"') < 0);
			});
		}
	});

	it('exports the AP radios by their device names, every protocol under its own name', () => {
		with_collector(snmp6, { fs: { data: AP }, options: ALL }, (r) => {
			assert.match(contains([
				'node_snmp6_ifindex{device="phy0-ap0"} ' + trim(split(split(AP['/proc/net/dev_snmp6/phy0-ap0'], '\n')[0], /\s+/)[1]),
			]), r.lines);
			for (let t in [ 'Ip6_InReceives', 'Icmp6_InMsgs', 'Icmp6_OutMLDv2Reports' ])
				assert.match(true, `# TYPE node_snmp6_${t}_total counter` in r.lines, t);
		});
	});

	it('exports the 13 default fields of each device of the caju router, and no other', () => {
		with_collector(snmp6, { fs: { data: ROUTER } }, (r) => {
			let families = map(r.families, (f) => f.name);

			assert.match(true, r.result.ok);
			assert.match([
				'node_snmp6_Ip6_InHdrErrors_total', 'node_snmp6_Ip6_InTooBigErrors_total', 'node_snmp6_Ip6_InNoRoutes_total',
				'node_snmp6_Ip6_InAddrErrors_total', 'node_snmp6_Ip6_InDiscards_total', 'node_snmp6_Ip6_OutForwDatagrams_total',
				'node_snmp6_Ip6_OutDiscards_total', 'node_snmp6_Ip6_OutNoRoutes_total', 'node_snmp6_Ip6_InOctets_total',
				'node_snmp6_Ip6_OutOctets_total', 'node_snmp6_Icmp6_InMsgs_total', 'node_snmp6_Icmp6_InErrors_total',
				'node_snmp6_Icmp6_OutMsgs_total',
			], families);
			assert.match(13 * length(ROUTER_DEVICES), length(samples(r.lines)));
			assert.match(contains([
				'node_snmp6_Ip6_OutOctets_total{device="eth0"} 224',
				'node_snmp6_Icmp6_OutMsgs_total{device="eth0"} 3',
			]), r.lines);
		});
	});

	it('exports the default fields of the caju AP, 13 a device where it had about 70', () => {
		with_collector(snmp6, { fs: { data: AP } }, (r) => {
			assert.match(13 * length(AP_DEVICES), length(samples(r.lines)));
			assert.match(true, values_of(AP) > 69 * length(AP_DEVICES));
		});
	});

	it('exports the fields its own pattern matches, the interface index by its name', () => {
		with_collector(snmp6, { fs: { data: ROUTER }, options: { fields: '^(ifIndex|Icmp6_OutRouterAdvertisements)$' } }, (r) => {
			assert.match([ 'node_snmp6_ifindex', 'node_snmp6_Icmp6_OutRouterAdvertisements_total' ], map(r.families, (f) => f.name));
			assert.match(2 * length(ROUTER_DEVICES), length(samples(r.lines)));
		});
	});

	it('fails with CONFIG_INVALID for a fields option that is no regular expression', () => {
		with_collector(snmp6, { fs: { data: ROUTER }, options: { fields: '(Ip6' } }, (r) => {
			assert.match({ ok: false, error: 'CONFIG_INVALID' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	it('names each field as the fields option matches it', () => {
		assert.match([ 'Ip6_InReceives', 'Icmp6_OutType143', 'Udp6_InDatagrams', 'UdpLite6_InErrors', 'ifIndex', 'Mystery' ],
			map([ 'Ip6InReceives', 'Icmp6OutType143', 'Udp6InDatagrams', 'UdpLite6InErrors', 'ifIndex', 'Mystery' ], snmp6.field_of));
	});

	prop('exports the lines of any device whose fields the pattern matches, and only those',
		gen.array(gen.tuple(gen.elements('Ip6InOctets', 'Ip6InReceives', 'Icmp6InMsgs', 'Icmp6OutType135', 'ifIndex'), gen.int(0, 1000000)),
			{ min_len: 0, max_len: 8 }), (all) => {
			// Each name once, as the kernel writes it.
			let seen = {};
			let rows = filter(all, (r) => !seen[r[0]] && (seen[r[0]] = true));
			let text = join('', map(rows, (r) => `${r[0]} ${r[1]}\n`));
			let want = [];

			for (let r in rows)
				if (match(snmp6.field_of(r[0]), regexp(snmp6.DEFAULT_FIELDS)))
					push(want, r[1]);

			with_collector(snmp6, { fs: { data: { '/proc/net/dev_snmp6/eth0': text } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(length(want), length(samples(r.lines)));
			});
		});

	it('leaves out a device that goes away before it is read', () => {
		let data = { '/proc/net/dev_snmp6/eth0': 'Ip6InOctets 3\n', '/proc/net/dev_snmp6/gone': null };

		with_collector(snmp6, { fs: { data, behavior: { lsdir: () => [ 'gone', 'eth0' ] } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_snmp6_Ip6_InOctets_total{device="eth0"} 3' ], samples(r.lines));
		});
	});

	it('skips lines without a value', () => {
		let data = { '/proc/net/dev_snmp6/eth0': 'Ip6InReceives 7\nIp6Lonely\n\n' };

		with_collector(snmp6, { fs: { data }, options: ALL }, (r) => {
			assert.match([ 'node_snmp6_Ip6_InReceives_total{device="eth0"} 7' ], samples(r.lines));
		});
	});

	it('has nothing to observe without /proc/net/dev_snmp6 (IPv6 disabled)', () => {
		with_collector(snmp6, { fs: { data: {}, behavior: { lsdir: () => null, stat: () => null } } }, (r) => {
			assert.match({ ok: true, none: 'no IPv6 (no /proc/net/dev_snmp6)', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('fails with SOURCE_UNREADABLE when /proc/net/dev_snmp6 is there and cannot be read', () => {
		with_collector(snmp6, { fs: { data: {}, behavior: { lsdir: () => null, stat: () => ({ type: 'directory' }) } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/net/dev_snmp6' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('names a statistic of no known protocol as it is', () => {
		assert.match([ 'counter', 'node_snmp6_Mystery_total', 'IPv6 statistic Mystery of the device.' ], snmp6.family_of('Mystery'));
	});

	prop('exports every name and value of a device file, split at its protocol',
		gen.array(gen.tuple(gen.oneof(gen.constant('Ip6'), gen.constant('Icmp6'), gen.constant('Udp6'), gen.constant('UdpLite6')),
			gen.alphanumeric({ min_len: 1, max_len: 12 }), gen.int(0, 1000000000)), { min_len: 1, max_len: 10 }), (rows) => {
			// Names made unique, and starting with a capital, as the kernel's are.
			let text = join('', map(rows, (r, i) => sprintf('%sX%s%d  \t%d\n', r[0], r[1], i, r[2])));
			let want = map(rows, (r, i) => sprintf('node_snmp6_%s_X%s%d_total{device="eth0"} %d', r[0], r[1], i, r[2]));

			with_collector(snmp6, { fs: { data: { '/proc/net/dev_snmp6/eth0': text } }, options: ALL }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(want, samples(r.lines));
			});
		});
});

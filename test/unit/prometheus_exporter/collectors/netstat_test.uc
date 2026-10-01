'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as netstat from 'prometheus_exporter.collectors.netstat';

const PATHS = [ '/proc/net/netstat', '/proc/net/snmp', '/proc/net/snmp6' ];
const ROUTER = fixtures.files('caju-router', PATHS);
const AP = fixtures.files('caju-ap', PATHS);

// The header and value lines of one section of a capture.
function section(text, name) {
	return join('', map(filter(split(text, '\n'), (l) => index(l, name + ': ') == 0), (l) => l + '\n'));
}

// The samples in exposition lines.
function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

// The "<name> <value>" lines of /proc/net/snmp6.
function snmp6_values_of(text) {
	return length(filter(split(text, '\n'), (l) => length(split(trim(l), /\s+/)) >= 2));
}

// Values in a section: one per name, after the section's own field.
function values_of(text) {
	let n = 0;
	let l = split(rtrim(text, '\n'), '\n');

	for (let i = 0; i + 1 < length(l); i += 2)
		n += length(split(trim(l[i]), /\s+/)) - 1;

	return n;
}

describe('collectors.netstat', () => {
	it("exports a section of the caju router's /proc/net/snmp", () => {
		let snmp = section(ROUTER['/proc/net/snmp'], 'IcmpMsg') + section(ROUTER['/proc/net/snmp'], 'Udp');

		with_collector(netstat, { fs: { data: { '/proc/net/netstat': null, '/proc/net/snmp': snmp, '/proc/net/snmp6': null } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_netstat_IcmpMsg_InType3 Statistic IcmpMsgInType3.',
				'# TYPE node_netstat_IcmpMsg_InType3 untyped',
				'node_netstat_IcmpMsg_InType3 1201',
				'# HELP node_netstat_IcmpMsg_InType8 Statistic IcmpMsgInType8.',
				'# TYPE node_netstat_IcmpMsg_InType8 untyped',
				'node_netstat_IcmpMsg_InType8 69',
				'# HELP node_netstat_IcmpMsg_OutType0 Statistic IcmpMsgOutType0.',
				'# TYPE node_netstat_IcmpMsg_OutType0 untyped',
				'node_netstat_IcmpMsg_OutType0 69',
				'# HELP node_netstat_IcmpMsg_OutType3 Statistic IcmpMsgOutType3.',
				'# TYPE node_netstat_IcmpMsg_OutType3 untyped',
				'node_netstat_IcmpMsg_OutType3 1629',
				'# HELP node_netstat_IcmpMsg_OutType8 Statistic IcmpMsgOutType8.',
				'# TYPE node_netstat_IcmpMsg_OutType8 untyped',
				'node_netstat_IcmpMsg_OutType8 1',
				'# HELP node_netstat_Udp_InDatagrams Statistic UdpInDatagrams.',
				'# TYPE node_netstat_Udp_InDatagrams untyped',
				'node_netstat_Udp_InDatagrams 42597',
				'# HELP node_netstat_Udp_NoPorts Statistic UdpNoPorts.',
				'# TYPE node_netstat_Udp_NoPorts untyped',
				'node_netstat_Udp_NoPorts 81',
				'# HELP node_netstat_Udp_InErrors Statistic UdpInErrors.',
				'# TYPE node_netstat_Udp_InErrors untyped',
				'node_netstat_Udp_InErrors 0',
				'# HELP node_netstat_Udp_OutDatagrams Statistic UdpOutDatagrams.',
				'# TYPE node_netstat_Udp_OutDatagrams untyped',
				'node_netstat_Udp_OutDatagrams 11803',
				'# HELP node_netstat_Udp_RcvbufErrors Statistic UdpRcvbufErrors.',
				'# TYPE node_netstat_Udp_RcvbufErrors untyped',
				'node_netstat_Udp_RcvbufErrors 0',
				'# HELP node_netstat_Udp_SndbufErrors Statistic UdpSndbufErrors.',
				'# TYPE node_netstat_Udp_SndbufErrors untyped',
				'node_netstat_Udp_SndbufErrors 0',
				'# HELP node_netstat_Udp_InCsumErrors Statistic UdpInCsumErrors.',
				'# TYPE node_netstat_Udp_InCsumErrors untyped',
				'node_netstat_Udp_InCsumErrors 0',
				'# HELP node_netstat_Udp_IgnoredMulti Statistic UdpIgnoredMulti.',
				'# TYPE node_netstat_Udp_IgnoredMulti untyped',
				'node_netstat_Udp_IgnoredMulti 9',
				'# HELP node_netstat_Udp_MemErrors Statistic UdpMemErrors.',
				'# TYPE node_netstat_Udp_MemErrors untyped',
				'node_netstat_Udp_MemErrors 0',
			], r.lines);
		});
	});

	it('exports every value of the three files of the caju router', () => {
		with_collector(netstat, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(values_of(ROUTER['/proc/net/netstat']) + values_of(ROUTER['/proc/net/snmp'])
				+ snmp6_values_of(ROUTER['/proc/net/snmp6']), length(samples(r.lines)));
			assert.match([ 'untyped' ], uniq(map(r.families, (f) => f.type)));
			assert.match(contains([
				'node_netstat_TcpExt_SyncookiesSent 0',
				'node_netstat_IpExt_InOctets 810852736',
				'node_netstat_MPTcpExt_MPCapableSYNRX 0',
				'node_netstat_Ip_Forwarding 1',
				'node_netstat_Tcp_MaxConn -1',
				'node_netstat_Tcp_CurrEstab 18',
				'# HELP node_netstat_Ip6_InReceives Statistic Ip6InReceives.',
				'node_netstat_Ip6_InReceives 5536',
				'node_netstat_Icmp6_InType133 10',
				'node_netstat_Udp6_InDatagrams 201',
				'node_netstat_UdpLite6_InDatagrams 0',
			]), r.lines);
		});
	});

	it('exports every value of the three files of the caju AP', () => {
		with_collector(netstat, { fs: { data: AP } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(values_of(AP['/proc/net/netstat']) + values_of(AP['/proc/net/snmp'])
				+ snmp6_values_of(AP['/proc/net/snmp6']), length(samples(r.lines)));
		});
	});

	it('exports one file when the others cannot be read, as upstream', () => {
		with_collector(netstat, { fs: { data: { '/proc/net/netstat': ROUTER['/proc/net/netstat'], '/proc/net/snmp': null, '/proc/net/snmp6': null } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(values_of(ROUTER['/proc/net/netstat']), length(samples(r.lines)));
		});
	});

	it('exports /proc/net/snmp6 alone, by protocol, and leaves out lines of no protocol or without a value', () => {
		let snmp6 = 'Ip6InReceives 7\nIcmp6OutMsgs\t3\nUdpLite6NoPorts 2\nUdp6NoPorts 1\nifIndex 4\nIp6Lonely\n';

		with_collector(netstat, { fs: { data: { '/proc/net/netstat': null, '/proc/net/snmp': null, '/proc/net/snmp6': snmp6 } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_netstat_Ip6_InReceives Statistic Ip6InReceives.',
				'# TYPE node_netstat_Ip6_InReceives untyped',
				'node_netstat_Ip6_InReceives 7',
				'# HELP node_netstat_Icmp6_OutMsgs Statistic Icmp6OutMsgs.',
				'# TYPE node_netstat_Icmp6_OutMsgs untyped',
				'node_netstat_Icmp6_OutMsgs 3',
				'# HELP node_netstat_UdpLite6_NoPorts Statistic UdpLite6NoPorts.',
				'# TYPE node_netstat_UdpLite6_NoPorts untyped',
				'node_netstat_UdpLite6_NoPorts 2',
				'# HELP node_netstat_Udp6_NoPorts Statistic Udp6NoPorts.',
				'# TYPE node_netstat_Udp6_NoPorts untyped',
				'node_netstat_Udp6_NoPorts 1',
			], r.lines);
		});
	});

	it('fails with SOURCE_UNREADABLE when no file can be read', () => {
		with_collector(netstat, { fs: { data: { '/proc/net/netstat': null, '/proc/net/snmp': null, '/proc/net/snmp6': null } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/net/netstat, /proc/net/snmp, /proc/net/snmp6' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for sections whose lines do not match, keeping the others', () => {
		let snmp = 'Ip: Forwarding DefaultTTL\nIp: 1 64\n' +
			'Udp: InDatagrams NoPorts\nUdp: 5\n' +
			'Tcp: RtoMin\nIcmp: 200\n' +
			'Icmp: InMsgs\n';

		with_collector(netstat, { fs: { data: { '/proc/net/netstat': null, '/proc/net/snmp': snmp, '/proc/net/snmp6': null } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: '/proc/net/snmp: Udp: Tcp: Icmp:' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([ 'node_netstat_Ip_Forwarding 1', 'node_netstat_Ip_DefaultTTL 64' ], samples(r.lines));
		});
	});

	prop('exports every value of any table of sections',
		gen.array(gen.tuple(
			gen.alphanumeric({ min_len: 1, max_len: 8 }),
			gen.array(gen.tuple(gen.alphanumeric({ min_len: 1, max_len: 10 }), gen.int(-1, 1000000)), { min_len: 1, max_len: 6 })),
			{ min_len: 1, max_len: 5 }), (sections) => {
			let text = '';
			let want = {};
			let n = 0;

			for (let i, s in sections) {
				// Section and value names made unique, as the kernel's are.
				let name = `S${i}${s[0]}`;
				let names = map(s[1], (v, j) => `${v[0]}${j}`);

				text += `${name}: ${join(' ', names)}\n${name}: ${join(' ', map(s[1], (v) => v[1]))}\n`;
				for (let j, v in s[1]) {
					want[`node_netstat_${name}_${names[j]}`] = v[1];
					n++;
				}
			}

			with_collector(netstat, { fs: { data: { '/proc/net/netstat': text, '/proc/net/snmp': null, '/proc/net/snmp6': null } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(map(keys(want), (k) => `${k} ${want[k]}`)), sort(samples(r.lines)));
				assert.match(n, length(samples(r.lines)));
			});
		});
	prop('exports every line of /proc/net/snmp6 under its protocol',
		gen.array(gen.tuple(gen.oneof(gen.constant('Ip6'), gen.constant('Icmp6'), gen.constant('Udp6'), gen.constant('UdpLite6')),
			gen.alphanumeric({ min_len: 1, max_len: 10 }), gen.int(0, 1000000000)), { min_len: 1, max_len: 10 }), (rows) => {
			// Names made unique, and starting with a capital, as the kernel's are.
			let text = join('', map(rows, (r, i) => sprintf('%sX%s%d\t%d\n', r[0], r[1], i, r[2])));
			let want = map(rows, (r, i) => sprintf('node_netstat_%s_X%s%d %d', r[0], r[1], i, r[2]));

			with_collector(netstat, { fs: { data: { '/proc/net/netstat': null, '/proc/net/snmp': null, '/proc/net/snmp6': text } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(want, samples(r.lines));
			});
		});
});

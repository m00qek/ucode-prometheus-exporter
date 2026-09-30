'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as netstat from 'node_exporter.collectors.netstat';

const PATHS = [ '/proc/net/netstat', '/proc/net/snmp' ];
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

		with_collector(netstat, { fs: { data: { '/proc/net/netstat': null, '/proc/net/snmp': snmp } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_netstat_IcmpMsg_InType3 IcmpMsg InType3 from /proc/net/snmp.',
				'# TYPE node_netstat_IcmpMsg_InType3 gauge',
				'node_netstat_IcmpMsg_InType3 1201',
				'# HELP node_netstat_IcmpMsg_InType8 IcmpMsg InType8 from /proc/net/snmp.',
				'# TYPE node_netstat_IcmpMsg_InType8 gauge',
				'node_netstat_IcmpMsg_InType8 69',
				'# HELP node_netstat_IcmpMsg_OutType0 IcmpMsg OutType0 from /proc/net/snmp.',
				'# TYPE node_netstat_IcmpMsg_OutType0 gauge',
				'node_netstat_IcmpMsg_OutType0 69',
				'# HELP node_netstat_IcmpMsg_OutType3 IcmpMsg OutType3 from /proc/net/snmp.',
				'# TYPE node_netstat_IcmpMsg_OutType3 gauge',
				'node_netstat_IcmpMsg_OutType3 1629',
				'# HELP node_netstat_IcmpMsg_OutType8 IcmpMsg OutType8 from /proc/net/snmp.',
				'# TYPE node_netstat_IcmpMsg_OutType8 gauge',
				'node_netstat_IcmpMsg_OutType8 1',
				'# HELP node_netstat_Udp_InDatagrams Udp InDatagrams from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_InDatagrams gauge',
				'node_netstat_Udp_InDatagrams 42597',
				'# HELP node_netstat_Udp_NoPorts Udp NoPorts from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_NoPorts gauge',
				'node_netstat_Udp_NoPorts 81',
				'# HELP node_netstat_Udp_InErrors Udp InErrors from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_InErrors gauge',
				'node_netstat_Udp_InErrors 0',
				'# HELP node_netstat_Udp_OutDatagrams Udp OutDatagrams from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_OutDatagrams gauge',
				'node_netstat_Udp_OutDatagrams 11803',
				'# HELP node_netstat_Udp_RcvbufErrors Udp RcvbufErrors from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_RcvbufErrors gauge',
				'node_netstat_Udp_RcvbufErrors 0',
				'# HELP node_netstat_Udp_SndbufErrors Udp SndbufErrors from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_SndbufErrors gauge',
				'node_netstat_Udp_SndbufErrors 0',
				'# HELP node_netstat_Udp_InCsumErrors Udp InCsumErrors from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_InCsumErrors gauge',
				'node_netstat_Udp_InCsumErrors 0',
				'# HELP node_netstat_Udp_IgnoredMulti Udp IgnoredMulti from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_IgnoredMulti gauge',
				'node_netstat_Udp_IgnoredMulti 9',
				'# HELP node_netstat_Udp_MemErrors Udp MemErrors from /proc/net/snmp.',
				'# TYPE node_netstat_Udp_MemErrors gauge',
				'node_netstat_Udp_MemErrors 0',
			], r.lines);
		});
	});

	it('exports every value of both files of the caju router', () => {
		with_collector(netstat, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(values_of(ROUTER['/proc/net/netstat']) + values_of(ROUTER['/proc/net/snmp']),
				length(samples(r.lines)));
			assert.match(contains([
				'node_netstat_TcpExt_SyncookiesSent 0',
				'node_netstat_IpExt_InOctets 810852736',
				'node_netstat_MPTcpExt_MPCapableSYNRX 0',
				'node_netstat_Ip_Forwarding 1',
				'node_netstat_Tcp_MaxConn -1',
				'node_netstat_Tcp_CurrEstab 18',
			]), r.lines);
		});
	});

	it('exports every value of both files of the caju AP', () => {
		with_collector(netstat, { fs: { data: AP } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(values_of(AP['/proc/net/netstat']) + values_of(AP['/proc/net/snmp']),
				length(samples(r.lines)));
		});
	});

	it('exports one file when the other cannot be read, as upstream', () => {
		with_collector(netstat, { fs: { data: { '/proc/net/netstat': ROUTER['/proc/net/netstat'], '/proc/net/snmp': null } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(values_of(ROUTER['/proc/net/netstat']), length(samples(r.lines)));
		});
	});

	it('fails with SOURCE_UNREADABLE when neither file can be read', () => {
		with_collector(netstat, { fs: { data: { '/proc/net/netstat': null, '/proc/net/snmp': null } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for sections whose lines do not match, keeping the others', () => {
		let snmp = 'Ip: Forwarding DefaultTTL\nIp: 1 64\n' +
			'Udp: InDatagrams NoPorts\nUdp: 5\n' +
			'Tcp: RtoMin\nIcmp: 200\n' +
			'Icmp: InMsgs\n';

		with_collector(netstat, { fs: { data: { '/proc/net/netstat': null, '/proc/net/snmp': snmp } } }, (r) => {
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

			with_collector(netstat, { fs: { data: { '/proc/net/netstat': text, '/proc/net/snmp': null } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(map(keys(want), (k) => `${k} ${want[k]}`)), sort(samples(r.lines)));
				assert.match(n, length(samples(r.lines)));
			});
		});
});

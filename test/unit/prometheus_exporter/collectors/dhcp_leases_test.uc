'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, jail_of, outcome } from 'context';
import { rc } from 'lib.rc';
import * as Result from 'prometheus_exporter.result';
import * as fixtures from 'lib.fixtures';
import * as dhcp_leases from 'prometheus_exporter.collectors.dhcp_leases';

const LEASEFILE = dhcp_leases.DEFAULT_LEASEFILE;

// caju-router runs dnsmasq for DHCPv4 and odhcpd-ipv6only with DHCPv6 off
// everywhere: its lease file, with fake MACs and names, and netifd's dump.
const ROUTER_LEASES = fixtures.file('caju-router', LEASEFILE);
const ROUTER_DUMP = fixtures.ubus('caju-router', 'network.interface', 'dump');
const ROUTER_V6 = fixtures.ubus('caju-router', 'dhcp', 'ipv6leases');
const ROUTER_DHCP = json(fixtures.file('caju-router', '/uci/dhcp.json'));
const AP_DUMP = fixtures.ubus('caju-ap', 'network.interface', 'dump');

// odhcpd serving both families, and a dnsmasq lease file with DHCPv6, on the
// synthetic dump's lan.
const SYNTHETIC_DUMP = fixtures.ubus('synthetic', 'network.interface', 'dump');
const SYNTHETIC_V4 = fixtures.ubus('synthetic', 'dhcp', 'ipv4leases');
const SYNTHETIC_V6 = fixtures.ubus('synthetic', 'dhcp', 'ipv6leases');
const SYNTHETIC_LEASES = fixtures.file('synthetic', LEASEFILE);

// What ucode's ubus reports for odhcpd-ipv6only's missing method, as on the caju router.
const METHOD_NOT_FOUND = "Method not found: Failed to invoke function 'ipv4leases' on object 'dhcp'";

// When the router's leases were captured: they all expire later.
const NOW = 1790818630;

const DNSMASQ_ONLY = { cfg01411c: { '.type': 'dnsmasq' } };

function router(options) {
	return {
		ubus: {
			data: { 'network.interface:dump': ROUTER_DUMP, 'dhcp:ipv6leases': ROUTER_V6 },
			errors: { 'dhcp:ipv4leases': METHOD_NOT_FOUND },
		},
		uci: { data: { dhcp: ROUTER_DHCP } },
		fs: { data: { [LEASEFILE]: ROUTER_LEASES } },
		time: NOW,
		options,
	};
}

function synthetic(options) {
	return {
		ubus: {
			data: {
				'network.interface:dump': SYNTHETIC_DUMP,
				'dhcp:ipv4leases': SYNTHETIC_V4,
				'dhcp:ipv6leases': SYNTHETIC_V6,
			},
		},
		uci: { data: { dhcp: DNSMASQ_ONLY } },
		fs: { data: { [LEASEFILE]: SYNTHETIC_LEASES } },
		time: NOW,
		options,
	};
}

// dnsmasq alone, with this lease file, on the caju router's interfaces: odhcpd
// is disabled.
function dnsmasq(text, dhcp) {
	return {
		ubus: { data: { 'network.interface:dump': ROUTER_DUMP, ...rc({ dnsmasq: true, odhcpd: false }) } },
		uci: { data: { dhcp: dhcp ?? DNSMASQ_ONLY } },
		fs: { data: { [LEASEFILE]: text } },
		time: NOW,
	};
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function of(lines, name) {
	return filter(lines, (l) => index(l, name + '{') == 0);
}

describe('collectors.dhcp_leases', () => {
	it("counts the caju router's dnsmasq leases on each of its VLANs", () => {
		with_collector(dhcp_leases, router(), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_openwrt_dhcp_leases Active DHCP leases, by server, interface and family.',
				'# TYPE node_openwrt_dhcp_leases gauge',
				'node_openwrt_dhcp_leases{server="dnsmasq",interface="main",family="ipv4"} 4',
				'node_openwrt_dhcp_leases{server="dnsmasq",interface="guest",family="ipv4"} 1',
				'node_openwrt_dhcp_leases{server="dnsmasq",interface="iot",family="ipv4"} 2',
			], r.lines);
		});
	});

	it("exports each of the caju router's leases with the leases option", () => {
		with_collector(dhcp_leases, router({ leases: '1' }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_openwrt_dhcp_lease_info An active DHCP lease: its address, client and hostname.',
				'# TYPE node_openwrt_dhcp_lease_info gauge',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="main",family="ipv4",address="192.168.13.130",mac="02:00:00:00:00:13",hostname="laptop"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="main",family="ipv4",address="192.168.13.155",mac="02:00:00:00:00:14",hostname="phone-c"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="main",family="ipv4",address="192.168.13.113",mac="02:00:00:00:00:15",hostname="desktop"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="guest",family="ipv4",address="172.16.1.167",mac="02:00:00:00:00:16",hostname="watch"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="main",family="ipv4",address="192.168.13.116",mac="02:00:00:00:00:17",hostname="phone-d"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="iot",family="ipv4",address="192.168.17.70",mac="02:00:00:00:00:06",hostname="display"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="iot",family="ipv4",address="192.168.17.152",mac="02:00:00:00:00:18"} 1',
				'# HELP node_openwrt_dhcp_lease_expiry_timestamp_seconds When an active DHCP lease expires, unless it never does.',
				'# TYPE node_openwrt_dhcp_lease_expiry_timestamp_seconds gauge',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="main",family="ipv4",address="192.168.13.130"} 1790861559',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="main",family="ipv4",address="192.168.13.155"} 1790860618',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="main",family="ipv4",address="192.168.13.113"} 1790860499',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="guest",family="ipv4",address="172.16.1.167"} 1790859808',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="main",family="ipv4",address="192.168.13.116"} 1790859277',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="iot",family="ipv4",address="192.168.17.70"} 1790859246',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="iot",family="ipv4",address="192.168.17.152"} 1790859222',
			], slice(r.lines, 5));
		});
	});

	it('counts the leases of dnsmasq and odhcpd, of both families, with 0 where odhcpd serves none', () => {
		with_collector(dhcp_leases, synthetic(), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_openwrt_dhcp_leases{server="dnsmasq",interface="lan",family="ipv4"} 2',
				'node_openwrt_dhcp_leases{server="dnsmasq",family="ipv4"} 1',
				'node_openwrt_dhcp_leases{server="dnsmasq",interface="lan",family="ipv6"} 2',
				'node_openwrt_dhcp_leases{server="odhcpd",interface="lan",family="ipv4"} 2',
				'node_openwrt_dhcp_leases{server="odhcpd",family="ipv4"} 0',
				'node_openwrt_dhcp_leases{server="odhcpd",interface="lan",family="ipv6"} 2',
			], samples(r.lines));
		});
	});

	it('exports a series per address and delegated prefix of each lease, and no expiry for those that never expire', () => {
		with_collector(dhcp_leases, synthetic({ leases: '1' }), (r) => {
			assert.match([
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="lan",family="ipv4",address="192.168.1.101",mac="02:00:00:00:00:31",hostname="tablet"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="lan",family="ipv4",address="192.168.1.102",mac="02:00:00:00:00:32",hostname="nas"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",family="ipv4",address="10.99.0.5",mac="02:00:00:00:00:34",hostname="roamer"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="lan",family="ipv6",address="2001:db8:1:10::abcd",duid="000100012f3c4d5e020000000035",iaid="305419896",hostname="laptop-3"} 1',
				'node_openwrt_dhcp_lease_info{server="dnsmasq",interface="lan",family="ipv6",address="fd00:5:6:10::42",iaid="T42"} 1',
				'node_openwrt_dhcp_lease_info{server="odhcpd",interface="lan",family="ipv4",address="192.168.1.50",mac="02:00:00:00:00:21",hostname="printer"} 1',
				'node_openwrt_dhcp_lease_info{server="odhcpd",interface="lan",family="ipv4",address="192.168.1.10",mac="02:00:00:00:00:22",duid="00040102030405060708090a0b0c0d0e0f10",iaid="1"} 1',
				'node_openwrt_dhcp_lease_info{server="odhcpd",interface="lan",family="ipv6",address="2001:db8:1:10::1234",duid="000100012f3c4d5e020000000023",iaid="287454020",hostname="laptop-2"} 1',
				'node_openwrt_dhcp_lease_info{server="odhcpd",interface="lan",family="ipv6",address="fd00:5:6:10::1234",duid="000100012f3c4d5e020000000023",iaid="287454020",hostname="laptop-2"} 1',
				'node_openwrt_dhcp_lease_info{server="odhcpd",interface="lan",family="ipv6",address="2001:db8:1:1c::/62",duid="00030001020000000024",iaid="1"} 1',
			], of(r.lines, 'node_openwrt_dhcp_lease_info'));
			assert.match([
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="lan",family="ipv4",address="192.168.1.101"} 1790900000',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",family="ipv4",address="10.99.0.5"} 1790900000',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="lan",family="ipv6",address="2001:db8:1:10::abcd"} 1790900000',
				'node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="dnsmasq",interface="lan",family="ipv6",address="fd00:5:6:10::42"} 1790900000',
				`node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="odhcpd",interface="lan",family="ipv4",address="192.168.1.50"} ${NOW + 41000}`,
				`node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="odhcpd",interface="lan",family="ipv6",address="2001:db8:1:10::1234"} ${NOW + 7190}`,
				`node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="odhcpd",interface="lan",family="ipv6",address="fd00:5:6:10::1234"} ${NOW + 7190}`,
				`node_openwrt_dhcp_lease_expiry_timestamp_seconds{server="odhcpd",interface="lan",family="ipv6",address="2001:db8:1:1c::/62"} ${NOW + 7190}`,
			], of(r.lines, 'node_openwrt_dhcp_lease_expiry_timestamp_seconds'));
		});
	});

	it("reads the lease file /etc/config/dhcp names, each once, and dnsmasq's default for an instance without one", () => {
		let dhcp = {
			a: { '.type': 'dnsmasq', leasefile: '/tmp/a.leases' },
			b: { '.type': 'dnsmasq' },
			c: { '.type': 'dnsmasq', leasefile: '/tmp/a.leases' },
		};
		let cfg = dnsmasq(`${NOW + 60} 02:00:00:00:00:41 192.168.13.200 x *\n`, dhcp);
		cfg.fs.data['/tmp/a.leases'] = `${NOW + 60} 02:00:00:00:00:42 192.168.13.201 y *\n${NOW + 60} 02:00:00:00:00:43 192.168.11.50 z *\n`;

		with_collector(dhcp_leases, cfg, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_openwrt_dhcp_leases{server="dnsmasq",interface="main",family="ipv4"} 2',
				'node_openwrt_dhcp_leases{server="dnsmasq",interface="mgmt",family="ipv4"} 1',
			], samples(r.lines));
		});
	});

	it('succeeds with nothing to say for a dnsmasq without leases', () => {
		with_collector(dhcp_leases, dnsmasq(''), (r) => assert.match([ true, [] ], [ r.result.ok, r.lines ]));
	});

	it('counts odhcpd alone where dnsmasq is disabled', () => {
		let cfg = synthetic();
		cfg.fs.data[LEASEFILE] = null;
		cfg.ubus.data = { ...cfg.ubus.data, ...rc({ dnsmasq: false, odhcpd: true }) };

		with_collector(dhcp_leases, cfg, (r) => {
			assert.match([ true, null ], [ r.result.ok, r.result.none ]);
			assert.match([ 'odhcpd' ], uniq(map(samples(r.lines), (l) => match(l, /server="([a-z]+)"/)[1])));
		});
	});

	it('counts odhcpd and fails where dnsmasq is enabled and has no lease file, as when it does not run', () => {
		let cfg = synthetic();
		cfg.fs.data[LEASEFILE] = null;
		cfg.ubus.data = { ...cfg.ubus.data, ...rc({ dnsmasq: true, odhcpd: true }) };

		with_collector(dhcp_leases, cfg, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: `dnsmasq is enabled, without its lease file (${LEASEFILE})` },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([ 'odhcpd' ], uniq(map(samples(r.lines), (l) => match(l, /server="([a-z]+)"/)[1])));
		});
	});

	it('counts dnsmasq and fails where odhcpd is enabled and not on ubus', () => {
		let cfg = dnsmasq(ROUTER_LEASES);
		cfg.ubus.data = { ...cfg.ubus.data, ...rc({ dnsmasq: true, odhcpd: true }) };

		with_collector(dhcp_leases, cfg, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: 'odhcpd is enabled, and not on ubus (dhcp)' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([ 'dnsmasq' ], uniq(map(samples(r.lines), (l) => match(l, /server="([a-z]+)"/)[1])));
		});
	});

	// The caju AP has /etc/config/dhcp's dnsmasq section, but runs neither
	// dnsmasq nor odhcpd, as an AP that serves no DHCP has them disabled.
	function ap(scripts) {
		return {
			ubus: { data: { 'network.interface:dump': AP_DUMP, ...rc(scripts) } },
			uci: { data: { dhcp: { cfg01411c: { '.type': 'dnsmasq', leasefile: LEASEFILE } } } },
			fs: { data: { [LEASEFILE]: null } },
		};
	}

	it('has nothing to observe where dnsmasq and odhcpd are both disabled, or not installed, as on the caju AP', () => {
		with_collector(dhcp_leases, ap({ dnsmasq: false, odhcpd: false }), (r) => {
			assert.match({ ok: true, none: 'dnsmasq is disabled, odhcpd is disabled', error: null, lines: [], logs: [] }, outcome(r));
		});
		with_collector(dhcp_leases, ap({ dnsmasq: false }), (r) => {
			assert.match({ ok: true, none: 'dnsmasq is disabled, odhcpd is not installed', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('fails where either is enabled and neither is there', () => {
		for (let scripts in [ { dnsmasq: true, odhcpd: false }, { dnsmasq: false, odhcpd: true }, { dnsmasq: true, odhcpd: true } ])
			with_collector(dhcp_leases, ap(scripts), (r) => {
				assert.match({ ok: false, error: 'SOURCE_UNREADABLE', lines: [] }, { ok: r.result.ok, error: r.result.error, lines: r.lines }, scripts);
			});
	});

	it('has nothing to observe without a dnsmasq instance in /etc/config/dhcp, and odhcpd disabled', () => {
		with_collector(dhcp_leases, { ubus: { data: { 'network.interface:dump': AP_DUMP, ...rc({ dnsmasq: true, odhcpd: false }) } } }, (r) => {
			assert.match({ ok: true, none: 'dnsmasq has no instance, odhcpd is disabled', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('fails without a dnsmasq instance and odhcpd enabled and not on ubus', () => {
		with_collector(dhcp_leases, { ubus: { data: { 'network.interface:dump': AP_DUMP, ...rc({ odhcpd: true }) } } }, (r) => {
			assert.match('SOURCE_UNREADABLE', r.result.error);
		});
	});

	prop('observes each server that is there, and fails for one enabled that is not',
		gen.tuple(gen.elements('running', 'enabled', 'disabled'), gen.elements('running', 'enabled', 'disabled')), (p) => {
			let cfg = synthetic();
			if (p[0] != 'running')
				cfg.fs.data[LEASEFILE] = null;
			if (p[1] != 'running') {
				delete cfg.ubus.data['dhcp:ipv4leases'];
				delete cfg.ubus.data['dhcp:ipv6leases'];
			}
			cfg.ubus.data = { ...cfg.ubus.data, ...rc({ dnsmasq: p[0] != 'disabled', odhcpd: p[1] != 'disabled' }) };

			with_collector(dhcp_leases, cfg, (r) => {
				let servers = uniq(map(samples(r.lines), (l) => match(l, /server="([a-z]+)"/)[1]));

				assert.match(!('enabled' in p), r.result.ok, p);
				assert.match(p[0] == 'disabled' && p[1] == 'disabled', Result.is_none(r.result), p);
				assert.match(filter([ p[0] == 'running' ? 'dnsmasq' : null, p[1] == 'running' ? 'odhcpd' : null ], (s) => s), sort(servers), p);
			});
		});

	it('passes on a failed dump of the interfaces', () => {
		let cfg = dnsmasq(ROUTER_LEASES);
		cfg.ubus = { errors: { 'network.interface:dump': "Not found: Failed to resolve object name 'network.interface'" } };

		with_collector(dhcp_leases, cfg, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	it('passes on a failed odhcpd call other than a missing method', () => {
		let cfg = router();
		cfg.ubus.errors['dhcp:ipv6leases'] = 'Request timed out';

		with_collector(dhcp_leases, cfg, (r) => {
			assert.match({ error: 'UBUS_CALL_FAILED', details: 'dhcp ipv6leases: Request timed out' },
				{ error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for an odhcpd reply without its device table or lease lists', () => {
		let cases = [
			[ {}, 'dhcp ipv6leases: no device table' ],
			[ { device: { 'br-lan': {} } }, 'dhcp ipv6leases: br-lan: no lease list' ],
		];

		for (let c in cases) {
			let cfg = router();
			cfg.ubus.data['dhcp:ipv6leases'] = c[0];

			with_collector(dhcp_leases, cfg, (r) => {
				assert.match({ error: 'SOURCE_INVALID', details: c[1] }, { error: r.result.error, details: r.result.details });
			});
		}
	});

	it('fails with SOURCE_INVALID for a malformed lease file', () => {
		let cases = [
			[ '1790900000 02:00:00:00:00:01 192.168.13.5 host\n', 'line 1: 4 fields, not 5' ],
			[ '\n1790900000 02:00:00:00:00:01 192.168.13.300 host *\n', 'line 2: "192.168.13.300" is not an address' ],
		];

		for (let c in cases)
			with_collector(dhcp_leases, dnsmasq(c[0]), (r) => {
				assert.match({ error: 'SOURCE_INVALID', details: `${LEASEFILE}: ${c[1]}` }, { error: r.result.error, details: r.result.details });
				assert.match([], r.lines);
			});
	});

	prop('compares the first bits of two addresses',
		gen.tuple(gen.array(gen.int(0, 255), { len: 16 }), gen.int(0, 128), gen.int(0, 127)), (t) => {
			let addr = t[0], bits = t[1], flip = t[2];
			let other = [ ...addr ];
			other[flip >> 3] ^= 0x80 >> (flip & 7);

			assert.match(true, dhcp_leases.in_prefix(addr, addr, bits));
			assert.match(flip >= bits, dhcp_leases.in_prefix(other, addr, bits));
			assert.match(false, dhcp_leases.in_prefix(slice(addr, 0, 4), addr, 0));
		});

	// interface_of() keeps the subnets sorted, and IPv4 ones as numbers, for
	// speed: it must pick what a look at every subnet in the dump's order
	// picks, the first of the most specific that hold the address.
	prop('finds the interface of the most specific subnet that holds an address',
		gen.tuple(
			gen.array(gen.tuple(gen.elements('a', 'b', 'c'), gen.elements('10.1.0.0', '10.1.2.0', '10.0.0.0', 'fd00::', 'fd00:0:0:1::'),
				gen.int(-2, 130)), { max_len: 8 }),
			gen.elements('10.1.2.3', '10.1.3.4', '10.9.9.9', '192.168.1.1', 'fd00::1', 'fd00:0:0:1::5', '2001:db8::1')), (t) => {
			let list = map(t[0], (s) => ({
				interface: s[0],
				[index(s[1], ':') >= 0 ? 'ipv6-address' : 'ipv4-address']: [ { address: s[1], mask: s[2] } ],
			}));
			let bytes = iptoarr(t[1]);
			let best = null;

			for (let s in t[0])
				if (s[2] > (best?.[2] ?? -1) && dhcp_leases.in_prefix(bytes, iptoarr(s[1]), s[2]))
					best = s;

			assert.match(best?.[0], dhcp_leases.interface_of(dhcp_leases.networks(list), bytes), sprintf('%J', t));
		});

	prop('counts the unexpired leases of a lease file on each interface',
		gen.array(gen.tuple(gen.elements([ 'main', 13 ], [ 'iot', 17 ], [ 'mgmt', 11 ]), gen.int(2, 254), gen.elements('expired', 'active', 'infinite')),
			{ max_len: 40 }), (rows) => {
			let text = '';
			let want = {};
			let order = [];
			let seen = {};

			for (let i, row in rows) {
				let address = `192.168.${row[0][1]}.${row[1]}`;
				if (seen[address])
					continue;
				seen[address] = true;

				let expiry = { expired: NOW - 1 - i, active: NOW + 1 + i, infinite: 0 }[row[2]];
				text += sprintf('%d 02:00:00:00:%02x:%02x %s host-%d *\n', expiry, i >> 8, i & 0xff, address, i);

				if (row[2] == 'expired')
					continue;
				if (!(row[0][0] in order))
					push(order, row[0][0]);
				want[row[0][0]] = (want[row[0][0]] ?? 0) + 1;
			}

			with_collector(dhcp_leases, dnsmasq(text), (r) => {
				assert.match(true, r.result.ok);
				assert.match(map(order, (name) => `node_openwrt_dhcp_leases{server="dnsmasq",interface="${name}",family="ipv4"} ${want[name]}`),
					samples(r.lines));
			});
		});
});

describe('dhcp_leases in the jail', () => {
	it('gets /etc/config/dhcp and the lease file of each dnsmasq instance', () => {
		let two = { a: { '.type': 'dnsmasq' }, b: { '.type': 'dnsmasq', leasefile: '/tmp/guest.leases' }, c: { '.type': 'dnsmasq', leasefile: '' } };

		assert.match([ '/etc/config/dhcp', LEASEFILE ], jail_of(dhcp_leases, router()).mounts);
		assert.match([ '/etc/config/dhcp', LEASEFILE, '/tmp/guest.leases' ], jail_of(dhcp_leases, { uci: { data: { dhcp: two } } }).mounts);
	});

	it('gets no lease file without a dnsmasq instance', () => {
		assert.match([ '/etc/config/dhcp' ], jail_of(dhcp_leases, { uci: { data: { dhcp: {} } } }).mounts);
	});
});

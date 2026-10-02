'use strict';

// Writes the benchmark's worlds: what a router's /proc, /sys, ubus, netlink and
// programs would give the collectors, at the sizes of a profile (PROFILES),
// from a seeded generator, so every run of every machine reads the same input.
// The real devices' fixtures (test/fixtures/) are the templates: the kernel's
// table layouts and field names, a station's and a lease's shape; the
// generator multiplies them and varies the values.
//
//   ucode -L src -L test test/bench/gen.uc OUTDIR [PROFILE...]
//
// OUTDIR/<profile>/root/       files at their paths: /proc, /sys, /etc/config, /tmp, /var
// OUTDIR/<profile>/conntrack/N conntrack tables of N entries, for the scaling cases
// OUTDIR/<profile>/commands/   what the programs print (nft, ethtool)
// OUTDIR/<profile>/world.json  { profile, sizes, commands }
// OUTDIR/<profile>/<source>.json what ubus, nl80211 and rtnl answer, a file each
//
// bench.world reads a world back as the modules deps.session() takes.

import { readfile, writefile, mkdir, symlink, stat } from 'fs';

const FIXTURES = 'test/fixtures';

// Sizes. `typical` is a home router with an access point on it; `large` a busy
// one: 50 links, a 20k-entry conntrack table, 200 stations, 1000 leases, and
// a NAS's disks.
const PROFILES = {
	typical: {
		cpus: 4, links: 12, conntrack: 300, conntrack_scaling: [],
		radios: 2, ifaces_per_radio: 2, stations: 20,
		leases: 40, odhcpd_leases: 10, hosts: 10, interfaces: 6,
		peers: 3, counters: 20, textfile_samples: 20, hwmon: 2, thermal: 2, ntp_sources: 4, disks: 1,
	},
	large: {
		cpus: 4, links: 50, conntrack: 20000, conntrack_scaling: [ 1000, 10000, 20000 ],
		radios: 3, ifaces_per_radio: 3, stations: 200,
		leases: 1000, odhcpd_leases: 200, hosts: 200, interfaces: 20,
		peers: 30, counters: 100, textfile_samples: 500, hwmon: 4, thermal: 4, ntp_sources: 12, disks: 4,
	},
};

// A linear congruential generator: the same numbers on every machine.
function rng(seed) {
	let state = seed;

	return function(n) {
		state = (state * 1103515245 + 12345) % 2147483648;
		return n ? state % n : state;
	};
}

// [ fn(0), fn(1), ... fn(n - 1) ]
function times(n, fn) {
	let out = [];

	for (let i = 0; i < n; i++)
		push(out, fn(i));

	return out;
}

function fixture(path) {
	let s = readfile(`${FIXTURES}/${path}`);

	if (s == null)
		die(`no fixture ${path}`);

	return s;
}

function fixture_json(path) {
	return json(fixture(path));
}

function mkdir_p(path) {
	let at = '';

	for (let part in split(path, '/')) {
		if (part == '')
			continue;
		at += '/' + part;
		if (!stat(at))
			mkdir(at);
	}
}

function dirname(path) {
	let parts = split(path, '/');
	pop(parts);
	return join('/', parts);
}

function put(root, path, content) {
	mkdir_p(dirname(root + path));
	if (!writefile(root + path, content))
		die(`cannot write ${root}${path}`);
}

function mac(i) {
	return sprintf('02:00:00:%02x:%02x:%02x', (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff);
}

// ---- links -----------------------------------------------------------------

const LINK_NAMES = [
	'lo', 'eth0', 'eth1', 'lan1', 'lan2', 'lan3', 'lan4', 'wan', 'br-lan', 'br-guest',
	'br-iot', 'pppoe-wan', 'wg0', 'ifb4wan',
];

// Hardware-backed links have a device in sysfs (ethtool reads their driver).
function is_hardware(name) {
	return match(name, /^(eth|lan|wan$|phy)/) != null;
}

function link_names(p) {
	let names = [];

	for (let r = 0; r < p.radios; r++)
		for (let i = 0; i < p.ifaces_per_radio; i++)
			push(names, `phy${r}-ap${i}`);

	names = [ ...slice(LINK_NAMES, 0, p.links - length(names)), ...names ];
	for (let v = 1; length(names) < p.links; v++)
		push(names, `vlan${v}`);

	return names;
}

function links(p, rand) {
	let template = fixture_json('caju-ap/rtnl/RTM_GETLINK.json')[2];
	let out = [];

	for (let i, name in link_names(p)) {
		let l = json(sprintf('%J', template));
		let up = name != 'wg0' && i % 7 != 6;

		l.dev = l.ifname = name;
		l.address = name == 'lo' ? '00:00:00:00:00:00' : mac(0x100 + i);
		l.flags = up ? 4099 : 4098;
		l.operstate = up ? 6 : 2;
		l.carrier = up;
		l.mtu = name == 'pppoe-wan' ? 1492 : 1500;
		l.group = 0;
		delete l.master;
		delete l.link;
		delete l.linkinfo;

		for (let k in keys(l.stats64))
			l.stats64[k] = rand(1000000000);

		push(out, l);
	}

	return out;
}

function sysfs_link(root, l, i, rand) {
	let dir = `/sys/class/net/${l.dev}`;
	let attrs = {
		addr_assign_type: '0', address: l.address, broadcast: 'ff:ff:ff:ff:ff:ff',
		carrier_changes: '' + rand(100), carrier_down_count: '' + rand(50), carrier_up_count: '' + rand(50),
		dev_id: '0x0', dormant: '0', flags: sprintf('0x%x', l.flags & 0xffff), ifalias: '',
		ifindex: '' + (i + 1), iflink: '' + (i + 1), link_mode: '0', mtu: '' + l.mtu,
		name_assign_type: '4', netdev_group: '0', operstate: l.operstate == 6 ? 'up' : 'down',
		tx_queue_len: '1000', type: l.dev == 'lo' ? '772' : '1',
	};

	if (l.operstate == 6)
		attrs.carrier = '1';
	if (is_hardware(l.dev)) {
		attrs.duplex = 'full';
		attrs.speed = l.operstate == 6 ? '1000' : '-1';
	}

	for (let name, v in attrs)
		put(root, `${dir}/${name}`, v + '\n');

	if (is_hardware(l.dev)) {
		let dev = `/sys/devices/platform/soc/1510000${i % 10}.ethernet/${l.dev}`;
		mkdir_p(root + dev);
		symlink(`../../../devices/platform/soc/1510000${i % 10}.ethernet/${l.dev}`, `${root}${dir}/device`);
	}
}

// ---- /proc -------------------------------------------------------------------

function proc_stat(p, rand) {
	let lines = [ 'cpu  ' + join(' ', times(10, () => rand(10000000))) ];

	for (let c = 0; c < p.cpus; c++)
		push(lines, `cpu${c} ` + join(' ', times(10, () => rand(1000000))));

	push(lines, 'intr ' + join(' ', times(64, () => rand(100000))),
		`ctxt ${rand(100000000)}`, 'btime 1790800000', `processes ${rand(100000)}`,
		'procs_running 1', 'procs_blocked 0', 'softirq 1 2 3 4 5 6 7 8 9 10 11');

	return join('\n', lines) + '\n';
}

function hex_rows(n, columns, rand, last) {
	let rows = [];

	for (let r = 0; r < n; r++)
		push(rows, join(' ', times(columns, (j) => sprintf('%08x', (last != null && j == columns - 1) ? last(r) : rand(65536)))));

	return rows;
}

// A table whose values follow the template's names: each value from the
// generator, so no two worlds' numbers are the fixture's.
function revalue(text, rand) {
	return replace(text, /([ \t:])[0-9]+( |\t|\n)/g, (m, a, b) => a + rand(100000000) + b);
}

function conntrack_table(n, seed) {
	let rand = rng(seed);
	let lines = [];
	let clients = 64;

	for (let i = 0; i < n; i++) {
		let v6 = i % 5 == 4;
		let src = v6 ? sprintf('2001:0db8:0000:0001:0000:0000:0000:%04x', rand(clients) + 1) : sprintf('192.168.1.%d', rand(clients) + 2);
		let dst = v6 ? sprintf('2001:0db8:0000:%04x:0000:0000:0000:0001', rand(4096)) : sprintf('198.51.%d.%d', rand(256), rand(254) + 1);
		let sport = 1024 + rand(60000), dport = [ 443, 80, 53, 123, 5223 ][rand(5)];
		let acct = `packets=${rand(10000)} bytes=${rand(10000000)}`;
		let reply = `packets=${rand(10000)} bytes=${rand(100000000)}`;
		let family = v6 ? 'ipv6     10' : 'ipv4     2';
		let wan = v6 ? '2001:0db8:0000:0002:0000:0000:0000:0001' : '100.64.0.1';

		if (rand(3) == 0)
			push(lines, `${family} udp      17 ${rand(180)} src=${src} dst=${dst} sport=${sport} dport=${dport} ${acct} ` +
				`src=${dst} dst=${wan} sport=${dport} dport=${sport} ${reply} [ASSURED] mark=0 zone=0 use=2`);
		else
			push(lines, `${family} tcp      6 ${rand(432000)} ESTABLISHED src=${src} dst=${dst} sport=${sport} dport=${dport} ${acct} ` +
				`src=${dst} dst=${wan} sport=${dport} dport=${sport} ${reply} [ASSURED] mark=0 zone=0 use=2`);
	}

	return join('\n', lines) + '\n';
}

// ---- wireless ------------------------------------------------------------------

function wireless(p, rand, world) {
	let iface_template = fixture_json('caju-ap/ubus/network.wireless.status.json').radio_2G.interfaces[0];
	let sta_template = fixture_json('caju-ap/nl80211/NL80211_CMD_GET_STATION.phy0-ap0.json')[0];
	let client_template = fixture_json('caju-ap/ubus/hostapd.phy0-ap0.get_clients.json');
	let status_template = fixture_json('caju-ap/ubus/hostapd.phy0-ap0.get_status.json');
	let survey = fixture_json('caju-ap/nl80211/NL80211_CMD_GET_SURVEY.phy0-ap0.json');
	let first_client = client_template.clients[keys(client_template.clients)[0]];
	let n_ifaces = p.radios * p.ifaces_per_radio;
	let status = {};
	let sta = 0;

	for (let r = 0; r < p.radios; r++) {
		let freq = r == 0 ? 2462 : 5745 + 20 * r;
		let radio = { up: true, pending: false, autostart: true, disabled: false,
			config: { type: 'mac80211', band: r == 0 ? '2g' : '5g', channel: r == 0 ? '11' : '149', country: 'BR', htmode: r == 0 ? 'HE20' : 'HE80' },
			interfaces: [] };

		for (let i = 0; i < p.ifaces_per_radio; i++) {
			let ifname = `phy${r}-ap${i}`;
			let n = p.stations / n_ifaces + (r * p.ifaces_per_radio + i < p.stations % n_ifaces ? 1 : 0);
			let iface = json(sprintf('%J', iface_template));
			let ssid = `ssid-${i}`;
			let stations = [], clients = {};

			iface.ifname = ifname;
			iface.config.ssid = ssid;
			push(radio.interfaces, iface);

			world.nl80211[`NL80211_CMD_GET_INTERFACE:${ifname}`] = {
				dev: ifname, ifname, iftype: 3, mac: mac(0xa000 + r * 16 + i), ssid,
				wiphy: r, wiphy_freq: freq, wiphy_tx_power_level: 2600,
			};
			world.nl80211[`NL80211_CMD_GET_SURVEY:${ifname}`] = map(survey, (s) => ({
				dev: ifname, survey_info: { ...s.survey_info, frequency: s.survey_info.frequency == 2412 ? freq : s.survey_info.frequency },
			}));

			for (let k = 0; k < n; k++, sta++) {
				let s = json(sprintf('%J', sta_template));
				let addr = mac(0x10000 + sta);

				s.dev = ifname;
				s.mac = addr;
				s.sta_info.signal = -40 - rand(50);
				s.sta_info.rx_bytes64 = s.sta_info.rx_bytes = rand(1000000000);
				s.sta_info.tx_bytes64 = s.sta_info.tx_bytes = rand(1000000000);
				s.sta_info.connected_time = rand(100000);
				s.sta_info.inactive_time = rand(30000);
				s.sta_info.expected_throughput = rand(500000);
				push(stations, s);

				let c = json(sprintf('%J', first_client));
				c.signal = s.sta_info.signal;
				c.bytes = { rx: s.sta_info.rx_bytes, tx: s.sta_info.tx_bytes };
				c.rrm = [ rand(128), rand(4), 0, 0, rand(8) ];
				clients[addr] = c;
			}

			world.nl80211[`NL80211_CMD_GET_STATION:${ifname}`] = length(stations) ? stations : null;
			world.ubus[`hostapd.${ifname}:get_status`] = { ...status_template, bssid: mac(0xa000 + r * 16 + i), ssid, freq };
			world.ubus[`hostapd.${ifname}:get_clients`] = { freq, clients };
		}

		status[`radio${r}`] = radio;
	}

	world.ubus['network.wireless:status'] = status;
}

// ---- network, DHCP -----------------------------------------------------------

function interfaces(p) {
	let list = [];

	for (let i = 0; i < p.interfaces; i++) {
		let name = i == 0 ? 'lan' : (i == 1 ? 'wan' : (i == 2 ? 'wan6' : `net${i}`));
		let dev = i == 0 ? 'br-lan' : (i == 1 ? 'pppoe-wan' : `br-net${i}`);

		push(list, {
			interface: name, up: i % 5 != 4, pending: false, available: true, autostart: true, dynamic: false,
			uptime: 1000 + i, l3_device: dev, proto: i == 1 ? 'pppoe' : 'static', device: dev, updated: [ 'addresses' ],
			metric: 0, dns_metric: 0, delegation: true,
			'ipv4-address': [ { address: i == 1 ? '100.64.0.1' : sprintf('192.168.%d.1', i + 1), mask: 24 } ],
			'ipv6-address': [ { address: sprintf('fd00:0:0:%x::1', i + 1), mask: 64 } ],
			'ipv6-prefix': [], 'ipv6-prefix-assignment': [],
			route: [ { target: '0.0.0.0', mask: 0, nexthop: '100.64.0.254', source: '0.0.0.0/0' } ],
			'dns-server': [], 'dns-search': [], neighbors: [], inactive: {}, data: {},
		});
	}

	return { interface: list };
}

function leasefile(p, rand) {
	let lines = [];

	for (let i = 0; i < p.leases; i++) {
		let expiry = i % 10 == 9 ? 0 : 1790900000 + rand(86400);
		push(lines, sprintf('%d %s 192.168.%d.%d host-%d 01:%s', expiry, mac(0x20000 + i), 1 + (i / 250) % p.interfaces, 2 + i % 250, i, mac(0x20000 + i)));
	}

	push(lines, 'duid 00:01:00:01:2f:3c:4d:5e:02:00:00:00:00:01');
	return join('\n', lines) + '\n';
}

function odhcpd(p, rand) {
	let leases = [];

	for (let i = 0; i < p.odhcpd_leases; i++)
		push(leases, {
			duid: sprintf('000100012f3c4d5e%012x', i), iaid: i + 1, hostname: `v6-${i}`, 'accept-reconf': false,
			assigned: i, flags: [ 'bound' ], valid: 7000 + rand(200),
			'ipv6-addr': [ { address: sprintf('fd00:0:0:1::%x', 0x1000 + i), 'preferred-lifetime': 3590, 'valid-lifetime': 7190 } ],
		});

	return { device: { 'br-lan': { leases } } };
}

function uci_dhcp(p) {
	let s = "config dnsmasq\n\toption domainneeded '1'\n\toption leasefile '/tmp/dhcp.leases'\n\n";

	for (let i = 0; i < p.hosts; i++)
		s += sprintf("config host\n\toption name 'static-%d'\n\toption mac '%s'\n\toption ip '192.168.1.%d'\n\n", i, mac(0x30000 + i), 2 + i % 250);

	return s;
}

function wireguard(p, rand) {
	let peers = {};
	let sections = {};

	for (let i = 0; i < p.peers; i++) {
		let key = sprintf('%040d=', i);
		peers[key] = {
			endpoint: sprintf('198.51.100.%d:51820', i + 1), allowed_ips: [ sprintf('10.251.%d.0/24', i) ],
			last_handshake: 1790800000 + rand(1000), rx_bytes: rand(100000000), tx_bytes: rand(100000000),
			persistent_keepalive_interval: 25,
		};
		sections[sprintf('cfg%06x', i)] = { '.anonymous': true, '.type': 'wireguard_wg0', '.name': sprintf('cfg%06x', i),
			'.index': i + 2, public_key: key, description: sprintf('peer %d', i) };
	}

	// uci_get: rpcd's `uci get { config: network, type: wireguard_wg0 }`, peer_names on.
	return { status: { wg0: { ifindex: 30, public_key: sprintf('%040d=', 999), listen_port: 51820, peers } }, uci_get: { values: sections } };
}

// ---- programs ------------------------------------------------------------------

function nft_counters(p, rand) {
	let list = [ { metainfo: { version: '1.1.6', json_schema_version: 1 } } ];

	for (let i = 0; i < p.counters; i++)
		push(list, { counter: { family: 'inet', name: `cnt_${i}`, table: 'fw4', handle: i + 1, packets: rand(1000000), bytes: rand(1000000000) } });

	return sprintf('%J\n', { nftables: list });
}

// The statistics of a Synopsys DesignWare MAC (stmmac, as on the NanoPi R3S
// and many Rockchip and MediaTek boards): about 250 names, from the driver's
// own patterns (stmmac_ethtool.c): MMC counters per direction, the DMA's
// and MTL's, and per queue.
function dwmac_names() {
	let names = [];
	let mmc = [ 'octetcount_gb', 'framecount_gb', 'broadcastframe_g', 'multicastframe_g', '64_octets_gb',
		'65_to_127_octets_gb', '128_to_255_octets_gb', '256_to_511_octets_gb', '512_to_1023_octets_gb',
		'1024_to_max_octets_gb', 'unicast_gb', 'multicast_gb', 'broadcast_gb', 'underflow_error', 'octetcount_g',
		'framecount_g', 'pause_frame', 'vlan_frame_g', 'oversize_g', 'lpi_usec', 'lpi_tran', 'crc_error',
		'align_error', 'run_error', 'jabber_error', 'undersize_g', 'length_error', 'fifo_overflow', 'watchdog_error',
		'discard_frames_gb', 'discard_octets_gb' ];
	let ip = [ 'ipv4_gd', 'ipv4_hderr', 'ipv4_nopay', 'ipv4_frag', 'ipv4_udsbl', 'ipv6_gd', 'ipv6_hderr', 'ipv6_nopay',
		'udp_gd', 'udp_err', 'tcp_gd', 'tcp_err', 'icmp_gd', 'icmp_err' ];
	let ptp = [ 'sync', 'follow_up', 'delay_req', 'delay_resp', 'pdelay_req', 'pdelay_resp', 'pdelay_follow_up',
		'announce', 'management' ];
	let plain = [ 'tx_underflow', 'tx_carrier', 'tx_losscarrier', 'vlan_tag', 'tx_deferred', 'tx_vlan', 'tx_jabber',
		'tx_frame_flushed', 'tx_payload_error', 'tx_ip_header_error', 'rx_desc', 'sa_filter_fail', 'overflow_error',
		'ipc_csum_error', 'rx_collision', 'rx_crc_errors', 'dribbling_bit', 'rx_length', 'rx_mii', 'rx_multicast',
		'rx_gmac_overflow', 'rx_watchdog', 'da_rx_filter_fail', 'sa_rx_filter_fail', 'rx_missed_cntr',
		'rx_overflow_cntr', 'rx_vlan', 'rx_split_hdr_pkt_n', 'tx_undeflow_irq', 'tx_process_stopped_irq',
		'tx_jabber_irq', 'rx_overflow_irq', 'rx_buf_unav_irq', 'rx_process_stopped_irq', 'rx_watchdog_irq',
		'tx_early_irq', 'fatal_bus_error_irq', 'rx_early_irq', 'threshold', 'irq_receive_pmt_irq_n', 'mmc_tx_irq_n',
		'mmc_rx_irq_n', 'mmc_rx_csum_offload_irq_n', 'irq_tx_path_in_lpi_mode_n', 'irq_tx_path_exit_lpi_mode_n',
		'irq_rx_path_in_lpi_mode_n', 'irq_rx_path_exit_lpi_mode_n', 'phy_eee_wakeup_error_n', 'ip_hdr_err',
		'ip_payload_err', 'ip_csum_bypassed', 'ipv4_pkt_rcvd', 'ipv6_pkt_rcvd', 'no_ptp_rx_msg_type_ext',
		'ptp_frame_type', 'ptp_ver', 'timestamp_dropped', 'av_pkt_rcvd', 'av_tagged_pkt_rcvd', 'vlan_tag_priority_val',
		'l3_filter_match', 'l4_filter_match', 'l3_l4_filter_no_match', 'irq_pcs_ane_n', 'irq_pcs_link_n', 'irq_rgmii_n',
		'mtl_tx_status_fifo_full', 'mtl_tx_fifo_not_empty', 'mmtl_fifo_ctrl', 'mac_tx_in_pause', 'mac_gmii_tx_proto_engine',
		'mtl_rx_fifo_fill_level_full', 'mtl_rx_fifo_ctrl_active', 'mac_gmii_rx_proto_engine', 'mtl_est_cgce',
		'rx_pkt_n', 'rx_normal_irq_n', 'tx_pkt_n', 'tx_normal_irq_n', 'tx_clean', 'tx_set_ic_bit', 'tx_tso_frames',
		'tx_tso_nfrags', 'normal_irq_n', 'napi_poll' ];

	for (let dir in [ 'tx', 'rx' ])
		for (let m in mmc)
			push(names, `mmc_${dir}_${m}`);
	for (let m in ip)
		push(names, `mmc_rx_${m}`, `mmc_rx_${m}_octets`);
	for (let m in ptp)
		push(names, `ptp_rx_msg_type_${m}`);
	push(names, ...plain);
	for (let q = 0; q < 8; q++)
		push(names, `q${q}_tx_pkt_n`, `q${q}_tx_irq_n`, `q${q}_rx_pkt_n`, `q${q}_rx_irq_n`);

	return names;
}

// What `ethtool -S` prints for a link: a DesignWare MAC's statistics for
// eth0 and eth1, the caju AP's mt76 radio's for a Wi-Fi interface and its
// DSA port's for the switch ports.
function ethtool(name, rand) {
	if (match(name, /^eth/))
		return 'NIC statistics:\n' + join('', map(dwmac_names(), (n) => `     ${n}: ${rand(1000000)}\n`));

	return revalue(fixture(match(name, /^phy/) ? 'caju-ap/commands/ethtool_S_phy0-ap0.txt' : 'caju-ap/commands/ethtool_S_lan.txt'), rand);
}

// What `tc -s -j qdisc show` prints for these links: SQM's CAKE on wan and
// its ifb (the caju router's, as the template), each with wan's ingress
// qdisc, mq over a fq_codel per queue on eth0, fq_codel on the other
// hardware links and noqueue on the virtual ones.
function qdiscs(links, rand) {
	let all = fixture_json('caju-router/commands/tc_s_j_qdisc_show.json');
	let cake = filter(all, (q) => q.kind == 'cake' && q.dev == 'eth1')[0];
	let fq_codel = filter(all, (q) => q.kind == 'fq_codel')[0];
	let ingress = filter(all, (q) => q.kind == 'ingress')[0];
	let noqueue = filter(all, (q) => q.kind == 'noqueue')[0];
	let out = [];

	let counted = function(template, dev, extra) {
		let q = { ...json(sprintf('%J', template)), dev, ...(extra ?? {}) };

		for (let k in [ 'bytes', 'packets', 'drops', 'overlimits', 'requeues' ])
			q[k] = rand(1000000000);
		for (let t in q.tins ?? [])
			for (let k in [ 'sent_bytes', 'sent_packets', 'drops', 'ecn_mark', 'peak_delay_us', 'avg_delay_us', 'base_delay_us' ])
				t[k] = rand(1000000);

		return q;
	};

	for (let l in links) {
		let name = l.dev;

		if (name == 'wan' || name == 'ifb4wan')
			push(out, counted(cake, name, { handle: sprintf('80%02x:', rand(256)) }));
		else if (name == 'eth0') {
			push(out, counted(fq_codel, name, { kind: 'mq', options: {} }));
			for (let i = 1; i <= 4; i++)
				push(out, counted(fq_codel, name, { root: null, parent: `:${i}` }));
		} else if (is_hardware(name))
			push(out, counted(fq_codel, name));
		else
			push(out, { ...noqueue, dev: name });

		if (name == 'wan')
			push(out, counted(ingress, name));
	}

	return sprintf('%J\n', out);
}

// What chronyc prints, as the chrony collector runs it (as root, as CSV): the
// seriguela router's tracking and server statistics, and `n` sources made
// after its first.
function chrony(dir, world, n, rand) {
	let source = split(trim(fixture('seriguela-router/commands/chronyc_c_sources.txt')), '\n')[0];
	let sources = '';

	for (let i = 0; i < n; i++) {
		let f = split(source, ',');

		f[1] = i ? '+' : '*';
		f[2] = sprintf('2001:db8::%x', 0x100 + i);
		f[6] = '' + rand(1024);
		sources += join(',', f) + '\n';
	}

	for (let r in [ [ 'tracking', fixture('seriguela-router/commands/chronyc_c_tracking.txt') ], [ 'sources', sources ],
	                [ 'serverstats', fixture('seriguela-router/commands/chronyc_c_serverstats.txt') ] ]) {
		writefile(`${dir}/commands/chronyc-${r[0]}.txt`, r[1]);
		world.commands[join(' ', map([ 'chronyc', '-u', 'root', '-c', r[0] ], (a) => `'${a}'`))] = `commands/chronyc-${r[0]}.txt`;
	}
}

// ---- block devices ---------------------------------------------------------------

// /proc/diskstats of a kernel 5.5 or later (20 fields): loop devices, flash,
// an eMMC with its partitions and boot areas (the seriguela router's layout),
// and `disks` SATA or USB disks of three partitions each; and the
// rotational files of the devices diskstats exports by default.
function diskstats(root, p, rand) {
	let lines = [];
	let line = (major, minor, name) => push(lines, sprintf('%4d %7d %s %s', major, minor, name,
		join(' ', times(17, () => rand(100000000)))));

	for (let i = 0; i < 8; i++)
		line(7, i, `loop${i}`);
	for (let i = 0; i < 8; i++)
		line(31, i, `mtdblock${i}`);
	line(179, 0, 'mmcblk0');
	line(179, 1, 'mmcblk0p1');
	line(179, 2, 'mmcblk0p2');
	line(179, 32, 'mmcblk0boot0');
	line(179, 64, 'mmcblk0boot1');
	put(root, '/sys/block/mmcblk0/queue/rotational', '0\n');

	for (let d = 0; d < p.disks; d++) {
		let name = 'sd' + chr(97 + d);

		line(8, d * 16, name);
		for (let k = 1; k <= 3; k++)
			line(8, d * 16 + k, `${name}${k}`);
		put(root, `/sys/block/${name}/queue/rotational`, `${d % 2}\n`);
	}

	put(root, '/proc/diskstats', join('\n', lines) + '\n');
}

// What hwmon reads of fans, voltages, currents and power: on each chip two
// fans and four voltages, with files it does not read beside them (as a
// Super-I/O's), and a current and power monitor's readings on every other one.
function hwmon_readings(root, p, rand) {
	for (let h = 0; h < p.hwmon; h++) {
		let d = `/sys/class/hwmon/hwmon${h}`;

		for (let f = 1; f <= 2; f++)
			for (let e in [ [ 'input', rand(3000) ], [ 'min', 300 ], [ 'alarm', rand(2) ], [ 'beep', 0 ], [ 'pulses', 2 ] ])
				put(root, `${d}/fan${f}_${e[0]}`, `${e[1]}\n`);
		for (let v = 0; v < 4; v++)
			for (let e in [ [ 'input', 1000 + rand(11000) ], [ 'min', 900 ], [ 'max', 13000 ], [ 'alarm', 0 ], [ 'beep', 0 ] ])
				put(root, `${d}/in${v}_${e[0]}`, `${e[1]}\n`);
		if (h % 2) {
			put(root, `${d}/curr1_input`, `${rand(5000)}\n`);
			put(root, `${d}/power1_input`, `${rand(60000000)}\n`);
			put(root, `${d}/shunt_resistor`, '10000\n');
		}
	}
}

// ---- the world -------------------------------------------------------------------

function generate(dir, profile) {
	let p = PROFILES[profile];
	let rand = rng(42);
	let root = `${dir}/root`;
	let world = { profile, sizes: p, ubus: {}, nl80211: {}, rtnl: {}, commands: {} };

	if (!p)
		die(`no profile ${profile}`);

	mkdir_p(root);

	// /proc
	put(root, '/proc/stat', proc_stat(p, rand));
	for (let f in [ 'meminfo', 'vmstat', 'loadavg', 'net/netstat', 'net/snmp', 'net/snmp6',
	                'sys/fs/file-nr', 'sys/kernel/random/entropy_avail', 'sys/kernel/random/poolsize',
	                'sys/kernel/arch', 'sys/kernel/domainname', 'sys/kernel/hostname', 'sys/kernel/osrelease',
	                'sys/kernel/ostype', 'sys/kernel/version' ])
		put(root, `/proc/${f}`, fixture(`caju-ap/proc/${f}`));
	put(root, '/proc/self/mounts', fixture('caju-router/proc/self/mounts'));
	put(root, '/proc/net/softnet_stat', join('\n', hex_rows(p.cpus, 13, rand, (r) => r)) + '\n');
	put(root, '/proc/sys/net/netfilter/nf_conntrack_count', `${p.conntrack}\n`);
	put(root, '/proc/sys/net/netfilter/nf_conntrack_max', '65536\n');
	put(root, '/proc/net/stat/nf_conntrack', split(fixture('caju-router/proc/net/stat/nf_conntrack'), '\n')[0] + '\n' +
		join('\n', hex_rows(p.cpus, 17, rand)) + '\n');
	mkdir_p(`${dir}/conntrack`);
	for (let n in p.conntrack_scaling)
		writefile(`${dir}/conntrack/${n}`, conntrack_table(n, 7));

	// The scrape's table is a scaling case's when it has that size.
	if (p.conntrack in p.conntrack_scaling)
		symlink(`../../../conntrack/${p.conntrack}`, `${root}/proc/net/nf_conntrack`);
	else
		put(root, '/proc/net/nf_conntrack', conntrack_table(p.conntrack, 7));

	// Links: netlink, sysfs, dev_snmp6, ethtool -S
	let snmp6 = fixture('caju-ap/proc/net/dev_snmp6/eth0');
	let all = links(p, rand);
	world.rtnl.RTM_GETLINK = all;
	mkdir_p(`${dir}/commands`);
	for (let i, l in all) {
		sysfs_link(root, l, i, rand);
		put(root, `/proc/net/dev_snmp6/${l.dev}`, replace(revalue(snmp6, rand), /ifIndex[ \t]+[0-9]+/, `ifIndex                         \t${i + 1}`));

		if (l.dev != 'lo') {
			writefile(`${dir}/commands/ethtool-S-${l.dev}.txt`, ethtool(l.dev, rand));
			world.commands[join(' ', map([ 'ethtool', '-S', l.dev ], (a) => `'${a}'`))] = `commands/ethtool-S-${l.dev}.txt`;
		}
	}
	writefile(`${dir}/commands/nft.txt`, nft_counters(p, rand));
	world.commands["'nft' '--json' 'list' 'counters'"] = 'commands/nft.txt';
	// A generator of its own, so the rest of the world is what it was without it.
	writefile(`${dir}/commands/tc.json`, qdiscs(all, rng(43)));
	// chronyd serving time to the lan, its command socket there (as outside
	// the jail): so the collector asks for serverstats too.
	chrony(dir, world, p.ntp_sources, rng(44));
	put(root, '/etc/config/chrony', "config server\n\toption hostname 'time.example'\n\nconfig allow\n\toption interface 'lan'\n");
	put(root, '/var/run/chrony/chronyd.sock', 'a file where the socket is: the collector only sees it is there\n');
	world.commands["'tc' '-s' '-j' 'qdisc' 'show'"] = 'commands/tc.json';

	// /sys: hwmon, thermal
	for (let h = 0; h < p.hwmon; h++) {
		let d = `/sys/class/hwmon/hwmon${h}`;
		put(root, `${d}/name`, h % 2 ? 'mt7915_phy0\n' : 'cpu_thermal\n');
		for (let t = 1; t <= 3; t++) {
			put(root, `${d}/temp${t}_input`, `${40000 + rand(20000)}\n`);
			put(root, `${d}/temp${t}_label`, `sensor ${t}\n`);
		}
		put(root, `${d}/pwm1`, `${rand(255)}\n`);
	}
	// Generators of their own, so the rest of the world is what it was without them.
	hwmon_readings(root, p, rng(45));
	diskstats(root, p, rng(46));
	// sockstat: the seriguela router's sockets, and its cat's auxiliary vector for the page size.
	for (let f in [ 'net/sockstat', 'net/sockstat6', 'self/auxv' ])
		put(root, `/proc/${f}`, fixture(`seriguela-router/proc/${f}`));
	for (let z = 0; z < p.thermal; z++) {
		let d = `/sys/class/thermal/thermal_zone${z}`;
		put(root, `${d}/type`, `zone${z}-thermal\n`);
		put(root, `${d}/policy`, 'step_wise\n');
		put(root, `${d}/temp`, `${40000 + rand(20000)}\n`);
		put(root, `${d}/mode`, 'enabled\n');
		put(root, `${d}/passive`, '0\n');
	}

	// textfile
	let prom = '# HELP bench_value A value.\n# TYPE bench_value gauge\n';
	for (let i = 0; i < p.textfile_samples; i++)
		prom += sprintf('bench_value{id="%d",kind="k%d"} %d\n', i, i % 7, rand(1000000));
	put(root, '/var/prometheus/bench.prom', prom);

	// DHCP and the network config
	put(root, '/tmp/dhcp.leases', leasefile(p, rand));
	put(root, '/etc/config/dhcp', uci_dhcp(p));
	let wg = wireguard(p, rand);
	// The bench measures what a scrape costs, not where its guards stop it:
	// no collector is stopped at its budget, which nat_traffic on 20,000
	// connections passes on a slow router. The deadline cases still have
	// their deadline.
	put(root, '/etc/config/prometheus-exporter',
		"config prometheus-exporter 'main'\n\toption enabled '1'\n\toption collector_budget '60'\n\n" +
		"config collector 'dhcp_leases'\n\toption leases '1'\n\n" +
		"config collector 'wireguard'\n\toption peer_names '1'\n\n");

	// ubus
	world.ubus['system:board'] = fixture_json('caju-router/ubus/system.board.json');
	world.ubus['luci:getMountPoints'] = fixture_json('caju-router/ubus/luci.getMountPoints.json');
	world.ubus['dnsmasq:metrics'] = fixture_json('caju-router/ubus/dnsmasq.metrics.json');
	world.ubus['network.interface:dump'] = interfaces(p);
	world.ubus['dhcp:ipv4leases'] = { device: {} };
	world.ubus['dhcp:ipv6leases'] = odhcpd(p, rand);
	world.ubus['wireguard:status'] = wg.status;
	world.ubus['uci:get'] = wg.uci_get;

	// timesync: busybox ntpd runs, synchronized, as its last event says; no
	// chronyd (rc knows no init script of that name).
	world.ubus['service:list'] = fixture_json('caju-ap/ubus/service.list.sysntpd.json');
	world.ubus['rc:list'] = {};
	put(root, '/var/run/prometheus-exporter/timesync/ntpd', fixture('synthetic/var/run/prometheus-exporter/timesync/ntpd'));
	wireless(p, rand, world);

	// Apart, so a case loads only what its collectors ask: the benchmark
	// measures their memory, not the world's.
	for (let source in [ 'ubus', 'nl80211', 'rtnl' ]) {
		writefile(`${dir}/${source}.json`, sprintf('%J', world[source]));
		delete world[source];
	}

	writefile(`${dir}/world.json`, sprintf('%J', world));
}

if (!length(ARGV)) {
	warn('usage: gen.uc OUTDIR [PROFILE...]\n');
	exit(2);
}

for (let profile in (length(ARGV) > 1 ? slice(ARGV, 1) : keys(PROFILES))) {
	mkdir_p(`${ARGV[0]}/${profile}`);
	generate(`${ARGV[0]}/${profile}`, profile);
}

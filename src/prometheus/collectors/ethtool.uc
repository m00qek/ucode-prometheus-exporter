'use strict';

import { Result } from 'prometheus.exporter';

export const meta = {
	name: 'ethtool',
	title: 'Network drivers and links',
	help: 'Network driver statistics, driver information and link modes, from ethtool -S, -i and ethtool <device>.',
	needs: [ 'rtnl', 'fs', 'exec' ],
	commands: [ 'ethtool' ],
	cost: 'heavy',
};

const ENTRIES = {
	rx_bytes: [ 'node_ethtool_received_bytes_total', 'Network interface bytes received' ],
	rx_dropped: [ 'node_ethtool_received_dropped_total', 'Number of received frames dropped' ],
	rx_errors: [ 'node_ethtool_received_errors_total', 'Number of received frames with errors' ],
	rx_packets: [ 'node_ethtool_received_packets_total', 'Network interface packets received' ],
	tx_bytes: [ 'node_ethtool_transmitted_bytes_total', 'Network interface bytes sent' ],
	tx_errors: [ 'node_ethtool_transmitted_errors_total', 'Number of sent frames with errors' ],
	tx_packets: [ 'node_ethtool_transmitted_packets_total', 'Network interface packets sent' ],
};

const NOT_NAME = /_*[^0-9A-Za-z_]+_*/g;
const NAME = /^[0-9A-Za-z_]*$/;
const RX = /(^|_)rx(_|$)/g;
const TX = /(^|_)tx(_|$)/g;

export function sanitize(stat) {
	return match(stat, NAME) ? stat : replace(stat, NOT_NAME, '_');
};

function fqname_of(key) {
	let name = ltrim(lc(key), '_');

	if (index(name, 'rx') >= 0)
		name = replace(name, RX, '$1received$2');
	if (index(name, 'tx') >= 0)
		name = replace(name, TX, '$1transmitted$2');

	return 'node_ethtool_' + name;
}

export function fqname(stat) {
	return fqname_of(sanitize(stat));
};

const INFO = 'node_ethtool_info';

const PORTS = [ 'TP', 'AUI', 'BNC', 'MII', 'FIBRE', 'Backplane' ];

const LINK_MODE = /^([0-9]+)base([A-Za-z0-9_]+)\/(Half|Full)$/;

const NAMES = {};
const NAMES_MAX = 4096;
let named = 0;

function names(stat) {
	let n = NAMES[stat];

	if (!n) {
		let key = sanitize(stat), fq = fqname_of(key);

		n = [ fq, ENTRIES[key] ?? [ fq, `Network interface ${key}` ] ];
		if (named++ < NAMES_MAX)
			NAMES[stat] = n;
	}

	return n;
}

export function family(stat) {
	return names(stat)[1];
};

export function exported(stats) {
	let by_fq = {};
	let written = {};

	for (let s in stats) {
		let n = names(s[0]);

		by_fq[n[0]] = (n[0] in by_fq) ? false : s;
		written[n[1][0]] = !(n[1][0] in written);
	}

	let out = [];
	for (let fq in sort(keys(by_fq))) {
		let s = by_fq[fq];
		let fam = s ? names(s[0])[1][0] : null;

		if (s && written[fam] && fam != INFO)
			push(out, s);
	}

	return out;
};

function statistic(line) {
	let p = max(rindex(line, ' '), rindex(line, '\t'));

	if (p < 1)
		return null;

	let q = p;
	while (q > 0 && index(' \t', substr(line, q - 1, 1)) >= 0)
		q--;

	return (q >= 2 && substr(line, q - 1, 1) == ':') ? [ substr(line, 0, q - 1), substr(line, p + 1) ] : null;
}

export function statistics(text) {
	let stats = [];

	for (let line in split(text ?? '', '\n')) {
		let s = statistic(trim(line));

		if (s)
			push(stats, s);
	}

	return stats;
};

export function driver_info(text) {
	let info = { bus_info: '', driver: '', expansion_rom_version: '', firmware_version: '', version: '' };

	for (let line in split(text ?? '', '\n')) {
		let c = index(line, ':');
		let key = (c > 0) ? replace(trim(substr(line, 0, c)), '-', '_') : null;

		if (key in keys(info))
			info[key] = trim(substr(line, c + 1));
	}

	return info;
};

export function link_settings(text) {
	let s = {
		supported: { ports: [], modes: [], pause: null, asymmetric_pause: null, autonegotiate: null },
		advertised: { modes: [], pause: null, asymmetric_pause: null, autonegotiate: null },
		autonegotiate: null,
	};
	let modes = null;

	for (let line in split(text ?? '', '\n')) {
		let t = trim(line);
		let c = index(t, ':');
		let value = t;

		if (c >= 0) {
			let name = substr(t, 0, c);

			value = trim(substr(t, c + 1));
			modes = (name == 'Supported link modes') ? s.supported.modes : (name == 'Advertised link modes') ? s.advertised.modes : null;

			if (name == 'Supported ports')
				s.supported.ports = filter(split(replace(value, /[\[\]]/g, ' '), /[ \t]+/), (w) => w in PORTS);
			else if (name == 'Supported pause frame use' || name == 'Advertised pause frame use') {
				let to = (substr(name, 0, 1) == 'S') ? s.supported : s.advertised;

				to.pause = index(value, 'Symmetric') >= 0;
				to.asymmetric_pause = index(value, 'Receive-only') >= 0 || index(value, 'Transmit-only') >= 0;
			}
			else if (name == 'Supports auto-negotiation')
				s.supported.autonegotiate = (value == 'Yes');
			else if (name == 'Advertised auto-negotiation')
				s.advertised.autonegotiate = (value == 'Yes');
			else if (name == 'Auto-negotiation')
				s.autonegotiate = (value == 'on');
		}

		if (modes == null)
			continue;

		for (let w in split(value, /[ \t]+/)) {
			let m = match(w, LINK_MODE);

			if (m)
				push(modes, [ `${m[1]}base${m[2]}`, lc(m[3]), +m[1] ]);
		}
	}

	return s;
};

export function backed(fs, dev) {
	return fs.stat(`/sys/class/net/${dev}/device`) != null;
};

function cannot_run(res) {
	return res.data?.status == null || res.data.status in [ 126, 127 ];
}

export function collect(deps, out) {
	let c = deps.rtnl.const;
	let links = deps.rtnl.request(c.RTM_GETLINK, c.NLM_F_DUMP);

	if (!links.ok)
		return links;

	let families = {};
	let info = out.gauge('node_ethtool_info', 'A metric with a constant \'1\' value labeled by bus_info, device, driver, expansion_rom_version, firmware_version, version.');
	let port = out.gauge('node_network_supported_port_info', 'Type of ports or PHYs supported by network device');
	let speeds = {
		supported: out.gauge('node_network_supported_speed_bytes', 'Combination of speeds and features supported by network device'),
		advertised: out.gauge('node_network_advertised_speed_bytes', 'Combination of speeds and features offered by network device'),
	};
	let flags = {
		supported: {
			autonegotiate: out.gauge('node_network_autonegotiate_supported', 'If this port device supports autonegotiate'),
			pause: out.gauge('node_network_pause_supported', 'If this port device supports pause frames'),
			asymmetric_pause: out.gauge('node_network_asymmetricpause_supported', 'If this port device supports asymmetric pause frames'),
		},
		advertised: {
			autonegotiate: out.gauge('node_network_autonegotiate_advertised', 'If this port device offers autonegotiate'),
			pause: out.gauge('node_network_pause_advertised', 'If this port device offers pause capability'),
			asymmetric_pause: out.gauge('node_network_asymmetricpause_advertised', 'If this port device offers asymmetric pause capability'),
		},
	};
	let autonegotiate = out.gauge('node_network_autonegotiate', 'If this port is using autonegotiate');

	for (let link in links.data ?? []) {
		let device = link.dev ?? link.ifname;

		if (device == null || !backed(deps.fs, device))
			continue;

		let labels = out.labels({ device });
		let res = deps.exec.run([ 'ethtool', '-S', device ]);

		if (res.ok) {
			for (let s in exported(statistics(res.data))) {
				let f = family(s[0]);

				families[f[0]] ??= out.untyped(f[0], f[1]);
				families[f[0]](labels, s[1]);
			}
		} else if (cannot_run(res))
			return res;

		res = deps.exec.run([ 'ethtool', '-i', device ]);
		if (res.ok) {
			let d = driver_info(res.data);

			info({ bus_info: d.bus_info, device, driver: d.driver, expansion_rom_version: d.expansion_rom_version,
				firmware_version: d.firmware_version, version: d.version }, 1);
		} else if (cannot_run(res))
			return res;

		res = deps.exec.run([ 'ethtool', device ]);
		if (!res.ok) {
			if (cannot_run(res))
				return res;
			continue;
		}

		let s = link_settings(res.data);

		for (let type in s.supported.ports)
			port({ device, type }, 1);

		for (let which in [ 'supported', 'advertised' ]) {
			for (let m in s[which].modes)
				speeds[which]({ device, duplex: m[1], mode: m[0] }, m[2] * 125000);
			for (let flag, record in flags[which])
				if (s[which][flag] != null)
					record(labels, s[which][flag]);
		}

		if (s.autonegotiate != null)
			autonegotiate(labels, s.autonegotiate);
	}

	return Result.ok();
};

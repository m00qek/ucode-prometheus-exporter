'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/snmp6.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Per-device IPv6 statistics: each "<name> <value>" line of
// /proc/net/dev_snmp6/<device> is a counter
// node_snmp6_<protocol>_<rest of the name>_total{device}, split as the netstat
// collector splits the system-wide /proc/net/snmp6 (Ip6InReceives is
// node_snmp6_Ip6_InReceives_total), and its ifIndex line is the gauge
// node_snmp6_ifindex. The system-wide counters are the netstat collector's
// node_netstat_Ip6_*, Icmp6_*, Udp6_* and UdpLite6_*, as in node_exporter,
// which has no per-device ones.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { lines, fields } from 'node_exporter.proc';

export const meta = {
	name: 'snmp6',
	help: 'Per-device IPv6 statistics from /proc/net/dev_snmp6.',
	needs: [ 'fs' ],
};

const DEVICES = '/proc/net/dev_snmp6';

// The protocols of the names, as node_exporter (and the netstat collector,
// which is a package apart) split /proc/net/snmp6's.
const SNMP6_NAME = /^(Ip6|Icmp6|UdpLite6|Udp6)(.+)$/;

// The family of a statistic: [ type, name, help ].
export function family_of(stat) {
	if (stat == 'ifIndex')
		return [ 'gauge', 'node_snmp6_ifindex', 'Interface index of the device.' ];

	let m = match(stat, SNMP6_NAME);
	let name = m ? `${m[1]}_${m[2]}` : stat;

	return [ 'counter', `node_snmp6_${name}_total`, `IPv6 statistic ${stat} of the device.` ];
};

function parse(fs, out, device) {
	for (let line in lines(fs, `${DEVICES}/${device}`) ?? []) {
		let x = fields(line);

		if (length(x) >= 2) {
			let f = family_of(x[0]);
			out[f[0]](f[1], f[2])({ device }, x[1]);
		}
	}
}

export function collect(deps, out) {
	let devices = deps.fs.lsdir(DEVICES);

	// Where IPv6 is disabled there is no /proc/net/dev_snmp6: nothing to collect.
	if (devices == null)
		return Result.err(errors.SOURCE_UNREADABLE, DEVICES);

	// A device that goes away before it is read is left out.
	for (let device in sort(devices))
		parse(deps.fs, out, device);

	return Result.ok();
};

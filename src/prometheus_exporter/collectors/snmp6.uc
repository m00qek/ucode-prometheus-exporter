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

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { lines, fields } from 'prometheus_exporter.proc';

export const meta = {
	name: 'snmp6',
	title: 'IPv6 statistics per device',
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

// `families` holds each statistic's family once made: every device has the
// same statistics, and a family's name is a regex match.
function parse(fs, out, families, device) {
	let labels = out.labels({ device });

	for (let line in lines(fs, `${DEVICES}/${device}`) ?? []) {
		let x = fields(line);

		if (length(x) >= 2) {
			let record = families[x[0]];

			if (!record) {
				let f = family_of(x[0]);
				record = families[x[0]] = out[f[0]](f[1], f[2]);
			}

			record(labels, x[1]);
		}
	}
}

export function collect(deps, out) {
	let devices = deps.fs.lsdir(DEVICES);

	// Where IPv6 is disabled there is no /proc/net/dev_snmp6: nothing to
	// observe. One that is there and cannot be read is a failure.
	if (devices == null)
		return deps.fs.stat(DEVICES) == null
			? Result.none('no IPv6 (no /proc/net/dev_snmp6)')
			: Result.err(errors.SOURCE_UNREADABLE, DEVICES);

	// A device that goes away before it is read is left out.
	let families = {};
	for (let device in sort(devices))
		parse(deps.fs, out, families, device);

	return Result.ok();
};

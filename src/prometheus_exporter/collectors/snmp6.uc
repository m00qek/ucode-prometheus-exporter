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
//
// A device has some 70 statistics, and a router a dozen devices or more, each
// statistic a series of each. The `fields` option is a regular expression of
// the <protocol>_<name> fields to export (Ip6_InOctets; ifIndex as it is), as
// netstat's is, and by default keeps 13: those of node_exporter's netstat
// defaults a device has (its octets, its ICMP messages and the ICMP errors it
// received), and what tells a router's devices apart besides: the datagrams
// it forwarded out of each, those it discarded either way or found no route
// for, and those it received with a bad header, a destination not its own, or
// too big to forward (a smaller MTU on the way out, as PPPoE's 1492). The
// rest are the system-wide counters again, by device, or rarely move: the
// multicast and broadcast counts, fragments and reassembly, ECN marks, each
// ICMPv6 type. The interface index is netclass's node_network_iface_id. `.*`
// exports every one. Each name is matched once a scrape, whatever the number
// of devices.

import { Result, errors, proc } from 'prometheus_exporter.api';

export const DEFAULT_FIELDS = '^(Ip6_(InOctets|OutOctets|OutForwDatagrams|InDiscards|OutDiscards|InNoRoutes|OutNoRoutes|' +
	'InHdrErrors|InAddrErrors|InTooBigErrors)|Icmp6_(InMsgs|OutMsgs|InErrors))$';

export const meta = {
	name: 'snmp6',
	title: 'IPv6 statistics per device',
	help: 'Per-device IPv6 statistics from /proc/net/dev_snmp6.',
	needs: [ 'fs' ],
	options: {
		fields: {
			default: DEFAULT_FIELDS,
			title: 'Exported fields',
			datatype: 'regex',
			help: 'A regular expression of the <protocol>_<name> fields to export (13 of the 70 or so of a device by default; .* for every one).',
		},
	},
};

const DEVICES = '/proc/net/dev_snmp6';

// The protocols of the names, as node_exporter (and the netstat collector,
// which is a package apart) split /proc/net/snmp6's.
const SNMP6_NAME = /^(Ip6|Icmp6|UdpLite6|Udp6)(.+)$/;

// The field of a statistic, as the `fields` option matches it: Ip6_InReceives
// for Ip6InReceives; one of no known protocol, as ifIndex, as it is.
export function field_of(stat) {
	let m = match(stat, SNMP6_NAME);

	return m ? `${m[1]}_${m[2]}` : stat;
};

// The family of a statistic: [ type, name, help ].
export function family_of(stat) {
	if (stat == 'ifIndex')
		return [ 'gauge', 'node_snmp6_ifindex', 'Interface index of the device.' ];

	return [ 'counter', `node_snmp6_${field_of(stat)}_total`, `IPv6 statistic ${stat} of the device.` ];
};

// The family a statistic is recorded in, declared: the index's by its name,
// so that the reference pages find it.
function declare(out, stat) {
	if (stat == 'ifIndex')
		return out.gauge('node_snmp6_ifindex', 'Interface index of the device.');

	let f = family_of(stat);
	return out[f[0]](f[1], f[2]);
}

// `families` holds how each statistic is recorded once it is known: its
// family, or false for one the pattern leaves out. Every device has the same
// statistics, so each is matched once, and its family made once.
function parse(fs, out, pattern, families, device) {
	let labels = out.labels({ device });

	for (let line in proc.lines(fs, `${DEVICES}/${device}`) ?? []) {
		let x = proc.fields(line);

		if (length(x) < 2)
			continue;

		let record = families[x[0]];

		if (record == null)
			record = families[x[0]] = match(field_of(x[0]), pattern) ? declare(out, x[0]) : false;

		if (record)
			record(labels, x[1]);
	}
}

export function collect(deps, out, options) {
	let pattern;

	try {
		pattern = regexp(options.fields);
	} catch (e) {
		return Result.err(errors.CONFIG_INVALID, `fields: ${e.message}`);
	}

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
		parse(deps.fs, out, pattern, families, device);

	return Result.ok();
};

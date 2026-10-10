'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

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

const SNMP6_NAME = /^(Ip6|Icmp6|UdpLite6|Udp6)(.+)$/;

export function field_of(stat) {
	let m = match(stat, SNMP6_NAME);

	return m ? `${m[1]}_${m[2]}` : stat;
};

export function family_of(stat) {
	if (stat == 'ifIndex')
		return [ 'gauge', 'node_snmp6_ifindex', 'Interface index of the device.' ];

	return [ 'counter', `node_snmp6_${field_of(stat)}_total`, `IPv6 statistic ${stat} of the device.` ];
};

function declare(out, stat) {
	if (stat == 'ifIndex')
		return out.gauge('node_snmp6_ifindex', 'Interface index of the device.');

	let f = family_of(stat);
	return out[f[0]](f[1], f[2]);
}

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

	if (devices == null)
		return deps.fs.stat(DEVICES) == null
			? Result.none('no IPv6 (no /proc/net/dev_snmp6)')
			: Result.err(errors.SOURCE_UNREADABLE, DEVICES);

	let families = {};
	for (let device in sort(devices))
		parse(deps.fs, out, pattern, families, device);

	return Result.ok();
};

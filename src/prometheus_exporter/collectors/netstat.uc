'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/netstat.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The kernel's protocol statistics, as node_exporter's netstat collector
// (collector/netstat_linux.go) names and types them: each section of
// /proc/net/netstat and /proc/net/snmp is a header line of names and a line of
// values, both starting with the section ("TcpExt:"), and each value is an
// untyped node_netstat_<section>_<name>; each "<name> <value>" line of
// /proc/net/snmp6 is node_netstat_<protocol>_<rest of the name>, Ip6InReceives
// being node_netstat_Ip6_InReceives. Every field is exported, where
// node_exporter keeps a few by default (--collector.netstat.fields).

import { Result, errors, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'netstat',
	title: 'Protocol statistics',
	help: 'Protocol statistics from /proc/net/netstat, /proc/net/snmp and /proc/net/snmp6.',
	needs: [ 'fs' ],
};

const TABLES = [ '/proc/net/netstat', '/proc/net/snmp' ];
const SNMP6 = '/proc/net/snmp6';

// The protocols of /proc/net/snmp6's names, as node_exporter splits them.
const SNMP6_NAME = /^(Ip6|Icmp6|UdpLite6|Udp6)(.+)$/;

// With node_exporter's help: "Statistic TcpExtSyncookiesSent."
function record(out, section, name, value) {
	out.untyped(`node_netstat_${section}_${name}`, `Statistic ${section}${name}.`)(null, value);
}

// The sections of one table file, recorded; the sections whose two lines do not
// match (named apart, or with more names than values or fewer), which are left
// out. Null when the file cannot be read.
function parse_table(fs, out, path) {
	let l = proc.lines(fs, path);

	if (l == null)
		return null;

	let bad = [];

	for (let i = 0; i + 1 < length(l); i += 2) {
		let names = proc.fields(l[i]);
		let values = proc.fields(l[i + 1]);

		if (!length(names) || names[0] != values[0] || length(names) != length(values)
		    || substr(names[0], -1) != ':') {
			push(bad, names[0] ?? '');
			continue;
		}

		let section = substr(names[0], 0, -1);
		for (let j = 1; j < length(names); j++)
			record(out, section, names[j], values[j]);
	}

	if (length(l) % 2)
		push(bad, proc.fields(l[-1])[0] ?? '');

	return bad;
}

// /proc/net/snmp6, recorded: nothing in it is a section that can break, and a
// line without a value or a protocol is left out. Null when the file cannot be
// read, as where IPv6 is disabled.
function parse_snmp6(fs, out) {
	let l = proc.lines(fs, SNMP6);

	if (l == null)
		return null;

	for (let line in l) {
		let x = proc.fields(line);
		let m = length(x) >= 2 ? match(x[0], SNMP6_NAME) : null;

		if (m)
			record(out, m[1], m[2], x[1]);
	}

	return [];
}

export function collect(deps, out) {
	let sources = [ ...TABLES, SNMP6 ];
	let readable = 0;
	let invalid = [];

	for (let path in sources) {
		let bad = (path == SNMP6) ? parse_snmp6(deps.fs, out) : parse_table(deps.fs, out, path);

		if (bad == null)
			continue;

		readable++;
		if (length(bad))
			push(invalid, `${path}: ${join(' ', bad)}`);
	}

	// Any file alone is worth exporting, as upstream has it.
	if (!readable)
		return Result.err(errors.SOURCE_UNREADABLE, join(', ', sources));
	if (length(invalid))
		return Result.err(errors.SOURCE_INVALID, join('; ', invalid));

	return Result.ok();
};

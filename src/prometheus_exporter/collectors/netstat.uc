'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/netstat.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The kernel's protocol statistics, as node_exporter's netstat collector
// (collector/netstat_linux.go) names and types them: each section of
// /proc/net/netstat and /proc/net/snmp is a header line of names and a line of
// values, both starting with the section ("TcpExt:"), and each value is an
// untyped node_netstat_<section>_<name>; each "<name> <value>" line of
// /proc/net/snmp6 is node_netstat_<protocol>_<rest of the name>, Ip6InReceives
// being node_netstat_Ip6_InReceives.
//
// The `fields` option is node_exporter's --collector.netstat.fields: a regular
// expression of the <section>_<name> fields to export, by default
// node_exporter's own, which keeps some 35 of the kernel's 400 or so: the
// errors, IP forwarding and octets, ICMP messages, TCP's connections,
// segments, retransmissions and listen queue, and UDP's datagrams and buffer
// errors. `.*` exports every one. It is a POSIX extended regular expression
// (ucode's), as vmstat's `fields` is. Every line is still read and checked,
// whatever the pattern: a malformed section fails the collector, as before.

import { Result, errors, proc } from 'prometheus_exporter.api';

export const DEFAULT_FIELDS = '^(.*_(InErrors|InErrs)|Ip_Forwarding|Ip(6|Ext)_(InOctets|OutOctets)|Icmp6?_(InMsgs|OutMsgs)|' +
	'TcpExt_(Listen.*|Syncookies.*|TCPSynRetrans|TCPTimeouts|TCPOFOQueue|TCPRcvQDrop)|' +
	'Tcp_(ActiveOpens|InSegs|OutSegs|OutRsts|PassiveOpens|RetransSegs|CurrEstab)|' +
	'Udp6?_(InDatagrams|OutDatagrams|NoPorts|RcvbufErrors|SndbufErrors))$';

export const meta = {
	name: 'netstat',
	title: 'Protocol statistics',
	help: 'Protocol statistics from /proc/net/netstat, /proc/net/snmp and /proc/net/snmp6.',
	needs: [ 'fs' ],
	options: {
		fields: {
			default: DEFAULT_FIELDS,
			title: 'Exported fields',
			datatype: 'regex',
			help: 'A regular expression of the <section>_<name> fields to export (node_exporter\'s by default; .* for every one).',
		},
	},
};

const TABLES = [ '/proc/net/netstat', '/proc/net/snmp' ];
const SNMP6 = '/proc/net/snmp6';

// The protocols of /proc/net/snmp6's names, as node_exporter splits them.
const SNMP6_NAME = /^(Ip6|Icmp6|UdpLite6|Udp6)(.+)$/;

// With node_exporter's help: "Statistic TcpExtSyncookiesSent." A field the
// pattern does not match is left out.
function record(out, pattern, section, name, value) {
	let field = `${section}_${name}`;

	if (match(field, pattern))
		out.untyped(`node_netstat_${field}`, `Statistic ${section}${name}.`)(null, value);
}

// The sections of one table file, recorded; the sections whose two lines do not
// match (named apart, or with more names than values or fewer), which are left
// out. Null when the file cannot be read.
function parse_table(fs, out, pattern, path) {
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
			record(out, pattern, section, names[j], values[j]);
	}

	if (length(l) % 2)
		push(bad, proc.fields(l[-1])[0] ?? '');

	return bad;
}

// /proc/net/snmp6, recorded: nothing in it is a section that can break, and a
// line without a value or a protocol is left out. Null when the file cannot be
// read, as where IPv6 is disabled.
function parse_snmp6(fs, out, pattern) {
	let l = proc.lines(fs, SNMP6);

	if (l == null)
		return null;

	for (let line in l) {
		let x = proc.fields(line);
		let m = length(x) >= 2 ? match(x[0], SNMP6_NAME) : null;

		if (m)
			record(out, pattern, m[1], m[2], x[1]);
	}

	return [];
}

export function collect(deps, out, options) {
	let pattern;

	try {
		pattern = regexp(options.fields);
	} catch (e) {
		return Result.err(errors.CONFIG_INVALID, `fields: ${e.message}`);
	}

	let sources = [ ...TABLES, SNMP6 ];
	let readable = 0;
	let invalid = [];

	for (let path in sources) {
		let bad = (path == SNMP6) ? parse_snmp6(deps.fs, out, pattern) : parse_table(deps.fs, out, pattern, path);

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

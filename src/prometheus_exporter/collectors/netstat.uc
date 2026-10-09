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

// The fields DEFAULT_FIELDS names whole, by section and name. A scrape
// checks each of the kernel's 400 or so fields, and musl's regexec takes
// 14 us in the devenv to match one against the pattern, as long as forty
// lookups: the default, which nearly every router has, is looked for
// instead (default_at), and any other pattern is matched.
const DEFAULT_WHOLE = {
	Ip: { Forwarding: true },
	Ip6: { InOctets: true, OutOctets: true },
	IpExt: { InOctets: true, OutOctets: true },
	Icmp: { InMsgs: true, OutMsgs: true },
	Icmp6: { InMsgs: true, OutMsgs: true },
	TcpExt: { TCPSynRetrans: true, TCPTimeouts: true, TCPOFOQueue: true, TCPRcvQDrop: true },
	Tcp: { ActiveOpens: true, InSegs: true, OutSegs: true, OutRsts: true, PassiveOpens: true, RetransSegs: true, CurrEstab: true },
	Udp: { InDatagrams: true, OutDatagrams: true, NoPorts: true, RcvbufErrors: true, SndbufErrors: true },
	Udp6: { InDatagrams: true, OutDatagrams: true, NoPorts: true, RcvbufErrors: true, SndbufErrors: true },
};
const NONE = {};

// Whether DEFAULT_FIELDS matches a field, <section>_<name>: one it names
// whole, one that starts with TcpExt_Listen or TcpExt_Syncookies, or one
// that ends with _InErrors or _InErrs.
function default_field(field) {
	let i = index(field, '_');

	return (i > 0 && DEFAULT_WHOLE[substr(field, 0, i)]?.[substr(field, i + 1)] == true && index(substr(field, i + 1), '_') < 0) ||
		substr(field, 0, 13) == 'TcpExt_Listen' || substr(field, 0, 17) == 'TcpExt_Syncookies' ||
		substr(field, -9) == '_InErrors' || substr(field, -7) == '_InErrs';
}

// The names of a section's fields, joined by spaces, that may end with
// InErrors or InErrs, and those that start with Listen or Syncookies, for
// TcpExt: one match finds them all.
const ERR_NAMES = /(^| )([^ ]*InErr[^ ]*)/g;
const TCPEXT_NAMES = /(^| )((Listen|Syncookies)[^ ]*)/g;
const TCPEXT_KNOWN = [ 'ListenOverflows', 'ListenDrops', 'SyncookiesSent', 'SyncookiesRecv', 'SyncookiesFailed' ];

// Where in `names`, from `from` on, the fields of a section without an
// underscore are that DEFAULT_FIELDS matches, in order; null for a section
// that names a field twice, which the kernel's never do.
//
// For such a section the name alone tells it, as default_field() would of
// `${section}_${name}`: one of the section's DEFAULT_WHOLE, one that is,
// or ends with _, InErrors or InErrs, or one of TcpExt's that starts with
// Listen or Syncookies. So they are looked for, not each field checked: an
// index() of each whole name, and one match of the names for the others.
// The kernel's sections have 400 or so fields, and a turn of a loop for
// each cost more than the rest of netstat; TcpExt and MPTcpExt, two thirds
// of them, have but a few the default takes, or none.
function default_at(section, names, from) {
	if (length(uniq(names)) != length(names))
		return null;

	let at = [];
	let whole = DEFAULT_WHOLE[section] ?? NONE;
	let text = join(' ', names);

	for (let name in whole) {
		let i = index(names, name);

		if (i >= from)
			push(at, i);
	}

	if (index(text, 'InErr') >= 0)
		for (let m in match(text, ERR_NAMES) ?? []) {
			let name = m[2];

			if (name == 'InErrors' || name == 'InErrs' || substr(name, -9) == '_InErrors' || substr(name, -7) == '_InErrs')
				push(at, index(names, name));
		}

	// TcpExt's names that start with Listen or Syncookies are the kernel's
	// five, unless as many splits of the names say there are more: the
	// match reads all 2 kB of them.
	if (section == 'TcpExt') {
		let known = 0;

		for (let name in TCPEXT_KNOWN) {
			let i = index(names, name);

			if (i >= 0) {
				push(at, i);
				known++;
			}
		}

		if (length(split(text, ' Listen')) + length(split(text, ' Syncookies')) - 2 != known)
			for (let m in match(text, TCPEXT_NAMES) ?? [])
				push(at, index(names, m[2]));
	}

	return sort(filter(uniq(at), (i) => i >= from), (a, b) => a - b);
}

// Records the fields of one section, `names` and `values` from `from` on, as
// rows of out.batch(): those `pattern` matches, or with a null pattern
// DEFAULT_FIELDS (default_at, or default_field for a section with an
// underscore). With node_exporter's help: "Statistic TcpExtSyncookiesSent."
function record(rows, pattern, section, names, values, from) {
	let at = (!pattern && index(section, '_') < 0) ? default_at(section, names, from) : null;

	if (at != null) {
		for (let j in at)
			push(rows, [ `node_netstat_${section}_${names[j]}`, `Statistic ${section}${names[j]}.`, values[j] ]);
		return;
	}

	for (let j = from; j < length(names); j++) {
		let name = names[j];
		let field = `${section}_${name}`;

		if (pattern ? match(field, pattern) : default_field(field))
			push(rows, [ `node_netstat_${field}`, `Statistic ${section}${name}.`, values[j] ]);
	}
}

// The sections of one table file, recorded; the sections whose two lines do not
// match (named apart, or with more names than values or fewer), which are left
// out. Null when the file cannot be read.
function parse_table(fs, rows, pattern, path) {
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

		record(rows, pattern, substr(names[0], 0, -1), names, values, 1);
	}

	if (length(l) % 2)
		push(bad, proc.fields(l[-1])[0] ?? '');

	return bad;
}

// The names of /proc/net/snmp6's fields DEFAULT_FIELDS names whole.
const SNMP6_WHOLE = {
	Ip6InOctets: true, Ip6OutOctets: true, Icmp6InMsgs: true, Icmp6OutMsgs: true,
	Udp6InDatagrams: true, Udp6OutDatagrams: true, Udp6NoPorts: true, Udp6RcvbufErrors: true, Udp6SndbufErrors: true,
};

// A /proc/net/snmp6 line's protocol and the rest of its name, as the
// protocols' regex, ^(Ip6|Icmp6|UdpLite6|Udp6)(.+)$, splits them, or null:
// by its first letters, without a match.
function snmp6_name(name) {
	let p = substr(name, 0, 3);
	let n = (p == 'Ip6') ? 3 : (p == 'Icm') ? 5 : (p == 'Udp') ? ((substr(name, 3, 1) == '6') ? 4 : 8) : 0;

	if (!n || length(name) <= n)
		return null;

	p = substr(name, 0, n);

	return (p == 'Ip6' || p == 'Icmp6' || p == 'Udp6' || p == 'UdpLite6') ? [ name, p, substr(name, n) ] : null;
}

// /proc/net/snmp6, recorded: nothing in it is a section that can break, and a
// line without a value or a protocol is left out. Null when the file cannot be
// read, as where IPv6 is disabled.
//
// The kernel writes a line as "%-32s\t%lu": a name, the spaces that pad it
// and a tab, then a value. In a file without \v, \f and \r, such a line is
// its two fields by a split on its tab and a trim of each, without the regex
// proc.fields() splits it with; and with the default pattern, a name it
// takes neither whole nor with InErr in it is left out there, its value
// unread, as about 75 of the 90 are. Any other line is proc.fields()'.
function parse_snmp6(fs, rows, pattern) {
	let text = fs.readfile(SNMP6);

	if (text == null)
		return null;

	let plain = index(text, '\v') < 0 && index(text, '\f') < 0 && index(text, '\r') < 0;
	let l = split(text, '\n');

	if (l[-1] == '')
		pop(l);

	for (let line in l) {
		let x = null;

		if (plain) {
			x = split(line, '\t');

			let name = (length(x) == 2) ? trim(x[0]) : null;

			if (name == null || name == '' || index(name, ' ') >= 0) {
				x = null;
			} else if (!pattern && SNMP6_WHOLE[name] != true && index(name, 'InErr') < 0) {
				continue;
			} else {
				let value = trim(x[1]);

				x = (value != '' && index(value, ' ') < 0) ? [ name, value ] : null;
			}
		}

		x ??= proc.fields(line);

		let m = length(x) >= 2 ? snmp6_name(x[0]) : null;

		if (m)
			record(rows, pattern, m[1], [ m[2] ], [ x[1] ], 0);
	}

	return [];
}

export function collect(deps, out, options) {
	let pattern = null;

	try {
		if (options.fields != DEFAULT_FIELDS)
			pattern = regexp(options.fields);
	} catch (e) {
		return Result.err(errors.CONFIG_INVALID, `fields: ${e.message}`);
	}

	let sources = [ ...TABLES, SNMP6 ];
	let readable = 0;
	let invalid = [];
	let rows = [];

	for (let path in sources) {
		let bad = (path == SNMP6) ? parse_snmp6(deps.fs, rows, pattern) : parse_table(deps.fs, rows, pattern, path);

		if (bad == null)
			continue;

		readable++;
		if (length(bad))
			push(invalid, `${path}: ${join(' ', bad)}`);
	}

	out.batch('untyped', rows);

	// Any file alone is worth exporting, as upstream has it.
	if (!readable)
		return Result.err(errors.SOURCE_UNREADABLE, join(', ', sources));
	if (length(invalid))
		return Result.err(errors.SOURCE_INVALID, join('; ', invalid));

	return Result.ok();
};

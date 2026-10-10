'use strict';

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

function default_field(field) {
	let i = index(field, '_');

	return (i > 0 && DEFAULT_WHOLE[substr(field, 0, i)]?.[substr(field, i + 1)] == true && index(substr(field, i + 1), '_') < 0) ||
		substr(field, 0, 13) == 'TcpExt_Listen' || substr(field, 0, 17) == 'TcpExt_Syncookies' ||
		substr(field, -9) == '_InErrors' || substr(field, -7) == '_InErrs';
}

const ERR_NAMES = /(^| )([^ ]*InErr[^ ]*)/g;
const TCPEXT_NAMES = /(^| )((Listen|Syncookies)[^ ]*)/g;
const TCPEXT_KNOWN = [ 'ListenOverflows', 'ListenDrops', 'SyncookiesSent', 'SyncookiesRecv', 'SyncookiesFailed' ];

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

function parse_table(fs, rows, pattern, path) {
	let l = proc.rows(fs, path);

	if (l == null)
		return null;

	let bad = [];

	for (let i = 0; i + 1 < length(l); i += 2) {
		let names = l[i];
		let values = l[i + 1];

		if (!length(names) || names[0] != values[0] || length(names) != length(values)
		    || substr(names[0], -1) != ':') {
			push(bad, names[0] ?? '');
			continue;
		}

		record(rows, pattern, substr(names[0], 0, -1), names, values, 1);
	}

	if (length(l) % 2)
		push(bad, l[-1][0] ?? '');

	return bad;
}

const SNMP6_WHOLE = {
	Ip6InOctets: true, Ip6OutOctets: true, Icmp6InMsgs: true, Icmp6OutMsgs: true,
	Udp6InDatagrams: true, Udp6OutDatagrams: true, Udp6NoPorts: true, Udp6RcvbufErrors: true, Udp6SndbufErrors: true,
};

function snmp6_name(name) {
	let p = substr(name, 0, 3);
	let n = (p == 'Ip6') ? 3 : (p == 'Icm') ? 5 : (p == 'Udp') ? ((substr(name, 3, 1) == '6') ? 4 : 8) : 0;

	if (!n || length(name) <= n)
		return null;

	p = substr(name, 0, n);

	return (p == 'Ip6' || p == 'Icmp6' || p == 'Udp6' || p == 'UdpLite6') ? [ name, p, substr(name, n) ] : null;
}

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

	if (!readable)
		return Result.err(errors.SOURCE_UNREADABLE, join(', ', sources));
	if (length(invalid))
		return Result.err(errors.SOURCE_INVALID, join('; ', invalid));

	return Result.ok();
};

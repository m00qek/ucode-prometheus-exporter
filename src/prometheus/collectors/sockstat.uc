'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

export const meta = {
	name: 'sockstat',
	title: 'Sockets',
	help: 'Sockets in use per protocol (TCP, UDP, raw, fragments) and the memory they hold, from /proc/net/sockstat and /proc/net/sockstat6, as node_exporter has them.',
	needs: [ 'fs' ],
};

export const SOCKSTAT = '/proc/net/sockstat';
export const SOCKSTAT6 = '/proc/net/sockstat6';
export const AUXV = '/proc/self/auxv';

const KEYS = [ 'inuse', 'orphan', 'tw', 'alloc', 'mem', 'memory' ];

export function page_size(s) {
	return proc.auxv(s)?.[proc.AT_PAGESZ];
};

export function parse(rows) {
	let res = { used: null, protocols: [] };

	for (let i, line in rows) {
		let f = split(line, ' ');

		if (length(f) < 3 || length(f) % 2 == 0)
			return `line ${i + 1}: ${sprintf('%J', line)}`;

		let values = {};
		for (let j = 1; j < length(f); j += 2) {
			let n = +f[j + 1];

			if (type(n) != 'int')
				return `line ${i + 1}: ${sprintf('%J', line)}`;
			values[f[j]] = n;
		}

		let protocol = rtrim(f[0], ':');

		if (protocol == 'sockets')
			res.used = values.used ?? 0;
		else
			push(res.protocols, { protocol, values });
	}

	return res;
};

function read(fs, path, optional) {
	let rows = proc.lines(fs, path);

	if (rows == null)
		return (optional && fs.stat(path) == null) ? null : Result.err(errors.SOURCE_UNREADABLE, path);

	let res = parse(rows);

	return type(res) == 'string' ? Result.err(errors.SOURCE_INVALID, `${path}: ${res}`) : res;
}

function gauge(out, protocol, key, n) {
	out.gauge(`node_sockstat_${protocol}_${key}`, `Number of ${protocol} sockets in state ${key}.`)(null, n);
}

function record(out, stat, page) {
	if (stat.used != null)
		out.gauge('node_sockstat_sockets_used', 'Number of IPv4 sockets in use.')(null, stat.used);

	for (let p in stat.protocols) {
		let v = p.values;

		for (let key in KEYS)
			if (key in v || key == 'inuse')
				gauge(out, p.protocol, key, v[key] ?? 0);

		if ('mem' in v && page != null)
			gauge(out, p.protocol, 'mem_bytes', v.mem * page);
	}
}

function has_mem(stats) {
	for (let s in stats)
		for (let p in s?.protocols ?? [])
			if ('mem' in p.values)
				return true;

	return false;
}

export function collect(deps, out) {
	let v4 = read(deps.fs, SOCKSTAT, false);
	let v6 = read(deps.fs, SOCKSTAT6, true);

	for (let r in [ v4, v6 ])
		if (Result.is(r))
			return r;

	let page = has_mem([ v4, v6 ]) ? page_size(deps.fs.readfile(AUXV)) : null;

	record(out, v4, page);
	if (v6)
		record(out, v6, page);

	return Result.ok();
};

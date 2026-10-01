'use strict';

// node_exporter's sockstat collector (collector/sockstat_linux.go, over
// procfs's NetSockstat): the sockets of each protocol of /proc/net/sockstat
// and, where the kernel has IPv6, /proc/net/sockstat6, as gauges named
// node_sockstat_<protocol>_<key> (node_sockstat_TCP_inuse), and the sockets in
// use, node_sockstat_sockets_used. Each line is a protocol and its key and
// value pairs; of the keys, node_exporter's (inuse, orphan, tw, alloc, mem,
// memory) are exported, and a protocol's inuse is 0 when its line has none,
// as there. `mem` is in pages: node_sockstat_<protocol>_mem_bytes is it in
// bytes, by the page size the kernel gave this process (AT_PAGESZ in
// /proc/self/auxv: 4 KiB on most targets, 16 KiB on loongarch64), and is left
// out where that cannot be read. `memory` (FRAG's) is in bytes already.
//
// A kernel without IPv6 has no /proc/net/sockstat6: its families are not
// there, and the IPv4 ones are, as in node_exporter. A line that is not a
// protocol and pairs of a key and an integer fails the collector, as it fails
// procfs's parser.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { lines } from 'prometheus_exporter.proc';

export const meta = {
	name: 'sockstat',
	title: 'Sockets',
	help: 'Sockets in use per protocol (TCP, UDP, raw, fragments) and the memory they hold, from /proc/net/sockstat and /proc/net/sockstat6, as node_exporter has them.',
	needs: [ 'fs' ],
};

export const SOCKSTAT = '/proc/net/sockstat';
export const SOCKSTAT6 = '/proc/net/sockstat6';
export const AUXV = '/proc/self/auxv';

// The keys node_exporter exports, in its order; mem_bytes comes after.
const KEYS = [ 'inuse', 'orphan', 'tw', 'alloc', 'mem', 'memory' ];

// The auxiliary vector's types (linux/auxvec.h): the vector ends with AT_NULL,
// and no type the kernel defines is as large as AT_MAX.
const AT_NULL = 0;
const AT_PAGESZ = 6;
const AT_MAX = 64;

// The layouts an auxiliary vector may have: [ bytes of a word, little-endian ].
const LAYOUTS = [ [ 8, true ], [ 4, true ], [ 8, false ], [ 4, false ] ];

function word(s, at, size, le) {
	let v = 0;

	for (let i = 0; i < size; i++)
		v = v * 256 + ord(s, le ? at + size - 1 - i : at + i);

	return v;
}

// AT_PAGESZ of an auxiliary vector as /proc/self/auxv gives it: pairs of
// words (a type, a value) in the process's own word size and byte order,
// which nothing says, ending with AT_NULL. The layout is the one by which
// every type is one the kernel could define, the vector ends at AT_NULL and
// AT_PAGESZ is a power of two; any other reads a value or an address as a
// type, and stops at its first. Null when none fits.
export function page_size(s) {
	let n = length(s ?? '');

	for (let l in LAYOUTS) {
		let size = l[0], le = l[1], pair = size * 2, ps = null;

		if (!n || n % pair)
			continue;

		for (let at = 0; at < n; at += pair) {
			let t = word(s, at, size, le);

			if (t >= AT_MAX || t < 0)
				break;
			if (t == AT_PAGESZ)
				ps = word(s, at + size, size, le);
			if (t == AT_NULL) {
				if (at + pair == n && ps >= 1024 && !(ps & (ps - 1)))
					return ps;
				break;
			}
		}
	}

	return null;
};

// A file's lines as { used, protocols: [ { protocol, values: { key: n } } ] };
// or a string saying what is wrong with its first malformed line.
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

// The parsed file at `path`; null where `optional` and it is not there; or a
// Result.err.
function read(fs, path, optional) {
	let rows = lines(fs, path);

	if (rows == null)
		return (optional && fs.stat(path) == null) ? null : Result.err(errors.SOURCE_UNREADABLE, path);

	let res = parse(rows);

	return type(res) == 'string' ? Result.err(errors.SOURCE_INVALID, `${path}: ${res}`) : res;
}

// node_exporter's help, for every key.
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

// Whether a protocol of `stats` counts its memory in pages.
function has_mem(stats) {
	for (let s in stats)
		for (let p in s?.protocols ?? [])
			if ('mem' in p.values)
				return true;

	return false;
}

export function collect(deps, out) {
	// IPv4's file is there whenever procfs is; IPv6's only where the kernel has IPv6.
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

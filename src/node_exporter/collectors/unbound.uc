'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/unbound.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Unbound's statistics, as the Lua exporter's unbound collector reads them: the
// stats_noreset command of unbound's remote control, asked on its Unix control
// socket (what `unbound-control stats_noreset` prints, without resetting the
// counters). They are named as letsencrypt/unbound_exporter names them, so its
// dashboards work: the counters of each thread (threadN.*) with a `thread`
// label, and the recursion times of total.*. Where that exporter's name breaks
// the conventions (a counter without _total), _total is added; a time is in
// seconds. time.*, the per-thread TCP buffer usage and the extended statistics
// are left out.
//
// Unbound answers there only when its config has a `remote-control:` clause
// with `control-enable: yes` and a path as `control-interface` (see the
// `socket` option). A reply line that is not name=value (unbound answers
// "error ..." to a command it refuses) ends the reading and fails the
// collector, as does a counter that is not a number; the counters read before
// are kept.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { format_value } from 'node_exporter.exposition';

// The directory of a socket's path: '/' for one at the root.
export function socket_dir(path) {
	let dir = replace(path, /\/[^\/]*$/, '');

	return dir == '' ? '/' : dir;
};

export const meta = {
	name: 'unbound',
	title: 'Unbound DNS resolver',
	help: 'Unbound DNS resolver statistics, from its remote control socket.',
	needs: [ 'socket' ],
	// OpenWrt's unbound package never makes a Unix control socket: its UCI
	// option unbound_control writes `control-interface: 127.0.0.1` and `::1`
	// (levels 1 and 2) or all addresses (3 and 4), and nothing at all by default
	// (0); net/unbound/files/unbound.sh, unbound_control(). So the path is set
	// by hand in /etc/unbound/unbound_ext.conf, and the default is the Lua
	// collector's /run/unbound.ctl: a device set up for it keeps working. On
	// OpenWrt /run links to /var/run (base-files' boot), beside unbound's
	// pidfile, and unbound makes the socket before it enters its chroot.
	options: {
		socket: { default: '/run/unbound.ctl', datatype: 'file', help: 'Unbound\'s control socket, in a directory of its own.' },
	},
	// The socket's directory: the jail cannot mount a socket itself, and
	// unbound makes it anew each start. A directory that holds every
	// service's (/run) is not mounted: the socket then needs one of its own.
	paths: [ (options) => [ socket_dir(options.socket) ] ],
};

// The Lua collector's wait for the reply, one second.
const TIMEOUT_MS = 1000;

// [ key, family, type, help, scale ] of the per-thread statistics, in unbound's
// order (daemon/remote.c, print_stats), keys without their threadN.
const THREAD = [
	[ 'num.queries', 'unbound_queries_total', 'counter', 'Total number of queries received.' ],
	[ 'num.queries_ip_ratelimited', 'unbound_queries_ip_ratelimited_total', 'counter', 'Total number of queries rate limited.' ],
	[ 'num.queries_cookie_valid', 'unbound_queries_cookie_valid_total', 'counter', 'Total number of queries with a valid cookie.' ],
	[ 'num.queries_cookie_client', 'unbound_queries_cookie_client_total', 'counter', 'Total number of queries with a client cookie.' ],
	[ 'num.queries_cookie_invalid', 'unbound_queries_cookie_invalid_total', 'counter', 'Total number of queries with an invalid cookie.' ],
	[ 'num.queries_discard_timeout', 'unbound_queries_discard_timeout_total', 'counter', 'Total number of queries removed due to discard-timeout.' ],
	[ 'num.queries_replyaddr_limit', 'unbound_queries_replyaddr_limit_total', 'counter', 'Total number of queries removed due to replyaddr limits.' ],
	[ 'num.queries_wait_limit', 'unbound_queries_wait_limit_total', 'counter', 'Total number of queries removed due to wait-limit.' ],
	[ 'num.cachehits', 'unbound_cache_hits_total', 'counter', 'Total number of queries that were successfully answered using a cache lookup.' ],
	[ 'num.cachemiss', 'unbound_cache_misses_total', 'counter', 'Total number of cache queries that needed recursive processing.' ],
	[ 'num.prefetch', 'unbound_prefetches_total', 'counter', 'Total number of cache prefetches performed.' ],
	[ 'num.queries_timed_out', 'unbound_queries_timed_out_total', 'counter', 'Total number of queries dropped after waiting too long in the socket buffer.' ],
	[ 'query.queue_time_us.max', 'unbound_query_queue_time_seconds_max', 'gauge', 'Longest wait of a query in the socket buffer, in seconds.', 0.000001 ],
	[ 'num.expired', 'unbound_expired_total', 'counter', 'Total number of expired entries served.' ],
	[ 'num.recursivereplies', 'unbound_recursive_replies_total', 'counter', 'Total number of replies sent to queries that needed recursive processing.' ],
	[ 'num.dns_error_reports', 'unbound_dns_error_reports_total', 'counter', 'Total number of DNS Error Reports generated.' ],
	[ 'requestlist.avg', 'unbound_request_list_avg', 'gauge', 'Average size of the request list when a recursive query is added.' ],
	[ 'requestlist.max', 'unbound_request_list_max', 'gauge', 'Largest size of the request list.' ],
	[ 'requestlist.overwritten', 'unbound_request_list_overwritten_total', 'counter', 'Total number of requests in the request list that were overwritten by newer entries.' ],
	[ 'requestlist.exceeded', 'unbound_request_list_exceeded_total', 'counter', 'Number of queries that were dropped because the request list was full.' ],
	[ 'requestlist.current.all', 'unbound_request_list_current_all', 'gauge', 'Current size of the request list, including internally generated queries.' ],
	[ 'requestlist.current.user', 'unbound_request_list_current_user', 'gauge', 'Current size of the request list, only counting the requests from client queries.' ],
	[ 'requestlist.current.replies', 'unbound_request_list_current_replies', 'gauge', 'Current count of the number of reply entries waiting on request list entries.' ],
];

// The same of the statistics of all threads that are exported, keys whole.
const TOTAL = [
	[ 'total.recursion.time.avg', 'unbound_recursion_time_seconds_avg', 'gauge', 'Average time it took to answer queries that needed recursive processing (does not include in-cache requests).' ],
	[ 'total.recursion.time.median', 'unbound_recursion_time_seconds_median', 'gauge', 'The median of the time it took to answer queries that needed recursive processing.' ],
];

// { values, threads, bad } of a stats reply: its name=value lines as values
// (the first of a name), and the threads they name, in order, up to `bad`, the
// first other line, or null.
function parse(reply) {
	let values = {};
	let threads = [];

	for (let line in split(reply, '\n')) {
		line = rtrim(line, '\r');
		if (line == '')
			continue;

		let m = match(line, /^([^=]+)=(.+)$/);
		if (!m)
			return { values, threads, bad: line };

		values[m[1]] ??= m[2];

		let t = match(m[1], /^thread([0-9]+)\./);
		if (t && !(t[1] in threads))
			push(threads, t[1]);
	}

	return { values, threads, bad: null };
}

export function collect(deps, out, options) {
	let path = options.socket;
	let res = deps.socket.unix_request(path, 'UBCT1 stats_noreset\n', TIMEOUT_MS);

	if (!res.ok)
		return res;

	let p = parse(res.data);
	let bad = null;

	// One sample of a family; a value that is not a number fails the collector.
	function record(sample, key, labels, scale) {
		let v = p.values[key];

		if (v == null)
			return;
		if (format_value(v) == null) {
			bad ??= `${key}=${v}`;
			return;
		}

		sample(labels, scale ? +v * scale : v);
	}

	for (let f in THREAD) {
		let sample = out[f[2]](f[1], f[3]);

		for (let thread in p.threads)
			record(sample, `thread${thread}.${f[0]}`, { thread }, f[4]);
	}

	for (let f in TOTAL)
		record(out[f[2]](f[1], f[3]), f[0], null, f[4]);

	bad = p.bad ?? bad;

	if (bad != null)
		return Result.err(errors.SOURCE_INVALID, `${path}: ${sprintf('%J', bad)}`);

	if (!length(p.values))
		return Result.err(errors.SOURCE_INVALID, `${path}: empty reply`);

	return Result.ok();
};

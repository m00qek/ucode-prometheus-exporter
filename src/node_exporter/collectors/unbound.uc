'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/unbound.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Unbound's statistics, as the Lua exporter's unbound collector: the
// stats_noreset command of unbound's remote control, asked on its Unix control
// socket (what `unbound-control stats_noreset` prints, without resetting the
// counters), and its total.* counters as the Lua collector's 23 families. The
// per-thread counters, time.* and extended statistics are left out.
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

export const meta = {
	name: 'unbound',
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
	options: { socket: '/run/unbound.ctl' },
};

// The Lua collector's wait for the reply, one second.
const TIMEOUT_MS = 1000;

// [ key, family, type, help ], in unbound's order (daemon/remote.c, print_stats).
const COUNTERS = [
	[ 'total.num.queries', 'unbound_num_queries_total', 'counter', 'Queries received.' ],
	[ 'total.num.queries_ip_ratelimited', 'unbound_num_queries_ip_ratelimited_total', 'counter', 'Queries rate limited.' ],
	[ 'total.num.queries_cookie_valid', 'unbound_num_queries_cookie_valid_total', 'counter', 'Queries with a valid DNS Cookie.' ],
	[ 'total.num.queries_cookie_client', 'unbound_num_queries_cookie_client_total', 'counter', 'Queries with only the client part of a DNS Cookie.' ],
	[ 'total.num.queries_cookie_invalid', 'unbound_num_queries_cookie_invalid_total', 'counter', 'Queries with an invalid DNS Cookie.' ],
	[ 'total.num.queries_discard_timeout', 'unbound_num_queries_discard_timeout_total', 'counter', 'Queries removed due to discard-timeout.' ],
	[ 'total.num.queries_wait_limit', 'unbound_num_queries_wait_limit_total', 'counter', 'Queries removed due to wait-limit.' ],
	[ 'total.num.cachehits', 'unbound_cachehits_total', 'counter', 'Queries answered from the cache.' ],
	[ 'total.num.cachemiss', 'unbound_cachemiss_total', 'counter', 'Queries that needed recursive processing.' ],
	[ 'total.num.prefetch', 'unbound_prefetch_total', 'counter', 'Cache prefetches performed.' ],
	[ 'total.num.queries_timed_out', 'unbound_num_queries_timed_out_total', 'counter', 'Queries dropped after waiting too long in the socket buffer.' ],
	[ 'total.query.queue_time_us.max', 'unbound_query_queue_time_us_max', 'gauge', 'Longest wait of a query in the socket buffer, in microseconds.' ],
	[ 'total.num.expired', 'unbound_num_expired_total', 'counter', 'Replies that served an expired cache entry.' ],
	[ 'total.num.recursivereplies', 'unbound_num_recursivereplies_total', 'counter', 'Replies sent to queries that needed recursive processing.' ],
	[ 'total.num.dns_error_reports', 'unbound_num_dns_error_reports_total', 'counter', 'DNS Error Reports generated.' ],
	[ 'total.requestlist.avg', 'unbound_requestlist_avg', 'gauge', 'Average size of the request list when a recursive query is added.' ],
	[ 'total.requestlist.max', 'unbound_requestlist_max', 'gauge', 'Largest size of the request list.' ],
	[ 'total.requestlist.overwritten', 'unbound_requestlist_overwritten_total', 'counter', 'Requests in the request list overwritten by newer ones.' ],
	[ 'total.requestlist.exceeded', 'unbound_requestlist_exceeded_total', 'counter', 'Queries dropped because the request list was full.' ],
	[ 'total.requestlist.current.all', 'unbound_requestlist_current_all', 'gauge', 'Current size of the request list, internal queries included.' ],
	[ 'total.requestlist.current.user', 'unbound_requestlist_current_user', 'gauge', 'Current size of the request list, client queries only.' ],
	[ 'total.recursion.time.avg', 'unbound_recursion_time_avg', 'gauge', 'Average time to answer a query that needed recursive processing, in seconds.' ],
	[ 'total.recursion.time.median', 'unbound_recursion_time_median', 'gauge', 'Median time to answer a query that needed recursive processing, in seconds.' ],
];

// { values, bad } of a stats reply: its name=value lines as values (the first
// of a name), up to `bad`, the first other line, or null.
function parse(reply) {
	let values = {};

	for (let line in split(reply, '\n')) {
		line = rtrim(line, '\r');
		if (line == '')
			continue;

		let m = match(line, /^([^=]+)=(.+)$/);
		if (!m)
			return { values, bad: line };

		values[m[1]] ??= m[2];
	}

	return { values, bad: null };
}

export function collect(deps, out, options) {
	let path = options.socket;
	let res = deps.socket.unix_request(path, 'UBCT1 stats_noreset\n', TIMEOUT_MS);

	if (!res.ok)
		return res;

	let p = parse(res.data);
	let bad = p.bad;

	for (let c in COUNTERS) {
		let v = p.values[c[0]];

		if (v == null)
			continue;

		if (format_value(v) == null) {
			bad ??= `${c[0]}=${v}`;
			continue;
		}

		let family = (c[2] == 'counter') ? out.counter : out.gauge;
		family(c[1], c[3])(null, v);
	}

	if (bad != null)
		return Result.err(errors.SOURCE_INVALID, `${path}: ${sprintf('%J', bad)}`);

	if (!length(p.values))
		return Result.err(errors.SOURCE_INVALID, `${path}: empty reply`);

	return Result.ok();
};

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
// seconds. time.* and the per-thread TCP buffer usage are left out.
//
// With `extended-statistics: yes` in unbound's config (OpenWrt's UCI option
// extended_stats), the reply goes on with what that exporter has of it too,
// written where the reply has it (EXTENDED, LABELED): the queries by type,
// class, opcode, header flag and transport, the answers by rcode and DNSSEC
// result, the caches' sizes and memory, the modules' memory, the unwanted
// traffic, and the recursion times' histogram, unbound_response_time_seconds,
// as that exporter makes it: unbound's buckets, which hold each a range,
// summed into Prometheus's, which hold all below their bound, and the sum the
// average recursion time times the count. Unbound leaves out a type, class,
// opcode or rcode no query had (stat_inhibit_zero), so their series come as
// the queries do. What that exporter does not have (the stream and HTTP
// buffers' memory, the caches' lock collisions, dnscrypt's) is left out.
//
// Unbound answers there only when its config has a `remote-control:` clause
// with `control-enable: yes` and a path as `control-interface` (see the
// `socket` option). A reply line that is not name=value (unbound answers
// "error ..." to a command it refuses) ends the reading and fails the
// collector, as does a counter that is not a number; the counters read before
// are kept.
//
// Unbound disabled (its init script), or not installed, is nothing to
// observe: the socket is asked first, and rpcd's rc only when it fails.
// Enabled, a socket that does not answer is a failure.

import { Result, errors, services, exposition } from 'prometheus_exporter.api';

// The directory of a socket's path: '/' for one at the root.
export function socket_dir(path) {
	let dir = replace(path, /\/[^\/]*$/, '');

	return dir == '' ? '/' : dir;
};

export const meta = {
	name: 'unbound',
	title: 'Unbound DNS resolver',
	help: 'Unbound DNS resolver statistics, from its remote control socket.',
	needs: [ 'socket', 'ubus' ],
	// rc list: whether its service is enabled (the API's services).
	ubus: { rc: [ 'list' ] },
	// Unbound's control socket is srw-rw---- unbound:unbound.
	groups: [ 'unbound' ],
	// OpenWrt's unbound package never makes a Unix control socket: its UCI
	// option unbound_control writes `control-interface: 127.0.0.1` and `::1`
	// (levels 1 and 2) or all addresses (3 and 4), and nothing at all by default
	// (0); net/unbound/files/unbound.sh, unbound_control(). So the path is set
	// by hand, in /etc/unbound/unbound_ext.conf:
	//
	//   remote-control:
	//     control-enable: yes
	//     control-interface: /var/lib/unbound/unbound.ctl
	//
	// /var/lib/unbound is the one directory the package makes, and unbound's
	// alone: its init script makes it and hands it to unbound at each start,
	// and it is unbound's chroot. unbound makes the socket there, as root before
	// it enters the chroot (srw-rw---- unbound:unbound, which root reads). The
	// Lua collector's /run/unbound.ctl cannot be had in the jail: /run holds
	// every service's.
	options: {
		socket: {
			default: '/var/lib/unbound/unbound.ctl',
			title: 'Control socket',
			datatype: 'file',
			help: 'Unbound\'s control socket (control-interface), in a directory the jail can mount: not one every service shares, such as /run.',
		},
	},
	// The socket's directory: the jail cannot mount a socket itself, and
	// unbound makes it anew each start. A directory that holds every
	// service's (/run) is not mounted. At boot unbound starts after the
	// exporter, and makes the directory then: the service mounts it once it
	// is there (see prometheus_exporter.watch).
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

// The extended statistics of a key of their own, as letsencrypt/unbound_exporter
// names them: { key: [ family, type, help ] }.
const EXTENDED = {
	'num.query.tcp': [ 'unbound_query_tcp_total', 'counter', 'Total number of queries that were made using TCP towards the Unbound server.' ],
	'num.query.tcpout': [ 'unbound_query_tcpout_total', 'counter', 'Total number of queries that the Unbound server made using TCP outgoing towards other servers.' ],
	'num.query.udpout': [ 'unbound_query_udpout_total', 'counter', 'Total number of queries that the Unbound server made using UDP outgoing towards other servers.' ],
	'num.query.tls': [ 'unbound_query_tls_total', 'counter', 'Total number of queries that were made using TCP TLS towards the Unbound server.' ],
	'num.query.tls.resume': [ 'unbound_query_tls_resume_total', 'counter', 'Total number of queries that were made using TCP TLS Resume towards the Unbound server.' ],
	'num.query.https': [ 'unbound_query_https_total', 'counter', 'Total number of queries that were made using HTTPS towards the Unbound server.' ],
	'num.query.ipv6': [ 'unbound_query_ipv6_total', 'counter', 'Total number of queries that were made using IPv6 towards the Unbound server.' ],
	'num.query.edns.present': [ 'unbound_query_edns_present_total', 'counter', 'Total number of queries that had an EDNS OPT record present.' ],
	'num.query.edns.DO': [ 'unbound_query_edns_DO_total', 'counter', 'Total number of queries that had an EDNS OPT record with the DO (DNSSEC OK) bit set present.' ],
	'num.query.subnet': [ 'unbound_query_subnet_total', 'counter', 'Total number of queries that got an answer that contained EDNS client subnet data.' ],
	'num.query.subnet_cache': [ 'unbound_query_subnet_cache_total', 'counter', 'Total number of queries answered from the edns client subnet cache.' ],
	'num.query.cachedb': [ 'unbound_query_cachedb_total', 'counter', 'Total number of queries answered from cachedb.' ],
	'num.query.authzone.up': [ 'unbound_query_authzone_up_total', 'counter', 'Total number of queries answered from auth-zone data, upstream queries.' ],
	'num.query.authzone.down': [ 'unbound_query_authzone_down_total', 'counter', 'Total number of queries answered from auth-zone data, downstream queries.' ],
	'num.answer.secure': [ 'unbound_answers_secure_total', 'counter', 'Total number of answers that were secure.' ],
	'num.answer.bogus': [ 'unbound_answers_bogus_total', 'counter', 'Total number of answers that were bogus.' ],
	'num.rrset.bogus': [ 'unbound_rrset_bogus_total', 'counter', 'Total number of rrsets marked bogus by the validator.' ],
	'unwanted.queries': [ 'unbound_unwanted_queries_total', 'counter', 'Total number of queries that were refused or dropped because they failed the access control settings.' ],
	'unwanted.replies': [ 'unbound_unwanted_replies_total', 'counter', 'Total number of replies that were unwanted or unsolicited.' ],
	'msg.cache.count': [ 'unbound_msg_cache_count', 'gauge', 'The Number of Messages cached' ],
	'rrset.cache.count': [ 'unbound_rrset_cache_count', 'gauge', 'The Number of rrset cached' ],
	'infra.cache.count': [ 'unbound_infra_cache_count', 'gauge', 'The number of infra cache entries' ],
	'key.cache.count': [ 'unbound_key_cache_count', 'gauge', 'The number of key cache entries' ],
	'mem.total.sbrk': [ 'unbound_memory_sbrk_bytes', 'gauge', 'Memory in bytes allocated through sbrk.' ],
};

// Those of a key that ends in a label's value, by its prefix:
// [ prefix, family, type, help, label ].
const LABELED = [
	[ 'num.query.type.', 'unbound_query_types_total', 'counter', 'Total number of queries with a given query type.', 'type' ],
	[ 'num.query.class.', 'unbound_query_classes_total', 'counter', 'Total number of queries with a given query class.', 'class' ],
	[ 'num.query.opcode.', 'unbound_query_opcodes_total', 'counter', 'Total number of queries with a given query opcode.', 'opcode' ],
	[ 'num.query.flags.', 'unbound_query_flags_total', 'counter', 'Total number of queries that had a given flag set in the header.', 'flag' ],
	[ 'num.answer.rcode.', 'unbound_answer_rcodes_total', 'counter', 'Total number of answers to queries, from cache or from recursion, by response code.', 'rcode' ],
	[ 'num.query.aggressive.', 'unbound_query_aggressive_nsec_total', 'counter', 'Total number of queries that the Unbound server generated response using Aggressive NSEC.', 'rcode' ],
	[ 'num.rpz.action.', 'unbound_rpz_action_count_total', 'counter', 'Total number of triggered Response Policy Zone actions, by type.', 'type' ],
	[ 'mem.cache.', 'unbound_memory_caches_bytes', 'gauge', 'Memory in bytes in use by caches.', 'cache' ],
	[ 'mem.mod.', 'unbound_memory_modules_bytes', 'gauge', 'Memory in bytes in use by modules.', 'module' ],
];

// A bucket of the recursion times' histogram: its range's ends, each
// <seconds>.<microseconds>.
const BUCKET = /^histogram\.[0-9]+\.[0-9]+\.to\.([0-9]+\.[0-9]+)$/;

// The exposition text of unbound_response_time_seconds, from `buckets`
// ([ upper bound, count ] of unbound's) and the average recursion time, as
// unbound_exporter makes it; null without buckets.
export function histogram(buckets, avg) {
	if (!length(buckets))
		return null;

	let lines = [ '# HELP unbound_response_time_seconds Query response time in seconds.', '# TYPE unbound_response_time_seconds histogram' ];
	let count = 0;

	for (let b in sort([ ...buckets ], (a, b) => a[0] - b[0])) {
		count += b[1];
		push(lines, `unbound_response_time_seconds_bucket{le="${exposition.format_value(b[0])}"} ${count}`);
	}

	push(lines, `unbound_response_time_seconds_bucket{le="+Inf"} ${count}`,
		`unbound_response_time_seconds_sum ${exposition.format_value((avg ?? 0) * count)}`,
		`unbound_response_time_seconds_count ${count}`);

	return join('\n', lines) + '\n';
};

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
		return services.unless_disabled(deps.ubus, 'unbound', res);

	let p = parse(res.data);
	let bad = null;

	// One sample of a family; a value that is not a number fails the collector.
	function record(sample, key, labels, scale) {
		let v = p.values[key];

		if (v == null)
			return;
		if (exposition.format_value(v) == null) {
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

	// The extended statistics, in the reply's order, where it has them; each
	// family declared once.
	let buckets = [];
	let families = {};
	let family = (name, type, help) => families[name] ??= out[type](name, help);

	for (let key in keys(p.values)) {
		let f = EXTENDED[key];

		if (f) {
			record(family(f[0], f[1], f[2]), key, null);
			continue;
		}

		let m = match(key, BUCKET);
		if (m) {
			if (exposition.format_value(p.values[key]) == null)
				bad ??= `${key}=${p.values[key]}`;
			else
				push(buckets, [ +m[1], +p.values[key] ]);
			continue;
		}

		for (let l in LABELED)
			if (substr(key, 0, length(l[0])) == l[0]) {
				record(family(l[1], l[2], l[3]), key, { [l[4]]: substr(key, length(l[0])) });
				break;
			}
	}

	let text = histogram(buckets, +(p.values['total.recursion.time.avg'] ?? 0));
	if (text != null) {
		let res = out.parse(text);

		if (!res.ok)
			return res;
	}

	bad = p.bad ?? bad;

	if (bad != null)
		return Result.err(errors.SOURCE_INVALID, `${path}: ${sprintf('%J', bad)}`);

	if (!length(p.values))
		return Result.err(errors.SOURCE_INVALID, `${path}: empty reply`);

	return Result.ok();
};

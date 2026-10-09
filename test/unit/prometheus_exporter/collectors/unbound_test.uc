'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, jail_of, outcome } from 'prometheus_exporter.devkit.collector';
import { rc } from 'prometheus_exporter.devkit.rc';
import * as fixtures from 'lib.fixtures';
import * as unbound from 'prometheus_exporter.collectors.unbound';
import { format_value } from 'prometheus_exporter.exposition';

// What unbound 1.26.1 (OpenWrt 25.12's) answers stats_noreset with num-threads 2
// and extended statistics; see test/fixtures/synthetic/SOURCES.
const EXTENDED = fixtures.file('synthetic', '/sockets/unbound.stats_noreset.txt');

// The same without them, as OpenWrt's default config has it: up to time.elapsed.
function basic(reply) {
	let lines = split(reply, '\n');
	let end = 0;

	while (substr(lines[end], 0, 13) != 'time.elapsed=')
		end++;

	return join('\n', slice(lines, 0, end + 1)) + '\n';
}

const STATS = basic(EXTENDED);
const CTL = '/var/lib/unbound/unbound.ctl';

// The families: [ key (without threadN. for a thread's), name, type ].
const FAMILIES = [
	[ 'num.queries', 'unbound_queries_total', 'counter' ],
	[ 'num.queries_ip_ratelimited', 'unbound_queries_ip_ratelimited_total', 'counter' ],
	[ 'num.queries_cookie_valid', 'unbound_queries_cookie_valid_total', 'counter' ],
	[ 'num.queries_cookie_client', 'unbound_queries_cookie_client_total', 'counter' ],
	[ 'num.queries_cookie_invalid', 'unbound_queries_cookie_invalid_total', 'counter' ],
	[ 'num.queries_discard_timeout', 'unbound_queries_discard_timeout_total', 'counter' ],
	[ 'num.queries_replyaddr_limit', 'unbound_queries_replyaddr_limit_total', 'counter' ],
	[ 'num.queries_wait_limit', 'unbound_queries_wait_limit_total', 'counter' ],
	[ 'num.cachehits', 'unbound_cache_hits_total', 'counter' ],
	[ 'num.cachemiss', 'unbound_cache_misses_total', 'counter' ],
	[ 'num.prefetch', 'unbound_prefetches_total', 'counter' ],
	[ 'num.queries_timed_out', 'unbound_queries_timed_out_total', 'counter' ],
	[ 'query.queue_time_us.max', 'unbound_query_queue_time_seconds_max', 'gauge' ],
	[ 'num.expired', 'unbound_expired_total', 'counter' ],
	[ 'num.recursivereplies', 'unbound_recursive_replies_total', 'counter' ],
	[ 'num.dns_error_reports', 'unbound_dns_error_reports_total', 'counter' ],
	[ 'requestlist.avg', 'unbound_request_list_avg', 'gauge' ],
	[ 'requestlist.max', 'unbound_request_list_max', 'gauge' ],
	[ 'requestlist.overwritten', 'unbound_request_list_overwritten_total', 'counter' ],
	[ 'requestlist.exceeded', 'unbound_request_list_exceeded_total', 'counter' ],
	[ 'requestlist.current.all', 'unbound_request_list_current_all', 'gauge' ],
	[ 'requestlist.current.user', 'unbound_request_list_current_user', 'gauge' ],
	[ 'requestlist.current.replies', 'unbound_request_list_current_replies', 'gauge' ],
	[ 'total.recursion.time.avg', 'unbound_recursion_time_seconds_avg', 'gauge' ],
	[ 'total.recursion.time.median', 'unbound_recursion_time_seconds_median', 'gauge' ],
];
// The first PER_THREAD of them are each thread's.
const PER_THREAD = 23;

function with_reply(reply, cb) {
	with_collector(unbound, { socket: { data: { [CTL]: reply } } }, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function brief(res) {
	return { ok: res.ok, error: res.error, details: res.details };
}

describe('collectors.unbound', () => {
	it('exports the counters of each thread of a stats_noreset reply and the total recursion times, with unbound_exporter\'s names', () => {
		let asked = [];

		with_reply((req) => { push(asked, req); return STATS; }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'UBCT1 stats_noreset\n' ], asked);
			assert.match([
				'# HELP unbound_queries_total Total number of queries received.',
				'# TYPE unbound_queries_total counter',
				'unbound_queries_total{thread="0"} 18342',
				'unbound_queries_total{thread="1"} 17905',
				'# HELP unbound_queries_ip_ratelimited_total Total number of queries rate limited.',
				'# TYPE unbound_queries_ip_ratelimited_total counter',
				'unbound_queries_ip_ratelimited_total{thread="0"} 0',
				'unbound_queries_ip_ratelimited_total{thread="1"} 0',
				'# HELP unbound_queries_cookie_valid_total Total number of queries with a valid cookie.',
				'# TYPE unbound_queries_cookie_valid_total counter',
				'unbound_queries_cookie_valid_total{thread="0"} 0',
				'unbound_queries_cookie_valid_total{thread="1"} 0',
				'# HELP unbound_queries_cookie_client_total Total number of queries with a client cookie.',
				'# TYPE unbound_queries_cookie_client_total counter',
				'unbound_queries_cookie_client_total{thread="0"} 0',
				'unbound_queries_cookie_client_total{thread="1"} 0',
				'# HELP unbound_queries_cookie_invalid_total Total number of queries with an invalid cookie.',
				'# TYPE unbound_queries_cookie_invalid_total counter',
				'unbound_queries_cookie_invalid_total{thread="0"} 0',
				'unbound_queries_cookie_invalid_total{thread="1"} 0',
				'# HELP unbound_queries_discard_timeout_total Total number of queries removed due to discard-timeout.',
				'# TYPE unbound_queries_discard_timeout_total counter',
				'unbound_queries_discard_timeout_total{thread="0"} 0',
				'unbound_queries_discard_timeout_total{thread="1"} 0',
				'# HELP unbound_queries_replyaddr_limit_total Total number of queries removed due to replyaddr limits.',
				'# TYPE unbound_queries_replyaddr_limit_total counter',
				'unbound_queries_replyaddr_limit_total{thread="0"} 0',
				'unbound_queries_replyaddr_limit_total{thread="1"} 0',
				'# HELP unbound_queries_wait_limit_total Total number of queries removed due to wait-limit.',
				'# TYPE unbound_queries_wait_limit_total counter',
				'unbound_queries_wait_limit_total{thread="0"} 0',
				'unbound_queries_wait_limit_total{thread="1"} 0',
				'# HELP unbound_cache_hits_total Total number of queries that were successfully answered using a cache lookup.',
				'# TYPE unbound_cache_hits_total counter',
				'unbound_cache_hits_total{thread="0"} 15221',
				'unbound_cache_hits_total{thread="1"} 14917',
				'# HELP unbound_cache_misses_total Total number of cache queries that needed recursive processing.',
				'# TYPE unbound_cache_misses_total counter',
				'unbound_cache_misses_total{thread="0"} 3121',
				'unbound_cache_misses_total{thread="1"} 2988',
				'# HELP unbound_prefetches_total Total number of cache prefetches performed.',
				'# TYPE unbound_prefetches_total counter',
				'unbound_prefetches_total{thread="0"} 412',
				'unbound_prefetches_total{thread="1"} 398',
				'# HELP unbound_queries_timed_out_total Total number of queries dropped after waiting too long in the socket buffer.',
				'# TYPE unbound_queries_timed_out_total counter',
				'unbound_queries_timed_out_total{thread="0"} 0',
				'unbound_queries_timed_out_total{thread="1"} 0',
				'# HELP unbound_query_queue_time_seconds_max Longest wait of a query in the socket buffer, in seconds.',
				'# TYPE unbound_query_queue_time_seconds_max gauge',
				'unbound_query_queue_time_seconds_max{thread="0"} 0',
				'unbound_query_queue_time_seconds_max{thread="1"} 0',
				'# HELP unbound_expired_total Total number of expired entries served.',
				'# TYPE unbound_expired_total counter',
				'unbound_expired_total{thread="0"} 97',
				'unbound_expired_total{thread="1"} 88',
				'# HELP unbound_recursive_replies_total Total number of replies sent to queries that needed recursive processing.',
				'# TYPE unbound_recursive_replies_total counter',
				'unbound_recursive_replies_total{thread="0"} 3119',
				'unbound_recursive_replies_total{thread="1"} 2987',
				'# HELP unbound_dns_error_reports_total Total number of DNS Error Reports generated.',
				'# TYPE unbound_dns_error_reports_total counter',
				'unbound_dns_error_reports_total{thread="0"} 0',
				'unbound_dns_error_reports_total{thread="1"} 0',
				'# HELP unbound_request_list_avg Average size of the request list when a recursive query is added.',
				'# TYPE unbound_request_list_avg gauge',
				'unbound_request_list_avg{thread="0"} 0.535805',
				'unbound_request_list_avg{thread="1"} 0.505611',
				'# HELP unbound_request_list_max Largest size of the request list.',
				'# TYPE unbound_request_list_max gauge',
				'unbound_request_list_max{thread="0"} 14',
				'unbound_request_list_max{thread="1"} 12',
				'# HELP unbound_request_list_overwritten_total Total number of requests in the request list that were overwritten by newer entries.',
				'# TYPE unbound_request_list_overwritten_total counter',
				'unbound_request_list_overwritten_total{thread="0"} 0',
				'unbound_request_list_overwritten_total{thread="1"} 0',
				'# HELP unbound_request_list_exceeded_total Number of queries that were dropped because the request list was full.',
				'# TYPE unbound_request_list_exceeded_total counter',
				'unbound_request_list_exceeded_total{thread="0"} 0',
				'unbound_request_list_exceeded_total{thread="1"} 0',
				'# HELP unbound_request_list_current_all Current size of the request list, including internally generated queries.',
				'# TYPE unbound_request_list_current_all gauge',
				'unbound_request_list_current_all{thread="0"} 1',
				'unbound_request_list_current_all{thread="1"} 0',
				'# HELP unbound_request_list_current_user Current size of the request list, only counting the requests from client queries.',
				'# TYPE unbound_request_list_current_user gauge',
				'unbound_request_list_current_user{thread="0"} 0',
				'unbound_request_list_current_user{thread="1"} 0',
				'# HELP unbound_request_list_current_replies Current count of the number of reply entries waiting on request list entries.',
				'# TYPE unbound_request_list_current_replies gauge',
				'unbound_request_list_current_replies{thread="0"} 0',
				'unbound_request_list_current_replies{thread="1"} 0',
				'# HELP unbound_recursion_time_seconds_avg Average time it took to answer queries that needed recursive processing (does not include in-cache requests).',
				'# TYPE unbound_recursion_time_seconds_avg gauge',
				'unbound_recursion_time_seconds_avg 0.069884',
				'# HELP unbound_recursion_time_seconds_median The median of the time it took to answer queries that needed recursive processing.',
				'# TYPE unbound_recursion_time_seconds_median gauge',
				'unbound_recursion_time_seconds_median 0.040598',
			], r.lines);
		});
	});

	it('has its 25 families, names and types', () => {
		with_reply(STATS, (r) => {
			assert.match(map(FAMILIES, (f) => [ f[1], f[2] ]), map(r.families, (f) => [ f.name, f.type ]));
		});
	});

	it('asks the socket its `socket` option names', () => {
		with_collector(unbound, { socket: { strict: true, data: { '/var/run/unbound/control': 'thread0.num.queries=7\n' } },
			options: { socket: '/var/run/unbound/control' } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'unbound_queries_total{thread="0"} 7' ], samples(r.lines));
		});
	});

	it('ignores the total, time and unknown counters, and carriage returns', () => {
		let reply = 'thread0.num.queries=99\r\ntotal.num.queries=5\r\ntime.up=86412.500113\r\n' +
			'mem.streamwait=0\r\nmsg.cache.max_collisions=1\r\nthread0.tcpusage=3\r\n' +
			'thread0.num.a_counter_unbound_adds_later=8\r\nthread0.num.cachemiss=2\r\n';

		with_reply(reply, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'unbound_queries_total{thread="0"} 99', 'unbound_cache_misses_total{thread="0"} 2' ], samples(r.lines));
		});
	});

	it("exports the extended statistics of a reply that has them, with unbound_exporter's names", () => {
		with_reply(EXTENDED, (r) => {
			let names = map(r.families, (f) => f.name);

			assert.match(true, r.result.ok);
			assert.match([
				'unbound_memory_caches_bytes', 'unbound_memory_modules_bytes', 'unbound_query_types_total', 'unbound_query_classes_total',
				'unbound_query_opcodes_total', 'unbound_query_tcp_total', 'unbound_query_tcpout_total', 'unbound_query_udpout_total',
				'unbound_query_tls_total', 'unbound_query_tls_resume_total', 'unbound_query_https_total', 'unbound_query_ipv6_total',
				'unbound_query_flags_total', 'unbound_query_edns_present_total', 'unbound_query_edns_DO_total', 'unbound_answer_rcodes_total',
				'unbound_answers_secure_total', 'unbound_answers_bogus_total', 'unbound_rrset_bogus_total', 'unbound_query_aggressive_nsec_total',
				'unbound_unwanted_queries_total', 'unbound_unwanted_replies_total', 'unbound_msg_cache_count', 'unbound_rrset_cache_count',
				'unbound_infra_cache_count', 'unbound_key_cache_count', 'unbound_query_authzone_up_total', 'unbound_query_authzone_down_total',
				'unbound_response_time_seconds',
			], slice(names, length(FAMILIES)));
			assert.match(contains([
				'# TYPE unbound_memory_caches_bytes gauge',
				'unbound_memory_caches_bytes{cache="rrset"} 2105348',
				'unbound_memory_caches_bytes{cache="message"} 1340292',
				'unbound_memory_modules_bytes{module="iterator"} 16588',
				'unbound_query_types_total{type="A"} 20113',
				'unbound_query_types_total{type="HTTPS"} 3104',
				'unbound_query_classes_total{class="IN"} 36247',
				'unbound_query_opcodes_total{opcode="QUERY"} 36247',
				'unbound_query_tcp_total 41',
				'unbound_query_flags_total{flag="RD"} 36247',
				'unbound_query_edns_DO_total 1876',
				'unbound_answer_rcodes_total{rcode="NOERROR"} 34877',
				'unbound_answer_rcodes_total{rcode="nodata"} 2930',
				'unbound_answers_secure_total 1209',
				'unbound_query_aggressive_nsec_total{rcode="NXDOMAIN"} 37',
				'unbound_unwanted_replies_total 3',
				'# TYPE unbound_msg_cache_count gauge',
				'unbound_msg_cache_count 4120',
				'unbound_key_cache_count 97',
			]), r.lines);
		});
	});

	it("sums unbound's histogram of recursion times into Prometheus's, as unbound_exporter does", () => {
		with_reply(EXTENDED, (r) => {
			let lines = filter(r.lines, (l) => match(l, /^unbound_response_time_seconds/));

			assert.match(43, length(lines));
			assert.match(contains([
				'unbound_response_time_seconds_bucket{le="1e-06"} 0',
				'unbound_response_time_seconds_bucket{le="0.001024"} 2',
				'unbound_response_time_seconds_bucket{le="0.002048"} 33',
				'unbound_response_time_seconds_bucket{le="0.524288"} 6037',
				'unbound_response_time_seconds_bucket{le="1"} 6089',
				'unbound_response_time_seconds_bucket{le="4"} 6106',
				'unbound_response_time_seconds_bucket{le="524288"} 6106',
				'unbound_response_time_seconds_bucket{le="+Inf"} 6106',
				'unbound_response_time_seconds_sum 426.711704',
				'unbound_response_time_seconds_count 6106',
			]), lines);
		});
	});

	it('writes the histogram of any buckets, in the order of their bounds', () => {
		assert.match('# HELP unbound_response_time_seconds Query response time in seconds.\n' +
			'# TYPE unbound_response_time_seconds histogram\n' +
			'unbound_response_time_seconds_bucket{le="0.5"} 3\n' +
			'unbound_response_time_seconds_bucket{le="2"} 4\n' +
			'unbound_response_time_seconds_bucket{le="+Inf"} 4\n' +
			'unbound_response_time_seconds_sum 1\n' +
			'unbound_response_time_seconds_count 4\n', unbound.histogram([ [ 2, 1 ], [ 0.5, 3 ] ], 0.25));
		assert.match(null, unbound.histogram([], 0.25));
	});

	it('fails with SOURCE_INVALID for a bucket that is not a number, keeping the rest', () => {
		with_reply('thread0.num.queries=5\nhistogram.000000.000000.to.000000.000001=x\nnum.query.tcp=2\n', (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: `${CTL}: "histogram.000000.000000.to.000000.000001=x"` }, brief(r.result));
			assert.match([ 'unbound_queries_total{thread="0"} 5', 'unbound_query_tcp_total 2' ], samples(r.lines));
		});
	});

	it('gives the longest queue time in seconds', () => {
		with_reply('thread3.query.queue_time_us.max=250000\n', (r) => {
			assert.match([ 'unbound_query_queue_time_seconds_max{thread="3"} 0.25' ], samples(r.lines));
		});
	});

	it('has nothing to observe where unbound is disabled, or not installed, and its socket does not answer', () => {
		with_collector(unbound, { socket: { strict: false }, ubus: { data: rc({ unbound: false }) } }, (r) => {
			assert.match({ ok: true, none: 'unbound is disabled', error: null, lines: [], logs: [] }, outcome(r));
		});
		with_collector(unbound, { socket: { strict: false }, ubus: { data: rc({}) } }, (r) => {
			assert.match({ ok: true, none: 'unbound is not installed', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('reads a disabled unbound that runs, and asks rc nothing', () => {
		with_reply('thread0.num.queries=7\n', (r) => {
			assert.match([ true, null, [ 'unbound_queries_total{thread="0"} 7' ] ], [ r.result.ok, r.result.none, samples(r.lines) ]);
		});
	});

	it('fails with SOCKET_FAILED where there is no control socket', () => {
		with_collector(unbound, { socket: { strict: false }, ubus: { data: rc({ unbound: true }) } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: connect(): No such file or directory` }, brief(r.result));
			assert.match([], r.lines);
			assert.match([ `collector 'unbound': SOCKET_FAILED (${CTL}: connect(): No such file or directory)` ], r.logs);
		});
	});

	it('fails with SOCKET_FAILED where unbound refuses the connection', () => {
		with_collector(unbound, { socket: { errors: { [CTL]: 'connect(): Connection refused' } }, ubus: { data: rc({ unbound: true }) } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: connect(): Connection refused` }, brief(r.result));
		});
	});

	it('fails with SOCKET_FAILED when unbound stops answering for a second, keeping nothing', () => {
		with_collector(unbound, { socket: { data: { [CTL]: 'thread0.num.queries=5\n' }, hangs: { [CTL]: true } }, ubus: { data: rc({ unbound: true }) } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: no reply for 1000 ms` }, brief(r.result));
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID at a line that is not name=value, keeping the counters before it', () => {
		with_reply('thread0.num.queries=5\nerror version mismatch\nthread0.num.cachehits=3\n', (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: `${CTL}: "error version mismatch"` }, brief(r.result));
			assert.match([ 'unbound_queries_total{thread="0"} 5' ], samples(r.lines));
		});
	});

	it('fails with SOURCE_INVALID for a counter that is not a number, keeping the others', () => {
		with_reply('thread0.num.queries=lots\nthread0.num.cachehits=3\n', (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: `${CTL}: "thread0.num.queries=lots"` }, brief(r.result));
			assert.match([ 'unbound_cache_hits_total{thread="0"} 3' ], samples(r.lines));
		});
	});

	it('fails with SOURCE_INVALID for an empty reply', () => {
		with_reply('', (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: `${CTL}: empty reply` }, brief(r.result));
		});
	});

	prop('exports every known counter of every thread a reply has, whatever else it has and in any order',
		gen.array(gen.tuple(gen.int(0, PER_THREAD - 1), gen.int(0, 3), gen.int(0, 1099511627776), gen.bool()), { min_len: 1, max_len: 40 }), (rows) => {
			let reply = '';
			let want = {};

			for (let row in rows) {
				let f = FAMILIES[row[0]];
				let key = `thread${row[1]}.${f[0]}`;
				let value = format_value((f[0] == 'query.queue_time_us.max') ? row[2] * 0.000001 : row[2]);

				// The total with the same name, which must not count.
				if (row[3])
					reply += `total.${f[0]}=${row[2] + 1}\n`;
				reply += `${key}=${row[2]}\n`;
				want[key] ??= `${f[1]}{thread="${row[1]}"} ${value}`;
			}

			with_reply(reply, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(values(want)), sort(samples(r.lines)));
			});
		});
});

describe('unbound in the jail', () => {
	it('gets the directory of its socket', () => {
		let j = jail_of(unbound, { options: { socket: '/var/run/unbound/control.sock' } });
		assert.match([ [ '/var/run/unbound' ], [] ], [ j.mounts, j.problems ]);
	});

	it('gets the directory OpenWrt\'s unbound package makes, by default', () => {
		let j = jail_of(unbound, {});
		assert.match([ [ '/var/lib/unbound' ], [], [] ], [ j.mounts, j.missing, j.problems ]);
	});

	it('waits for the directory until unbound makes it', () => {
		let j = jail_of(unbound, { absent: [ '/var/lib/unbound' ] });
		assert.match([ [], [ '/var/lib/unbound' ], [] ], [ j.mounts, j.missing, j.problems ]);
	});

	it('gets nothing for a socket in a directory every service shares, and says so', () => {
		let j = jail_of(unbound, { options: { socket: '/run/unbound.ctl' } });
		assert.match([ [], [ '/run is too broad to mount for one collector' ] ], [ j.mounts, j.problems ]);
	});

	it('takes a socket path\'s directory', () => {
		assert.match([ '/run', '/var/run/unbound', '/', 'x' ], map([ '/run/unbound.ctl', '/var/run/unbound/c', '/c', 'x' ], unbound.socket_dir));
	});
});

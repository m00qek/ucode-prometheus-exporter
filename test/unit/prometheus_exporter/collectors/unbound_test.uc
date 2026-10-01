'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, jail_of } from 'context';
import * as fixtures from 'lib.fixtures';
import * as unbound from 'prometheus_exporter.collectors.unbound';

// What unbound 1.26.1 (OpenWrt 25.12's) answers stats_noreset with num-threads 2
// and no extended statistics; see test/fixtures/synthetic/SOURCES.
const STATS = fixtures.file('synthetic', '/sockets/unbound.stats_noreset.txt');
const CTL = '/run/unbound.ctl';

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

	it('ignores the total, time, extended and unknown counters, and carriage returns', () => {
		let reply = 'thread0.num.queries=99\r\ntotal.num.queries=5\r\ntime.up=86412.500113\r\n' +
			'histogram.000000.000000.to.000000.000001=0\r\nnum.query.type.A=4\r\nthread0.tcpusage=3\r\n' +
			'thread0.num.a_counter_unbound_adds_later=8\r\nthread0.num.cachemiss=2\r\n';

		with_reply(reply, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'unbound_queries_total{thread="0"} 99', 'unbound_cache_misses_total{thread="0"} 2' ], samples(r.lines));
		});
	});

	it('gives the longest queue time in seconds', () => {
		with_reply('thread3.query.queue_time_us.max=250000\n', (r) => {
			assert.match([ 'unbound_query_queue_time_seconds_max{thread="3"} 0.25' ], samples(r.lines));
		});
	});

	it('fails with SOCKET_FAILED where there is no control socket', () => {
		with_collector(unbound, { socket: { strict: false } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: connect(): No such file or directory` }, brief(r.result));
			assert.match([], r.lines);
			assert.match([ `collector 'unbound': SOCKET_FAILED (${CTL}: connect(): No such file or directory)` ], r.logs);
		});
	});

	it('fails with SOCKET_FAILED where unbound refuses the connection', () => {
		with_collector(unbound, { socket: { errors: { [CTL]: 'connect(): Connection refused' } } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: connect(): Connection refused` }, brief(r.result));
		});
	});

	it('fails with SOCKET_FAILED when unbound stops answering for a second, keeping nothing', () => {
		with_collector(unbound, { socket: { data: { [CTL]: 'thread0.num.queries=5\n' }, hangs: { [CTL]: true } } }, (r) => {
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
				let value = (f[0] == 'query.queue_time_us.max') ? row[2] / 1000000.0 : row[2];

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

	it('gets nothing for a socket in a directory every service shares, and says so', () => {
		let j = jail_of(unbound, {});
		assert.match([ [], [ '/run is too broad to mount for one collector' ] ], [ j.mounts, j.problems ]);
	});

	it('takes a socket path\'s directory', () => {
		assert.match([ '/run', '/var/run/unbound', '/', 'x' ], map([ '/run/unbound.ctl', '/var/run/unbound/c', '/c', 'x' ], unbound.socket_dir));
	});
});

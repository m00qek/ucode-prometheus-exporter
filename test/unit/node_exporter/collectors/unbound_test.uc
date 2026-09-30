'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as unbound from 'node_exporter.collectors.unbound';

// What unbound 1.26.1 (OpenWrt 25.12's) answers stats_noreset with num-threads 2
// and no extended statistics; see test/fixtures/synthetic/SOURCES.
const STATS = fixtures.file('synthetic', '/sockets/unbound.stats_noreset.txt');
const CTL = '/run/unbound.ctl';

// The Lua collector's families: [ key, name, type ].
const FAMILIES = [
	[ 'total.num.queries', 'unbound_num_queries_total', 'counter' ],
	[ 'total.num.queries_ip_ratelimited', 'unbound_num_queries_ip_ratelimited_total', 'counter' ],
	[ 'total.num.queries_cookie_valid', 'unbound_num_queries_cookie_valid_total', 'counter' ],
	[ 'total.num.queries_cookie_client', 'unbound_num_queries_cookie_client_total', 'counter' ],
	[ 'total.num.queries_cookie_invalid', 'unbound_num_queries_cookie_invalid_total', 'counter' ],
	[ 'total.num.queries_discard_timeout', 'unbound_num_queries_discard_timeout_total', 'counter' ],
	[ 'total.num.queries_wait_limit', 'unbound_num_queries_wait_limit_total', 'counter' ],
	[ 'total.num.cachehits', 'unbound_cachehits_total', 'counter' ],
	[ 'total.num.cachemiss', 'unbound_cachemiss_total', 'counter' ],
	[ 'total.num.prefetch', 'unbound_prefetch_total', 'counter' ],
	[ 'total.num.queries_timed_out', 'unbound_num_queries_timed_out_total', 'counter' ],
	[ 'total.query.queue_time_us.max', 'unbound_query_queue_time_us_max', 'gauge' ],
	[ 'total.num.expired', 'unbound_num_expired_total', 'counter' ],
	[ 'total.num.recursivereplies', 'unbound_num_recursivereplies_total', 'counter' ],
	[ 'total.num.dns_error_reports', 'unbound_num_dns_error_reports_total', 'counter' ],
	[ 'total.requestlist.avg', 'unbound_requestlist_avg', 'gauge' ],
	[ 'total.requestlist.max', 'unbound_requestlist_max', 'gauge' ],
	[ 'total.requestlist.overwritten', 'unbound_requestlist_overwritten_total', 'counter' ],
	[ 'total.requestlist.exceeded', 'unbound_requestlist_exceeded_total', 'counter' ],
	[ 'total.requestlist.current.all', 'unbound_requestlist_current_all', 'gauge' ],
	[ 'total.requestlist.current.user', 'unbound_requestlist_current_user', 'gauge' ],
	[ 'total.recursion.time.avg', 'unbound_recursion_time_avg', 'gauge' ],
	[ 'total.recursion.time.median', 'unbound_recursion_time_median', 'gauge' ],
];

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
	it('exports the total counters of a stats_noreset reply, with the Lua names and types', () => {
		let asked = [];

		with_reply((req) => { push(asked, req); return STATS; }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'UBCT1 stats_noreset\n' ], asked);
			assert.match([
				'# HELP unbound_num_queries_total Queries received.',
				'# TYPE unbound_num_queries_total counter',
				'unbound_num_queries_total 36247',
				'# HELP unbound_num_queries_ip_ratelimited_total Queries rate limited.',
				'# TYPE unbound_num_queries_ip_ratelimited_total counter',
				'unbound_num_queries_ip_ratelimited_total 0',
				'# HELP unbound_num_queries_cookie_valid_total Queries with a valid DNS Cookie.',
				'# TYPE unbound_num_queries_cookie_valid_total counter',
				'unbound_num_queries_cookie_valid_total 0',
				'# HELP unbound_num_queries_cookie_client_total Queries with only the client part of a DNS Cookie.',
				'# TYPE unbound_num_queries_cookie_client_total counter',
				'unbound_num_queries_cookie_client_total 0',
				'# HELP unbound_num_queries_cookie_invalid_total Queries with an invalid DNS Cookie.',
				'# TYPE unbound_num_queries_cookie_invalid_total counter',
				'unbound_num_queries_cookie_invalid_total 0',
				'# HELP unbound_num_queries_discard_timeout_total Queries removed due to discard-timeout.',
				'# TYPE unbound_num_queries_discard_timeout_total counter',
				'unbound_num_queries_discard_timeout_total 0',
				'# HELP unbound_num_queries_wait_limit_total Queries removed due to wait-limit.',
				'# TYPE unbound_num_queries_wait_limit_total counter',
				'unbound_num_queries_wait_limit_total 0',
				'# HELP unbound_cachehits_total Queries answered from the cache.',
				'# TYPE unbound_cachehits_total counter',
				'unbound_cachehits_total 30138',
				'# HELP unbound_cachemiss_total Queries that needed recursive processing.',
				'# TYPE unbound_cachemiss_total counter',
				'unbound_cachemiss_total 6109',
				'# HELP unbound_prefetch_total Cache prefetches performed.',
				'# TYPE unbound_prefetch_total counter',
				'unbound_prefetch_total 810',
				'# HELP unbound_num_queries_timed_out_total Queries dropped after waiting too long in the socket buffer.',
				'# TYPE unbound_num_queries_timed_out_total counter',
				'unbound_num_queries_timed_out_total 0',
				'# HELP unbound_query_queue_time_us_max Longest wait of a query in the socket buffer, in microseconds.',
				'# TYPE unbound_query_queue_time_us_max gauge',
				'unbound_query_queue_time_us_max 0',
				'# HELP unbound_num_expired_total Replies that served an expired cache entry.',
				'# TYPE unbound_num_expired_total counter',
				'unbound_num_expired_total 185',
				'# HELP unbound_num_recursivereplies_total Replies sent to queries that needed recursive processing.',
				'# TYPE unbound_num_recursivereplies_total counter',
				'unbound_num_recursivereplies_total 6106',
				'# HELP unbound_num_dns_error_reports_total DNS Error Reports generated.',
				'# TYPE unbound_num_dns_error_reports_total counter',
				'unbound_num_dns_error_reports_total 0',
				'# HELP unbound_requestlist_avg Average size of the request list when a recursive query is added.',
				'# TYPE unbound_requestlist_avg gauge',
				'unbound_requestlist_avg 0.521029',
				'# HELP unbound_requestlist_max Largest size of the request list.',
				'# TYPE unbound_requestlist_max gauge',
				'unbound_requestlist_max 14',
				'# HELP unbound_requestlist_overwritten_total Requests in the request list overwritten by newer ones.',
				'# TYPE unbound_requestlist_overwritten_total counter',
				'unbound_requestlist_overwritten_total 0',
				'# HELP unbound_requestlist_exceeded_total Queries dropped because the request list was full.',
				'# TYPE unbound_requestlist_exceeded_total counter',
				'unbound_requestlist_exceeded_total 0',
				'# HELP unbound_requestlist_current_all Current size of the request list, internal queries included.',
				'# TYPE unbound_requestlist_current_all gauge',
				'unbound_requestlist_current_all 1',
				'# HELP unbound_requestlist_current_user Current size of the request list, client queries only.',
				'# TYPE unbound_requestlist_current_user gauge',
				'unbound_requestlist_current_user 0',
				'# HELP unbound_recursion_time_avg Average time to answer a query that needed recursive processing, in seconds.',
				'# TYPE unbound_recursion_time_avg gauge',
				'unbound_recursion_time_avg 0.069884',
				'# HELP unbound_recursion_time_median Median time to answer a query that needed recursive processing, in seconds.',
				'# TYPE unbound_recursion_time_median gauge',
				'unbound_recursion_time_median 0.040598',
			], r.lines);
		});
	});

	it('has the Lua collector\'s 23 families, names and types', () => {
		with_reply(STATS, (r) => {
			assert.match(map(FAMILIES, (f) => [ f[1], f[2] ]), map(r.families, (f) => [ f.name, f.type ]));
		});
	});

	it('asks the socket its `socket` option names', () => {
		with_collector(unbound, { socket: { strict: true, data: { '/var/run/unbound/control': 'total.num.queries=7\n' } },
			options: { socket: '/var/run/unbound/control' } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'unbound_num_queries_total 7' ], samples(r.lines));
		});
	});

	it('ignores the per-thread, time, extended and unknown counters, and carriage returns', () => {
		let reply = 'thread0.num.queries=99\r\ntotal.num.queries=5\r\ntime.up=86412.500113\r\n' +
			'histogram.000000.000000.to.000000.000001=0\r\nnum.query.type.A=4\r\ntotal.num.queries_replyaddr_limit=3\r\n' +
			'total.num.a_counter_unbound_adds_later=8\r\ntotal.num.cachemiss=2\r\n';

		with_reply(reply, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'unbound_num_queries_total 5', 'unbound_cachemiss_total 2' ], samples(r.lines));
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
		with_collector(unbound, { socket: { data: { [CTL]: 'total.num.queries=5\n' }, hangs: { [CTL]: true } } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: no reply for 1000 ms` }, brief(r.result));
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID at a line that is not name=value, keeping the counters before it', () => {
		with_reply('total.num.queries=5\nerror version mismatch\ntotal.num.cachehits=3\n', (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: `${CTL}: "error version mismatch"` }, brief(r.result));
			assert.match([ 'unbound_num_queries_total 5' ], samples(r.lines));
		});
	});

	it('fails with SOURCE_INVALID for a counter that is not a number, keeping the others', () => {
		with_reply('total.num.queries=lots\ntotal.num.cachehits=3\n', (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: `${CTL}: "total.num.queries=lots"` }, brief(r.result));
			assert.match([ 'unbound_cachehits_total 3' ], samples(r.lines));
		});
	});

	it('fails with SOURCE_INVALID for an empty reply', () => {
		with_reply('', (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: `${CTL}: empty reply` }, brief(r.result));
		});
	});

	prop('exports every known counter a reply has, whatever else it has and in any order',
		gen.array(gen.tuple(gen.int(0, 22), gen.int(0, 1099511627776), gen.bool()), { min_len: 1, max_len: 40 }), (rows) => {
			let reply = '';
			let want = {};

			for (let row in rows) {
				let f = FAMILIES[row[0]];

				// A thread's counter with the same name, which must not count.
				if (row[2])
					reply += `thread1.${substr(f[0], 6)}=${row[1] + 1}\n`;
				reply += `${f[0]}=${row[1]}\n`;
				want[f[1]] ??= `${f[1]} ${row[1]}`;
			}

			with_reply(reply, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(values(want)), sort(samples(r.lines)));
			});
		});
});

'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, jail_of, outcome } from 'prometheus.exporter.devkit.collector';
import { rc } from 'prometheus.exporter.devkit.rc';
import * as fixtures from 'lib.fixtures';
import * as agh from 'prometheus.collectors.agh';

// AdGuard Home 0.107.79's replies to an HTTP/1.0 request, as the router's
// answers them, their domains, clients and upstreams made up; see
// test/fixtures/SOURCES.
const STATUS = fixtures.file('seriguela-router', '/sockets/127.0.0.1_8080.control_status.txt');
const STATS = fixtures.file('seriguela-router', '/sockets/127.0.0.1_8080.control_stats.txt');
const PORT = '127.0.0.1:8080';

function head_of(reply) {
	return substr(reply, 0, index(reply, '\r\n\r\n') + 4);
}

function json_of(reply) {
	return json(substr(reply, index(reply, '\r\n\r\n') + 4));
}

function reply(head, data) {
	return head + sprintf('%J', data) + '\n';
}

const OK = head_of(STATUS);

// The server: each path's reply, by the request's first line.
function server(replies) {
	return function(req) {
		let path = split(split(req, '\r\n')[0], ' ')[1];

		return replies[path] ?? 'HTTP/1.0 404 Not Found\r\nContent-Type: text/plain\r\n\r\n404 page not found\n';
	};
}

function run(replies, cb, cfg) {
	with_collector(agh, { socket: { data: { [PORT]: server(replies) } }, ...(cfg ?? {}) }, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function brief(res) {
	return { ok: res.ok, error: res.error, details: res.details };
}

describe('collectors.agh', () => {
	it('writes whether AdGuard Home answers, its version, protection and the totals of its statistics window', () => {
		let asked = [];

		with_collector(agh, { socket: { data: { [PORT]: (req) => {
			push(asked, req);
			return server({ '/control/status': STATUS, '/control/stats': STATS })(req);
		} } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'GET /control/status HTTP/1.0\r\nHost: 127.0.0.1:8080\r\nAccept: application/json\r\nUser-Agent: ucode-prometheus-exporter\r\nConnection: close\r\n\r\n',
				'GET /control/stats HTTP/1.0\r\nHost: 127.0.0.1:8080\r\nAccept: application/json\r\nUser-Agent: ucode-prometheus-exporter\r\nConnection: close\r\n\r\n',
			], asked);
			assert.match([
				'# HELP adguard_up Whether AdGuard Home\'s HTTP API answered: 1 or 0.',
				'# TYPE adguard_up gauge',
				'adguard_up 1',
				'# HELP adguard_build_info AdGuard Home\'s version: always 1.',
				'# TYPE adguard_build_info gauge',
				'adguard_build_info{version="0.107.79"} 1',
				'# HELP adguard_running Whether AdGuard Home\'s DNS server runs: 1 or 0.',
				'# TYPE adguard_running gauge',
				'adguard_running 1',
				'# HELP adguard_protection_enabled Whether AdGuard Home\'s protection, its filtering, is on: 1 or 0.',
				'# TYPE adguard_protection_enabled gauge',
				'adguard_protection_enabled 1',
				'# HELP adguard_start_time_seconds When AdGuard Home started, in seconds since the epoch.',
				'# TYPE adguard_start_time_seconds gauge',
				'adguard_start_time_seconds 1792437171.9284565',
				'# HELP adguard_stats_window_seconds The statistics window of AdGuard Home, in seconds: its totals, adguard_stats_*, are of that much time up to now; 0 with its statistics off.',
				'# TYPE adguard_stats_window_seconds gauge',
				'adguard_stats_window_seconds 86400',
				'# HELP adguard_stats_dns_queries DNS queries AdGuard Home answered in its statistics window (adguard_stats_window_seconds): a total that drops as the window moves, not a counter.',
				'# TYPE adguard_stats_dns_queries gauge',
				'adguard_stats_dns_queries 14496',
				'# HELP adguard_stats_blocked_filtering Of them, the queries its filter lists and rules blocked, in the statistics window.',
				'# TYPE adguard_stats_blocked_filtering gauge',
				'adguard_stats_blocked_filtering 1482',
				'# HELP adguard_stats_replaced_safebrowsing Of them, the queries safe browsing blocked, in the statistics window.',
				'# TYPE adguard_stats_replaced_safebrowsing gauge',
				'adguard_stats_replaced_safebrowsing 0',
				'# HELP adguard_stats_replaced_safesearch Of them, the queries safe search rewrote, in the statistics window.',
				'# TYPE adguard_stats_replaced_safesearch gauge',
				'adguard_stats_replaced_safesearch 0',
				'# HELP adguard_stats_replaced_parental Of them, the queries parental control blocked, in the statistics window.',
				'# TYPE adguard_stats_replaced_parental gauge',
				'adguard_stats_replaced_parental 0',
				'# HELP adguard_stats_avg_processing_time_seconds The mean time AdGuard Home took to answer a query in the statistics window, in seconds.',
				'# TYPE adguard_stats_avg_processing_time_seconds gauge',
				'adguard_stats_avg_processing_time_seconds 0.003338',
			], r.lines);
		});
	});

	it('writes nothing of the domains, clients and upstreams AdGuard Home ranks', () => {
		let stats = json_of(STATS);
		let named = [];

		for (let k in [ 'top_queried_domains', 'top_clients', 'top_blocked_domains', 'top_upstreams_responses', 'top_upstreams_avg_time' ])
			for (let entry in stats[k])
				push(named, ...keys(entry));

		run({ '/control/status': STATUS, '/control/stats': STATS }, (r) => {
			assert.match(true, length(named) > 10);
			assert.match([], filter(named, (n) => index(r.text, n) >= 0));
		});
	});

	it('reads the window\'s length in days where AdGuard Home keeps more than a day', () => {
		let week = { ...json_of(STATS), time_units: 'days', dns_queries: [ 1, 2, 3, 4, 5, 6, 7 ] };

		run({ '/control/status': STATUS, '/control/stats': reply(OK, week) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'adguard_stats_window_seconds 604800' ], filter(r.lines, (l) => index(l, 'adguard_stats_window_seconds ') == 0));
		});
	});

	it('writes a window of 0 and no totals with AdGuard Home\'s statistics off', () => {
		let off = { time_units: 'hours', dns_queries: [], num_dns_queries: 0, avg_processing_time: 0 };

		run({ '/control/status': STATUS, '/control/stats': reply(OK, off) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'adguard_stats_window_seconds 0' ], filter(samples(r.lines), (l) => index(l, 'adguard_stats_') == 0));
		});
	});

	it('writes what AdGuard Home says of itself, and leaves out what it does not say', () => {
		let paused = { running: false, protection_enabled: false };

		run({ '/control/status': reply(OK, paused), '/control/stats': STATS }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'adguard_up 1', 'adguard_running 0', 'adguard_protection_enabled 0' ],
				filter(samples(r.lines), (l) => index(l, 'adguard_stats_') != 0));
		});
	});

	it('connects to the address and port of its options, IPv6 too', () => {
		with_collector(agh, {
			options: { address: '::1', port: '3000' },
			socket: { data: { '[::1]:3000': server({ '/control/status': STATUS, '/control/stats': STATS }) } },
		}, (r) => {
			assert.match([ true, 'adguard_up 1' ], [ r.result.ok, samples(r.lines)[0] ]);
		});
	});

	it('refuses an address that is not one, or a port out of range, with CONFIG_INVALID', () => {
		with_collector(agh, { options: { address: 'localhost' } }, (r) => {
			assert.match([ 'CONFIG_INVALID', 'address: expected an IPv4 or IPv6 address, got "localhost"' ], [ r.result.error, r.result.details ]);
		});
		with_collector(agh, { options: { port: '0' } }, (r) => {
			assert.match([ 'CONFIG_INVALID', 'port: expected an integer from 1 to 65535, got 0' ], [ r.result.error, r.result.details ]);
		});
	});

	it('fails where AdGuard Home asks for a login, which it does not send, and says up is 0', () => {
		let login = 'HTTP/1.0 401 Unauthorized\r\nContent-Type: text/plain\r\n\r\nUnauthorized\n';

		run({ '/control/status': login, '/control/stats': login }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE',
				details: 'http://127.0.0.1:8080/control/status: AdGuard Home asks for a login (401 Unauthorized), and agh reads it without one: it reads an AdGuard Home with no users alone' },
				brief(r.result));
			assert.match([ 'adguard_up 0' ], samples(r.lines));
		});
	});

	it('fails with SOURCE_INVALID on what is not AdGuard Home\'s API, saying nothing of the reply', () => {
		let secret = 'top_clients:192.168.1.20';

		for (let c in [
			[ { '/control/status': `HTTP/1.0 200 OK\r\n\r\n<html>${secret}</html>` }, 'http://127.0.0.1:8080/control/status: not a JSON object' ],
			[ { '/control/status': `${secret}\r\n\r\n{}` }, 'http://127.0.0.1:8080/control/status: not an HTTP reply' ],
			[ { '/control/status': STATUS }, 'http://127.0.0.1:8080/control/stats: 404 Not Found' ],
			[ { '/control/status': STATUS, '/control/stats': reply(OK, [ secret ]) }, 'http://127.0.0.1:8080/control/stats: not a JSON object' ],
			[ { '/control/status': STATUS, '/control/stats': reply(OK, { time_units: 'weeks', dns_queries: [] }) },
				'http://127.0.0.1:8080/control/stats: no time_units of hours or days, or no dns_queries' ],
			[ { '/control/status': 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n' },
				'http://127.0.0.1:8080/control/status: a chunked reply to HTTP/1.0' ],
		])
			run(c[0], (r) => {
				assert.match({ ok: false, error: 'SOURCE_INVALID', details: c[1] }, brief(r.result));
				assert.match([ 'adguard_up 0' ], samples(r.lines));
				assert.match(-1, index(r.result.details, secret));
			});
	});

	it('has nothing to observe where nothing answers and AdGuard Home is disabled or not installed', () => {
		for (let scripts in [ {}, { adguardhome: false } ])
			with_collector(agh, { socket: { strict: false }, ubus: { data: rc(scripts) } }, (r) => {
				assert.match({ ok: true, none: scripts.adguardhome == null ? 'adguardhome is not installed' : 'adguardhome is disabled',
					error: null, lines: [], logs: [] }, outcome(r));
			});
	});

	it('fails with SOCKET_FAILED where AdGuard Home is enabled and nothing answers, or it stops answering', () => {
		with_collector(agh, { socket: { strict: false }, ubus: { data: rc({ adguardhome: true }) } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: '127.0.0.1:8080: connect(): Connection refused' }, brief(r.result));
			assert.match([ 'adguard_up 0' ], samples(r.lines));
		});
		with_collector(agh, { socket: { data: { [PORT]: 'HTTP/1.0 200' }, hangs: { [PORT]: true } }, ubus: { data: rc({ adguardhome: true }) } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: '127.0.0.1:8080: no reply for 1500 ms' }, brief(r.result));
		});
	});

	it('fails without connecting to an address that is not the device\'s', () => {
		with_collector(agh, { options: { address: '192.0.2.1' }, socket: { strict: false }, ubus: { data: rc({ adguardhome: true }) } }, (r) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED',
				details: '192.0.2.1:8080: 192.0.2.1 is not an address of this device, and a collector connects to the device\'s own ports alone' }, brief(r.result));
		});
	});

	it('asks the jail for no path, and the ubus ACL for rc list alone', () => {
		let j = jail_of(agh, {});

		assert.match([ [], { rc: [ 'list' ] } ], [ j.paths, j.ubus ]);
	});

	prop('writes any totals AdGuard Home gives, as it gives them',
		gen.tuple(gen.int(0, 2147483647), gen.int(0, 1000000), gen.int(1, 90)), (t) => {
			let hours = [];

			for (let i = 0; i < t[2]; i++)
				push(hours, 1);

			let stats = { time_units: 'hours', dns_queries: hours, num_dns_queries: t[0], num_blocked_filtering: t[1] };

			run({ '/control/status': STATUS, '/control/stats': reply(OK, stats) }, (r) => {
				assert.match([
					`adguard_stats_window_seconds ${t[2] * 3600}`,
					`adguard_stats_dns_queries ${t[0]}`,
					`adguard_stats_blocked_filtering ${t[1]}`,
				], filter(samples(r.lines), (l) => index(l, 'adguard_stats_') == 0));
			});
		});
});

'use strict';

import { Result, errors, services } from 'prometheus.exporter';

export const meta = {
	name: 'agh',
	title: 'AdGuard Home',
	help: 'AdGuard Home\'s protection and the totals of its statistics window, from its HTTP API on the device, read without a login.',
	needs: [ 'socket', 'ubus' ],
	ubus: { rc: [ 'list' ] },
	options: {
		address: {
			default: '127.0.0.1',
			title: 'Address',
			datatype: 'ipaddr',
			help: 'An address of this device that AdGuard Home\'s web interface listens on (http.address in its adguardhome.yaml): 127.0.0.1 where it listens on every address, 0.0.0.0.',
		},
		port: {
			default: 8080,
			title: 'Port',
			datatype: 'range(1,65535)',
			help: 'The port of AdGuard Home\'s web interface (http.address in its adguardhome.yaml).',
		},
	},
};

const TIMEOUT_MS = 1500;

const HEAD = /^HTTP\/1\.[01] ([0-9]{3})[^\r\n]*/;

const CHUNKED = /\r\ntransfer-encoding:[ \t]*chunked/i;

const UNITS = { hours: 3600, days: 86400 };

const TIME_UNITS = /^\{"time_units":("[a-z]*"),/;

const TOTALS = ',"dns_queries":[';

const STATUS = [
	[ 'running', 'adguard_running', 'Whether AdGuard Home\'s DNS server runs: 1 or 0.' ],
	[ 'protection_enabled', 'adguard_protection_enabled', 'Whether AdGuard Home\'s protection, its filtering, is on: 1 or 0.' ],
];

const STATS = [
	[ 'num_dns_queries', 'adguard_stats_dns_queries',
		'DNS queries AdGuard Home answered in its statistics window (adguard_stats_window_seconds): a total that drops as the window moves, not a counter.' ],
	[ 'num_blocked_filtering', 'adguard_stats_blocked_filtering',
		'Of them, the queries its filter lists and rules blocked, in the statistics window.' ],
	[ 'num_replaced_safebrowsing', 'adguard_stats_replaced_safebrowsing',
		'Of them, the queries safe browsing blocked, in the statistics window.' ],
	[ 'num_replaced_safesearch', 'adguard_stats_replaced_safesearch',
		'Of them, the queries safe search rewrote, in the statistics window.' ],
	[ 'num_replaced_parental', 'adguard_stats_replaced_parental',
		'Of them, the queries parental control blocked, in the statistics window.' ],
	[ 'avg_processing_time', 'adguard_stats_avg_processing_time_seconds',
		'The mean time AdGuard Home took to answer a query in the statistics window, in seconds.' ],
];

function request(path, host) {
	return `GET ${path} HTTP/1.0\r\nHost: ${host}\r\nAccept: application/json\r\nUser-Agent: ucode-prometheus-exporter\r\nConnection: close\r\n\r\n`;
}

function number(v) {
	return (type(v) in [ 'int', 'double' ]) ? v : null;
}

function parsed(text) {
	try {
		return json(text);
	} catch (e) {
		return null;
	}
}

function totals(text) {
	let head = match(substr(text, 0, 32), TIME_UNITS);
	let at = head ? index(text, TOTALS) : -1;
	let tail = (at > 0) ? parsed('{' + substr(text, at + 1)) : null;

	if (type(tail) != 'object' || type(tail.dns_queries) != 'array')
		return parsed(text);

	for (let s in STATS)
		if (!(s[0] in tail))
			return parsed(text);

	tail.time_units = json(head[1]);
	return tail;
}

function body(reply, where, parse) {
	let end = index(reply, '\r\n\r\n');
	let m = (end >= 0) ? match(substr(reply, 0, end), HEAD) : null;

	if (!m)
		return Result.err(errors.SOURCE_INVALID, `${where}: not an HTTP reply`);

	let code = int(m[1]);

	if (code == 401 || code == 403)
		return Result.err(errors.SOURCE_UNREADABLE,
			`${where}: AdGuard Home asks for a login (${trim(substr(m[0], 9))}), and agh reads it without one: it reads an AdGuard Home with no users alone`);
	if (code != 200)
		return Result.err(errors.SOURCE_INVALID, `${where}: ${trim(substr(m[0], 9))}`);
	if (match(substr(reply, 0, end + 2), CHUNKED))
		return Result.err(errors.SOURCE_INVALID, `${where}: a chunked reply to HTTP/1.0`);

	let data = parse(substr(reply, end + 4));

	if (type(data) != 'object')
		return Result.err(errors.SOURCE_INVALID, `${where}: not a JSON object`);

	return Result.ok(data);
}

function window_seconds(stats) {
	let unit = UNITS[stats.time_units];

	if (unit == null || type(stats.dns_queries) != 'array')
		return null;

	return length(stats.dns_queries) * unit;
}

export function collect(deps, out, options) {
	let up = out.gauge('adguard_up', 'Whether AdGuard Home\'s HTTP API answered: 1 or 0.');
	let host = (index(options.address, ':') >= 0) ? `[${options.address}]:${options.port}` : `${options.address}:${options.port}`;

	function get(path, parse) {
		let res = deps.socket.tcp_request(options.address, options.port, request(path, host), TIMEOUT_MS);

		return res.ok ? body(res.data, `http://${host}${path}`, parse) : res;
	}

	let status = get('/control/status', parsed);

	if (!status.ok && status.error == errors.SOCKET_FAILED) {
		up(null, 0);
		return services.unless_disabled(deps.ubus, 'adguardhome', status);
	}

	let stats = status.ok ? get('/control/stats', totals) : status;

	if (!stats.ok) {
		up(null, 0);
		return stats;
	}

	let st = status.data;
	let window = window_seconds(stats.data);

	if (window == null) {
		up(null, 0);
		return Result.err(errors.SOURCE_INVALID, `http://${host}/control/stats: no time_units of hours or days, or no dns_queries`);
	}

	up(null, 1);

	if (type(st.version) == 'string' && st.version != '')
		out.gauge('adguard_build_info', 'AdGuard Home\'s version: always 1.')({ version: st.version }, 1);

	out.batch('gauge', map(STATUS, (s) => [ s[1], s[2], (type(st[s[0]]) == 'bool') ? st[s[0]] : null ]));
	out.gauge('adguard_start_time_seconds', 'When AdGuard Home started, in seconds since the epoch.')(
		null, (number(st.start_time) != null) ? st.start_time / 1000.0 : null);

	out.gauge('adguard_stats_window_seconds',
		'The statistics window of AdGuard Home, in seconds: its totals, adguard_stats_*, are of that much time up to now; 0 with its statistics off.')(null, window);

	if (window > 0)
		out.batch('gauge', map(STATS, (s) => [ s[1], s[2], number(stats.data[s[0]]) ]));

	return Result.ok();
};

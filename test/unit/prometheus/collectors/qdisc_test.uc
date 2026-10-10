'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as commands from 'prometheus.exporter.devkit.commands';
import * as qdisc from 'prometheus.collectors.qdisc';

const TC = commands.line([ 'tc', '-s', '-j', 'qdisc', 'show' ]);

// SQM's piece_of_cake on the caju router: CAKE on eth1 and the guest VLAN and
// on their ifbs, an ingress qdisc on each shaped device, fq_codel on eth0 and
// noqueue on the rest.
const CAJU = fixtures.file('caju-router', '/commands/tc_s_j_qdisc_show.json');

// The seriguela router without SQM: the kernel's defaults, mq over fq_codel
// on eth0 (a multiqueue NIC), fq_codel on eth1, noqueue on the rest.
const SERIGUELA = fixtures.file('seriguela-router', '/commands/tc_s_j_qdisc_show.json');

// layer_cake's diffserv4 CAKE on pppoe-wan, and simple.qos's HTB on its ifb.
const DIFFSERV4 = fixtures.file('synthetic', '/commands/tc_s_j_qdisc_show.json');

function with_tc(output, cb) {
	with_collector(qdisc, { fs: commands.fs(output == null ? {} : { [TC]: output }) }, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function starting(lines, prefix) {
	return filter(lines, (l) => index(l, prefix) == 0);
}

// The generic families' help and type lines, around each family's samples.
function generic(rows) {
	let fams = [
		[ 'node_qdisc_bytes_total', 'counter', 'Number of bytes sent.' ],
		[ 'node_qdisc_packets_total', 'counter', 'Number of packets sent.' ],
		[ 'node_qdisc_drops_total', 'counter', 'Number of packets dropped.' ],
		[ 'node_qdisc_requeues_total', 'counter', 'Number of packets dequeued, not transmitted, and requeued.' ],
		[ 'node_qdisc_overlimits_total', 'counter', 'Number of overlimit packets.' ],
		[ 'node_qdisc_current_queue_length', 'gauge', 'Number of packets currently in queue to be sent.' ],
		[ 'node_qdisc_backlog', 'gauge', 'Number of bytes currently in queue to be sent.' ],
	];
	let lines = [];

	for (let i, f in fams) {
		push(lines, `# HELP ${f[0]} ${f[2]}`, `# TYPE ${f[0]} ${f[1]}`);
		for (let r in rows)
			push(lines, `${f[0]}{device="${r[0]}",kind="${r[1]}"} ${r[2][i]}`);
	}

	return lines;
}

describe('collectors.qdisc', () => {
	it('exports the root qdisc of each device of the caju router, and CAKE\'s tins', () => {
		with_tc({ out: CAJU }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				...generic([
					[ 'eth0', 'fq_codel', [ 4702791774, 4255435, 0, 3, 0, 0, 0 ] ],
					[ 'eth1', 'cake', [ 1641508283, 2187578, 0, 0, 105637, 0, 0 ] ],
					[ 'vlan-guest', 'cake', [ 953015, 5350, 0, 0, 0, 0, 0 ] ],
					[ 'ifb4vlan-guest', 'cake', [ 881687, 5373, 0, 0, 0, 0, 0 ] ],
					[ 'ifb4eth1', 'cake', [ 4720115103, 4250784, 91, 0, 624476, 0, 0 ] ],
				]),
				'# HELP node_qdisc_cake_capacity_estimate_bytes_per_second The rate CAKE shapes to, in bytes per second: its bandwidth, or what autorate-ingress estimates.',
				'# TYPE node_qdisc_cake_capacity_estimate_bytes_per_second gauge',
				'node_qdisc_cake_capacity_estimate_bytes_per_second{device="eth1"} 27500000',
				'node_qdisc_cake_capacity_estimate_bytes_per_second{device="vlan-guest"} 3750000',
				'node_qdisc_cake_capacity_estimate_bytes_per_second{device="ifb4vlan-guest"} 1250000',
				'node_qdisc_cake_capacity_estimate_bytes_per_second{device="ifb4eth1"} 56250000',
				'# HELP node_qdisc_cake_memory_used_bytes Memory CAKE\'s queues use, in bytes.',
				'# TYPE node_qdisc_cake_memory_used_bytes gauge',
				'node_qdisc_cake_memory_used_bytes{device="eth1"} 1317440',
				'node_qdisc_cake_memory_used_bytes{device="vlan-guest"} 2304',
				'node_qdisc_cake_memory_used_bytes{device="ifb4vlan-guest"} 2304',
				'node_qdisc_cake_memory_used_bytes{device="ifb4eth1"} 7410368',
				'# HELP node_qdisc_cake_memory_limit_bytes Memory CAKE\'s queues may use, in bytes.',
				'# TYPE node_qdisc_cake_memory_limit_bytes gauge',
				'node_qdisc_cake_memory_limit_bytes{device="eth1"} 11000000',
				'node_qdisc_cake_memory_limit_bytes{device="vlan-guest"} 4194304',
				'node_qdisc_cake_memory_limit_bytes{device="ifb4vlan-guest"} 4194304',
				'node_qdisc_cake_memory_limit_bytes{device="ifb4eth1"} 15503360',
				'# HELP node_qdisc_cake_tin_threshold_rate_bytes_per_second The rate a CAKE tin is shaped to, in bytes per second.',
				'# TYPE node_qdisc_cake_tin_threshold_rate_bytes_per_second gauge',
				'node_qdisc_cake_tin_threshold_rate_bytes_per_second{device="eth1",tin="0"} 27500000',
				'node_qdisc_cake_tin_threshold_rate_bytes_per_second{device="vlan-guest",tin="0"} 3750000',
				'node_qdisc_cake_tin_threshold_rate_bytes_per_second{device="ifb4vlan-guest",tin="0"} 1250000',
				'node_qdisc_cake_tin_threshold_rate_bytes_per_second{device="ifb4eth1",tin="0"} 56250000',
				'# HELP node_qdisc_cake_tin_bytes_total Bytes a CAKE tin sent.',
				'# TYPE node_qdisc_cake_tin_bytes_total counter',
				'node_qdisc_cake_tin_bytes_total{device="eth1",tin="0"} 1641508283',
				'node_qdisc_cake_tin_bytes_total{device="vlan-guest",tin="0"} 953015',
				'node_qdisc_cake_tin_bytes_total{device="ifb4vlan-guest",tin="0"} 881687',
				'node_qdisc_cake_tin_bytes_total{device="ifb4eth1",tin="0"} 4720249973',
				'# HELP node_qdisc_cake_tin_packets_total Packets a CAKE tin sent.',
				'# TYPE node_qdisc_cake_tin_packets_total counter',
				'node_qdisc_cake_tin_packets_total{device="eth1",tin="0"} 2187578',
				'node_qdisc_cake_tin_packets_total{device="vlan-guest",tin="0"} 5350',
				'node_qdisc_cake_tin_packets_total{device="ifb4vlan-guest",tin="0"} 5373',
				'node_qdisc_cake_tin_packets_total{device="ifb4eth1",tin="0"} 4250875',
				'# HELP node_qdisc_cake_tin_drops_total Packets a CAKE tin dropped.',
				'# TYPE node_qdisc_cake_tin_drops_total counter',
				'node_qdisc_cake_tin_drops_total{device="eth1",tin="0"} 0',
				'node_qdisc_cake_tin_drops_total{device="vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_drops_total{device="ifb4vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_drops_total{device="ifb4eth1",tin="0"} 91',
				'# HELP node_qdisc_cake_tin_ecn_marks_total Packets a CAKE tin marked with ECN instead of dropping them.',
				'# TYPE node_qdisc_cake_tin_ecn_marks_total counter',
				'node_qdisc_cake_tin_ecn_marks_total{device="eth1",tin="0"} 0',
				'node_qdisc_cake_tin_ecn_marks_total{device="vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_ecn_marks_total{device="ifb4vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_ecn_marks_total{device="ifb4eth1",tin="0"} 129',
				'# HELP node_qdisc_cake_tin_ack_drops_total ACKs a CAKE tin\'s ACK filter dropped.',
				'# TYPE node_qdisc_cake_tin_ack_drops_total counter',
				'node_qdisc_cake_tin_ack_drops_total{device="eth1",tin="0"} 0',
				'node_qdisc_cake_tin_ack_drops_total{device="vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_ack_drops_total{device="ifb4vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_ack_drops_total{device="ifb4eth1",tin="0"} 0',
				'# HELP node_qdisc_cake_tin_backlog_bytes Bytes queued in a CAKE tin.',
				'# TYPE node_qdisc_cake_tin_backlog_bytes gauge',
				'node_qdisc_cake_tin_backlog_bytes{device="eth1",tin="0"} 0',
				'node_qdisc_cake_tin_backlog_bytes{device="vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_backlog_bytes{device="ifb4vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_backlog_bytes{device="ifb4eth1",tin="0"} 0',
				'# HELP node_qdisc_cake_tin_peak_delay_seconds Peak queueing delay in a CAKE tin, in seconds.',
				'# TYPE node_qdisc_cake_tin_peak_delay_seconds gauge',
				'node_qdisc_cake_tin_peak_delay_seconds{device="eth1",tin="0"} 0.000335',
				'node_qdisc_cake_tin_peak_delay_seconds{device="vlan-guest",tin="0"} 1.4e-05',
				'node_qdisc_cake_tin_peak_delay_seconds{device="ifb4vlan-guest",tin="0"} 3.5e-05',
				'node_qdisc_cake_tin_peak_delay_seconds{device="ifb4eth1",tin="0"} 0.000173',
				'# HELP node_qdisc_cake_tin_average_delay_seconds Average queueing delay in a CAKE tin, in seconds.',
				'# TYPE node_qdisc_cake_tin_average_delay_seconds gauge',
				'node_qdisc_cake_tin_average_delay_seconds{device="eth1",tin="0"} 0.000137',
				'node_qdisc_cake_tin_average_delay_seconds{device="vlan-guest",tin="0"} 1.3e-05',
				'node_qdisc_cake_tin_average_delay_seconds{device="ifb4vlan-guest",tin="0"} 2.3e-05',
				'node_qdisc_cake_tin_average_delay_seconds{device="ifb4eth1",tin="0"} 3.3e-05',
				'# HELP node_qdisc_cake_tin_base_delay_seconds Queueing delay of a CAKE tin\'s sparse flows, in seconds.',
				'# TYPE node_qdisc_cake_tin_base_delay_seconds gauge',
				'node_qdisc_cake_tin_base_delay_seconds{device="eth1",tin="0"} 1.2e-05',
				'node_qdisc_cake_tin_base_delay_seconds{device="vlan-guest",tin="0"} 6e-06',
				'node_qdisc_cake_tin_base_delay_seconds{device="ifb4vlan-guest",tin="0"} 1.1e-05',
				'node_qdisc_cake_tin_base_delay_seconds{device="ifb4eth1",tin="0"} 6e-06',
				'# HELP node_qdisc_cake_tin_sparse_flows Sparse flows in a CAKE tin.',
				'# TYPE node_qdisc_cake_tin_sparse_flows gauge',
				'node_qdisc_cake_tin_sparse_flows{device="eth1",tin="0"} 3',
				'node_qdisc_cake_tin_sparse_flows{device="vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_sparse_flows{device="ifb4vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_sparse_flows{device="ifb4eth1",tin="0"} 2',
				'# HELP node_qdisc_cake_tin_bulk_flows Bulk flows in a CAKE tin.',
				'# TYPE node_qdisc_cake_tin_bulk_flows gauge',
				'node_qdisc_cake_tin_bulk_flows{device="eth1",tin="0"} 1',
				'node_qdisc_cake_tin_bulk_flows{device="vlan-guest",tin="0"} 1',
				'node_qdisc_cake_tin_bulk_flows{device="ifb4vlan-guest",tin="0"} 1',
				'node_qdisc_cake_tin_bulk_flows{device="ifb4eth1",tin="0"} 1',
				'# HELP node_qdisc_cake_tin_unresponsive_flows Flows in a CAKE tin that do not respond to congestion signals.',
				'# TYPE node_qdisc_cake_tin_unresponsive_flows gauge',
				'node_qdisc_cake_tin_unresponsive_flows{device="eth1",tin="0"} 0',
				'node_qdisc_cake_tin_unresponsive_flows{device="vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_unresponsive_flows{device="ifb4vlan-guest",tin="0"} 0',
				'node_qdisc_cake_tin_unresponsive_flows{device="ifb4eth1",tin="0"} 0',
			], r.lines);
		});
	});

	it('exports the defaults of a device without SQM, mq\'s and not its children\'s', () => {
		with_tc({ out: SERIGUELA }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(generic([
				[ 'eth0', 'mq', [ 2586134931, 4720091, 1, 3542, 0, 0, 0 ] ],
				[ 'eth1', 'fq_codel', [ 10541333168, 8590047, 0, 5324, 0, 0, 0 ] ],
			]), r.lines);
		});
	});

	it('labels each of a diffserv4 CAKE\'s tins, and leaves out its ingress qdisc and HTB\'s leaves', () => {
		with_tc({ out: DIFFSERV4 }, (r) => {
			let s = samples(r.lines);

			assert.match(true, r.result.ok);
			assert.match([
				'node_qdisc_bytes_total{device="pppoe-wan",kind="cake"} 81234567890',
				'node_qdisc_bytes_total{device="ifb4pppoe-wan",kind="htb"} 912300000000',
			], starting(s, 'node_qdisc_bytes_total'));
			assert.match([
				'node_qdisc_current_queue_length{device="pppoe-wan",kind="cake"} 2',
				'node_qdisc_current_queue_length{device="ifb4pppoe-wan",kind="htb"} 0',
			], starting(s, 'node_qdisc_current_queue_length'));
			assert.match([ 'node_qdisc_backlog{device="pppoe-wan",kind="cake"} 3028', 'node_qdisc_backlog{device="ifb4pppoe-wan",kind="htb"} 0' ],
				starting(s, 'node_qdisc_backlog'));
			assert.match([
				'node_qdisc_cake_tin_threshold_rate_bytes_per_second{device="pppoe-wan",tin="0"} 312500',
				'node_qdisc_cake_tin_threshold_rate_bytes_per_second{device="pppoe-wan",tin="1"} 5000000',
				'node_qdisc_cake_tin_threshold_rate_bytes_per_second{device="pppoe-wan",tin="2"} 2500000',
				'node_qdisc_cake_tin_threshold_rate_bytes_per_second{device="pppoe-wan",tin="3"} 1250000',
			], starting(s, 'node_qdisc_cake_tin_threshold_rate_bytes_per_second'));
			assert.match([
				'node_qdisc_cake_tin_ack_drops_total{device="pppoe-wan",tin="0"} 0',
				'node_qdisc_cake_tin_ack_drops_total{device="pppoe-wan",tin="1"} 92310',
				'node_qdisc_cake_tin_ack_drops_total{device="pppoe-wan",tin="2"} 0',
				'node_qdisc_cake_tin_ack_drops_total{device="pppoe-wan",tin="3"} 0',
			], starting(s, 'node_qdisc_cake_tin_ack_drops_total'));
			assert.match([
				'node_qdisc_cake_tin_peak_delay_seconds{device="pppoe-wan",tin="0"} 0',
				'node_qdisc_cake_tin_peak_delay_seconds{device="pppoe-wan",tin="1"} 0.024518',
				'node_qdisc_cake_tin_peak_delay_seconds{device="pppoe-wan",tin="2"} 0.00152',
				'node_qdisc_cake_tin_peak_delay_seconds{device="pppoe-wan",tin="3"} 0.00031',
			], starting(s, 'node_qdisc_cake_tin_peak_delay_seconds'));
			assert.match([ 'node_qdisc_cake_tin_backlog_bytes{device="pppoe-wan",tin="1"} 3028' ],
				filter(starting(s, 'node_qdisc_cake_tin_backlog_bytes'), (l) => substr(l, -2) != ' 0'));
			assert.match([], filter(s, (l) => index(l, 'kind="ingress"') >= 0 || index(l, 'kind="fq_codel"') >= 0));
		});
	});

	it('exports nothing where every device has noqueue', () => {
		with_tc({ out: '[{"kind":"noqueue","handle":"0:","dev":"lo","root":true,"options":{},"bytes":0,"packets":0}]\n' }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('leaves out an entry it cannot read, and a field tc does not print', () => {
		with_tc({ out: sprintf('%J', [ 7, null, { root: true, kind: 'pfifo' }, { root: true, dev: 'x0', kind: 'pfifo', bytes: 10, drops: 'many' } ]) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_qdisc_bytes_total{device="x0",kind="pfifo"} 10' ], samples(r.lines));
		});
	});

	it('passes on a failing tc as COMMAND_FAILED', () => {
		with_tc({ out: '', status: 1 }, (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'tc: exit status 1' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with COMMAND_FAILED when tc cannot start', () => {
		with_tc(null, (r) => {
			assert.match({ error: 'COMMAND_FAILED', details: 'tc: cannot start' }, { error: r.result.error, details: r.result.details });
		});
	});

	it('passes on a tc that does not answer in time as COMMAND_TIMEOUT', () => {
		with_tc({ hangs: true }, (r) => {
			assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'tc: still running after 5 s, killed' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_INVALID for output that is not a JSON list', () => {
		for (let out in [ 'Error: Cannot find device "x".\n', '', '{}', 'null', '"x"' ])
			with_tc({ out }, (r) => {
				assert.match('SOURCE_INVALID', r.result.error, out);
				assert.match([], r.lines, out);
			});
	});

	prop('exports each root qdisc once, but noqueue, and each CAKE tin',
		gen.array(gen.tuple(gen.int(0, 3), gen.int(0, 1), gen.int(0, 1000000000), gen.int(0, 4)), { min_len: 0, max_len: 8 }), (rows) => {
			const KINDS = [ 'fq_codel', 'cake', 'noqueue', 'htb' ];
			let list = map(rows, (row, i) => {
				let q = { kind: KINDS[row[0]], dev: `d${i}`, bytes: row[2], packets: 1, drops: 0, overlimits: 0, requeues: 0, backlog: 0, qlen: 0 };

				if (row[1])
					q.root = true;
				else
					q.parent = '1:1';
				if (q.kind == 'cake')
					q.tins = map(slice([ 0, 1, 2, 3 ], 0, row[3]), (t) => ({ sent_bytes: t, peak_delay_us: 1000 * t }));

				return q;
			});
			let roots = filter(list, (q) => q.root && q.kind != 'noqueue');
			let tins = [];

			for (let q in roots)
				for (let t in (q.tins ?? []))
					push(tins, `node_qdisc_cake_tin_bytes_total{device="${q.dev}",tin="${t.sent_bytes}"} ${t.sent_bytes}`);

			with_tc({ out: sprintf('%J', list) }, (r) => {
				let s = samples(r.lines);

				assert.match(true, r.result.ok);
				assert.match(map(roots, (q) => `node_qdisc_bytes_total{device="${q.dev}",kind="${q.kind}"} ${q.bytes}`),
					starting(s, 'node_qdisc_bytes_total'));
				assert.match(tins, starting(s, 'node_qdisc_cake_tin_bytes_total'));
			});
		});
});

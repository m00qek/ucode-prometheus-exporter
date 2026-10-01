'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as softnet from 'prometheus_exporter.collectors.softnet';

const PATH = softnet.PATH;
const ROUTER = fixtures.files('caju-router', [ PATH ]);
const AP = fixtures.files('caju-ap', [ PATH ]);

const NAMES = [
	'node_softnet_processed_total', 'node_softnet_dropped_total', 'node_softnet_times_squeezed_total',
	'node_softnet_cpu_collision_total', 'node_softnet_received_rps_total', 'node_softnet_flow_limit_count_total',
	'node_softnet_backlog_len',
];

function stat(text) {
	return { fs: { data: { [PATH]: text } } };
}

function row(values) {
	return join(' ', map(values, (v) => sprintf('%08x', v)));
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.softnet', () => {
	it("exports node_exporter's seven metrics for each of the caju router's four CPUs", () => {
		with_collector(softnet, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(NAMES, map(r.families, (f) => f.name));
			assert.match([
				'# HELP node_softnet_processed_total Number of processed packets',
				'# TYPE node_softnet_processed_total counter',
				'node_softnet_processed_total{cpu="0"} 721836',
				'node_softnet_processed_total{cpu="1"} 31166',
				'node_softnet_processed_total{cpu="2"} 1786703',
				'node_softnet_processed_total{cpu="3"} 28341',
				'# HELP node_softnet_dropped_total Number of dropped packets',
				'# TYPE node_softnet_dropped_total counter',
				'node_softnet_dropped_total{cpu="0"} 0',
				'node_softnet_dropped_total{cpu="1"} 0',
				'node_softnet_dropped_total{cpu="2"} 0',
				'node_softnet_dropped_total{cpu="3"} 0',
				'# HELP node_softnet_times_squeezed_total Number of times processing packets ran out of quota',
				'# TYPE node_softnet_times_squeezed_total counter',
				'node_softnet_times_squeezed_total{cpu="0"} 0',
				'node_softnet_times_squeezed_total{cpu="1"} 0',
				'node_softnet_times_squeezed_total{cpu="2"} 1',
				'node_softnet_times_squeezed_total{cpu="3"} 0',
				'# HELP node_softnet_cpu_collision_total Number of collision occur while obtaining device lock while transmitting',
				'# TYPE node_softnet_cpu_collision_total counter',
				'node_softnet_cpu_collision_total{cpu="0"} 0',
				'node_softnet_cpu_collision_total{cpu="1"} 0',
				'node_softnet_cpu_collision_total{cpu="2"} 0',
				'node_softnet_cpu_collision_total{cpu="3"} 0',
				'# HELP node_softnet_received_rps_total Number of times cpu woken up received_rps',
				'# TYPE node_softnet_received_rps_total counter',
				'node_softnet_received_rps_total{cpu="0"} 230258',
				'node_softnet_received_rps_total{cpu="1"} 0',
				'node_softnet_received_rps_total{cpu="2"} 1',
				'node_softnet_received_rps_total{cpu="3"} 0',
				'# HELP node_softnet_flow_limit_count_total Number of times flow limit has been reached',
				'# TYPE node_softnet_flow_limit_count_total counter',
				'node_softnet_flow_limit_count_total{cpu="0"} 0',
				'node_softnet_flow_limit_count_total{cpu="1"} 0',
				'node_softnet_flow_limit_count_total{cpu="2"} 0',
				'node_softnet_flow_limit_count_total{cpu="3"} 0',
				'# HELP node_softnet_backlog_len Softnet backlog status',
				'# TYPE node_softnet_backlog_len gauge',
				'node_softnet_backlog_len{cpu="0"} 0',
				'node_softnet_backlog_len{cpu="1"} 0',
				'node_softnet_backlog_len{cpu="2"} 0',
				'node_softnet_backlog_len{cpu="3"} 0',
			], r.lines);
		});
	});

	it("labels the caju AP's two CPUs with the numbers the kernel writes", () => {
		with_collector(softnet, { fs: { data: AP } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_softnet_processed_total{cpu="0"} 630994',
				'node_softnet_processed_total{cpu="1"} 3652565',
			], slice(samples(r.lines), 0, 2));
		});
	});

	// With CPU 1 offline the second row is CPU 2's.
	it('takes the CPU from its column, not from the row number', () => {
		let text = row([ 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]) + '\n' + row([ 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0 ]) + '\n';

		with_collector(softnet, stat(text), (r) => {
			assert.match([ 'node_softnet_processed_total{cpu="0"} 5', 'node_softnet_processed_total{cpu="2"} 7' ],
				slice(samples(r.lines), 0, 2));
		});
	});

	// Linux 4.18 to 5.13 wrote 11 columns; 2.6.23, the first, 9.
	it('numbers the rows of older kernels, leaving out the metrics of columns they lack', () => {
		let text = row([ 1, 2, 3, 0, 0, 0, 0, 0, 4, 5, 6 ]) + '\n' + row([ 7, 8, 9, 0, 0, 0, 0, 0, 10 ]) + '\n';

		with_collector(softnet, stat(text), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_softnet_processed_total{cpu="0"} 1', 'node_softnet_processed_total{cpu="1"} 7',
				'node_softnet_dropped_total{cpu="0"} 2', 'node_softnet_dropped_total{cpu="1"} 8',
				'node_softnet_times_squeezed_total{cpu="0"} 3', 'node_softnet_times_squeezed_total{cpu="1"} 9',
				'node_softnet_cpu_collision_total{cpu="0"} 4', 'node_softnet_cpu_collision_total{cpu="1"} 10',
				'node_softnet_received_rps_total{cpu="0"} 5',
				'node_softnet_flow_limit_count_total{cpu="0"} 6',
			], samples(r.lines));
		});
	});

	it('fails with SOURCE_UNREADABLE without /proc/net/softnet_stat', () => {
		with_collector(softnet, stat(null), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: PATH },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([ "collector 'softnet': SOURCE_UNREADABLE (/proc/net/softnet_stat)" ], r.logs);
		});
	});

	it('fails with SOURCE_INVALID for a malformed table, exporting none of it', () => {
		let cases = [
			[ '', 'no rows' ],
			[ '00000001 00000002\n', 'row 1: 2 columns, fewer than 9' ],
			[ row([ 1, 0, 0, 0, 0, 0, 0, 0, 0 ]) + '\n' + 'zz ' + row([ 0, 0, 0, 0, 0, 0, 0, 0 ]) + '\n', 'row 2: "zz" is not hex' ],
			[ row([ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 ]) + '\n' + row([ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 ]) + '\n', 'row 2: CPU 3 again' ],
		];

		for (let c in cases)
			with_collector(softnet, stat(c[0]), (r) => {
				assert.match({ error: 'SOURCE_INVALID', details: `${PATH}: ${c[1]}` }, { error: r.result.error, details: r.result.details });
				assert.match([], r.lines);
			});
	});

	prop('exports every column of every CPU row, read as hex',
		gen.array(gen.array(gen.int(0, 0xffffffff), { len: 15 }), { min_len: 1, max_len: 8 }), (rows) => {
			let text = '';
			for (let i, values in rows) {
				values[12] = i;
				text += row(values) + '\n';
			}

			with_collector(softnet, stat(text), (r) => {
				let want = [];
				for (let c in softnet.COLUMNS)
					for (let i, values in rows)
						push(want, `node_softnet_${c[1]}{cpu="${i}"} ${values[c[0]]}`);

				assert.match(true, r.result.ok);
				assert.match(want, samples(r.lines));
			});
		});
});

'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as interrupts from 'prometheus.collectors.interrupts';

// An MT7981's, made up: see test/fixtures/synthetic/SOURCES.
const AP = fixtures.files('synthetic', [ '/proc/interrupts' ]);

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function with_text(text, cb) {
	with_collector(interrupts, { fs: { data: { '/proc/interrupts': text } } }, cb);
}

describe('collectors.interrupts', () => {
	it("exports every interrupt of each CPU, labeled as node_exporter labels them", () => {
		with_text(AP['/proc/interrupts'], (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_interrupts_total Interrupt details.',
				'# TYPE node_interrupts_total counter',
				'node_interrupts_total{cpu="0",type="11",info="GICv3",devices="30 Level arch_timer"} 1730566',
				'node_interrupts_total{cpu="1",type="11",info="GICv3",devices="30 Level arch_timer"} 1546829',
				'node_interrupts_total{cpu="0",type="14",info="GICv3",devices="155 Level ttyS0"} 2715',
				'node_interrupts_total{cpu="1",type="14",info="GICv3",devices="155 Level ttyS0"} 0',
			], slice(r.lines, 0, 6));
			assert.match(contains([
				'node_interrupts_total{cpu="0",type="23",info="GICv3",devices="245 Level mt7915e"} 182376',
				'node_interrupts_total{cpu="0",type="24",info="mt-eint",devices="10 Edge reset"} 0',
				'node_interrupts_total{cpu="1",type="IPI1",info="Function call interrupts",devices=""} 325871',
				'node_interrupts_total{cpu="0",type="IPI3",info="CPU stop NMIs",devices=""} 0',
			]), r.lines);
			// 10 numbered and 8 IPIs on 2 CPUs; Err has one count, not one per CPU.
			assert.match(36, length(samples(r.lines)));
			assert.match(false, index(r.text, 'type="Err"') >= 0);
		});
	});

	it("splits a line at its first ':', where arm64's has no blank after the name", () => {
		with_text('CPU0 CPU1\nIPI0:17283 20131 Rescheduling interrupts\n 5:3 4 GICv3 27 Level\n', (r) => {
			assert.match([
				'node_interrupts_total{cpu="0",type="IPI0",info="Rescheduling interrupts",devices=""} 17283',
				'node_interrupts_total{cpu="1",type="IPI0",info="Rescheduling interrupts",devices=""} 20131',
				'node_interrupts_total{cpu="0",type="5",info="GICv3",devices="27 Level"} 3',
				'node_interrupts_total{cpu="1",type="5",info="GICv3",devices="27 Level"} 4',
			], samples(r.lines));
		});
	});

	it('leaves out a line without a count for every CPU and something after them, and one without a name', () => {
		with_text('           CPU0       CPU1       CPU2       CPU3\n' +
				'ERR:          0\nMIS:          0\n 12:  1  2  3  4\n  no colon here\n 13:  1  2  3  4  IO-APIC  13-edge  fpu\n', (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_interrupts_total{cpu="0",type="13",info="IO-APIC",devices="13-edge fpu"} 1',
				'node_interrupts_total{cpu="1",type="13",info="IO-APIC",devices="13-edge fpu"} 2',
				'node_interrupts_total{cpu="2",type="13",info="IO-APIC",devices="13-edge fpu"} 3',
				'node_interrupts_total{cpu="3",type="13",info="IO-APIC",devices="13-edge fpu"} 4',
			], samples(r.lines));
		});
	});

	it('fails with SOURCE_UNREADABLE when /proc/interrupts cannot be read', () => {
		with_text(null, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/interrupts' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_INVALID for a file without a header of CPUs', () => {
		with_text('', (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: '/proc/interrupts: no CPUs in its header' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	prop('writes a sample per CPU of each line, its counts as they are',
		gen.tuple(gen.int(1, 8), gen.array(gen.int(0, 4294967295), { min_len: 8, max_len: 8 })), (t) => {
			let cpus = t[0], counts = slice(t[1], 0, cpus);
			let header = join(' ', map(counts, (v, i) => `CPU${i}`));
			let text = `${header}\n 42: ${join(' ', counts)} GICv3 99 Level eth0\n`;

			with_text(text, (r) => {
				assert.match(map(counts, (v, i) => `node_interrupts_total{cpu="${i}",type="42",info="GICv3",devices="99 Level eth0"} ${v}`),
					samples(r.lines));
			});
		});
});

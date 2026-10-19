'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { glob } from 'fs';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as mmc from 'prometheus.collectors.mmc';

// Every file a device has of its MMC hosts' cards.
function sysfs(device) {
	let root = `test/fixtures/${device}`;
	let paths = map(glob(`${root}/sys/class/mmc_host/*/*/*`), (p) => substr(p, length(root)));

	return fixtures.files(device, paths);
}

// The router's eMMC, new, and its SD card.
const ROUTER = {
	...sysfs('seriguela-router'),
	'/sys/class/mmc_host/mmc1/mmc1:0001/life_time': null,
	'/sys/class/mmc_host/mmc1/mmc1:0001/pre_eol_info': null,
};
const EMMC = '/sys/class/mmc_host/mmc0/mmc0:0001';

// A card's files, those the collector reads and it lacks not there (null).
function card(dir, files) {
	let data = {};

	for (let name in [ 'life_time', 'pre_eol_info', 'name', 'manfid', 'oemid', 'rev' ])
		data[`${dir}/${name}`] = null;

	for (let name, v in files)
		data[`${dir}/${name}`] = v;

	return data;
}

function emmc(life_time, pre_eol_info) {
	return card(EMMC, { type: 'MMC\n', name: 'AT3SFB\n', manfid: '0x0000ec\n', oemid: '0x2900\n', rev: '0x8\n', life_time, pre_eol_info });
}

function run(data, cb) {
	with_collector(mmc, { fs: { data } }, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.mmc', () => {
	it('writes the router\'s eMMC, its life time used of each type and its pre-EOL state, and nothing of its SD card', () => {
		run(ROUTER, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_mmc_info An eMMC that reports its health, by its sysfs device, product name, manufacturer and OEM IDs and revision: always 1.',
				'# TYPE node_mmc_info gauge',
				'node_mmc_info{device="mmc0:0001",name="AT3SFB",manfid="0x0000ec",oemid="0x2900",rev="0x8"} 1',
				'# HELP node_mmc_life_time_step Life time used of the eMMC\'s type A (SLC) or B (MLC) memory, as it estimates it in steps of 10%: 1 is 0-10% used, 10 is 90-100%, 11 past its estimated life.',
				'# TYPE node_mmc_life_time_step gauge',
				'node_mmc_life_time_step{device="mmc0:0001",type="a"} 1',
				'node_mmc_life_time_step{device="mmc0:0001",type="b"} 1',
				'# HELP node_mmc_pre_eol_state The eMMC\'s reserved blocks, its pre-EOL information: 1 for its state, normal, warning (80% of them consumed) or urgent; 0 for the others.',
				'# TYPE node_mmc_pre_eol_state gauge',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="normal"} 1',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="warning"} 0',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="urgent"} 0',
			], r.lines);
		});
	});

	it('writes a worn eMMC: 10 and 11 steps, past its life, and its reserved blocks urgent', () => {
		run(emmc('0x0a 0x0B\n', '0x03\n'), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_mmc_info{device="mmc0:0001",name="AT3SFB",manfid="0x0000ec",oemid="0x2900",rev="0x8"} 1',
				'node_mmc_life_time_step{device="mmc0:0001",type="a"} 10',
				'node_mmc_life_time_step{device="mmc0:0001",type="b"} 11',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="normal"} 0',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="warning"} 0',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="urgent"} 1',
			], samples(r.lines));
		});
	});

	it('leaves out what the eMMC does not define (0) or a value the standard reserves', () => {
		run(emmc('0x00 0x02\n', '0x04\n'), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_mmc_info{device="mmc0:0001",name="AT3SFB",manfid="0x0000ec",oemid="0x2900",rev="0x8"} 1',
				'node_mmc_life_time_step{device="mmc0:0001",type="b"} 2',
			], samples(r.lines));
		});
		run(emmc('0x0c 0x00\n', '0x02\n'), (r) => {
			assert.match([
				'node_mmc_info{device="mmc0:0001",name="AT3SFB",manfid="0x0000ec",oemid="0x2900",rev="0x8"} 1',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="normal"} 0',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="warning"} 1',
				'node_mmc_pre_eol_state{device="mmc0:0001",state="urgent"} 0',
			], samples(r.lines));
		});
	});

	it('has nothing to observe without an eMMC that reports its health', () => {
		let none = { ok: true, none: 'no eMMC reports its health', error: null, lines: [], logs: [] };
		let sd = card('/sys/class/mmc_host/mmc1/mmc1:0001', { type: 'SD\n', name: '00000\n' });

		with_collector(mmc, { fs: { behavior: { lsdir: () => null } } }, (r) => assert.match(none, outcome(r)));

		for (let data in [
			{ '/sys/class/mmc_host/gone': null },
			sd,
			{ ...sd, '/sys/class/mmc_host/mmc1/mmc1:0001/life_time': '\n', '/sys/class/mmc_host/mmc1/mmc1:0001/pre_eol_info': '' },
			emmc('0x00 0x00\n', '0x00\n'),
			card('/sys/class/mmc_host/mmc2/mmc2:0001', { type: 'SDIO\n' }),
		])
			run(data, (r) => assert.match(none, outcome(r), sprintf('%J', data)));
	});

	it('fails a life_time or pre_eol_info not as the kernel writes it, and still writes the others', () => {
		let other = card('/sys/class/mmc_host/mmc2/mmc2:0001', { name: 'OTHER\n', life_time: '0x02 0x03\n' });

		run({ ...emmc('0x1 0x01\n', '0x01\n'), ...other }, (r) => {
			assert.match([ false, 'SOURCE_INVALID', `${EMMC}/life_time: "0x1 0x01"` ], [ r.result.ok, r.result.error, r.result.details ]);
			assert.match([
				'node_mmc_info{device="mmc2:0001",name="OTHER"} 1',
				'node_mmc_life_time_step{device="mmc2:0001",type="a"} 2',
				'node_mmc_life_time_step{device="mmc2:0001",type="b"} 3',
			], samples(r.lines));
		});
		run(emmc('0x01 0x01\n', 'normal\n'), (r) => {
			assert.match([ 'SOURCE_INVALID', `${EMMC}/pre_eol_info: "normal"` ], [ r.result.error, r.result.details ]);
		});
	});

	it('writes the cards in the order of their hosts\' numbers', () => {
		let data = {};

		for (let n in [ 10, 2, 0 ])
			data = { ...data, ...card(`/sys/class/mmc_host/mmc${n}/mmc${n}:0001`, { life_time: '0x01 0x01\n' }) };

		run(data, (r) => {
			assert.match([ 'mmc0:0001', 'mmc2:0001', 'mmc10:0001' ],
				map(filter(r.lines, (l) => substr(l, 0, 13) == 'node_mmc_info'), (l) => match(l, /device="([^"]+)"/)[1]));
		});
	});

	prop('writes any defined step of either type as it reads it, in hex of either case',
		gen.tuple(gen.int(0, 15), gen.int(0, 15), gen.bool()), (t) => {
			let spell = (n) => sprintf(t[2] ? '0x%02X' : '0x%02x', n);

			run(emmc(`${spell(t[0])} ${spell(t[1])}\n`, '0x00\n'), (r) => {
				let want = [];

				if (t[0] >= 1 && t[0] <= 11)
					push(want, `node_mmc_life_time_step{device="mmc0:0001",type="a"} ${t[0]}`);
				if (t[1] >= 1 && t[1] <= 11)
					push(want, `node_mmc_life_time_step{device="mmc0:0001",type="b"} ${t[1]}`);

				assert.match(want, filter(r.lines, (l) => substr(l, 0, 23) == 'node_mmc_life_time_step'));
				assert.match(length(want) ? null : 'no eMMC reports its health', r.result.none);
			});
		});
});

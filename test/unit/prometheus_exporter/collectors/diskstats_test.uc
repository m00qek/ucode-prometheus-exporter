'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus_exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as diskstats from 'prometheus_exporter.collectors.diskstats';

const PATH = diskstats.PATH;
const rotational = (d) => `/sys/block/${d}/queue/rotational`;

// The seriguela router boots from an eMMC (mmcblk0) and has an SD card
// (mmcblk1) at /mnt/data; the caju AP has flash alone.
const ROUTER = fixtures.files('seriguela-router', [ PATH, rotational('mmcblk0'), rotational('mmcblk1') ]);
const AP = fixtures.files('caju-ap', [ PATH ]);
// Kernel 4.14's 14 fields: a NAND router with a USB hard disk.
const OLD = fixtures.files('synthetic', [ PATH, rotational('sda') ]);

// A file the data does not hold is not there: a device without
// /sys/block/<device>/queue/rotational, as a partition.
function fs_of(data) {
	return { data, behavior: { readfile: (p) => data[p] } };
}

function file(text, options) {
	return { fs: fs_of({ [PATH]: text }), options };
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function of_device(lines, device) {
	return filter(samples(lines), (l) => index(l, `{device="${device}"`) > 0);
}

describe('collectors.diskstats', () => {
	it("exports the seriguela router's eMMC and SD card, and none of their partitions, boot areas or loop devices", () => {
		with_collector(diskstats, { fs: fs_of(ROUTER) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_disk_info{device="mmcblk0",major="179",minor="0",rotational="0"} 1',
				'node_disk_info{device="mmcblk1",major="179",minor="96",rotational="0"} 1',
			], filter(r.lines, (l) => index(l, 'node_disk_info{') == 0));
			assert.match([
				'node_disk_info{device="mmcblk0",major="179",minor="0",rotational="0"} 1',
				'node_disk_reads_completed_total{device="mmcblk0"} 1311',
				'node_disk_reads_merged_total{device="mmcblk0"} 31',
				'node_disk_read_bytes_total{device="mmcblk0"} 46970880',
				'node_disk_read_time_seconds_total{device="mmcblk0"} 1.301',
				'node_disk_writes_completed_total{device="mmcblk0"} 354',
				'node_disk_writes_merged_total{device="mmcblk0"} 19256',
				'node_disk_written_bytes_total{device="mmcblk0"} 42766336',
				'node_disk_write_time_seconds_total{device="mmcblk0"} 3.023',
				'node_disk_io_now{device="mmcblk0"} 0',
				'node_disk_io_time_seconds_total{device="mmcblk0"} 1.5',
				'node_disk_io_time_weighted_seconds_total{device="mmcblk0"} 4.33',
				'node_disk_discards_completed_total{device="mmcblk0"} 0',
				'node_disk_discards_merged_total{device="mmcblk0"} 0',
				'node_disk_discarded_sectors_total{device="mmcblk0"} 0',
				'node_disk_discard_time_seconds_total{device="mmcblk0"} 0',
				'node_disk_flush_requests_total{device="mmcblk0"} 49',
				'node_disk_flush_requests_time_seconds_total{device="mmcblk0"} 0.005',
			], of_device(r.lines, 'mmcblk0'));
			assert.match(contains([
				'node_disk_read_bytes_total{device="mmcblk1"} 326796288',
				'node_disk_written_bytes_total{device="mmcblk1"} 3051520000',
				'node_disk_write_time_seconds_total{device="mmcblk1"} 2038.873',
			]), r.lines);
			assert.match([], filter(r.lines, (l) => match(l, /device="(loop|mmcblk0p|mmcblk1p|mmcblk0boot)/)));
		});
	});

	it("writes node_exporter's types and help texts", () => {
		with_collector(diskstats, { fs: fs_of(ROUTER) }, (r) => {
			let types = {};
			for (let f in r.families)
				types[f.name] = f.type;

			assert.match(contains([
				'# HELP node_disk_info Info of /sys/block/<block_device>.',
				'# HELP node_disk_written_bytes_total The total number of bytes written successfully.',
				'# HELP node_disk_io_now The number of I/Os currently in progress.',
				'# HELP node_disk_flush_requests_total The total number of flush requests completed successfully',
			]), r.lines);
			assert.match([ 'gauge', 'gauge' ], [ types.node_disk_info, types.node_disk_io_now ]);
			assert.match([], filter(keys(types), (n) => !(n in [ 'node_disk_info', 'node_disk_io_now' ]) && types[n] != 'counter'));
			assert.match([], filter(keys(types), (n) => types[n] == 'counter' && !match(n, /_total$/)));
		});
	});

	it('has nothing to observe on the caju AP, whose block devices are flash and loop devices', () => {
		with_collector(diskstats, { fs: fs_of(AP) }, (r) => {
			assert.match({ ok: true, none: 'device_exclude leaves out every block device', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('has nothing to observe without a block device at all', () => {
		with_collector(diskstats, file(''), (r) => {
			assert.match({ ok: true, none: 'no block devices', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it("exports a kernel 4.14 line's 11 fields, and no discard or flush family", () => {
		with_collector(diskstats, { fs: fs_of(OLD) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_disk_info{device="sda",major="8",minor="0",rotational="1"} 1',
				'node_disk_reads_completed_total{device="sda"} 4310',
				'node_disk_reads_merged_total{device="sda"} 1022',
				'node_disk_read_bytes_total{device="sda"} 211269632',
				'node_disk_read_time_seconds_total{device="sda"} 21.84',
				'node_disk_writes_completed_total{device="sda"} 2981',
				'node_disk_writes_merged_total{device="sda"} 4870',
				'node_disk_written_bytes_total{device="sda"} 128978944',
				'node_disk_write_time_seconds_total{device="sda"} 98.41',
				'node_disk_io_now{device="sda"} 0',
				'node_disk_io_time_seconds_total{device="sda"} 41.23',
				'node_disk_io_time_weighted_seconds_total{device="sda"} 120.25',
			], samples(r.lines));
		});
	});

	it('leaves out mtdblock, ubiblock, zram, loop and the partitions of a disk by default', () => {
		let excluded = [ 'mtdblock0', 'ubiblock0_1', 'zram0', 'ram0', 'loop7', 'sda1', 'vdb2', 'xvda1', 'nvme0n1p2',
			'mmcblk0p1', 'mmcblk1boot0', 'fd0' ];
		let kept = [ 'sda', 'sdb', 'vda', 'nvme0n1', 'mmcblk0', 'mmcblk1', 'md0', 'dm-0', 'mtd0', 'ubi0' ];
		let rx = regexp(diskstats.DEFAULT_EXCLUDE);

		assert.match([ excluded, [] ], [ filter(excluded, (d) => match(d, rx)), filter(kept, (d) => match(d, rx)) ]);
	});

	it('exports what the device_exclude option leaves', () => {
		with_collector(diskstats, { fs: fs_of(ROUTER), options: { device_exclude: '^(loop|mmcblk0)' } }, (r) => {
			assert.match([ 'mmcblk1', 'mmcblk1p1' ],
				map(filter(r.lines, (l) => index(l, 'node_disk_info{') == 0), (l) => match(l, /device="([^"]+)"/)[1]));
		});
		with_collector(diskstats, { fs: fs_of(AP), options: { device_exclude: '^$' } }, (r) => {
			assert.match(16, length(filter(r.lines, (l) => index(l, 'node_disk_info{') == 0)));
			assert.match(contains([ 'node_disk_read_bytes_total{device="mtdblock6"} 12371968' ]), r.lines);
		});
	});

	it('says a device without a queue directory is not rotational, as node_exporter does', () => {
		with_collector(diskstats, { fs: fs_of(ROUTER), options: { device_exclude: '^(loop|mmcblk0($|boot))' } }, (r) => {
			assert.match(contains([ 'node_disk_info{device="mmcblk1p1",major="179",minor="97",rotational="0"} 1' ]), r.lines);
		});
	});

	it('fails with CONFIG_INVALID for a device_exclude that is no regular expression', () => {
		with_collector(diskstats, file(OLD[PATH], { device_exclude: '(sd' }), (r) => {
			assert.match({ ok: false, error: 'CONFIG_INVALID' }, { ok: r.result.ok, error: r.result.error });
			assert.match(0, index(r.result.details, 'device_exclude: '));
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_UNREADABLE without /proc/diskstats', () => {
		with_collector(diskstats, file(null), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: PATH },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_INVALID for a field that is no integer, and writes nothing', () => {
		let text = '   8       0 sda 1 2 3 4 5 6 7 8 9 10 11\n   8      16 sdb 1 2 x 4 5 6 7 8 9 10 11\n';

		with_collector(diskstats, file(text), (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID' }, { ok: r.result.ok, error: r.result.error });
			assert.match(0, index(r.result.details, `${PATH}: line 2: `));
			assert.match([], r.lines);
		});
	});

	it('leaves out a line of fewer than 14 fields, as procfs does, and one device_exclude leaves out', () => {
		let text = '   8       0 sda 1 2 3 4 5 6 7 8 9 10 11\n   8       1 sda1 335 17330 0 0\n   7       0 loop0 1 2 x\n';

		with_collector(diskstats, file(text), (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'sda' ], uniq(map(samples(r.lines), (l) => match(l, /device="([^"]+)"/)[1])));
		});
	});

	it('reads sectors as 512 bytes and ticks as milliseconds', () => {
		assert.match([ 1024, 1.5, 7 ], [ diskstats.scaled(2, 512), diskstats.scaled(1500, 0.001), diskstats.scaled(7) ]);
	});

	prop('exports every field of a line of 14 to 20, scaled to bytes and seconds',
		gen.tuple(gen.int(11, 17), gen.array(gen.int(0, 1 << 40), { min_len: 17, max_len: 17 })), (t) => {
			let n = t[0], v = slice(t[1], 0, n);
			let line = sprintf('%4d %7d %s %s\n', 8, 0, 'sda', join(' ', v));
			let scale = [ null, null, 512, 0.001, null, null, 512, 0.001, null, 0.001, 0.001, null, null, null, 0.001, null, 0.001 ];

			with_collector(diskstats, file(line), (r) => {
				let got = filter(r.families, (f) => f.name != 'node_disk_info');

				assert.match(true, r.result.ok);
				assert.match(n, length(got));
				for (let i, f in got) {
					let want = scale[i] == 512 ? v[i] * 512 : (scale[i] ? v[i] / 1000.0 : v[i]);
					let delta = +f.samples[0].value - want;

					assert.match(true, delta > -0.0001 && delta < 0.0001, `${f.name}: ${f.samples[0].value} for ${v[i]}`);
				}
			});
		});

	prop('exports exactly the devices device_exclude does not match, in their order',
		gen.array(gen.elements('sda', 'sda1', 'nvme0n1', 'nvme0n1p1', 'mmcblk0', 'mmcblk0p2', 'mmcblk0boot1', 'mtdblock3',
			'ubiblock0_1', 'loop0', 'zram0', 'dm-0', 'md127'), { max_len: 12 }), (devices) => {
			devices = uniq(devices);
			let text = join('', map(devices, (d, i) => sprintf('%4d %7d %s 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17\n', 8, i, d)));
			let rx = regexp(diskstats.DEFAULT_EXCLUDE);
			let want = filter(devices, (d) => !match(d, rx));

			with_collector(diskstats, file(text), (r) => {
				assert.match(true, r.result.ok);
				assert.match(want, map(filter(r.lines, (l) => index(l, 'node_disk_info{') == 0), (l) => match(l, /device="([^"]+)"/)[1]));
				assert.match(length(want) ? null : (length(devices) ? 'device_exclude leaves out every block device' : 'no block devices'), r.result.none);
			});
		});
});

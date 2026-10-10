'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

export const DEFAULT_EXCLUDE = '^(z?ram|loop|fd|(h|s|v|xv)d[a-z]|nvme[0-9]+n[0-9]+p|mtdblock|ubiblock[0-9]+_|mmcblk[0-9]+(p|boot))[0-9]+$';

export const meta = {
	name: 'diskstats',
	title: 'Disk I/O',
	help: 'Reads, writes, discards and flushes of each disk, and the time spent on them, from /proc/diskstats, as node_exporter has them.',
	needs: [ 'fs' ],
	options: {
		device_exclude: {
			default: DEFAULT_EXCLUDE,
			title: 'Excluded devices',
			datatype: 'regex',
			help: 'A regular expression of the block devices to leave out: by default RAM disks, zram, loop devices, flash (mtdblock, ubiblock) and the partitions of disks, whose I/O their disk counts. ^$ leaves out none.',
		},
	},
};

export const PATH = '/proc/diskstats';

const SECTOR = 512;
const TICK = 0.001;

const STATS = [
	[ 'counter', 'node_disk_reads_completed_total', 'The total number of reads completed successfully.' ],
	[ 'counter', 'node_disk_reads_merged_total', 'The total number of reads merged.' ],
	[ 'counter', 'node_disk_read_bytes_total', 'The total number of bytes read successfully.', SECTOR ],
	[ 'counter', 'node_disk_read_time_seconds_total', 'The total number of seconds spent by all reads.', TICK ],
	[ 'counter', 'node_disk_writes_completed_total', 'The total number of writes completed successfully.' ],
	[ 'counter', 'node_disk_writes_merged_total', 'The number of writes merged.' ],
	[ 'counter', 'node_disk_written_bytes_total', 'The total number of bytes written successfully.', SECTOR ],
	[ 'counter', 'node_disk_write_time_seconds_total', 'This is the total number of seconds spent by all writes.', TICK ],
	[ 'gauge', 'node_disk_io_now', 'The number of I/Os currently in progress.' ],
	[ 'counter', 'node_disk_io_time_seconds_total', 'Total seconds spent doing I/Os.', TICK ],
	[ 'counter', 'node_disk_io_time_weighted_seconds_total', 'The weighted # of seconds spent doing I/Os.', TICK ],
	[ 'counter', 'node_disk_discards_completed_total', 'The total number of discards completed successfully.' ],
	[ 'counter', 'node_disk_discards_merged_total', 'The total number of discards merged.' ],
	[ 'counter', 'node_disk_discarded_sectors_total', 'The total number of sectors discarded successfully.' ],
	[ 'counter', 'node_disk_discard_time_seconds_total', 'This is the total number of seconds spent by all discards.', TICK ],
	[ 'counter', 'node_disk_flush_requests_total', 'The total number of flush requests completed successfully' ],
	[ 'counter', 'node_disk_flush_requests_time_seconds_total', 'This is the total number of seconds spent by all flush requests.', TICK ],
];

const MIN_FIELDS = 14;

export function scaled(n, scale) {
	if (scale == SECTOR)
		return n * SECTOR;
	if (scale == TICK)
		return n / 1000.0;

	return n;
};

export function parse(rows, exclude) {
	let out = [];

	for (let i, line in rows) {
		let f = proc.fields(line);

		if (length(f) < MIN_FIELDS || match(f[2], exclude))
			continue;

		let values = [];
		for (let j = 3; j < length(f) && j - 3 < length(STATS); j++) {
			let n = +f[j];

			if (type(n) != 'int')
				return `line ${i + 1}: ${sprintf('%J', line)}`;
			push(values, n);
		}

		push(out, { device: f[2], major: f[0], minor: f[1], values });
	}

	return out;
};

function rotational(fs, device) {
	return trim(proc.first_line(fs, `/sys/block/${device}/queue/rotational`) ?? '') == '1' ? '1' : '0';
}

export function collect(deps, out, options) {
	let exclude;

	try {
		exclude = regexp(options.device_exclude);
	} catch (e) {
		return Result.err(errors.CONFIG_INVALID, `device_exclude: ${e.message}`);
	}

	let rows = proc.lines(deps.fs, PATH);
	if (rows == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	let disks = parse(rows, exclude);
	if (type(disks) == 'string')
		return Result.err(errors.SOURCE_INVALID, `${PATH}: ${disks}`);
	if (!length(disks))
		return length(filter(rows, (l) => length(proc.fields(l)) >= MIN_FIELDS))
			? Result.none('device_exclude leaves out every block device')
			: Result.none('no block devices');

	let info = out.gauge('node_disk_info', 'Info of /sys/block/<block_device>.');
	let record = map(STATS, (s) => out[s[0]](s[1], s[2]));

	for (let d in disks) {
		let labels = out.labels({ device: d.device });

		info({ device: d.device, major: d.major, minor: d.minor, rotational: rotational(deps.fs, d.device) }, 1);
		for (let i, n in d.values)
			record[i](labels, scaled(n, STATS[i][3]));
	}

	return Result.ok();
};

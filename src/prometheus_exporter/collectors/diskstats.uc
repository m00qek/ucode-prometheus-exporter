'use strict';

// node_exporter's diskstats collector (collector/diskstats_linux.go, over
// procfs's blockdevice.ProcDiskstats): each block device of /proc/diskstats
// that the `device_exclude` option does not leave out, labeled `device`, with
// node_exporter's names, types and help texts. Sectors are the kernel's 512
// bytes whatever the device's own block size, and times its milliseconds:
// both in base units, bytes and seconds, as node_exporter has them, but for
// the discarded sectors, which it leaves as sectors.
//
// A line has 14 fields up to kernel 4.18, 18 with the discard statistics, and
// 20 with the flush statistics since 5.5; as node_exporter does, a device has
// the families its line has fields for, and a line of fewer than 14 fields (a
// partition of a 2.6.24 kernel or older) is left out.
//
// node_disk_info has the device's major and minor numbers and whether it is
// rotational (/sys/block/<device>/queue/rotational, 0 when there is none, as
// for a partition), as node_exporter's; its labels from udev's database
// (path, wwn, model, serial, revision) are not there: OpenWrt has no udev, and
// node_exporter leaves them empty without it.
//
// The default `device_exclude` is node_exporter's, which leaves out RAM
// disks, zram, loop devices, floppies and the partitions of SCSI, IDE, virtio,
// Xen and NVMe disks (whose I/O their disk counts), with what a router has
// besides: flash (mtdblock, ubiblock), and an eMMC's or SD card's partitions
// and boot areas (mmcblkNpN, mmcblkNbootN), as node_exporter leaves out other
// disks' partitions. zram stays out, as there: OpenWrt's zram-swap is swap,
// whose traffic is vmstat's pswpin and pswpout already. A router without a
// disk, the usual one, then has nothing to observe.

import { Result, errors, proc } from 'prometheus_exporter.api';

export const DEFAULT_EXCLUDE = '^(z?ram|loop|fd|(h|s|v|xv)d[a-z]|nvme[0-9]+n[0-9]+p|mtdblock|ubiblock[0-9]+_|mmcblk[0-9]+(p|boot))[0-9]+$';

export const meta = {
	name: 'diskstats',
	title: 'Disk I/O',
	help: 'Reads, writes, discards and flushes of each disk, and the time spent on them, from /proc/diskstats, as node_exporter has them.',
	needs: [ 'fs' ],
	options: {
		device_exclude: {
			default: DEFAULT_EXCLUDE,
			datatype: 'regex',
			help: 'A regular expression of the block devices to leave out: by default RAM disks, zram, loop devices, flash (mtdblock, ubiblock) and the partitions of disks, whose I/O their disk counts. ^$ leaves out none.',
		},
	},
};

export const PATH = '/proc/diskstats';

// The kernel's sector, 512 bytes whatever the device's, and its ticks, ms.
const SECTOR = 512;
const TICK = 0.001;

// After major, minor and name, each field of a line, in the kernel's order
// (Documentation/admin-guide/iostats.rst): [ type, name, help, scale ].
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
	// Kernel 4.18.
	[ 'counter', 'node_disk_discards_completed_total', 'The total number of discards completed successfully.' ],
	[ 'counter', 'node_disk_discards_merged_total', 'The total number of discards merged.' ],
	[ 'counter', 'node_disk_discarded_sectors_total', 'The total number of sectors discarded successfully.' ],
	[ 'counter', 'node_disk_discard_time_seconds_total', 'This is the total number of seconds spent by all discards.', TICK ],
	// Kernel 5.5.
	[ 'counter', 'node_disk_flush_requests_total', 'The total number of flush requests completed successfully' ],
	[ 'counter', 'node_disk_flush_requests_time_seconds_total', 'This is the total number of seconds spent by all flush requests.', TICK ],
];

// The fewest fields of a line procfs takes: the 11 statistics of kernels before 4.18.
const MIN_FIELDS = 14;

// A value in its base unit: `scale` 512 makes sectors bytes, 0.001 ms seconds.
export function scaled(n, scale) {
	if (scale == SECTOR)
		return n * SECTOR;
	if (scale == TICK)
		return n / 1000.0;

	return n;
};

// The lines of /proc/diskstats to export, each { device, major, minor,
// values }, values the statistics as integers; or a string saying what is
// wrong with the first malformed line of a device not left out.
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

// node_exporter's rotationalLabel: "1" for a rotational device, else "0".
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

'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as fixtures from 'lib.fixtures';
import { with_collector } from 'prometheus.exporter.devkit.collector';
import * as filesystem from 'prometheus.collectors.filesystem';

// The host's mount table, as rpcd's file read gives it.
const ROUTER_MOUNTS = fixtures.ubus('caju-router', 'file', 'read');
const ROUTER_POINTS = fixtures.ubus('caju-router', 'luci', 'getMountPoints');
const AP_MOUNTS = fixtures.ubus('caju-ap', 'file', 'read');
const AP_POINTS = fixtures.ubus('caju-ap', 'luci', 'getMountPoints');

// What the jail's own /proc/self/mounts holds: procd's jail mounts, none of the
// host's disks, and the bind mounts read-only.
const JAIL_MOUNTS = '/dev/root / squashfs ro,relatime 0 0\n' +
	'tmpfs /tmp tmpfs ro,nosuid,nodev,noatime 0 0\n' +
	'proc /proc proc ro,nosuid,nodev,noexec,relatime 0 0\n' +
	'sysfs /sys sysfs ro,nosuid,nodev,noexec,relatime 0 0\n';

// getMountPoints' points as the package's rpcd object gives them, with their
// inodes: no capture holds its reply (see test/fixtures/SOURCES), so each
// point gets a count of its own, as statvfs() would give it.
function with_inodes(points) {
	return { result: map(points.result, (p, i) => ({ ...p, files: 1000 * (i + 1), ffree: 900 * (i + 1) })) };
}

// mounts: the host's /proc/mounts, rpcd's reply ({ data }) or its text;
// points: the reply of the package's rpcd object.
function cfg(mounts, points) {
	return {
		ubus: { data: { 'file:read': type(mounts) == 'string' ? { data: mounts } : mounts, 'prometheus-exporter.filesystem:mounts': points } },
	};
}

// As where rpcd has not loaded the package's plugin: luci's getMountPoints.
function cfg_luci(mounts, points) {
	return {
		ubus: {
			data: { 'file:read': type(mounts) == 'string' ? { data: mounts } : mounts, 'luci:getMountPoints': points },
			errors: { 'prometheus-exporter.filesystem': 'Not found' },
		},
	};
}

describe('collectors.filesystem', () => {
	it('exports /tmp, /overlay and the /mnt/data disk of the caju router', () => {
		with_collector(filesystem, cfg(ROUTER_MOUNTS, with_inodes(ROUTER_POINTS)), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_filesystem_size_bytes Filesystem size in bytes.',
				'# TYPE node_filesystem_size_bytes gauge',
				'node_filesystem_size_bytes{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 2062958592',
				'node_filesystem_size_bytes{device="/dev/loop0",fstype="f2fs",mountpoint="/overlay"} 26835746816',
				'node_filesystem_size_bytes{device="/dev/mmcblk0p1",fstype="ext4",mountpoint="/mnt/data"} 31232282624',
				'# HELP node_filesystem_free_bytes Filesystem free space in bytes.',
				'# TYPE node_filesystem_free_bytes gauge',
				'node_filesystem_free_bytes{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 2060828672',
				'node_filesystem_free_bytes{device="/dev/loop0",fstype="f2fs",mountpoint="/overlay"} 26330566656',
				'node_filesystem_free_bytes{device="/dev/mmcblk0p1",fstype="ext4",mountpoint="/mnt/data"} 30541967360',
				'# HELP node_filesystem_avail_bytes Filesystem space available to non-root users in bytes.',
				'# TYPE node_filesystem_avail_bytes gauge',
				'node_filesystem_avail_bytes{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 2060828672',
				'node_filesystem_avail_bytes{device="/dev/loop0",fstype="f2fs",mountpoint="/overlay"} 26330566656',
				'node_filesystem_avail_bytes{device="/dev/mmcblk0p1",fstype="ext4",mountpoint="/mnt/data"} 28929495040',
				'# HELP node_filesystem_files Filesystem total file nodes.',
				'# TYPE node_filesystem_files gauge',
				'node_filesystem_files{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 2000',
				'node_filesystem_files{device="/dev/loop0",fstype="f2fs",mountpoint="/overlay"} 3000',
				'node_filesystem_files{device="/dev/mmcblk0p1",fstype="ext4",mountpoint="/mnt/data"} 6000',
				'# HELP node_filesystem_files_free Filesystem total free file nodes.',
				'# TYPE node_filesystem_files_free gauge',
				'node_filesystem_files_free{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 1800',
				'node_filesystem_files_free{device="/dev/loop0",fstype="f2fs",mountpoint="/overlay"} 2700',
				'node_filesystem_files_free{device="/dev/mmcblk0p1",fstype="ext4",mountpoint="/mnt/data"} 5400',
				'# HELP node_filesystem_readonly Filesystem read-only status.',
				'# TYPE node_filesystem_readonly gauge',
				'node_filesystem_readonly{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 0',
				'node_filesystem_readonly{device="/dev/loop0",fstype="f2fs",mountpoint="/overlay"} 0',
				'node_filesystem_readonly{device="/dev/mmcblk0p1",fstype="ext4",mountpoint="/mnt/data"} 0',
			], r.lines);
		});
	});

	it('exports /tmp and the jffs2 /overlay of the caju AP', () => {
		with_collector(filesystem, cfg(AP_MOUNTS, with_inodes(AP_POINTS)), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_filesystem_size_bytes{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 122658816',
				'node_filesystem_size_bytes{device="/dev/mtdblock7",fstype="jffs2",mountpoint="/overlay"} 1703936',
			], filter(r.lines, (l) => match(l, /^node_filesystem_size_bytes\{/)));
			assert.match([
				'node_filesystem_avail_bytes{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 122286080',
				'node_filesystem_avail_bytes{device="/dev/mtdblock7",fstype="jffs2",mountpoint="/overlay"} 1175552',
			], filter(r.lines, (l) => match(l, /^node_filesystem_avail_bytes\{/)));
		});
	});

	it('reads the ro option and the octal escapes of the host\'s /proc/mounts', () => {
		let mounts = '/dev/sda1 /mnt/usb\\040disk vfat ro,relatime,fmask=0022 0 0\n' +
			'/dev/sda1 /mnt/usb\\040disk vfat ro,relatime,fmask=0022 0 0\n';
		let points = { result: [ { device: '/dev/sda1', mount: '/mnt/usb disk', size: 4096, avail: 1024, free: 2048, files: 0, ffree: 0 } ] };

		with_collector(filesystem, cfg(mounts, points), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_filesystem_size_bytes{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 4096',
				'node_filesystem_free_bytes{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 2048',
				'node_filesystem_avail_bytes{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 1024',
				'node_filesystem_files{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 0',
				'node_filesystem_files_free{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 0',
				'node_filesystem_readonly{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 1',
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('leaves out a mount that rpcd could not statvfs', () => {
		let points = { result: filter(with_inodes(ROUTER_POINTS).result, (p) => p.mount != '/mnt/data') };

		with_collector(filesystem, cfg(ROUTER_MOUNTS, points), (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, index(r.text, '/mnt/data') >= 0);
			assert.match(2, length(filter(r.lines, (l) => match(l, /^node_filesystem_readonly\{/))));
		});
	});

	it("writes the sizes alone, from luci's getMountPoints, where rpcd has not loaded the package's plugin", () => {
		with_collector(filesystem, cfg_luci(ROUTER_MOUNTS, ROUTER_POINTS), (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_filesystem_size_bytes', 'node_filesystem_free_bytes', 'node_filesystem_avail_bytes', 'node_filesystem_readonly' ],
				map(r.families, (f) => f.name));
			assert.match(12, length(filter(r.lines, (l) => substr(l, 0, 1) != '#')));
		});
	});

	it('passes on a missing luci ubus object too (luci-base not installed)', () => {
		let c = { ubus: { data: { 'file:read': ROUTER_MOUNTS }, errors: { 'prometheus-exporter.filesystem': 'Not found', luci: 'Not found' } } };

		with_collector(filesystem, c, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'luci getMountPoints: Not found' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID when the package\'s rpcd object reports an error, or getMountPoints does', () => {
		with_collector(filesystem, cfg(ROUTER_MOUNTS, { error: 'luci.core: module not found' }), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: 'prometheus-exporter.filesystem mounts: luci.core: module not found' },
				{ error: r.result.error, details: r.result.details });
		});
		with_collector(filesystem, cfg_luci(ROUTER_MOUNTS, { error: 'Permission denied' }), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: 'luci getMountPoints: Permission denied' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('passes on another failure of the package\'s rpcd object, without asking luci', () => {
		let c = { ubus: { data: { 'file:read': ROUTER_MOUNTS }, errors: { 'prometheus-exporter.filesystem': 'Request timed out' } } };

		with_collector(filesystem, c, (r) => {
			assert.match({ error: 'UBUS_CALL_FAILED', details: 'prometheus-exporter.filesystem mounts: Request timed out' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('passes on rpcd failing to read the host\'s /proc/mounts', () => {
		let c = { ubus: { data: { 'prometheus-exporter.filesystem:mounts': with_inodes(ROUTER_POINTS) }, errors: { 'file:read': 'Request timed out' } } };

		with_collector(filesystem, c, (r) => {
			assert.match({ error: 'UBUS_CALL_FAILED', details: 'file read: Request timed out' },
				{ error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID when rpcd\'s file read gives no data', () => {
		with_collector(filesystem, cfg({}, with_inodes(ROUTER_POINTS)), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: 'file read /proc/mounts: no data' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('reads the host\'s mount table, not the jail\'s', () => {
		let c = cfg(ROUTER_MOUNTS, with_inodes(ROUTER_POINTS));
		c.fs = { data: { '/proc/self/mounts': JAIL_MOUNTS, '/proc/mounts': JAIL_MOUNTS, '/proc/1/mounts': JAIL_MOUNTS } };

		with_collector(filesystem, c, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_filesystem_readonly{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 0',
				'node_filesystem_readonly{device="/dev/loop0",fstype="f2fs",mountpoint="/overlay"} 0',
				'node_filesystem_readonly{device="/dev/mmcblk0p1",fstype="ext4",mountpoint="/mnt/data"} 0',
			], filter(r.lines, (l) => match(l, /^node_filesystem_readonly\{/)));
		});
	});

	it('excludes pseudo filesystems and the mount points under /dev, /proc, /sys and container storage', () => {
		for (let t in [ 'overlay', 'squashfs', 'tmpfs' ])
			assert.match(t != 'tmpfs', filesystem.excluded('/mnt/x', t), t);

		assert.match(true, filesystem.excluded('/dev', 'tmpfs'));
		assert.match(true, filesystem.excluded('/sys/fs/cgroup', 'tmpfs'));
		assert.match(true, filesystem.excluded('/run/credentials/x.service', 'ramfs'));
		assert.match(false, filesystem.excluded('/run', 'tmpfs'));
		assert.match(false, filesystem.excluded('/devices', 'ext4'));
		assert.match(false, filesystem.excluded('/mnt/proc', 'ext4'));
	});

	prop('excludes whatever lies under an excluded mount point, and nothing that only shares its prefix',
		gen.tuple(gen.elements('/dev', '/proc', '/sys', '/var/lib/docker', '/run/credentials', '/var/lib/containers/storage'),
			gen.alphanumeric({ min_len: 1, max_len: 12 })), (t) => {
			assert.match(true, filesystem.excluded(`${t[0]}/${t[1]}`, 'ext4'));
			assert.match(true, filesystem.excluded(t[0], 'ext4'));
			assert.match(false, filesystem.excluded(`${t[0]}${t[1]}`, 'ext4'));
			assert.match(false, filesystem.excluded(`/mnt${t[0]}`, 'ext4'));
		});

	prop('exports every mounted disk rpcd sized, with its sizes and inodes',
		gen.array(gen.tuple(gen.alphanumeric({ min_len: 1, max_len: 8 }), gen.int(1, 1 << 40), gen.bool(), gen.int(0, 1 << 32)),
			{ min_len: 0, max_len: 6 }), (disks) => {
			let mounts = '', result = [], want = {};

			for (let i, d in disks) {
				let mp = `/mnt/${d[0]}${i}`;
				mounts += `/dev/sd${i} ${mp} ext4 ${d[2] ? 'ro' : 'rw'},relatime 0 0\n`;
				push(result, { device: `/dev/sd${i}`, mount: mp, size: d[1], avail: d[1] / 4, free: d[1] / 2, files: d[3], ffree: d[3] / 2 });
				want[mp] = d;
			}

			with_collector(filesystem, cfg(mounts, { result }), (r) => {
				assert.match(true, r.result.ok);

				let got = {};
				for (let fam in r.families)
					for (let s in fam.samples)
						got[`${fam.name} ${s.labels[2][1]}`] = +s.value;

				for (let mp, d in want) {
					assert.match(d[1], got[`node_filesystem_size_bytes ${mp}`]);
					assert.match(d[1] / 2, got[`node_filesystem_free_bytes ${mp}`]);
					assert.match(d[2] ? 1 : 0, got[`node_filesystem_readonly ${mp}`]);
					assert.match(d[3], got[`node_filesystem_files ${mp}`]);
					assert.match(d[3] / 2, got[`node_filesystem_files_free ${mp}`]);
				}
				assert.match(6 * length(disks), length(keys(got)));
			});
		});
});

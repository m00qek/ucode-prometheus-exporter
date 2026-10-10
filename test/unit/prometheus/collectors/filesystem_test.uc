'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as fixtures from 'lib.fixtures';
import { with_collector } from 'prometheus.exporter.devkit.collector';
import * as filesystem from 'prometheus.collectors.filesystem';

// The package's rpcd object's reply on each device: its mounts with blocks,
// as /proc/mounts and statvfs() give them (see test/fixtures/SOURCES).
const ROUTER_POINTS = fixtures.ubus('caju-router', 'prometheus-exporter.filesystem', 'mounts');
const AP_POINTS = fixtures.ubus('caju-ap', 'prometheus-exporter.filesystem', 'mounts');

// The captures have no inode counts: each point gets a count of its own, as
// statvfs() would give it.
function with_inodes(points) {
	return { result: map(points.result, (p, i) => ({ ...p, files: 1000 * (i + 1), ffree: 900 * (i + 1) })) };
}

function cfg(points) {
	return { ubus: { data: { 'prometheus-exporter.filesystem:mounts': points } } };
}

describe('collectors.filesystem', () => {
	it('exports /tmp, /overlay and the /mnt/data disk of the caju router', () => {
		with_collector(filesystem, cfg(with_inodes(ROUTER_POINTS)), (r) => {
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
		with_collector(filesystem, cfg(with_inodes(AP_POINTS)), (r) => {
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

	it('writes the read-only flag and the fstype of each mount, as the plugin read them', () => {
		let points = { result: [
			{ device: '/dev/sda1', mount: '/mnt/usb disk', fstype: 'vfat', ro: true, size: 4096, avail: 1024, free: 2048, files: 0, ffree: 0 },
			{ device: '/dev/sda1', mount: '/mnt/usb disk', fstype: 'vfat', ro: true, size: 4096, avail: 1024, free: 2048, files: 0, ffree: 0 },
		] };

		with_collector(filesystem, cfg(points), (r) => {
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

	it('leaves out a mount the plugin could not statvfs, and a point that is not one', () => {
		let points = { result: [
			...filter(with_inodes(ROUTER_POINTS).result, (p) => p.mount != '/mnt/data'),
			null, 'x', { device: '/dev/sdb1', mount: '/mnt/b', size: 1 },
		] };

		with_collector(filesystem, cfg(points), (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, index(r.text, '/mnt/data') >= 0);
			assert.match(false, index(r.text, '/mnt/b') >= 0);
			assert.match(2, length(filter(r.lines, (l) => match(l, /^node_filesystem_readonly\{/))));
		});
	});

	it('calls the package\'s rpcd object alone: never rpcd\'s file read, which reads any file as root', () => {
		assert.match({ 'prometheus-exporter.filesystem': [ 'mounts' ] }, filesystem.meta.ubus);
	});

	it('fails, saying how to load it, where rpcd has not loaded the package\'s plugin', () => {
		let c = { ubus: { errors: { 'prometheus-exporter.filesystem': 'Not found' } } };

		with_collector(filesystem, c, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match(true, index(r.result.details, 'rpcd has not loaded the package\'s plugin') >= 0, r.result.details);
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID when the package\'s rpcd object reports an error', () => {
		with_collector(filesystem, cfg({ error: 'luci.core: module not found' }), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: 'prometheus-exporter.filesystem mounts: luci.core: module not found' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('passes on another failure of the package\'s rpcd object', () => {
		let c = { ubus: { errors: { 'prometheus-exporter.filesystem': 'Request timed out' } } };

		with_collector(filesystem, c, (r) => {
			assert.match({ error: 'UBUS_CALL_FAILED', details: 'prometheus-exporter.filesystem mounts: Request timed out' },
				{ error: r.result.error, details: r.result.details });
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
			let result = [], want = {};

			for (let i, d in disks) {
				let mp = `/mnt/${d[0]}${i}`;
				push(result, { device: `/dev/sd${i}`, mount: mp, fstype: 'ext4', ro: d[2], size: d[1], avail: d[1] / 4, free: d[1] / 2, files: d[3], ffree: d[3] / 2 });
				want[mp] = d;
			}

			with_collector(filesystem, cfg({ result }), (r) => {
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

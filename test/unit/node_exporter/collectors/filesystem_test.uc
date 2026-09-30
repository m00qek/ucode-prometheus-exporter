'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as fixtures from 'lib.fixtures';
import { with_collector } from 'context';
import * as filesystem from 'node_exporter.collectors.filesystem';

const ROUTER_MOUNTS = fixtures.files('caju-router', [ '/proc/self/mounts' ]);
const ROUTER_POINTS = fixtures.ubus('caju-router', 'luci', 'getMountPoints');
const AP_MOUNTS = fixtures.files('caju-ap', [ '/proc/self/mounts' ]);
const AP_POINTS = fixtures.ubus('caju-ap', 'luci', 'getMountPoints');

function cfg(mounts, points) {
	return {
		fs: { data: type(mounts) == 'string' ? { '/proc/self/mounts': mounts } : mounts },
		ubus: { data: { 'luci:getMountPoints': points } },
	};
}

describe('collectors.filesystem', () => {
	it('exports /tmp, /overlay and the /mnt/data disk of the caju router', () => {
		with_collector(filesystem, cfg(ROUTER_MOUNTS, ROUTER_POINTS), (r) => {
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
				'# HELP node_filesystem_readonly Filesystem read-only status.',
				'# TYPE node_filesystem_readonly gauge',
				'node_filesystem_readonly{device="tmpfs",fstype="tmpfs",mountpoint="/tmp"} 0',
				'node_filesystem_readonly{device="/dev/loop0",fstype="f2fs",mountpoint="/overlay"} 0',
				'node_filesystem_readonly{device="/dev/mmcblk0p1",fstype="ext4",mountpoint="/mnt/data"} 0',
			], r.lines);
		});
	});

	it('exports /tmp and the jffs2 /overlay of the caju AP', () => {
		with_collector(filesystem, cfg(AP_MOUNTS, AP_POINTS), (r) => {
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

	it('reads the ro option and the octal escapes of /proc/self/mounts', () => {
		let mounts = '/dev/sda1 /mnt/usb\\040disk vfat ro,relatime,fmask=0022 0 0\n' +
			'/dev/sda1 /mnt/usb\\040disk vfat ro,relatime,fmask=0022 0 0\n';
		let points = { result: [ { device: '/dev/sda1', mount: '/mnt/usb disk', size: 4096, avail: 1024, free: 2048 } ] };

		with_collector(filesystem, cfg(mounts, points), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_filesystem_size_bytes{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 4096',
				'node_filesystem_free_bytes{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 2048',
				'node_filesystem_avail_bytes{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 1024',
				'node_filesystem_readonly{device="/dev/sda1",fstype="vfat",mountpoint="/mnt/usb disk"} 1',
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('leaves out a mount that getMountPoints could not statvfs', () => {
		let points = { result: filter(ROUTER_POINTS.result, (p) => p.mount != '/mnt/data') };

		with_collector(filesystem, cfg(ROUTER_MOUNTS, points), (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, index(r.text, '/mnt/data') >= 0);
			assert.match(2, length(filter(r.lines, (l) => match(l, /^node_filesystem_readonly\{/))));
		});
	});

	it('passes on a missing luci ubus object (luci-base not installed)', () => {
		let c = { fs: { data: ROUTER_MOUNTS }, ubus: { errors: { luci: 'Not found' } } };

		with_collector(filesystem, c, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'luci getMountPoints: Not found' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID when getMountPoints reports an error', () => {
		with_collector(filesystem, cfg(ROUTER_MOUNTS, { error: 'Permission denied' }), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: 'luci getMountPoints: Permission denied' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_UNREADABLE when /proc/self/mounts cannot be read', () => {
		with_collector(filesystem, cfg({ '/proc/self/mounts': null }, ROUTER_POINTS), (r) => {
			assert.match({ error: 'SOURCE_UNREADABLE', details: '/proc/self/mounts' },
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

	prop('exports every mounted disk getMountPoints sized, with its sizes',
		gen.array(gen.tuple(gen.alphanumeric({ min_len: 1, max_len: 8 }), gen.int(1, 1 << 40), gen.bool()),
			{ min_len: 0, max_len: 6 }), (disks) => {
			let mounts = '', result = [], want = {};

			for (let i, d in disks) {
				let mp = `/mnt/${d[0]}${i}`;
				mounts += `/dev/sd${i} ${mp} ext4 ${d[2] ? 'ro' : 'rw'},relatime 0 0\n`;
				push(result, { device: `/dev/sd${i}`, mount: mp, size: d[1], avail: d[1] / 4, free: d[1] / 2 });
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
				}
				assert.match(4 * length(disks), length(keys(got)));
			});
		});
});

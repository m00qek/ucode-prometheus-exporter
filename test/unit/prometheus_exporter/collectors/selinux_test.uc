'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as selinux from 'prometheus_exporter.collectors.selinux';

const ENFORCE = '/sys/fs/selinux/enforce';

// OpenWrt builds without SELinux, as on both caju devices: no selinuxfs. The
// enforcing one is made up: selinuxfs's enforce is the mode as a bare "%d".
const ENFORCING = fixtures.files('synthetic', [ ENFORCE ]);

describe('collectors.selinux', () => {
	it('reports SELinux disabled where there is no selinuxfs, as on the caju devices', () => {
		with_collector(selinux, { fs: { data: { [ENFORCE]: null } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_selinux_enabled SELinux is enabled, 1 is true, 0 is false',
				'# TYPE node_selinux_enabled gauge',
				'node_selinux_enabled 0',
			], r.lines);
		});
	});

	it('reports SELinux enabled and enforcing', () => {
		with_collector(selinux, { fs: { data: ENFORCING } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_selinux_enabled SELinux is enabled, 1 is true, 0 is false',
				'# TYPE node_selinux_enabled gauge',
				'node_selinux_enabled 1',
				'# HELP node_selinux_current_mode Current SELinux enforcement mode',
				'# TYPE node_selinux_current_mode gauge',
				'node_selinux_current_mode 1',
			], r.lines);
		});
	});

	it('reports permissive mode as 0', () => {
		with_collector(selinux, { fs: { data: { [ENFORCE]: '0' } } }, (r) => {
			assert.match([ 'node_selinux_enabled 1', 'node_selinux_current_mode 0' ],
				filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('fails with SOURCE_INVALID for a mode that is not a number, keeping node_selinux_enabled', () => {
		with_collector(selinux, { fs: { data: { [ENFORCE]: 'enforcing\n' } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: '/sys/fs/selinux/enforce: "enforcing"' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([ 'node_selinux_enabled 1' ], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	prop('exports the mode the kernel reports, with or without a newline',
		gen.tuple(gen.int(0, 1), gen.elements('', '\n')), (x) => {
			with_collector(selinux, { fs: { data: { [ENFORCE]: `${x[0]}${x[1]}` } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match([ 'node_selinux_enabled 1', `node_selinux_current_mode ${x[0]}` ],
					filter(r.lines, (l) => substr(l, 0, 1) != '#'));
			});
		});
});

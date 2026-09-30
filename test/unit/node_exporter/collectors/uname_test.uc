'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as exposition from 'node_exporter.exposition';
import * as uname from 'node_exporter.collectors.uname';

const FILES = map([ 'ostype', 'hostname', 'osrelease', 'version', 'arch', 'domainname' ], (f) => `/proc/sys/kernel/${f}`);

const ROUTER = fixtures.files('caju-router', FILES);
const AP = fixtures.files('caju-ap', FILES);

describe('collectors.uname', () => {
	it('labels node_uname_info with the caju router\'s kernel', () => {
		with_collector(uname, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_uname_info Labeled system information as provided by the uname system call.',
				'# TYPE node_uname_info gauge',
				'node_uname_info{sysname="Linux",nodename="router",release="6.12.94",' +
					'version="#0 SMP Mon Jun 29 12:59:20 2026",machine="aarch64",domainname="(none)"} 1',
			], r.lines);
		});
	});

	it('names the caju AP', () => {
		with_collector(uname, { fs: { data: AP } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(true, index(r.text, 'nodename="ap"') >= 0);
		});
	});

	it('leaves out a label it cannot read and fails with SOURCE_UNREADABLE, keeping the sample', () => {
		with_collector(uname, { fs: { data: { ...ROUTER, '/proc/sys/kernel/arch': null } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/sys/kernel/arch' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([ 'node_uname_info{sysname="Linux",nodename="router",release="6.12.94",' +
				'version="#0 SMP Mon Jun 29 12:59:20 2026",domainname="(none)"} 1' ],
				filter(r.lines, (l) => substr(l, 0, 1) != '#'));
			assert.match([ "collector 'uname': SOURCE_UNREADABLE (/proc/sys/kernel/arch)" ], r.logs);
		});
	});

	it('writes nothing when /proc/sys/kernel cannot be read at all', () => {
		let none = {};
		for (let f in FILES)
			none[f] = null;

		with_collector(uname, { fs: { data: none } }, (r) => {
			assert.match('SOURCE_UNREADABLE', r.result.error);
			assert.match([], r.lines);
		});
	});

	prop('carries any host and domain name through, escaped',
		gen.tuple(gen.ascii({ min_len: 1, max_len: 64 }), gen.ascii({ min_len: 0, max_len: 64 })), (names) => {
			let host = names[0], domain = names[1];
			let data = { ...ROUTER, '/proc/sys/kernel/hostname': host + '\n', '/proc/sys/kernel/domainname': domain + '\n' };

			with_collector(uname, { fs: { data } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(true, index(r.text, `nodename="${exposition.escape_label(host)}"`) >= 0);
				assert.match(true, index(r.text, `domainname="${exposition.escape_label(domain)}"} 1`) >= 0);
			});
		});
});

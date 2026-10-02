'use strict';

// The collector contract as test/context.uc's with_collector holds a test to
// it: on small collectors made here, each breaking one rule.

import { describe, it, prop, gen, assert } from 'utest';
import { parse_thrown } from 'utest.util';
import { with_collector } from 'context';
import * as Result from 'prometheus_exporter.result';

function collector(name, meta, collect) {
	return { meta: { name, title: 'Test', help: 'A collector of the contract\'s tests.', needs: [], ...meta }, collect };
}

// How with_collector(mod, cfg) ended: { kind, message } of what it threw
// ('fail' for a test's failure), or { ran } when it called its callback.
function run(mod, cfg) {
	let ran = false;

	try {
		with_collector(mod, cfg ?? {}, () => { ran = true; });
	} catch (e) {
		return parse_thrown(e);
	}

	return { ran };
}

describe('with_collector\'s contract check', () => {
	it('fails a test whose collector reads a path its meta does not declare, which reads as in the jail', () => {
		let saw = 'unread';
		let foo = collector('foo', { needs: [ 'fs', 'uci' ], configs: [ 'foo' ] }, function(deps) {
			saw = deps.fs.readfile('/etc/foo/state');
			return saw == null ? Result.err('SOURCE_UNREADABLE', '/etc/foo/state') : Result.ok();
		});

		assert.match({ kind: 'fail', message: join('\n', [
			"collector 'foo' read /etc/foo/state, which its meta does not declare.",
			"In the service's jail that path does not exist: the read returns null, as it did here.",
			"Declare it in meta.paths (or its directory: '/etc/foo'), or stop reading it.",
			'Declared: /proc, /sys, /etc/config/foo',
		]) }, run(foo, { fs: { data: { '/etc/foo/state': 'there, outside the jail' } } }));
		assert.match(null, saw);
	});

	it('fails one that falls back on a default when it cannot read it, and succeeds', () => {
		let quiet = collector('quiet', { needs: [ 'fs' ] }, function(deps, out) {
			out.gauge('quiet_value', 'A value.')(null, +(deps.fs.readfile('/srv/quiet/value') ?? '0'));
			return Result.ok();
		});

		assert.match({ kind: 'fail', message: join('\n', [
			"collector 'quiet' read /srv/quiet/value, which its meta does not declare.",
			"In the service's jail that path does not exist: the read returns null, as it did here.",
			"Declare it in meta.paths (or its directory: '/srv/quiet'), or stop reading it.",
			'Declared: /proc, /sys',
		]) }, run(quiet, { fs: { data: { '/srv/quiet/value': '42' } } }));
	});

	it('fails one that connects to a socket its meta does not declare, which is not there as in the jail', () => {
		let got = null;
		let sock = collector('sock', { needs: [ 'socket' ] }, function(deps) {
			got = deps.socket.unix_request('/var/run/foo/foo.sock', 'stats\n', 100);
			return got;
		});

		assert.match({ kind: 'fail', message: join('\n', [
			"collector 'sock' connected to the socket /var/run/foo/foo.sock, which its meta does not declare.",
			"In the service's jail that socket is not there: connect fails with 'No such file or directory', as it did here.",
			"Declare its directory in meta.paths ('/var/run/foo'): the jail cannot mount a socket itself. Or stop connecting to it.",
			'Declared: /proc, /sys',
		]) }, run(sock, { socket: { data: { '/var/run/foo/foo.sock': 'answered outside the jail' } } }));
		assert.match([ false, 'SOCKET_FAILED', '/var/run/foo/foo.sock: connect(): No such file or directory' ], [ got.ok, got.error, got.details ]);
	});

	it('fails one that runs a program its meta.commands does not list, even as the test expects it to fail', () => {
		let runner = collector('runner', { needs: [ 'exec' ], commands: [ 'true' ] }, (deps) => deps.exec.run([ 'false' ]));

		assert.match({ kind: 'fail', message: join('\n', [
			"collector 'runner' ran 'false', which its meta.commands does not list.",
			'The exporter refuses it, in the jail or not: run() returns COMMAND_NOT_ALLOWED without running it, as it did here. ' +
			'A test that expects the collector to fail may pass by accident.',
			"List it in meta.commands, with 'exec' in meta.needs, or stop running it.",
			'Declared commands: true',
		]) }, run(runner));
	});

	it('answers a directory above the mounts as the jail makes it, and a glob, a stat, a realpath and a write as there', () => {
		let seen = {};
		let nosy = collector('nosy', { needs: [ 'fs', 'uci' ], configs: [ 'foo' ] }, function(deps) {
			seen = {
				lsdir: deps.fs.lsdir('/etc'),
				glob: deps.fs.glob('/etc/foo/*'),
				stat: deps.fs.stat('/etc/foo'),
				realpath: deps.fs.realpath('/etc'),
				open: deps.fs.open('/proc/sys/vm/drop_caches', 'w'),
			};
			return Result.ok();
		});
		let r = run(nosy, { fs: { data: { '/etc/passwd': 'root', '/etc/foo/a': 'x', '/proc/sys/vm/drop_caches': '0' } } });

		assert.match({ lsdir: [ 'config', 'resolv.conf' ], glob: [], stat: null, realpath: '/etc', open: null }, seen);
		assert.match('fail', r.kind);
		assert.match([
			join('\n', [
				"collector 'nosy' listed /etc, which its meta does not declare.",
				"In the service's jail it holds only what is mounted under it: lsdir returns [ \"config\", \"resolv.conf\" ], as it did here.",
				'It cannot be declared (/etc is too broad to mount for one collector): stop listing it.',
				'Declared: /proc, /sys, /etc/config/foo',
			]),
			join('\n', [
				"collector 'nosy' globbed /etc/foo/*, which its meta does not declare.",
				"In the service's jail nothing is there: glob matches nothing, as it did here.",
				'Declare it in meta.paths, or stop globbing it.',
				'Declared: /proc, /sys, /etc/config/foo',
			]),
			join('\n', [
				"collector 'nosy' looked up (stat) /etc/foo, which its meta does not declare.",
				"In the service's jail that path does not exist: stat returns null, as it did here.",
				'Declare it in meta.paths, or stop looking it up.',
				'Declared: /proc, /sys, /etc/config/foo',
			]),
			join('\n', [
				"collector 'nosy' resolved (realpath) /etc, which its meta does not declare.",
				"In the service's jail it is a directory the jail makes for what is mounted under it: realpath finds it, as it did here.",
				'It cannot be declared (/etc is too broad to mount for one collector): stop resolving it.',
				'Declared: /proc, /sys, /etc/config/foo',
			]),
			join('\n', [
				"collector 'nosy' opened /proc/sys/vm/drop_caches to write ('w').",
				"In the service's jail what a collector may read is mounted read-only: the open fails and returns null, as it did here.",
				'A collector writes samples, and nothing else: stop writing it.',
			]),
		], split(r.message, '\n\n'));
	});

	it('lets a collector touch what it declares and what every jail has, and asserts nothing of its result', () => {
		let tidy = collector('tidy', { needs: [ 'fs', 'socket', 'exec' ], commands: [ 'true' ], paths: [ '/srv/tidy' ] }, function(deps) {
			deps.fs.readfile('/proc/loadavg');
			deps.fs.lsdir('/sys/class/net');
			deps.fs.readfile('/srv/tidy/state');
			deps.fs.glob('/srv/tidy/*.json');
			deps.socket.unix_request('/srv/tidy/ctl.sock', 'x', 100);
			deps.exec.run([ 'true' ]);
			return Result.err('SOURCE_UNREADABLE', 'as the test means it to');
		});

		assert.match({ ran: true }, run(tidy, {
			fs: { data: { '/proc/loadavg': '0 0 0', '/sys/class/net/lo/mtu': '65536', '/srv/tidy/state': 'ok' }, commands: {} },
			socket: { data: { '/srv/tidy/ctl.sock': 'ok' } },
		}));
	});

	it('fails a meta the loader refuses, and text that is not valid exposition', () => {
		let helpless = collector('helpless', { help: '' }, () => Result.ok());
		let twice = collector('twice', {}, function(deps, out) {
			out.add([ { name: 'twice_value', type: 'gauge', help: 'A value.', samples: [ { name: 'twice_value', labels: [], value: '1' } ] } ]);
			out.add([ { name: 'twice_value', type: 'gauge', help: 'A value.', samples: [ { name: 'twice_value', labels: [], value: '2' } ] } ]);
			return Result.ok();
		});

		assert.match({ kind: 'fail', message: "collector 'helpless' has a meta the loader refuses: " +
			'COLLECTOR_INVALID (helpless: meta.help must be a sentence).\nThe exporter leaves it out, logged at err: fix its meta.' },
			run(helpless));

		let r = run(twice);

		assert.match([ 'fail', true ], [ r.kind, index(r.message, "collector 'twice' wrote text that is not valid exposition: EXPOSITION_INVALID") == 0 ]);
	});

	prop('fails as a test fails, so a property shrinks: whatever path outside the mounts it reads',
		gen.elements('/etc/shadow', '/root/.ssh/id_rsa', '/tmp/dhcp.leases', '/var/run/x.pid', 'relative/path', '/proc/../etc/passwd'), (path) => {
			let reader = collector('reader', { needs: [ 'fs' ] }, function(deps) {
				return deps.fs.readfile(path) == null ? Result.ok() : Result.err('SOURCE_INVALID', 'read it');
			});
			let r = run(reader, { fs: { data: { [path]: 'secret' } } });

			assert.match([ 'fail', true ], [ r.kind, index(r.message, `collector 'reader' read ${path}, which its meta does not declare.\n`) == 0 ]);
		});
});

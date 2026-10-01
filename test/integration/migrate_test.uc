'use strict';

// The import of a feed exporter's settings on OpenWrt's own uci, over a config
// directory of its own: the shipped config, and the feed's config files as their
// packages ship them, changed as someone would.

import { describe, it, assert, afterEach } from 'utest';
import { cursor } from 'uci';
import { readfile, writefile, mkdtemp, unlink, rmdir, lsdir } from 'fs';
import * as migrate from 'prometheus_exporter.migrate';
import * as config from 'prometheus_exporter.config';

const SHIPPED = readfile(`files/etc/config/${config.NAME}`);

// The feed packages' configs (utils/prometheus-node-exporter-{ucode,lua}/files/config).
const FEED_UCODE = `config prometheus-node-exporter-ucode 'main'
	option listen_interface 'lan'
	option listen_port '9200'
	option http_keepalive '70'

config collector 'wifi'
	option stations '0'
`;
const FEED_LUA = `config prometheus-node-exporter-lua 'main'
	option listen_interface 'loopback'
	option listen_port '9100'
	option omit_zero_values '1'
	option cert '/etc/uhttpd.crt'
	option key '/etc/uhttpd.key'
`;

let dirs = [];

// A config directory with these files, and a cursor over it.
function confdir(files) {
	let dir = mkdtemp('/tmp/migrate-XXXXXX');
	let save = mkdtemp('/tmp/migrate-save-XXXXXX');

	push(dirs, dir, save);
	for (let name, text in files)
		writefile(`${dir}/${name}`, text);

	return { dir, uci: cursor(dir, save) };
}

// The exporter's config as a fresh cursor reads it back from the file.
function read_back(dir) {
	let out = {};
	let uci = cursor(dir, '/tmp/migrate-none');

	uci.foreach(config.NAME, null, function(s) {
		let opts = {};
		for (let k, v in s)
			if (substr(k, 0, 1) != '.')
				opts[k] = v;
		out[s['.name']] = { type: s['.type'], ...opts };
	});

	return out;
}

describe('migrate, on uci', () => {
	afterEach(() => {
		for (let d in dirs) {
			for (let f in lsdir(d) ?? [])
				unlink(`${d}/${f}`);
			rmdir(d);
		}
		dirs = [];
	});

	it('knows the main section as the package ships it', () => {
		assert.match(true, migrate.pristine(cursor('files/etc/config', '/tmp/migrate-none')));
	});

	it('takes over the ucode exporter\'s settings, and leaves its config as it was', () => {
		let c = confdir({ [config.NAME]: SHIPPED, 'prometheus-node-exporter-ucode': FEED_UCODE });

		assert.match(true, migrate.run(c.uci).imported);
		assert.match({
			main: { type: config.NAME, ...migrate.SHIPPED, listen_interface: 'lan', listen_port: '9200' },
			wifi: { type: 'collector', stations: '0' },
		}, read_back(c.dir));
		assert.match(FEED_UCODE, readfile(`${c.dir}/prometheus-node-exporter-ucode`));
	});

	it('takes over the Lua exporter\'s, keeping this one\'s port for the old default', () => {
		let c = confdir({ [config.NAME]: SHIPPED, 'prometheus-node-exporter-lua': FEED_LUA });

		migrate.run(c.uci);
		assert.match({
			main: { type: config.NAME, ...migrate.SHIPPED, omit_zero_values: '1', cert: '/etc/uhttpd.crt', key: '/etc/uhttpd.key' },
		}, read_back(c.dir));
	});

	it('runs once: what it wrote is a change it then keeps', () => {
		let c = confdir({ [config.NAME]: SHIPPED, 'prometheus-node-exporter-ucode': FEED_UCODE });

		migrate.run(c.uci);
		let first = readfile(`${c.dir}/${config.NAME}`);
		let again = migrate.run(cursor(c.dir, '/tmp/migrate-none'));

		assert.match([ false, first ], [ again.imported, readfile(`${c.dir}/${config.NAME}`) ]);
	});
});

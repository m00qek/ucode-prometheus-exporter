'use strict';

// The import of a feed exporter's settings on OpenWrt's own uci, over a config
// directory of its own: the shipped config, and the feed's config files as their
// packages ship them, changed as someone would.

import { describe, it, assert, afterEach } from 'utest';
import { cursor } from 'uci';
import { readfile, writefile, mkdtemp, unlink, rmdir, lsdir } from 'fs';
import * as migrate from 'prometheus.exporter.migrate';
import * as config from 'prometheus.exporter.config';
import * as wifi from 'prometheus.collectors.wifi';

const SHIPPED = readfile(`files/etc/config/${config.NAME}`);
const SHIPPED_AUTH = readfile(`files/etc/config/${config.AUTH_CONFIG}`);
const HASH = '$1$$ysVNzQc4CTMkp5daOdZ.3/';
// 0.2.0's main section with basic auth, the hash in it.
const WITH_HASH = `config ${config.NAME} 'main'
	option listen_port '9100'
	option auth_user 'prom'
	option auth_password '${HASH}'
`;

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

	// One value the exporter refuses made the configuration invalid, and the
	// service would not start.
	it('takes over only the collector options the exporter takes, so that what it writes is valid', () => {
		let old = FEED_UCODE + `\toption colour 'blue'\n\toption budget '2'\n\nconfig collector 'loadavg'\n\toption budget 'soon'\n`;
		let c = confdir({ [config.NAME]: SHIPPED, 'prometheus-node-exporter-ucode': replace(old, "stations '0'", "stations 'maybe'") });
		let res = migrate.run(c.uci, { wifi: wifi.meta });

		assert.match([
			'prometheus-node-exporter-ucode: collector wifi, option stations: expected a boolean, got "maybe"; left at its default',
			'prometheus-node-exporter-ucode: collector wifi has no option colour; left out',
			'prometheus-node-exporter-ucode: collector loadavg, option budget: expected an integer, got "soon"; left at its default',
			'imported from /etc/config/prometheus-node-exporter-ucode: listen_interface=lan, listen_port=9200, collector wifi',
		], res.lines);
		assert.match({
			main: { type: config.NAME, ...migrate.SHIPPED, listen_interface: 'lan', listen_port: '9200' },
			wifi: { type: 'collector', budget: '2' },
		}, read_back(c.dir));

		let fresh = cursor(c.dir, '/tmp/migrate-none');

		assert.match([ true, true ], [ config.settings(fresh, 'wifi', wifi.meta).ok, config.main(fresh).ok ]);
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

	it('moves 0.2.0\'s hash into the config the package installs, where the exporter reads it', () => {
		let c = confdir({ [config.NAME]: WITH_HASH, [config.AUTH_CONFIG]: SHIPPED_AUTH });
		let res = migrate.move_hash(c.uci);

		assert.match({ moved: true, lines: [ `auth_password moved from /etc/config/${config.NAME} to /etc/config/${config.AUTH_CONFIG}` ] }, res);
		assert.match({ main: { type: config.NAME, listen_port: '9100', auth_user: 'prom' } }, read_back(c.dir));

		let fresh = cursor(c.dir, '/tmp/migrate-none');

		assert.match({ ok: true, data: { auth_password: HASH } }, { ...config.auth_values(fresh) });
		assert.match(-1, index(sprintf('%J', res), HASH));
	});

	it('keeps a hash saved apart already, and drops the main section\'s', () => {
		let other = '$1$$other';
		let c = confdir({ [config.NAME]: WITH_HASH, [config.AUTH_CONFIG]: `config auth 'main'\n\toption auth_password '${other}'\n` });

		assert.match([ `auth_password removed from /etc/config/${config.NAME}: /etc/config/${config.AUTH_CONFIG} has one already, which is kept` ],
			migrate.move_hash(c.uci).lines);
		assert.match([ null, other ], [ cursor(c.dir, '/tmp/migrate-none').get(config.NAME, 'main', 'auth_password'),
			cursor(c.dir, '/tmp/migrate-none').get(config.AUTH_CONFIG, 'main', 'auth_password') ]);
	});

	it('does nothing without a hash in the main section, and says so when the hash\'s config is gone', () => {
		let c = confdir({ [config.NAME]: SHIPPED, [config.AUTH_CONFIG]: SHIPPED_AUTH });

		assert.match({ moved: false, lines: [] }, migrate.move_hash(c.uci));
		assert.match([ SHIPPED, SHIPPED_AUTH ], [ readfile(`${c.dir}/${config.NAME}`), readfile(`${c.dir}/${config.AUTH_CONFIG}`) ]);

		let gone = confdir({ [config.NAME]: WITH_HASH });

		assert.match({ moved: false, lines: [ `/etc/config/${config.AUTH_CONFIG} is not there: auth_password left in /etc/config/${config.NAME}, where it is not read; set it again` ] },
			migrate.move_hash(gone.uci));
		assert.match(WITH_HASH, readfile(`${gone.dir}/${config.NAME}`));
	});

	it('the shipped hash\'s config has its section, and no hash', () => {
		let uci = cursor('files/etc/config', '/tmp/migrate-none');

		assert.match([ config.AUTH_TYPE, null ], [ uci.get(config.AUTH_CONFIG, config.AUTH_SECTION), uci.get(config.AUTH_CONFIG, config.AUTH_SECTION, 'auth_password') ]);
	});
});

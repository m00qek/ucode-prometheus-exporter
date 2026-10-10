'use strict';

import { describe, it, assert, contains, mock } from 'utest';
import * as migrate from 'prometheus.exporter.migrate';
import * as config from 'prometheus.exporter.config';

const UCODE = 'prometheus-node-exporter-ucode';
const LUA = 'prometheus-node-exporter-lua';
const SHIPPED_MAIN = { '.type': config.NAME, ...migrate.SHIPPED };

// A cursor over these configs ({ config: { section: { '.type', ... } } }).
function with_uci(data, cb) {
	mock.inject('uci', { strict: true, data }, (uci) => cb(uci.cursor()));
}

function plan_of(data) {
	let out;
	with_uci(data, (uci) => { out = migrate.plan(uci); });
	return out;
}

function pristine(data) {
	let out;
	with_uci(data, (uci) => { out = migrate.pristine(uci); });
	return out;
}

describe('migrate.pristine', () => {
	it('is the main section alone, as shipped', () => {
		assert.match(true, pristine({ [config.NAME]: { main: SHIPPED_MAIN } }));
	});

	it('takes the options in any order', () => {
		let reordered = { '.type': config.NAME };
		for (let k in reverse(keys(migrate.SHIPPED)))
			reordered[k] = migrate.SHIPPED[k];
		assert.match(true, pristine({ [config.NAME]: { main: reordered } }));
	});

	it('is not, with a value changed, an option added or removed, or another section', () => {
		let without_port = { ...migrate.SHIPPED };
		delete without_port.listen_port;

		assert.match([ false, false, false, false, false ], [
			pristine({ [config.NAME]: { main: { ...SHIPPED_MAIN, listen_port: '9200' } } }),
			pristine({ [config.NAME]: { main: { ...SHIPPED_MAIN, cert: '/etc/uhttpd.crt' } } }),
			pristine({ [config.NAME]: { main: { '.type': config.NAME, ...without_port } } }),
			pristine({ [config.NAME]: { main: SHIPPED_MAIN, wifi: { '.type': 'collector', stations: '0' } } }),
			pristine({ [config.NAME]: { other: SHIPPED_MAIN } }),
		]);
	});

	it('is not without a config to write into', () => {
		assert.match(false, pristine({}));
	});
});

describe('migrate.main_options', () => {
	let source = migrate.SOURCES[0];

	it('takes what this exporter reads, as uci holds it', () => {
		assert.match({
			set: { listen_interface: 'lan', listen_port: '9200', http_keepalive: '0', cert: '/etc/ssl/c.crt', key: '/etc/ssl/c.key', omit_zero_values: '1' },
			skipped: [],
		}, migrate.main_options(source, {
			listen_interface: 'lan', listen_port: '9200', http_keepalive: '0', cert: '/etc/ssl/c.crt', key: '/etc/ssl/c.key', omit_zero_values: '1',
		}));
	});

	it('leaves the old default port at this one\'s, and what is shipped out', () => {
		assert.match({ set: {}, skipped: [] },
			migrate.main_options(source, { listen_interface: 'loopback', listen_port: '9101', http_keepalive: '70' }));
		assert.match({ set: {}, skipped: [] }, migrate.main_options(migrate.SOURCES[1], { listen_port: '9100' }));
	});

	it('ignores what it does not take over', () => {
		assert.match({ set: {}, skipped: [] }, migrate.main_options(source, { enabled: '0', listen_ipv6: '1', '.type': 'x' }));
	});

	it('skips a value this exporter would refuse, saying why', () => {
		assert.match({
			set: { http_keepalive: '5' },
			skipped: [
				`${UCODE}: option listen_interface: expected an interface name or *, got ""; left at the default`,
				`${UCODE}: option listen_port: expected an integer from 1 to 65535, got 70000; left at the default`,
				`${UCODE}: option omit_zero_values: expected a boolean, got "maybe"; left at the default`,
			],
		}, migrate.main_options(source, { listen_interface: '', listen_port: '70000', http_keepalive: '5', omit_zero_values: 'maybe' }));
	});

	it('skips a list', () => {
		assert.match(1, length(migrate.main_options(source, { listen_interface: [ 'lan', 'wan' ] }).skipped));
	});
});

describe('migrate.plan', () => {
	it('is nothing without a feed exporter\'s config', () => {
		assert.match(null, plan_of({ [config.NAME]: { main: SHIPPED_MAIN } }));
	});

	it('takes the ucode exporter\'s main section and named collector sections', () => {
		assert.match({
			from: UCODE,
			main: { listen_interface: '*', listen_port: '9200' },
			collectors: { wifi: { stations: '0' } },
			skipped: [],
		}, plan_of({
			[UCODE]: {
				main: { '.type': UCODE, listen_interface: '*', listen_port: '9200', http_keepalive: '70' },
				wifi: { '.type': 'collector', stations: '0' },
				cfg0123: { '.type': 'collector', '.anonymous': true, stations: '1' },
			},
		}));
	});

	it('takes no section of a collector this exporter has not, and says what does its job', () => {
		assert.match({
			from: UCODE,
			main: {},
			collectors: { wifi: { stations: '1' } },
			skipped: [ `${UCODE}: collector wifi_stations is not this exporter's: wifi writes the stations, with its option stations, on by default` ],
		}, plan_of({
			[UCODE]: {
				main: { '.type': UCODE },
				wifi: { '.type': 'collector', stations: '1' },
				wifi_stations: { '.type': 'collector', enabled: '1' },
			},
		}));
	});

	it('prefers the ucode exporter\'s config to the Lua one\'s', () => {
		assert.match(UCODE, plan_of({
			[UCODE]: { main: { '.type': UCODE } },
			[LUA]: { main: { '.type': LUA, listen_port: '9300' } },
		}).from);
	});

	it('takes the Lua exporter\'s main section, and no collector sections', () => {
		assert.match({
			from: LUA,
			main: { listen_port: '9300', cert: '/etc/ssl/c.crt', key: '/etc/ssl/c.key', omit_zero_values: '1' },
			collectors: {},
			skipped: [],
		}, plan_of({
			[LUA]: {
				main: { '.type': LUA, listen_interface: 'loopback', listen_port: '9300', cert: '/etc/ssl/c.crt', key: '/etc/ssl/c.key', omit_zero_values: '1' },
				wifi: { '.type': 'collector', stations: '0' },
			},
		}));
	});

	it('reads only a main section of the old exporter\'s type', () => {
		assert.match({}, plan_of({ [UCODE]: { main: { '.type': 'other', listen_port: '9200' } } }).main);
	});
});

describe('migrate.run', () => {
	it('does nothing when no feed exporter left a config', () => {
		with_uci({ [config.NAME]: { main: SHIPPED_MAIN } }, (uci) => {
			assert.match({ imported: false, lines: [] }, migrate.run(uci));
			assert.match([], uci.__utest__.calls.commit);
		});
	});

	it('writes nothing over a config someone has changed', () => {
		with_uci({
			[config.NAME]: { main: { ...SHIPPED_MAIN, listen_port: '9400' } },
			[UCODE]: { main: { '.type': UCODE, listen_port: '9200' } },
		}, (uci) => {
			assert.match({
				imported: false,
				lines: [ `/etc/config/${config.NAME} is not as the package ships it: nothing imported from /etc/config/${UCODE}` ],
			}, migrate.run(uci));
			assert.match([ [], [] ], [ uci.__utest__.calls.set, uci.__utest__.calls.commit ]);
		});
	});

	it('writes the main options and collector sections, and commits', () => {
		with_uci({
			[config.NAME]: { main: SHIPPED_MAIN },
			[UCODE]: { main: { '.type': UCODE, listen_port: '9200' }, wifi: { '.type': 'collector', stations: '0' } },
		}, (uci) => {
			assert.match({ imported: true, lines: [ `imported from /etc/config/${UCODE}: listen_port=9200, collector wifi` ] }, migrate.run(uci));
			assert.match([
				[ config.NAME, 'main', 'listen_port', '9200' ],
				[ config.NAME, 'wifi', 'collector', null ],
				[ config.NAME, 'wifi', 'stations', '0' ],
			], uci.__utest__.calls.set);
			assert.match([ [ config.NAME ] ], uci.__utest__.calls.commit);
		});
	});

	it('says when an old config holds only defaults, and writes nothing', () => {
		with_uci({
			[config.NAME]: { main: SHIPPED_MAIN },
			[UCODE]: { main: { '.type': UCODE, listen_port: '9101', http_keepalive: '70' } },
		}, (uci) => {
			assert.match({ imported: false, lines: [ `imported from /etc/config/${UCODE}: nothing it changed from the defaults` ] }, migrate.run(uci));
			assert.match([], uci.__utest__.calls.commit);
		});
	});

	it('logs what it skipped', () => {
		with_uci({
			[config.NAME]: { main: SHIPPED_MAIN },
			[LUA]: { main: { '.type': LUA, listen_port: 'http', http_keepalive: '10' } },
		}, (uci) => {
			assert.match(contains([
				`${LUA}: option listen_port: expected an integer, got "http"; left at the default`,
				`imported from /etc/config/${LUA}: http_keepalive=10`,
			]), migrate.run(uci).lines);
		});
	});
});

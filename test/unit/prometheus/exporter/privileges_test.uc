'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as privileges from 'prometheus.exporter.privileges';
import * as config from 'prometheus.exporter.config';
import * as state from 'prometheus.exporter.state';

// What meta_problem() says of a meta with these declarations and needs.
function problem(needs, decl) {
	return privileges.meta_problem({ name: 'x', needs, ...decl });
}

describe('privileges', () => {
	it('names the service\'s user and group as the service is named, and its files in its run directory', () => {
		assert.match([ config.NAME, config.NAME ], [ privileges.USER, privileges.GROUP ]);
		assert.match(state.RUN_DIR, privileges.RUN_DIR);
		assert.match([ true, true, true ], map([ privileges.CAPABILITIES_FILE, privileges.TLS_CERT, privileges.TLS_KEY ],
			(p) => substr(p, 0, length(state.RUN_DIR) + 1) == state.RUN_DIR + '/'));
	});

	it('keeps the ACL where ubusd, which is not root, reads it as it starts: in its ACL directory, outside the run directory, which only root enters', () => {
		assert.match(false, substr(privileges.ACL_FILE, 0, length(state.RUN_DIR) + 1) == state.RUN_DIR + '/');
		assert.match('/usr/share/acl.d/prometheus-exporter.json', privileges.ACL_FILE);
	});

	it('lets a collector have no capability that reads past the jail or changes the system', () => {
		assert.match([ 'CAP_NET_ADMIN', 'CAP_NET_RAW' ], sort(keys(privileges.COLLECTOR_CAPABILITIES)));
		assert.match([ 10, 12, 13 ], map([ 'CAP_NET_BIND_SERVICE', 'CAP_NET_ADMIN', 'CAP_NET_RAW' ], (c) => privileges.CAPABILITIES[c]));
	});
});

describe('privileges.meta_problem', () => {
	it('takes declarations of ubus calls, capabilities, groups and proc files', () => {
		assert.match([ null, null, null, null, null ], [
			problem([ 'ubus' ], { ubus: { dnsmasq: [ 'metrics' ], rc: [ 'list' ] } }),
			problem([ 'ubus' ], { ubus: { 'hostapd.*': [ 'get_clients' ], 'network.interface': [ 'dump' ], uci: (o) => o.x ? [ 'get' ] : [] } }),
			problem([ 'exec' ], { capabilities: [ 'CAP_NET_ADMIN' ] }),
			problem([ 'socket', 'ubus' ], { ubus: { rc: [ 'list' ] }, groups: [ 'unbound' ] }),
			problem([ 'fs' ], { proc_files: [ '/proc/net/nf_conntrack' ] }),
		]);
	});

	it('wants the ubus calls of a collector that needs ubus, and none of one that does not', () => {
		assert.match([
			'meta.ubus must list the ubus objects and methods it calls: { object: [ method ] }',
			'meta.ubus must list the ubus objects and methods it calls: { object: [ method ] }',
			'meta.ubus without ubus in meta.needs',
		], [ problem([ 'ubus' ], {}), problem([ 'ubus' ], { ubus: {} }), problem([ 'fs' ], { ubus: { rc: [ 'list' ] } }) ]);
	});

	it('says what is wrong with a ubus declaration', () => {
		assert.match([
			"meta.ubus: 'hostapd*' is not the name of a ubus object, nor a prefix of names that ends in '.*'",
			"meta.ubus: '*' is not the name of a ubus object, nor a prefix of names that ends in '.*'",
			'meta.ubus: rc: its methods must be a list of names, or a function of its options that gives one',
			'meta.ubus: rc: its methods must be a list of names, or a function of its options that gives one',
			'meta.ubus: rc: its methods must be a list of names, or a function of its options that gives one',
			'meta.ubus: rc: its methods must be a list of names, or a function of its options that gives one',
		], [
			problem([ 'ubus' ], { ubus: { 'hostapd*': [ 'x' ] } }),
			problem([ 'ubus' ], { ubus: { '*': [ 'x' ] } }),
			problem([ 'ubus' ], { ubus: { rc: [] } }),
			problem([ 'ubus' ], { ubus: { rc: [ '*' ] } }),
			problem([ 'ubus' ], { ubus: { rc: 'list' } }),
			problem([ 'ubus' ], { ubus: { rc: [ 'list', 'list' ] } }),
		]);
	});

	it('refuses a capability a collector may not have, a group of its own and a file outside /proc', () => {
		assert.match([
			'meta.capabilities: CAP_DAC_READ_SEARCH is not one a collector may have: CAP_NET_ADMIN, CAP_NET_RAW',
			'meta.capabilities: CAP_NET_BIND_SERVICE is not one a collector may have: CAP_NET_ADMIN, CAP_NET_RAW',
			'meta.capabilities must list capabilities once each',
			'meta.groups must list the names of other groups, once each',
			'meta.groups must list the names of other groups, once each',
			'meta.proc_files must list plain paths under /proc, once each',
			'meta.proc_files must list plain paths under /proc, once each',
			'meta.proc_files must list plain paths under /proc, once each',
			'meta.proc_files without fs in meta.needs',
		], [
			problem([ 'fs' ], { capabilities: [ 'CAP_DAC_READ_SEARCH' ] }),
			problem([ 'fs' ], { capabilities: [ 'CAP_NET_BIND_SERVICE' ] }),
			problem([ 'fs' ], { capabilities: [ 'CAP_NET_ADMIN', 'CAP_NET_ADMIN' ] }),
			problem([ 'fs' ], { groups: [ privileges.GROUP ] }),
			problem([ 'fs' ], { groups: [ 'Root' ] }),
			problem([ 'fs' ], { proc_files: [ '/etc/shadow' ] }),
			problem([ 'fs' ], { proc_files: [ '/proc/../etc/shadow' ] }),
			problem([ 'fs' ], { proc_files: [ '/proc/net/*' ] }),
			problem([ 'exec' ], { proc_files: [ '/proc/net/nf_conntrack' ] }),
		]);
	});
});

describe('privileges.ubus_of', () => {
	it('gives the calls a collector declares, those of a function for its options', () => {
		let meta = { ubus: { wireguard: [ 'status' ], uci: (o) => o.peer_names ? [ 'get' ] : [] } };

		assert.match({ ubus: { wireguard: [ 'status' ] }, problems: [] }, privileges.ubus_of(meta, { peer_names: false }));
		assert.match({ ubus: { uci: [ 'get' ], wireguard: [ 'status' ] }, problems: [] }, privileges.ubus_of(meta, { peer_names: true }));
		assert.match({ ubus: {}, problems: [] }, privileges.ubus_of({}, null));
	});

	it('leaves out what a function fails to give, saying why', () => {
		let meta = { ubus: { a: () => die('boom'), b: () => 'get', c: [ 'x' ] } };

		assert.match({ ubus: { c: [ 'x' ] }, problems: [
			'meta.ubus: a: its function failed: boom',
			'meta.ubus: b: its function returned "get", not a list of method names',
		] }, privileges.ubus_of(meta, {}));
	});
});

describe('privileges.allows', () => {
	const DECLARED = { dnsmasq: [ 'metrics' ], 'hostapd.*': [ 'get_clients' ] };

	it('allows a declared method of an object, and of the objects a prefix names', () => {
		assert.match([ true, true, true ], [
			privileges.allows(DECLARED, 'dnsmasq', 'metrics'),
			privileges.allows(DECLARED, 'hostapd.wlan0', 'get_clients'),
			privileges.allows(DECLARED, 'hostapd.phy0-ap0', 'get_clients'),
		]);
	});

	it('allows nothing else, as ubusd would not', () => {
		assert.match([ false, false, false, false, false, false ], [
			privileges.allows(DECLARED, 'dnsmasq', 'reload'),
			privileges.allows(DECLARED, 'dnsmasq.x', 'metrics'),
			privileges.allows(DECLARED, 'hostapd', 'get_clients'),
			privileges.allows(DECLARED, 'hostapdx.wlan0', 'get_clients'),
			privileges.allows(DECLARED, 'hostapd.wlan0', 'del_client'),
			privileges.allows(DECLARED, null, 'metrics'),
		]);
	});

	prop('allows exactly what one of the declarations names',
		gen.tuple(gen.elements('dnsmasq', 'hostapd.wlan0', 'hostapd.', 'rc', 'system'), gen.elements('metrics', 'get_clients', 'list', 'board')), (call) => {
			let object = call[0], method = call[1];
			let want = (object == 'dnsmasq' && method == 'metrics') || (substr(object, 0, 8) == 'hostapd.' && method == 'get_clients');

			assert.match(want, privileges.allows(DECLARED, object, method), `${object} ${method}`);
		});
});

describe('privileges.lacking', () => {
	it('says which capabilities a process lacks, by its CapEff', () => {
		let status = (eff) => `Name:\tuhttpd\nCapInh:\t0000000000000000\nCapEff:\t${eff}\nCapBnd:\t000001ffffffffff\n`;

		assert.match([ [], [ 'CAP_NET_RAW' ], [ 'CAP_NET_ADMIN', 'CAP_NET_RAW' ], [], null ], [
			privileges.lacking(status('0000000000001000'), [ 'CAP_NET_ADMIN' ]),
			privileges.lacking(status('0000000000001000'), [ 'CAP_NET_ADMIN', 'CAP_NET_RAW' ]),
			privileges.lacking(status('0000000000000000'), [ 'CAP_NET_ADMIN', 'CAP_NET_RAW' ]),
			privileges.lacking(status('000001ffffffffff'), [ 'CAP_NET_ADMIN', 'CAP_NET_RAW', 'CAP_NET_BIND_SERVICE' ]),
			privileges.lacking(null, [ 'CAP_NET_ADMIN' ]),
		]);
	});
});

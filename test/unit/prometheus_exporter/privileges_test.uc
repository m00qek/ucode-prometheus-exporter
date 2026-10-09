'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as privileges from 'prometheus_exporter.privileges';
import * as config from 'prometheus_exporter.config';
import * as state from 'prometheus_exporter.state';

// What meta_problem() says of a meta with these declarations and needs.
function problem(needs, decl) {
	return privileges.meta_problem({ name: 'x', needs, ...decl });
}

const GROUPS = 'root:x:0:\nunbound:x:32768:unbound\nprometheus-exporter:x:32770:prometheus-exporter\nntp:x:123:ntp\n';

// A filesystem of `files` ({ path: { data, mode, gid } }) that records chown,
// chmod and what is written; `broken` names calls that fail.
function filesystem(files, broken) {
	let fails = (name) => (name in (broken ?? []));
	let fs = null;

	fs = {
		files,
		log: [],
		stat: (p) => (p in keys(files)) ? { type: 'file', mode: files[p].mode ?? 0o600, uid: 0, gid: files[p].gid ?? 0 } : null,
		readfile: (p) => files[p]?.data,
		open: function(p, mode, perm) {
			if (fails('open'))
				return null;
			files[p] = { data: '', mode: perm, gid: 0 };
			return { write: (t) => { files[p].data += t; return length(t); }, close: () => true };
		},
		chown: function(p, uid, gid) {
			if (fails('chown') || files[p] == null) return null;
			push(fs.log, [ 'chown', p, gid ]);
			files[p].gid = gid;
			return true;
		},
		chmod: function(p, mode) {
			if (fails('chmod') || files[p] == null) return null;
			push(fs.log, [ 'chmod', p, mode ]);
			files[p].mode = mode;
			return true;
		},
		rename: function(a, b) { if (fails('rename')) return null; files[b] = files[a]; delete files[a]; return true; },
		unlink: function(p) { if (files[p] == null) return null; delete files[p]; return true; },
		error: () => 'Permission denied',
	};

	return fs;
}

// sys for make(): fs, a lock that records, and a ubusd that records its reloads.
function system(fs, reload_ok) {
	let sys = null;

	sys = {
		fs,
		locks: [],
		reloads: 0,
		lock: function() { push(sys.locks, 'take'); return () => push(sys.locks, 'release'); },
		reload_ubus: function() { sys.reloads++; return reload_ok ?? true; },
	};

	return sys;
}

function grants(g) {
	return { ubus: {}, capabilities: [], groups: [], groups_off: [], files: [], files_off: [], tls: null, port: 9100, problems: [], ...(g ?? {}) };
}

describe('privileges', () => {
	it('names the service\'s user and group as the service is named, and its files in its run directory', () => {
		assert.match([ config.NAME, config.NAME ], [ privileges.USER, privileges.GROUP ]);
		assert.match(state.RUN_DIR, privileges.RUN_DIR);
		assert.match([ true, true, true ], map([ privileges.CAPABILITIES_FILE, privileges.TLS_CERT, privileges.TLS_KEY ],
			(p) => substr(p, 0, length(state.RUN_DIR) + 1) == state.RUN_DIR + '/'));
	});

	it('keeps the ACL where ubusd, which is not root, can read it: outside the run directory, which only root enters', () => {
		assert.match(false, substr(privileges.ACL_FILE, 0, length(state.RUN_DIR) + 1) == state.RUN_DIR + '/');
		assert.match('/usr/share/acl.d/prometheus-exporter.json', privileges.ACL_LINK);
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

describe('privileges.acl', () => {
	it('is the user\'s, with the canary and the calls of every collector, merged and sorted', () => {
		let ubus = privileges.merge([ { rc: [ 'list' ], dnsmasq: [ 'metrics' ] }, { rc: [ 'list' ], 'hostapd.*': [ 'get_status', 'get_clients' ] } ]);

		assert.match({
			user: 'prometheus-exporter',
			access: {
				dnsmasq: { methods: [ 'metrics' ] },
				'hostapd.*': { methods: [ 'get_clients', 'get_status' ] },
				rc: { methods: [ 'list' ] },
				system: { methods: [ 'board' ] },
			},
		}, privileges.acl(ubus));
		assert.match([ 'dnsmasq', 'hostapd.*', 'rc', 'system' ], keys(privileges.acl(ubus).access));
	});

	it('has the canary alone without a collector that calls ubus', () => {
		assert.match({ user: 'prometheus-exporter', access: { system: { methods: [ 'board' ] } } }, privileges.acl({}));
	});

	it('never has an object without methods, which ubusd would let the user call nothing of', () => {
		for (let o, a in privileges.acl(privileges.merge([ { a: [ 'x' ] }, { b: [ 'y', 'z' ] } ])).access)
			assert.match(true, length(a.methods) > 0, o);
	});
});

describe('privileges.capabilities_doc and lacking', () => {
	it('gives every set of the file the same capabilities, so the programs the jail runs have them too', () => {
		assert.match({
			bounding: [ 'CAP_NET_ADMIN' ], effective: [ 'CAP_NET_ADMIN' ], ambient: [ 'CAP_NET_ADMIN' ],
			permitted: [ 'CAP_NET_ADMIN' ], inheritable: [ 'CAP_NET_ADMIN' ],
		}, privileges.capabilities_doc([ 'CAP_NET_ADMIN', 'CAP_NET_ADMIN' ]));
		assert.match({ bounding: [], effective: [], ambient: [], permitted: [], inheritable: [] }, privileges.capabilities_doc([]));
	});

	it('adds the service\'s own for a port under 1024', () => {
		assert.match([ [ 'CAP_NET_ADMIN' ], [ 'CAP_NET_ADMIN', 'CAP_NET_BIND_SERVICE' ], [] ], [
			privileges.service_capabilities(grants({ capabilities: [ 'CAP_NET_ADMIN' ] })),
			privileges.service_capabilities(grants({ capabilities: [ 'CAP_NET_ADMIN' ], port: 443 })),
			privileges.service_capabilities(grants({ port: 1024 })),
		]);
	});

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

describe('privileges.membership and gid_of', () => {
	it('makes the user a member of the groups it wants, and of none it does not', () => {
		assert.match({ text: 'root:x:0:\nunbound:x:32768:unbound,prometheus-exporter\nntp:x:123:ntp\n', missing: [] },
			privileges.membership('root:x:0:\nunbound:x:32768:unbound\nntp:x:123:ntp\n', 'prometheus-exporter', { unbound: true }));
		assert.match({ text: 'unbound:x:32768:unbound\nchrony:x:323:\n', missing: [] },
			privileges.membership('unbound:x:32768:unbound,prometheus-exporter\nchrony:x:323:prometheus-exporter\n', 'prometheus-exporter', { unbound: false, chrony: false }));
		assert.match({ text: 'dialout:x:20:prometheus-exporter\n', missing: [] },
			privileges.membership('dialout:x:20:\n', 'prometheus-exporter', { dialout: true }));
	});

	it('changes nothing that is as it should be, and says which groups are not there', () => {
		assert.match({ text: null, missing: [ 'unbound' ] }, privileges.membership('ntp:x:123:ntp\n', 'prometheus-exporter', { unbound: true, ntp: false }));
		assert.match({ text: null, missing: [] }, privileges.membership(GROUPS, 'prometheus-exporter', {}));
	});

	it('finds a group\'s gid', () => {
		assert.match([ 32770, 0, null, null ], [ privileges.gid_of(GROUPS, 'prometheus-exporter'), privileges.gid_of(GROUPS, 'root'), privileges.gid_of(GROUPS, 'nobody'), privileges.gid_of(null, 'root') ]);
	});
});

describe('privileges.make', () => {
	function files(extra) {
		return {
			'/etc/group': { data: GROUPS, mode: 0o644 },
			'/etc/config/prometheus-exporter': { data: 'x', mode: 0o600 },
			'/etc/config/dhcp': { data: 'x', mode: 0o600 },
			'/etc/config/chrony': { data: 'x', mode: 0o640, gid: 32770 },
			'/proc/net/nf_conntrack': { data: '', mode: 0o440 },
			'/etc/uhttpd.crt': { data: 'CERT', mode: 0o644 },
			'/etc/uhttpd.key': { data: 'KEY', mode: 0o600, gid: 0 },
			...(extra ?? {}),
		};
	}

	it('gives the group read access to the configs and proc files of the enabled collectors, and takes it back from the others\'', () => {
		let fs = filesystem(files());
		let res = privileges.make(system(fs), grants({
			files: [ '/etc/config/dhcp', '/etc/config/prometheus-exporter', '/proc/net/nf_conntrack' ], files_off: [ '/etc/config/chrony', '/etc/config/wireless' ],
		}));

		assert.match([], res.problems);
		assert.match([ [ 0o640, 32770 ], [ 0o640, 32770 ], [ 0o440, 32770 ], [ 0o640, 0 ] ],
			map([ '/etc/config/dhcp', '/etc/config/prometheus-exporter', '/proc/net/nf_conntrack', '/etc/config/chrony' ], (p) => [ fs.files[p].mode, fs.files[p].gid ]));
		assert.match(true, 'took prometheus-exporter read access from /etc/config/chrony' in res.made);
		assert.match(true, 'gave prometheus-exporter read access to /etc/config/dhcp' in res.made);
	});

	it('gives the group no more than reading, and leaves a config that is right as it is', () => {
		let fs = filesystem(files({ '/etc/config/x': { data: 'x', mode: 0o664 }, '/etc/config/y': { data: 'y', mode: 0o640, gid: 32770 } }));

		privileges.make(system(fs), grants({ files: [ '/etc/config/x', '/etc/config/y' ] }));
		assert.match(0o644, fs.files['/etc/config/x'].mode);
		assert.match([], filter(fs.log, (l) => l[1] == '/etc/config/y'));
	});

	it('makes the user a member of the enabled collectors\' groups, under the lock, and of no other a collector declares', () => {
		let fs = filesystem(files({ '/etc/group': { data: 'unbound:x:32768:unbound\nchrony:x:323:chrony,prometheus-exporter\nprometheus-exporter:x:32770:\n', mode: 0o644 } }));
		let sys = system(fs);
		let res = privileges.make(sys, grants({ groups: [ 'unbound', 'dbus' ], groups_off: [ 'chrony' ] }));

		assert.match('unbound:x:32768:unbound,prometheus-exporter\nchrony:x:323:chrony\nprometheus-exporter:x:32770:\n', fs.files['/etc/group'].data);
		assert.match([ 0o644, 0 ], [ fs.files['/etc/group'].mode, fs.files['/etc/group'].gid ]);
		assert.match([ 'take', 'release' ], sys.locks);
		assert.match(true, 'no group dbus: prometheus-exporter joins it once it is there' in res.made);
	});

	it('refuses to grant anything without the service\'s group, which the package makes', () => {
		let fs = filesystem(files({ '/etc/group': { data: 'root:x:0:\n', mode: 0o644 } }));
		let sys = system(fs);

		assert.match({ made: [], problems: [ 'no group prometheus-exporter in /etc/group: reinstall the package, which makes it' ] },
			privileges.make(sys, grants({ files: [ '/etc/config/dhcp' ] })));
		assert.match([ [ 'take', 'release' ], 0o600 ], [ sys.locks, fs.files['/etc/config/dhcp'].mode ]);
	});

	it('writes the capabilities file of the enabled collectors, and the ACL of their calls, and has ubusd read it', () => {
		let fs = filesystem(files());
		let sys = system(fs);

		privileges.make(sys, grants({ capabilities: [ 'CAP_NET_ADMIN' ], ubus: { rc: [ 'list' ] }, port: 80 }));
		assert.match(privileges.capabilities_doc([ 'CAP_NET_ADMIN', 'CAP_NET_BIND_SERVICE' ]), json(fs.files[privileges.CAPABILITIES_FILE].data));
		assert.match(privileges.acl({ rc: [ 'list' ] }), json(fs.files[privileges.ACL_FILE].data));
		assert.match([ 0o644, 0, 1 ], [ fs.files[privileges.ACL_FILE].mode, fs.files[privileges.ACL_FILE].gid, sys.reloads ]);

		// The same again: ubusd is not told.
		privileges.make(sys, grants({ capabilities: [ 'CAP_NET_ADMIN' ], ubus: { rc: [ 'list' ] }, port: 80 }));
		assert.match(1, sys.reloads);
	});

	it('says when ubusd cannot be told', () => {
		assert.match([ `cannot have ubusd read ${privileges.ACL_FILE}` ], privileges.make(system(filesystem(files()), false), grants()).problems);
	});

	it('copies the TLS files for the group to read, and removes the copies without them', () => {
		let fs = filesystem(files());

		privileges.make(system(fs), grants({ tls: { cert: '/etc/uhttpd.crt', key: '/etc/uhttpd.key' } }));
		assert.match([ [ 'CERT', 0o640, 32770 ], [ 'KEY', 0o640, 32770 ], [ 'KEY', 0o600, 0 ] ],
			map([ privileges.TLS_CERT, privileges.TLS_KEY, '/etc/uhttpd.key' ], (p) => [ fs.files[p].data, fs.files[p].mode, fs.files[p].gid ]));

		privileges.make(system(fs), grants());
		assert.match([ null, null ], [ fs.files[privileges.TLS_CERT], fs.files[privileges.TLS_KEY] ]);
	});

	it('says what it could not do, and goes on', () => {
		let fs = filesystem(files(), [ 'chown' ]);
		let res = privileges.make(system(fs), grants({ files: [ '/etc/config/dhcp' ], ubus: { rc: [ 'list' ] } }));

		assert.match([
			'cannot give prometheus-exporter read access to /etc/config/dhcp: Permission denied',
			`cannot write ${privileges.CAPABILITIES_FILE}: Permission denied`,
			`cannot write ${privileges.ACL_FILE}: Permission denied`,
		], res.problems);
	});
});

describe('privileges.clean', () => {
	it('takes away the ACL, telling ubusd, the capabilities and the TLS copies', () => {
		let fs = filesystem({
			[privileges.ACL_FILE]: { data: '{}' }, [privileges.CAPABILITIES_FILE]: { data: '{}' },
			[privileges.TLS_CERT]: { data: 'C' }, [privileges.TLS_KEY]: { data: 'K' }, '/etc/config/dhcp': { data: 'x' },
		});
		let sys = system(fs);

		assert.match(true, privileges.clean(sys));
		assert.match([ [ '/etc/config/dhcp' ], 1 ], [ keys(fs.files), sys.reloads ]);
	});

	it('leaves ubusd alone when there was no ACL', () => {
		let sys = system(filesystem({}));

		assert.match([ true, 0 ], [ privileges.clean(sys), sys.reloads ]);
	});
});

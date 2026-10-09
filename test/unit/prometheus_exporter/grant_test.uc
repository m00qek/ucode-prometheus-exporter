'use strict';

import { describe, it, assert } from 'utest';
import * as grant from 'prometheus_exporter.grant';
import * as privileges from 'prometheus_exporter.privileges';

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

describe('grant.acl', () => {
	it('is the user\'s, with the canary and the calls of every collector, merged and sorted', () => {
		let ubus = grant.merge([ { rc: [ 'list' ], dnsmasq: [ 'metrics' ] }, { rc: [ 'list' ], 'hostapd.*': [ 'get_status', 'get_clients' ] } ]);

		assert.match({
			user: 'prometheus-exporter',
			access: {
				dnsmasq: { methods: [ 'metrics' ] },
				'hostapd.*': { methods: [ 'get_clients', 'get_status' ] },
				rc: { methods: [ 'list' ] },
				system: { methods: [ 'board' ] },
			},
		}, grant.acl(ubus));
		assert.match([ 'dnsmasq', 'hostapd.*', 'rc', 'system' ], keys(grant.acl(ubus).access));
	});

	it('has the canary alone without a collector that calls ubus', () => {
		assert.match({ user: 'prometheus-exporter', access: { system: { methods: [ 'board' ] } } }, grant.acl({}));
	});

	it('never has an object without methods, which ubusd would let the user call nothing of', () => {
		for (let o, a in grant.acl(grant.merge([ { a: [ 'x' ] }, { b: [ 'y', 'z' ] } ])).access)
			assert.match(true, length(a.methods) > 0, o);
	});
});

describe('grant.capabilities_doc and service_capabilities', () => {
	it('gives every set of the file the same capabilities, so the programs the jail runs have them too', () => {
		assert.match({
			bounding: [ 'CAP_NET_ADMIN' ], effective: [ 'CAP_NET_ADMIN' ], ambient: [ 'CAP_NET_ADMIN' ],
			permitted: [ 'CAP_NET_ADMIN' ], inheritable: [ 'CAP_NET_ADMIN' ],
		}, grant.capabilities_doc([ 'CAP_NET_ADMIN', 'CAP_NET_ADMIN' ]));
		assert.match({ bounding: [], effective: [], ambient: [], permitted: [], inheritable: [] }, grant.capabilities_doc([]));
	});

	it('adds the service\'s own for a port under 1024', () => {
		assert.match([ [ 'CAP_NET_ADMIN' ], [ 'CAP_NET_ADMIN', 'CAP_NET_BIND_SERVICE' ], [] ], [
			grant.service_capabilities(grants({ capabilities: [ 'CAP_NET_ADMIN' ] })),
			grant.service_capabilities(grants({ capabilities: [ 'CAP_NET_ADMIN' ], port: 443 })),
			grant.service_capabilities(grants({ port: 1024 })),
		]);
	});
});

describe('grant.membership and gid_of', () => {
	it('makes the user a member of the groups it wants, and of none it does not', () => {
		assert.match({ text: 'root:x:0:\nunbound:x:32768:unbound,prometheus-exporter\nntp:x:123:ntp\n', missing: [] },
			grant.membership('root:x:0:\nunbound:x:32768:unbound\nntp:x:123:ntp\n', 'prometheus-exporter', { unbound: true }));
		assert.match({ text: 'unbound:x:32768:unbound\nchrony:x:323:\n', missing: [] },
			grant.membership('unbound:x:32768:unbound,prometheus-exporter\nchrony:x:323:prometheus-exporter\n', 'prometheus-exporter', { unbound: false, chrony: false }));
		assert.match({ text: 'dialout:x:20:prometheus-exporter\n', missing: [] },
			grant.membership('dialout:x:20:\n', 'prometheus-exporter', { dialout: true }));
	});

	it('changes nothing that is as it should be, and says which groups are not there', () => {
		assert.match({ text: null, missing: [ 'unbound' ] }, grant.membership('ntp:x:123:ntp\n', 'prometheus-exporter', { unbound: true, ntp: false }));
		assert.match({ text: null, missing: [] }, grant.membership(GROUPS, 'prometheus-exporter', {}));
	});

	it('finds a group\'s gid', () => {
		assert.match([ 32770, 0, null, null ], [ grant.gid_of(GROUPS, 'prometheus-exporter'), grant.gid_of(GROUPS, 'root'), grant.gid_of(GROUPS, 'nobody'), grant.gid_of(null, 'root') ]);
	});
});

describe('grant.make', () => {
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
		let res = grant.make(system(fs), grants({
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

		grant.make(system(fs), grants({ files: [ '/etc/config/x', '/etc/config/y' ] }));
		assert.match(0o644, fs.files['/etc/config/x'].mode);
		assert.match([], filter(fs.log, (l) => l[1] == '/etc/config/y'));
	});

	it('makes the user a member of the enabled collectors\' groups, under the lock, and of no other a collector declares', () => {
		let fs = filesystem(files({ '/etc/group': { data: 'unbound:x:32768:unbound\nchrony:x:323:chrony,prometheus-exporter\nprometheus-exporter:x:32770:\n', mode: 0o644 } }));
		let sys = system(fs);
		let res = grant.make(sys, grants({ groups: [ 'unbound', 'dbus' ], groups_off: [ 'chrony' ] }));

		assert.match('unbound:x:32768:unbound,prometheus-exporter\nchrony:x:323:chrony\nprometheus-exporter:x:32770:\n', fs.files['/etc/group'].data);
		assert.match([ 0o644, 0 ], [ fs.files['/etc/group'].mode, fs.files['/etc/group'].gid ]);
		assert.match([ 'take', 'release' ], sys.locks);
		assert.match(true, 'no group dbus: prometheus-exporter joins it once it is there' in res.made);
	});

	it('refuses to grant anything without the service\'s group, which the package makes', () => {
		let fs = filesystem(files({ '/etc/group': { data: 'root:x:0:\n', mode: 0o644 } }));
		let sys = system(fs);

		assert.match({ made: [], problems: [ 'no group prometheus-exporter in /etc/group: reinstall the package, which makes it' ] },
			grant.make(sys, grants({ files: [ '/etc/config/dhcp' ] })));
		assert.match([ [ 'take', 'release' ], 0o600 ], [ sys.locks, fs.files['/etc/config/dhcp'].mode ]);
	});

	it('writes the capabilities file of the enabled collectors, and the ACL of their calls, and has ubusd read it', () => {
		let fs = filesystem(files());
		let sys = system(fs);

		grant.make(sys, grants({ capabilities: [ 'CAP_NET_ADMIN' ], ubus: { rc: [ 'list' ] }, port: 80 }));
		assert.match(grant.capabilities_doc([ 'CAP_NET_ADMIN', 'CAP_NET_BIND_SERVICE' ]), json(fs.files[privileges.CAPABILITIES_FILE].data));
		assert.match(grant.acl({ rc: [ 'list' ] }), json(fs.files[privileges.ACL_FILE].data));
		assert.match([ 0o644, 0, 1 ], [ fs.files[privileges.ACL_FILE].mode, fs.files[privileges.ACL_FILE].gid, sys.reloads ]);

		// The same again: ubusd is not told.
		grant.make(sys, grants({ capabilities: [ 'CAP_NET_ADMIN' ], ubus: { rc: [ 'list' ] }, port: 80 }));
		assert.match(1, sys.reloads);
	});

	it('says when ubusd cannot be told', () => {
		assert.match([ `cannot have ubusd read ${privileges.ACL_FILE}` ], grant.make(system(filesystem(files()), false), grants()).problems);
	});

	it('copies the TLS files for the group to read, and removes the copies without them', () => {
		let fs = filesystem(files());

		grant.make(system(fs), grants({ tls: { cert: '/etc/uhttpd.crt', key: '/etc/uhttpd.key' } }));
		assert.match([ [ 'CERT', 0o640, 32770 ], [ 'KEY', 0o640, 32770 ], [ 'KEY', 0o600, 0 ] ],
			map([ privileges.TLS_CERT, privileges.TLS_KEY, '/etc/uhttpd.key' ], (p) => [ fs.files[p].data, fs.files[p].mode, fs.files[p].gid ]));

		grant.make(system(fs), grants());
		assert.match([ null, null ], [ fs.files[privileges.TLS_CERT], fs.files[privileges.TLS_KEY] ]);
	});

	it('says what it could not do, and goes on', () => {
		let fs = filesystem(files(), [ 'chown' ]);
		let res = grant.make(system(fs), grants({ files: [ '/etc/config/dhcp' ], ubus: { rc: [ 'list' ] } }));

		assert.match([
			'cannot give prometheus-exporter read access to /etc/config/dhcp: Permission denied',
			`cannot write ${privileges.CAPABILITIES_FILE}: Permission denied`,
			`cannot write ${privileges.ACL_FILE}: Permission denied`,
		], res.problems);
	});
});

describe('grant.clean', () => {
	it('takes away the ACL, telling ubusd, the capabilities and the TLS copies', () => {
		let fs = filesystem({
			[privileges.ACL_FILE]: { data: '{}' }, [privileges.CAPABILITIES_FILE]: { data: '{}' },
			[privileges.TLS_CERT]: { data: 'C' }, [privileges.TLS_KEY]: { data: 'K' }, '/etc/config/dhcp': { data: 'x' },
		});
		let sys = system(fs);

		assert.match(true, grant.clean(sys));
		assert.match([ [ '/etc/config/dhcp' ], 1 ], [ keys(fs.files), sys.reloads ]);
	});

	it('leaves ubusd alone when there was no ACL', () => {
		let sys = system(filesystem({}));

		assert.match([ true, 0 ], [ grant.clean(sys), sys.reloads ]);
	});
});

'use strict';

import { describe, it, assert } from 'utest';
import * as ubusd from 'prometheus.exporter.ubusd';

const ON_UBUS = [ 'session', 'uci', 'dnsmasq', 'dhcp', 'service', 'system', 'network.interface' ];

// What each service registers; rpcd, dnsmasq and odhcpd do not register
// again when ubusd starts again, procd and netifd do.
const OWNS = { rpcd: [ 'session', 'uci' ], dnsmasq: [ 'dnsmasq' ], odhcpd: [ 'dhcp' ] };

// A ubusd of pid 7 that reads its ACLs on SIGHUP, or with `crash` crashes
// doing it; procd starts it again as pid 8 at the next sleep, unless
// `no_return`, and registers its own object at the one after, unless
// `no_procd`. A service restarts through procd's object, so not before.
// `before`: what is on ubus; `lost`: objects of other services that do not
// come back either; `broken`: services that cannot restart.
function world(opts) {
	let w = null;
	let before = opts?.before ?? ON_UBUS;

	w = {
		pid: 7, crashed: false, signals: [], restarted: [], slept: 0,
		on_ubus: [ ...before ],
		ubusd_pid: () => w.pid,
		alive: (pid) => pid == w.pid,
		signal: function(pid) {
			push(w.signals, pid);
			if (opts?.crash) {
				w.crashed = true;
				w.pid = null;
				w.on_ubus = null;
			}
			return opts?.signal ?? true;
		},
		objects: () => (w.on_ubus == null) ? null : [ ...w.on_ubus ],
		restart: function(service) {
			if (service in (opts?.broken ?? []) || !('service' in w.on_ubus))
				return false;
			push(w.restarted, service);
			push(w.on_ubus, ...filter(OWNS[service] ?? [], (o) => o in before));
			return true;
		},
		sleep: function(ms) {
			w.slept += ms;
			if (w.crashed && w.pid != null && !opts?.no_procd && 'service' in before && !('service' in w.on_ubus))
				push(w.on_ubus, 'service');
			if (w.crashed && w.pid == null && !opts?.no_return) {
				w.pid = 8;
				w.on_ubus = filter(before, (o) => !(o in [ 'service', ...OWNS.rpcd, ...OWNS.dnsmasq, ...OWNS.odhcpd, ...(opts?.lost ?? []) ]));
			}
		},
	};

	return w;
}

describe('ubusd.reload', () => {
	it('has ubusd read its ACLs, and leaves the rest be when it does', () => {
		let w = world();

		assert.match([ { ok: true, made: [], problems: [] }, [ 7 ], [], ubusd.SETTLE_MS ],
			[ ubusd.reload(w), w.signals, w.restarted, w.slept ]);
	});

	it('when that crashes ubusd, waits for procd to start it again, and restarts rpcd, dnsmasq and odhcpd, which do not register again', () => {
		let w = world({ crash: true });

		assert.match({
			ok: true,
			made: [
				'restarted rpcd, which does not register on ubus again by itself',
				'restarted dnsmasq, which does not register on ubus again by itself',
				'restarted odhcpd, which does not register on ubus again by itself',
			],
			problems: [ 'ubusd (pid 7) crashed as it read its ACLs again, and procd starts it again' ],
		}, ubusd.reload(w));
		assert.match([ [ 7 ], sort([ ...ON_UBUS ]) ], [ w.signals, sort(w.on_ubus) ]);
	});

	it('restarts only the services that were on ubus', () => {
		let w = world({ crash: true, before: [ 'session', 'uci', 'service', 'system' ] });

		assert.match([ true, [ 'rpcd' ] ], [ ubusd.reload(w).ok, w.restarted ]);
	});

	it('says which objects are not on ubus again, after waiting for them', () => {
		let w = world({ crash: true, before: [ ...ON_UBUS, 'hostapd.phy0-ap0' ], lost: [ 'hostapd.phy0-ap0' ] });
		let res = ubusd.reload(w);

		assert.match([ false, 'not on ubus again: hostapd.phy0-ap0: restart the services that register them, or reboot' ], [ res.ok, res.problems[-1] ]);
		assert.match(true, w.slept >= ubusd.RETURN_SECONDS * 1000);
	});

	it('says when a service cannot restart', () => {
		let res = ubusd.reload(world({ crash: true, broken: [ 'dnsmasq' ] }));

		assert.match([ false, true ], [ res.ok, 'cannot restart dnsmasq, which does not register on ubus again by itself' in res.problems ]);
	});

	it('restarts nothing until procd is on ubus again, and says to reboot when it is not', () => {
		let w = world({ crash: true, no_procd: true });

		assert.match({ ok: false, made: [], problems: [
			'ubusd (pid 7) crashed as it read its ACLs again, and procd starts it again',
			`procd did not register on ubus again within ${ubusd.RETURN_SECONDS} s: reboot`,
		] }, ubusd.reload(w));
		assert.match([], w.restarted);
	});

	it('says to reboot when procd does not start ubusd again', () => {
		let w = world({ crash: true, no_return: true });

		assert.match({ ok: false, made: [], problems: [
			'ubusd (pid 7) crashed as it read its ACLs again, and procd starts it again',
			`ubusd did not start again within ${ubusd.RETURN_SECONDS} s: reboot`,
		] }, ubusd.reload(w));
		assert.match([], w.restarted);
	});

	it('says when ubusd is not running, or cannot be signalled', () => {
		let gone = world();

		gone.pid = null;
		assert.match([
			{ ok: false, made: [], problems: [ 'ubusd is not running' ] },
			{ ok: false, made: [], problems: [ 'cannot signal ubusd (pid 7)' ] },
		], [ ubusd.reload(gone), ubusd.reload(world({ signal: false })) ]);
	});
});

describe('ubusd.host', () => {
	// /proc with an init, a ubusd and a zombie, and ubus's connect().
	let proc = {
		'/proc/1/comm': 'procd\n', '/proc/1/stat': '1 (procd) S 0 1',
		'/proc/763/comm': 'ubusd\n', '/proc/763/stat': '763 (ubusd) S 1 763',
		'/proc/900/comm': 'ubusd\n', '/proc/900/stat': '900 (ubusd) Z 1 900',
	};
	let fs = {
		lsdir: (p) => (p == '/proc') ? [ '1', '763', 'self', 'sys' ] : null,
		readfile: (p) => proc[p],
		stat: () => null,
	};

	it('finds ubusd in /proc, and a zombie is not alive', () => {
		let sys = ubusd.host(fs, () => null);

		assert.match([ 763, true, false, false ], [ sys.ubusd_pid(), sys.alive(763), sys.alive(900), sys.alive(12345) ]);
	});

	it('lists the objects on ubus, and nothing without a connection', () => {
		let closed = 0;
		let conn = { list: () => [ 'system', 'session' ], disconnect: () => closed++ };

		assert.match([ [ 'system', 'session' ], 1, null ], [ ubusd.host(fs, () => conn).objects(), closed, ubusd.host(fs, () => null).objects() ]);
	});

	it('restarts no service without its init script', () => {
		assert.match(false, ubusd.host(fs, () => null).restart('rpcd'));
	});
});

'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import { rc } from 'prometheus.exporter.devkit.rc';
import * as fixtures from 'lib.fixtures';
import * as mwan3 from 'prometheus.collectors.mwan3';

// Neither caju device runs mwan3. Three interfaces (online, offline, disabled)
// as mwan3's rpcd plugin builds `ubus call mwan3 status '{"section":"interfaces"}'`
// (feeds/packages net/mwan3/files/usr/share/rpcd/ucode/mwan3, interfaces_status):
// its keys and types, with made-up values.
const STATUS = fixtures.ubus('synthetic', 'mwan3', 'status');

// The reply, for the interfaces section only.
function status_of(reply) {
	return (args) => {
		assert.match({ section: 'interfaces' }, args);
		return reply;
	};
}

function run(reply, cb) {
	with_collector(mwan3, { ubus: { data: { ...rc({ mwan3: true }), 'mwan3:status': status_of(reply) } } }, cb);
}

function samples(lines, name) {
	return filter(lines, (l) => substr(l, 0, length(name) + 1) == name + '{');
}

describe('collectors.mwan3', () => {
	it('exports the tracking of every interface, every value a gauge', () => {
		run(STATUS, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'gauge' ], uniq(map(r.families, (f) => f.type)));
			assert.match([
				'# HELP mwan3_interface_age_seconds Seconds since mwan3track last checked the interface.',
				'# TYPE mwan3_interface_age_seconds gauge',
				'mwan3_interface_age_seconds{interface="wan"} 2',
				'mwan3_interface_age_seconds{interface="wanb"} 4',
				'mwan3_interface_age_seconds{interface="wwan"} 0',
				'# HELP mwan3_interface_online_seconds Seconds the interface has been online; 0 when not.',
				'# TYPE mwan3_interface_online_seconds gauge',
				'mwan3_interface_online_seconds{interface="wan"} 86231',
				'mwan3_interface_online_seconds{interface="wanb"} 0',
				'mwan3_interface_online_seconds{interface="wwan"} 0',
				'# HELP mwan3_interface_offline_seconds Seconds the interface has been offline; 0 when not.',
				'# TYPE mwan3_interface_offline_seconds gauge',
				'mwan3_interface_offline_seconds{interface="wan"} 0',
				'mwan3_interface_offline_seconds{interface="wanb"} 1804',
				'mwan3_interface_offline_seconds{interface="wwan"} 0',
				'# HELP mwan3_interface_uptime_seconds Seconds the network interface has been up.',
				'# TYPE mwan3_interface_uptime_seconds gauge',
				'mwan3_interface_uptime_seconds{interface="wan"} 86240',
				'mwan3_interface_uptime_seconds{interface="wanb"} 86215',
				'mwan3_interface_uptime_seconds{interface="wwan"} 0',
				'# HELP mwan3_interface_score The tracking score of the interface.',
				'# TYPE mwan3_interface_score gauge',
				'mwan3_interface_score{interface="wan"} 20',
				'mwan3_interface_score{interface="wanb"} 0',
				'mwan3_interface_score{interface="wwan"} 0',
				'# HELP mwan3_interface_lost Tracking probes lost in the current check.',
				'# TYPE mwan3_interface_lost gauge',
				'mwan3_interface_lost{interface="wan"} 0',
				'mwan3_interface_lost{interface="wanb"} 5',
				'mwan3_interface_lost{interface="wwan"} 0',
				'# HELP mwan3_interface_turn Tracking rounds in the current check.',
				'# TYPE mwan3_interface_turn gauge',
				'mwan3_interface_turn{interface="wan"} 0',
				'mwan3_interface_turn{interface="wanb"} 5',
				'mwan3_interface_turn{interface="wwan"} 0',
				'# HELP mwan3_interface_status The tracking status of the interface: 1 for the current one.',
				'# TYPE mwan3_interface_status gauge',
				'mwan3_interface_status{interface="wan",status="offline"} 0',
				'mwan3_interface_status{interface="wan",status="online"} 1',
				'mwan3_interface_status{interface="wan",status="disconnecting"} 0',
				'mwan3_interface_status{interface="wan",status="connecting"} 0',
				'mwan3_interface_status{interface="wan",status="disabled"} 0',
				'mwan3_interface_status{interface="wan",status="notracking"} 0',
				'mwan3_interface_status{interface="wan",status="unknown"} 0',
				'mwan3_interface_status{interface="wanb",status="offline"} 1',
				'mwan3_interface_status{interface="wanb",status="online"} 0',
				'mwan3_interface_status{interface="wanb",status="disconnecting"} 0',
				'mwan3_interface_status{interface="wanb",status="connecting"} 0',
				'mwan3_interface_status{interface="wanb",status="disabled"} 0',
				'mwan3_interface_status{interface="wanb",status="notracking"} 0',
				'mwan3_interface_status{interface="wanb",status="unknown"} 0',
				'mwan3_interface_status{interface="wwan",status="offline"} 0',
				'mwan3_interface_status{interface="wwan",status="online"} 0',
				'mwan3_interface_status{interface="wwan",status="disconnecting"} 0',
				'mwan3_interface_status{interface="wwan",status="connecting"} 0',
				'mwan3_interface_status{interface="wwan",status="disabled"} 0',
				'mwan3_interface_status{interface="wwan",status="notracking"} 0',
				'mwan3_interface_status{interface="wwan",status="unknown"} 1',
				'# HELP mwan3_interface_enabled Whether the interface is enabled in mwan3.',
				'# TYPE mwan3_interface_enabled gauge',
				'mwan3_interface_enabled{interface="wan"} 1',
				'mwan3_interface_enabled{interface="wanb"} 1',
				'mwan3_interface_enabled{interface="wwan"} 0',
				'# HELP mwan3_interface_running Whether mwan3track is tracking the interface.',
				'# TYPE mwan3_interface_running gauge',
				'mwan3_interface_running{interface="wan"} 1',
				'mwan3_interface_running{interface="wanb"} 1',
				'mwan3_interface_running{interface="wwan"} 0',
				'# HELP mwan3_interface_up Whether the network interface is up.',
				'# TYPE mwan3_interface_up gauge',
				'mwan3_interface_up{interface="wan"} 1',
				'mwan3_interface_up{interface="wanb"} 1',
				'mwan3_interface_up{interface="wwan"} 0',
			], r.lines);
		});
	});

	it('exports nothing for a config without interfaces', () => {
		run({ interfaces: {} }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('passes on the ubus error of an enabled mwan3', () => {
		with_collector(mwan3, { ubus: { data: rc({ mwan3: true }), errors: { 'mwan3:status': 'Not found' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'mwan3 status: Not found' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	// rpcd's plugin answers status whether mwan3 runs or not: rc is asked first.
	it('has nothing to observe, and asks mwan3 nothing, where mwan3 is disabled or not installed', () => {
		with_collector(mwan3, { ubus: { data: rc({ mwan3: false }) } }, (r) => {
			assert.match({ ok: true, none: 'mwan3 is disabled', error: null, lines: [], logs: [] }, outcome(r));
		});
		with_collector(mwan3, { ubus: { data: rc({}) } }, (r) => {
			assert.match({ ok: true, none: 'mwan3 is not installed', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('reads an enabled mwan3 that is stopped, which its interfaces say', () => {
		run({ interfaces: { wan: { status: 'unknown', enabled: true, running: false, up: false } } }, (r) => {
			assert.match([ true, null ], [ r.result.ok, r.result.none ]);
			assert.match(contains([ 'mwan3_interface_running{interface="wan"} 0' ]), r.lines);
		});
	});

	it('passes on a failure of rc when it cannot say', () => {
		with_collector(mwan3, { ubus: { data: { 'mwan3:status': status_of({ interfaces: {} }) }, errors: { 'rc:list': 'Permission denied' } } }, (r) => {
			assert.match([ true, null ], [ r.result.ok, r.result.none ]);
		});
	});

	it('fails with SOURCE_INVALID for a reply without interfaces', () => {
		run({ connected: {} }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});

	prop('marks exactly one status of each interface as the current one',
		gen.array(gen.oneof(gen.elements(...mwan3.STATUSES), gen.elements('paused', '', 'down')), { min_len: 1, max_len: 5 }),
		(statuses) => {
			let interfaces = {};
			for (let i = 0; i < length(statuses); i++)
				interfaces[`wan${i}`] = { status: statuses[i], enabled: true };

			run({ interfaces }, (r) => {
				assert.match(true, r.result.ok);
				for (let i = 0; i < length(statuses); i++) {
					let own = samples(r.lines, 'mwan3_interface_status');
					own = filter(own, (l) => index(l, `interface="wan${i}"`) >= 0);
					let current = statuses[i] in mwan3.STATUSES ? statuses[i] : 'unknown';

					assert.match(length(mwan3.STATUSES), length(own));
					assert.match([ `mwan3_interface_status{interface="wan${i}",status="${current}"} 1` ],
						filter(own, (l) => substr(l, -2) == ' 1'));
				}
			});
		});
});

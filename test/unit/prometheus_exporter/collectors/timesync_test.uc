'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, jail_of, outcome } from 'context';
import * as rc from 'lib.rc';
import * as fixtures from 'lib.fixtures';
import * as commands from 'lib.commands';
import * as timesync from 'prometheus_exporter.collectors.timesync';
import * as state from 'prometheus_exporter.state';
import { readfile } from 'fs';

const TRACKING = commands.line(timesync.CHRONYC_TRACKING);

// procd's instances: busybox ntpd on the caju AP, chronyd on the seriguela
// router (its daemon, and the hotplug instance that exited once it synced).
const NTPD_RUNS = fixtures.ubus('caju-ap', 'service.list', 'sysntpd');
const CHRONYD_RUNS = fixtures.ubus('seriguela-router', 'service.list', 'chronyd');
const NONE = fixtures.ubus('seriguela-router', 'service.list', 'sysntpd');

// The seriguela router's chronyd, synchronized to a server at stratum 3.
const SYNCED = fixtures.file('seriguela-router', '/commands/chronyc_c_tracking.txt');

// chronyd with no source to reach (no network): what it answers at first.
const UNSYNCED = fixtures.file('synthetic', '/commands/chronyc_c_tracking_unsynchronised.txt');

// What the hotplug script writes of busybox ntpd's periodic event.
const NTPD_STATE = fixtures.file('synthetic', timesync.NTPD_STATE);

const HELP = [
	'# HELP node_timesync_synchronized Whether the NTP daemon has synchronized the clock (1) or not (0).',
	'# TYPE node_timesync_synchronized gauge',
];

// cfg: { ntpd, chronyd: whether procd runs each; rc: enabled per init script;
// state: the hotplug script's file; tracking: chronyc's output }.
function with_ntp(cfg, cb) {
	let list = (args) => args?.name == 'sysntpd' ? (cfg.ntpd ? NTPD_RUNS : NONE) : (cfg.chronyd ? CHRONYD_RUNS : NONE);
	let outputs = cfg.tracking != null ? { [TRACKING]: cfg.tracking } : {};
	let data = cfg.state != null ? { [timesync.NTPD_STATE]: cfg.state } : {};

	with_collector(timesync, {
		ubus: { data: { 'service:list': list, ...rc.rc(cfg.rc ?? {}) } },
		// No file: a readfile() that finds nothing, as the real one.
		fs: commands.fs(outputs, { data, strict: cfg.state != null }),
	}, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.timesync', () => {
	it('reads the seriguela router\'s chronyd, synchronized', () => {
		with_ntp({ chronyd: true, tracking: { out: SYNCED }, rc: { chronyd: true, sysntpd: false } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				...HELP,
				'node_timesync_synchronized{daemon="chronyd"} 1',
				'# HELP node_timesync_stratum The stratum of the clock, while it is synchronized.',
				'# TYPE node_timesync_stratum gauge',
				'node_timesync_stratum{daemon="chronyd"} 4',
				'# HELP node_timesync_offset_seconds The offset of the clock from the daemon\'s reference at its last update, in seconds.',
				'# TYPE node_timesync_offset_seconds gauge',
				'node_timesync_offset_seconds{daemon="chronyd"} 0.000418361',
				'# HELP node_timesync_last_update_timestamp_seconds When the daemon last updated the clock (chronyd) or reported on it (busybox ntpd).',
				'# TYPE node_timesync_last_update_timestamp_seconds gauge',
				'node_timesync_last_update_timestamp_seconds{daemon="chronyd"} 1790874600.3103',
			], r.lines);
		});
	});

	it('reads busybox ntpd\'s last event on the caju AP, where chrony is not installed', () => {
		with_ntp({ ntpd: true, state: NTPD_STATE, rc: { sysntpd: true } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_timesync_synchronized{daemon="ntpd"} 1',
				'node_timesync_stratum{daemon="ntpd"} 3',
				'node_timesync_offset_seconds{daemon="ntpd"} -0.000213',
				'node_timesync_last_update_timestamp_seconds{daemon="ntpd"} 1790873100',
			], samples(r.lines));
		});
	});

	it('says an unsynchronized daemon is, and nothing more of it', () => {
		with_ntp({ chronyd: true, tracking: { out: UNSYNCED } }, (r) => {
			assert.match([ true, [ ...HELP, 'node_timesync_synchronized{daemon="chronyd"} 0' ] ], [ r.result.ok, r.lines ]);
		});
		with_ntp({ ntpd: true, state: 'time=1790873100\naction=unsync\nstratum=16\noffset=0.000000\nfreq_drift_ppm=0\npoll_interval=64\n' }, (r) => {
			assert.match([ true, [ ...HELP, 'node_timesync_synchronized{daemon="ntpd"} 0' ] ], [ r.result.ok, r.lines ]);
		});
	});

	it('does not know busybox ntpd synchronized before its first event', () => {
		with_ntp({ ntpd: true, rc: { sysntpd: true } }, (r) => {
			assert.match([ true, [ 'node_timesync_synchronized{daemon="ntpd"} 0' ] ], [ r.result.ok, samples(r.lines) ]);
		});
	});

	it('reads both daemons where both run', () => {
		with_ntp({ ntpd: true, chronyd: true, state: NTPD_STATE, tracking: { out: SYNCED } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_timesync_synchronized{daemon="chronyd"} 1',
				'node_timesync_synchronized{daemon="ntpd"} 1',
			], filter(samples(r.lines), (l) => index(l, 'node_timesync_synchronized') == 0));
		});
	});

	it('has nothing to observe where neither daemon runs, and chronyd is disabled or not there', () => {
		for (let scripts in [ { sysntpd: true, chronyd: false }, { sysntpd: false }, {} ])
			with_ntp({ rc: scripts }, (r) => {
				assert.match({ ok: true, none: 'neither ntpd nor chronyd runs', error: null, lines: [], logs: [] }, outcome(r));
			});
	});

	it('fails where chronyd is enabled and not running, with ntpd\'s samples', () => {
		with_ntp({ rc: { chronyd: true } }, (r) => {
			assert.match({ ok: false, none: null, error: 'SOURCE_UNREADABLE', lines: [],
				logs: [ "collector 'timesync': SOURCE_UNREADABLE (chronyd is enabled and not running)" ] }, outcome(r));
		});
		with_ntp({ ntpd: true, state: NTPD_STATE, rc: { chronyd: true } }, (r) => {
			assert.match([ false, 'SOURCE_UNREADABLE' ], [ r.result.ok, r.result.error ]);
			assert.match('node_timesync_synchronized{daemon="ntpd"} 1', samples(r.lines)[0]);
		});
	});

	it('passes on a chronyc that fails or does not answer in time', () => {
		with_ntp({ chronyd: true, tracking: { out: '', status: 1 } }, (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'chronyc: exit status 1' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
		with_ntp({ chronyd: true, tracking: { hangs: true } }, (r) => {
			assert.match('COMMAND_TIMEOUT', r.result.error);
		});
	});

	it('fails with SOURCE_INVALID for a tracking line it cannot read', () => {
		for (let out in [ '', '506 Cannot talk to daemon\n', 'CFC5577C,2001:db8::123,x,1790874600.3,0,0,0,0,0,0,0,0,0,Normal\n' ])
			with_ntp({ chronyd: true, tracking: { out } }, (r) => {
				assert.match([ 'SOURCE_INVALID', [] ], [ r.result.error, r.lines ], out);
			});
	});

	it('fails with SOURCE_INVALID for an event file it cannot read', () => {
		with_ntp({ ntpd: true, state: 'time=1790873100\naction=step\nstratum=\noffset=0.1\n' }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: `${timesync.NTPD_STATE}: stratum is "", not a number` },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('passes on a ubus that cannot say what procd runs', () => {
		with_collector(timesync, { ubus: { data: {}, errors: { 'service:list': 'Permission denied' } } }, (r) => {
			assert.match([ false, 'UBUS_CALL_FAILED' ], [ r.result.ok, r.result.error ]);
		});
	});

	it('reads the event file where the hotplug script writes it, in the service\'s run directory', () => {
		let script = readfile('files/etc/hotplug.d/ntp/90-prometheus-exporter');

		assert.match(`${state.RUN_DIR}/timesync`, timesync.STATE_DIR);
		assert.match([ true, true ], [ index(script, `\ndir=${state.RUN_DIR}\n`) >= 0, index(script, '\nstate=$dir/timesync/ntpd\n') >= 0 ]);
	});

	it('gets the event file\'s directory in the jail, which the service makes, and chronyc where it is installed', () => {
		let j = jail_of(timesync, { files: [ '/usr/bin/chronyc' ] });
		assert.match([ [ timesync.STATE_DIR ], [ '/bin/sh', '/usr/bin/chronyc', timesync.STATE_DIR ], [] ], [ j.owned, j.mounts, j.problems ]);

		j = jail_of(timesync, {});
		assert.match([ [ '/bin/sh', timesync.STATE_DIR ], [] ], [ j.mounts, j.problems ]);
	});

	prop('reads any event busybox ntpd sends, synchronized below stratum 16',
		gen.tuple(gen.int(1, 16), gen.int(-500000, 500000), gen.int(1700000000, 1900000000)), (t) => {
			let offset = sprintf('%f', t[1] / 1000000.0);
			let state = sprintf('time=%d\naction=stratum\nstratum=%d\noffset=%s\nfreq_drift_ppm=0\npoll_interval=64\n', t[2], t[0], offset);

			with_ntp({ ntpd: true, state }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(t[0] < 16 ? [
					'node_timesync_synchronized{daemon="ntpd"} 1',
					`node_timesync_stratum{daemon="ntpd"} ${t[0]}`,
					`node_timesync_offset_seconds{daemon="ntpd"} ${+offset}`,
					`node_timesync_last_update_timestamp_seconds{daemon="ntpd"} ${t[2]}`,
				] : [ 'node_timesync_synchronized{daemon="ntpd"} 0' ], samples(r.lines));
			});
		});
});

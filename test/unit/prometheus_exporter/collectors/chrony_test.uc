'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, jail_of, outcome } from 'context';
import * as rc from 'lib.rc';
import * as fixtures from 'lib.fixtures';
import * as commands from 'lib.commands';
import * as chrony from 'prometheus_exporter.collectors.chrony';
import { format_value } from 'prometheus_exporter.exposition';

const TRACKING = commands.line(chrony.argv('tracking'));
const SOURCES = commands.line(chrony.argv('sources'));
const SERVERSTATS = commands.line(chrony.argv('serverstats'));

// The seriguela router's chronyd: two NTS servers, serving time to four
// interfaces (its /etc/config/chrony has four allow sections).
const SERIGUELA = {
	tracking: fixtures.file('seriguela-router', '/commands/chronyc_c_tracking.txt'),
	sources: fixtures.file('seriguela-router', '/commands/chronyc_c_sources.txt'),
	serverstats: fixtures.file('seriguela-router', '/commands/chronyc_c_serverstats.txt'),
	uci: json(fixtures.file('seriguela-router', '/uci/chrony.json')),
};

// A real chronyd without a network: unsynchronized, no source.
const UNSYNCED = fixtures.file('synthetic', '/commands/chronyc_c_tracking_unsynchronised.txt');

// A reference clock, a peer and servers in every other state.
const STATES = fixtures.file('synthetic', '/commands/chronyc_c_sources.txt');

// cfg: { tracking, sources, serverstats: chronyc's outputs ({ out, status }
// or a string); uci: /etc/config/chrony; socket: whether chronyd's command
// socket is there, as outside the jail; rc: init scripts, chronyd enabled
// by default }.
function with_chrony(cfg, cb) {
	let outputs = {};

	for (let r in [ [ TRACKING, cfg.tracking ], [ SOURCES, cfg.sources ], [ SERVERSTATS, cfg.serverstats ] ])
		if (r[1] != null)
			outputs[r[0]] = type(r[1]) == 'string' ? { out: r[1] } : r[1];

	// chrony looks for chronyd's command socket, which the service's jail
	// never has, to read the server statistics where it runs outside it.
	with_collector(chrony, {
		ubus: { data: rc.rc(cfg.rc ?? { chronyd: true }) },
		uci: { data: { chrony: cfg.uci ?? {} } },
		fs: commands.fs(outputs, { behavior: { stat: (p) => (cfg.socket && p == chrony.SOCKET) ? { type: 'socket' } : null } }),
		outside_jail: [ chrony.SOCKET ],
	}, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function starting(lines, prefix) {
	return filter(lines, (l) => index(l, prefix) == 0);
}

const SERIGUELA_TRACKING = [
	'# HELP chrony_tracking_info Chrony tracking info',
	'# TYPE chrony_tracking_info gauge',
	'chrony_tracking_info{tracking_address="2001:db8::123",tracking_name="2001:db8::123",tracking_refid="CFC5577C"} 1',
	'# HELP chrony_tracking_last_offset_seconds Chrony tracking last offset in seconds',
	'# TYPE chrony_tracking_last_offset_seconds gauge',
	'chrony_tracking_last_offset_seconds 0.000418361',
	'# HELP chrony_tracking_reference_timestamp_seconds Chrony tracking Reference timestamp',
	'# TYPE chrony_tracking_reference_timestamp_seconds gauge',
	'chrony_tracking_reference_timestamp_seconds 1790874600.3102953',
	'# HELP chrony_tracking_system_time_seconds Chrony tracking System time',
	'# TYPE chrony_tracking_system_time_seconds gauge',
	'chrony_tracking_system_time_seconds -0.000499422',
	'# HELP chrony_tracking_remote_reference Chrony tracking is connected to a remote source',
	'# TYPE chrony_tracking_remote_reference gauge',
	'chrony_tracking_remote_reference 1',
	'# HELP chrony_tracking_rms_offset_seconds Chrony tracking long-term average of the offset',
	'# TYPE chrony_tracking_rms_offset_seconds gauge',
	'chrony_tracking_rms_offset_seconds 0.000529683',
	'# HELP chrony_tracking_root_delay_seconds This is the total of the network path delays to the stratum-1 computer from which the computer is ultimately synchronised',
	'# TYPE chrony_tracking_root_delay_seconds gauge',
	'chrony_tracking_root_delay_seconds 0.107750021',
	'# HELP chrony_tracking_root_dispersion_seconds Chrony tracking total of all measurement errors to the NTP root',
	'# TYPE chrony_tracking_root_dispersion_seconds gauge',
	'chrony_tracking_root_dispersion_seconds 0.001241775',
	'# HELP chrony_tracking_frequency_ppms Rate by which the system\'s clock would be wrong if chronyd was not correcting it, in PPMs',
	'# TYPE chrony_tracking_frequency_ppms gauge',
	'chrony_tracking_frequency_ppms -33.695',
	'# HELP chrony_tracking_residual_frequency_ppms For the currently selected reference source, the difference between the frequency it suggests and the one currently in use, in PPMs',
	'# TYPE chrony_tracking_residual_frequency_ppms gauge',
	'chrony_tracking_residual_frequency_ppms 0.011',
	'# HELP chrony_tracking_skew_ppms The estimated error bound on the frequency, in PPMs',
	'# TYPE chrony_tracking_skew_ppms gauge',
	'chrony_tracking_skew_ppms 0.22',
	'# HELP chrony_tracking_update_interval_seconds The time elapsed since the last measurement from the reference source was processed, in seconds',
	'# TYPE chrony_tracking_update_interval_seconds gauge',
	'chrony_tracking_update_interval_seconds 519',
	'# HELP chrony_tracking_stratum Chrony tracking client stratum',
	'# TYPE chrony_tracking_stratum gauge',
	'chrony_tracking_stratum 4',
];

function source(address) {
	return `{source_address="${address}",source_name="${address}"}`;
}

const SERIGUELA_SOURCES = [
	'# HELP chrony_sources_last_sample_age_seconds Chrony sources last good sample age in seconds',
	'# TYPE chrony_sources_last_sample_age_seconds gauge',
	`chrony_sources_last_sample_age_seconds${source('2001:db8::123')} 242`,
	`chrony_sources_last_sample_age_seconds${source('2001:db8:5:51::4')} 679`,
	'# HELP chrony_sources_reachability_ratio Chrony sources ratio of packet reachability',
	'# TYPE chrony_sources_reachability_ratio gauge',
	`chrony_sources_reachability_ratio${source('2001:db8::123')} 1`,
	`chrony_sources_reachability_ratio${source('2001:db8:5:51::4')} 1`,
	'# HELP chrony_sources_reachability_success Chrony sources last poll reachability success',
	'# TYPE chrony_sources_reachability_success gauge',
	`chrony_sources_reachability_success${source('2001:db8::123')} 1`,
	`chrony_sources_reachability_success${source('2001:db8:5:51::4')} 1`,
	'# HELP chrony_sources_last_sample_offset_seconds Chrony sources last sample offset in seconds',
	'# TYPE chrony_sources_last_sample_offset_seconds gauge',
	`chrony_sources_last_sample_offset_seconds${source('2001:db8::123')} 4.5417e-05`,
	`chrony_sources_last_sample_offset_seconds${source('2001:db8:5:51::4')} 0.000914455`,
	'# HELP chrony_sources_last_sample_error_margin_seconds Chrony sources last sample margin of error in seconds',
	'# TYPE chrony_sources_last_sample_error_margin_seconds gauge',
	`chrony_sources_last_sample_error_margin_seconds${source('2001:db8::123')} 0.054516211`,
	`chrony_sources_last_sample_error_margin_seconds${source('2001:db8:5:51::4')} 0.106982768`,
	'# HELP chrony_sources_polling_interval_seconds Chrony sources polling interval in seconds',
	'# TYPE chrony_sources_polling_interval_seconds gauge',
	`chrony_sources_polling_interval_seconds${source('2001:db8::123')} 512`,
	`chrony_sources_polling_interval_seconds${source('2001:db8:5:51::4')} 1024`,
	'# HELP chrony_sources_state_info Chrony sources state info',
	'# TYPE chrony_sources_state_info gauge',
	'chrony_sources_state_info{source_address="2001:db8::123",source_name="2001:db8::123",source_state="sync",source_mode="client"} 1',
	'chrony_sources_state_info{source_address="2001:db8:5:51::4",source_name="2001:db8:5:51::4",source_state="candidate",source_mode="client"} 1',
	'# HELP chrony_sources_stratum Chrony sources stratum',
	'# TYPE chrony_sources_stratum gauge',
	`chrony_sources_stratum${source('2001:db8::123')} 3`,
	`chrony_sources_stratum${source('2001:db8:5:51::4')} 1`,
];

describe('collectors.chrony', () => {
	it('reads the seriguela router\'s chronyd: tracking and sources, without the command socket', () => {
		with_chrony({ ...SERIGUELA }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ ...SERIGUELA_TRACKING, ...SERIGUELA_SOURCES ], r.lines);
		});
	});

	it('reads its server statistics where the command socket is there, as it serves time', () => {
		with_chrony({ ...SERIGUELA, socket: true }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ ...SERIGUELA_TRACKING, ...SERIGUELA_SOURCES ], slice(r.lines, 0, length(SERIGUELA_TRACKING) + length(SERIGUELA_SOURCES)));
			assert.match([
				'# HELP chrony_serverstats_ntp_packets_received_total The number of valid NTP requests received by the server.',
				'# TYPE chrony_serverstats_ntp_packets_received_total counter',
				'chrony_serverstats_ntp_packets_received_total 118',
				'# HELP chrony_serverstats_nts_ke_connections_accepted_total The number of NTS-KE connections accepted by the server.',
				'# TYPE chrony_serverstats_nts_ke_connections_accepted_total counter',
				'chrony_serverstats_nts_ke_connections_accepted_total 0',
				'# HELP chrony_serverstats_command_packets_received_total The number of command requests received by the server.',
				'# TYPE chrony_serverstats_command_packets_received_total counter',
				'chrony_serverstats_command_packets_received_total 98',
			], slice(r.lines, length(SERIGUELA_TRACKING) + length(SERIGUELA_SOURCES), length(SERIGUELA_TRACKING) + length(SERIGUELA_SOURCES) + 9));
			assert.match([
				'chrony_serverstats_ntp_packets_received_total 118',
				'chrony_serverstats_nts_ke_connections_accepted_total 0',
				'chrony_serverstats_command_packets_received_total 98',
				'chrony_serverstats_ntp_packets_dropped_total 0',
				'chrony_serverstats_nts_ke_connections_dropped_total 0',
				'chrony_serverstats_command_packets_dropped_total 0',
				'chrony_serverstats_client_log_records_dropped_total 0',
				'chrony_serverstats_authenticated_ntp_packets_total 0',
				'chrony_serverstats_interleaved_ntp_packets_total 0',
				'chrony_serverstats_ntp_timestamps_held 0',
				'chrony_serverstats_ntp_timestamp_span_seconds 0',
				'chrony_serverstats_ntp_daemon_rx_timestamps_total 0',
				'chrony_serverstats_ntp_daemon_tx_timestamps_total 118',
				'chrony_serverstats_ntp_kernel_rx_timestamps_total 118',
				'chrony_serverstats_ntp_kernel_tx_timestamps_total 0',
				'chrony_serverstats_ntp_hw_rx_timestamps_total 0',
				'chrony_serverstats_ntp_hw_tx_timestamps_total 0',
			], starting(samples(r.lines), 'chrony_serverstats_'));
			assert.match([ 'counter', 'gauge' ], uniq(map(filter(r.families, (f) => index(f.name, 'chrony_serverstats_') == 0), (f) => f.type)));
		});
	});

	it('asks no server statistics of a chronyd that serves no time', () => {
		with_chrony({ ...SERIGUELA, uci: { cfg01: { '.type': 'server', hostname: 'time.example' } }, socket: true }, (r) => {
			assert.match([ true, [] ], [ r.result.ok, starting(samples(r.lines), 'chrony_serverstats_') ]);
		});
	});

	it('reads what an older chronyc prints of its server statistics, and no more', () => {
		with_chrony({ ...SERIGUELA, socket: true, serverstats: '118,0,98,0,0\n' }, (r) => {
			assert.match([
				'chrony_serverstats_ntp_packets_received_total 118',
				'chrony_serverstats_command_packets_received_total 98',
				'chrony_serverstats_ntp_packets_dropped_total 0',
				'chrony_serverstats_command_packets_dropped_total 0',
				'chrony_serverstats_client_log_records_dropped_total 0',
			], starting(samples(r.lines), 'chrony_serverstats_'));
		});
	});

	it('reads a chronyd without a source, unsynchronized', () => {
		with_chrony({ tracking: UNSYNCED, sources: '' }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'chrony_tracking_info{tracking_address="",tracking_name="",tracking_refid="00000000"} 1',
				'chrony_tracking_last_offset_seconds 0',
				'chrony_tracking_reference_timestamp_seconds 0',
				'chrony_tracking_system_time_seconds 0',
				'chrony_tracking_remote_reference 1',
				'chrony_tracking_rms_offset_seconds 0',
				'chrony_tracking_root_delay_seconds 1',
				'chrony_tracking_root_dispersion_seconds 1',
				'chrony_tracking_frequency_ppms -15.463',
				'chrony_tracking_residual_frequency_ppms 0',
				'chrony_tracking_skew_ppms 0',
				'chrony_tracking_update_interval_seconds 0',
				'chrony_tracking_stratum 0',
			], samples(r.lines));
		});
	});

	it('names each source\'s state and mode, as chrony_exporter does', () => {
		with_chrony({ ...SERIGUELA, sources: STATES }, (r) => {
			let s = samples(r.lines);

			assert.match(true, r.result.ok);
			assert.match([
				'chrony_sources_state_info{source_address="GPS",source_name="GPS",source_state="sync",source_mode="reference clock"} 1',
				'chrony_sources_state_info{source_address="192.0.2.10",source_name="192.0.2.10",source_state="outlier",source_mode="peer"} 1',
				'chrony_sources_state_info{source_address="2001:db8::7",source_name="2001:db8::7",source_state="unreach",source_mode="client"} 1',
				'chrony_sources_state_info{source_address="198.51.100.5",source_name="198.51.100.5",source_state="falseticker",source_mode="client"} 1',
				'chrony_sources_state_info{source_address="203.0.113.9",source_name="203.0.113.9",source_state="jittery",source_mode="client"} 1',
			], starting(s, 'chrony_sources_state_info'));
			assert.match([
				`chrony_sources_reachability_ratio${source('GPS')} 1`,
				`chrony_sources_reachability_ratio${source('192.0.2.10')} 0.5`,
				`chrony_sources_reachability_ratio${source('2001:db8::7')} 0`,
				`chrony_sources_reachability_ratio${source('198.51.100.5')} 0.875`,
				`chrony_sources_reachability_ratio${source('203.0.113.9')} 0.875`,
			], starting(s, 'chrony_sources_reachability_ratio'));
			assert.match([ 1, 1, 0, 0, 1 ], map(starting(s, 'chrony_sources_reachability_success'), (l) => +split(l, ' ')[1]));
			assert.match([ 16, 64, 0.25, 1024, 256 ], map(starting(s, 'chrony_sources_polling_interval_seconds'), (l) => +split(l, ' ')[1]));
			// The server never reached has had no sample.
			assert.match([ 'GPS', '192.0.2.10', '198.51.100.5', '203.0.113.9' ],
				map(starting(s, 'chrony_sources_last_sample_age_seconds'), (l) => match(l, /source_address="([^"]*)"/)[1]));
		});
	});

	it('says chronyd\'s own clock is no remote reference', () => {
		with_chrony({ tracking: '4C4F434C,,10,1790874600.000000000,0.000000000,0.000000000,0.000000000,0.000,0.000,0.000,0.000000000,0.000000000,64.0,Normal\n', sources: '' }, (r) => {
			assert.match([ 'chrony_tracking_remote_reference 0' ], starting(samples(r.lines), 'chrony_tracking_remote_reference'));
		});
	});

	it('has nothing to observe where chronyd is disabled, or not installed', () => {
		with_chrony({ tracking: { out: '', status: 1 }, rc: { chronyd: false } }, (r) => {
			assert.match({ ok: true, none: 'chronyd is disabled', error: null, lines: [], logs: [] }, outcome(r));
		});
		with_chrony({ tracking: null, rc: {} }, (r) => {
			assert.match({ ok: true, none: 'chronyd is not installed', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('fails where chronyd is enabled and does not answer', () => {
		with_chrony({ tracking: { out: '', status: 1 } }, (r) => {
			assert.match({ ok: false, none: null, error: 'COMMAND_FAILED', lines: [],
				logs: [ "collector 'chrony': COMMAND_FAILED (chronyc: exit status 1)" ] }, outcome(r));
		});
		with_chrony({ tracking: { hangs: true } }, (r) => {
			assert.match([ false, 'COMMAND_TIMEOUT' ], [ r.result.ok, r.result.error ]);
		});
	});

	it('keeps the tracking of a chronyd whose sources it cannot read', () => {
		with_chrony({ ...SERIGUELA, sources: { out: '', status: 1 } }, (r) => {
			assert.match([ false, 'COMMAND_FAILED' ], [ r.result.ok, r.result.error ]);
			assert.match(SERIGUELA_TRACKING, r.lines);
		});
		with_chrony({ ...SERIGUELA, socket: true, serverstats: { out: '501 Not authorised\n', status: 1 } }, (r) => {
			assert.match([ false, 'COMMAND_FAILED' ], [ r.result.ok, r.result.error ]);
			assert.match([ ...SERIGUELA_TRACKING, ...SERIGUELA_SOURCES ], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for a report it cannot read', () => {
		let bad = [
			[ { tracking: '' }, 'chronyc -c tracking: 0 lines, not 1' ],
			[ { tracking: 'Normal\n' }, 'chronyc -c tracking: 1 fields, not 14' ],
			[ { tracking: 'CFC5577C,x,stratum,1,0,0,0,0,0,0,0,0,0,Normal\n' }, 'chronyc -c tracking: stratum "stratum" is not a number' ],
			[ { ...SERIGUELA, sources: '^,*,2001:db8::1\n' }, 'chronyc -c sources: line 1: 3 fields, not 10' ],
			[ { ...SERIGUELA, sources: '^,*,2001:db8::1,3,9,389,242,0,0,0\n' }, 'chronyc -c sources: line 1: "^,*,2001:db8::1,3,9,389,242,0,0,0"' ],
			[ { ...SERIGUELA, socket: true, serverstats: '1\n2\n' }, 'chronyc -c serverstats: 2 lines, not 1' ],
		];

		for (let b in bad)
			with_chrony(b[0], (r) => {
				assert.match({ ok: false, error: 'SOURCE_INVALID', details: b[1] },
					{ ok: r.result.ok, error: r.result.error, details: r.result.details }, b[1]);
			});
	});

	it('gets its config, the shell and chronyc in the jail, and not chronyd\'s directory', () => {
		let j = jail_of(chrony, { files: [ '/usr/bin/chronyc' ] });
		assert.match([ [ '/bin/sh', '/etc/config/chrony', '/usr/bin/chronyc' ], [] ], [ j.mounts, j.problems ]);
	});

	prop('reads any reachability register and polling interval',
		gen.tuple(gen.int(0, 255), gen.int(-6, 17)), (t) => {
			let reached = 0;
			for (let b = t[0]; b; b >>= 1)
				reached += b & 1;

			let line = sprintf('^,+,2001:db8::9,2,%d,%o,64,0.001,0.001,0.01\n', t[1], t[0]);
			let interval = 1.0;
			for (let i = 0; i < t[1]; i++) interval *= 2;
			for (let i = 0; i > t[1]; i--) interval /= 2;

			with_chrony({ ...SERIGUELA, sources: line }, (r) => {
				let s = samples(r.lines);

				assert.match(true, r.result.ok);
				assert.match(map([ reached / 8.0, t[0] & 1, interval ], format_value), [
					split(starting(s, 'chrony_sources_reachability_ratio')[0], ' ')[1],
					split(starting(s, 'chrony_sources_reachability_success')[0], ' ')[1],
					split(starting(s, 'chrony_sources_polling_interval_seconds')[0], ' ')[1],
				]);
			});
		});
});

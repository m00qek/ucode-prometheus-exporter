'use strict';

import { describe, it, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as ltq_dsl from 'node_exporter.collectors.ltq_dsl';

// Neither caju device has a DSL modem. A VDSL2 17a line with vectoring on a
// Lantiq VRX200, as ltq-vdsl-vr9-app's dsl_cpe_ubus.c builds `ubus call dsl
// metrics` (OpenWrt package/network/config/ltq-vdsl-vr9-app): the keys and
// their types are that file's, the values made up.
const METRICS = fixtures.ubus('synthetic', 'dsl', 'metrics');

function run(reply, cb) {
	with_collector(ltq_dsl, { ubus: { data: { 'dsl:metrics': reply } } }, cb);
}

describe('collectors.ltq_dsl', () => {
	it('exports the line state, rates and errors of a VDSL2 line', () => {
		run(METRICS, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP dsl_info The DSL modem: chipset, firmware and the DSLAM vendor.',
				'# TYPE dsl_info gauge',
				'dsl_info{atuc_vendor="Broadcom 196.200",atuc_system_vendor="Broadcom",chipset="Lantiq-VRX200",' +
					'firmware_version="5.9.1.4.0.7",api_version="4.17.18.6",driver_version="1.5.17.6"} 1',
				'# HELP dsl_line_info The DSL line: annex, standard, mode and profile.',
				'# TYPE dsl_line_info gauge',
				'dsl_line_info{annex="B",standard="G.993.2",' +
					'mode="G.993.2 (VDSL2, Profile 17a, with down- and upstream vectoring)",profile="17a"} 1',
				'# HELP dsl_up Whether the DSL line is up (showtime).',
				'# TYPE dsl_up gauge',
				'dsl_up 1',
				'# HELP dsl_state_info The state of the DSL line, as the driver names it.',
				'# TYPE dsl_state_info gauge',
				'dsl_state_info{state="Showtime with TC-Layer sync"} 1',
				'# HELP dsl_uptime_seconds Time the DSL line has been up.',
				'# TYPE dsl_uptime_seconds gauge',
				'dsl_uptime_seconds 356718',
				'# HELP dsl_line_attenuation_db Line attenuation.',
				'# TYPE dsl_line_attenuation_db gauge',
				'dsl_line_attenuation_db{direction="down"} 13.4',
				'dsl_line_attenuation_db{direction="up"} 8.6',
				'# HELP dsl_signal_attenuation_db Signal attenuation.',
				'# TYPE dsl_signal_attenuation_db gauge',
				'dsl_signal_attenuation_db{direction="down"} 13.2',
				'dsl_signal_attenuation_db{direction="up"} 8.4',
				'# HELP dsl_signal_to_noise_margin_db Signal to noise margin.',
				'# TYPE dsl_signal_to_noise_margin_db gauge',
				'dsl_signal_to_noise_margin_db{direction="down"} 11.7',
				'dsl_signal_to_noise_margin_db{direction="up"} 9.1',
				'# HELP dsl_aggregated_transmit_power_dbm Aggregated transmit power, in dBm.',
				'# TYPE dsl_aggregated_transmit_power_dbm gauge',
				'dsl_aggregated_transmit_power_dbm{direction="down"} 13.8',
				'dsl_aggregated_transmit_power_dbm{direction="up"} 14.3',
				'# HELP dsl_latency_seconds Interleaving delay.',
				'# TYPE dsl_latency_seconds gauge',
				'dsl_latency_seconds{direction="down"} 0.00014',
				'dsl_latency_seconds{direction="up"} 0',
				'# HELP dsl_data_rate_bits_per_second Data rate, in bits per second.',
				'# TYPE dsl_data_rate_bits_per_second gauge',
				'dsl_data_rate_bits_per_second{direction="down"} 116790000',
				'dsl_data_rate_bits_per_second{direction="up"} 40000000',
				'# HELP dsl_max_data_rate_bits_per_second Attainable data rate, in bits per second.',
				'# TYPE dsl_max_data_rate_bits_per_second gauge',
				'dsl_max_data_rate_bits_per_second{direction="down"} 131440000',
				'dsl_max_data_rate_bits_per_second{direction="up"} 48332000',
				'# HELP dsl_error_seconds_total Seconds with errors, by kind.',
				'# TYPE dsl_error_seconds_total counter',
				'dsl_error_seconds_total{err="forward error correction",loc="near"} 4821',
				'dsl_error_seconds_total{err="forward error correction",loc="far"} 97',
				'dsl_error_seconds_total{err="errored",loc="near"} 12',
				'dsl_error_seconds_total{err="errored",loc="far"} 5',
				'dsl_error_seconds_total{err="severely errored",loc="near"} 3',
				'dsl_error_seconds_total{err="severely errored",loc="far"} 1',
				'dsl_error_seconds_total{err="loss of signal",loc="near"} 0',
				'dsl_error_seconds_total{err="loss of signal",loc="far"} 0',
				'dsl_error_seconds_total{err="unavailable",loc="near"} 262',
				'dsl_error_seconds_total{err="unavailable",loc="far"} 262',
				'# HELP dsl_errors_total Errors, by kind.',
				'# TYPE dsl_errors_total counter',
				'dsl_errors_total{err="header error code error",loc="near"} 0',
				'dsl_errors_total{err="header error code error",loc="far"} 0',
				'dsl_errors_total{err="non pre-emptive crc error",loc="near"} 7',
				'dsl_errors_total{err="non pre-emptive crc error",loc="far"} 2',
				'dsl_errors_total{err="pre-emptive crc error",loc="near"} 0',
				'dsl_errors_total{err="pre-emptive crc error",loc="far"} 0',
				'# HELP dsl_erb_total Error reporting blocks for vectoring.',
				'# TYPE dsl_erb_total counter',
				'dsl_erb_total{counter="sent"} 1782345',
				'dsl_erb_total{counter="discarded"} 12',
			], r.lines);
		});
	});

	it('leaves out the latency of a fast-path line and the erb counters without vectoring', () => {
		let x = json(sprintf('%J', METRICS));
		x.downstream.interleave_delay = 0;
		delete x.erb;

		run(x, (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, index(r.text, 'dsl_latency_seconds') >= 0);
			assert.match(false, index(r.text, 'dsl_erb_total') >= 0);
		});
	});

	it('reports a line that is down, with no rates yet', () => {
		run({
			api_version: '4.17.18.6', chipset: 'Lantiq-VRX200', state: 'Handshake', up: false,
			upstream: {}, downstream: {}, errors: { near: {}, far: {} },
		}, (r) => {
			assert.match(true, r.result.ok);
			assert.match(contains([ 'dsl_up 0', 'dsl_state_info{state="Handshake"} 1' ]), r.lines);
			assert.match(false, index(r.text, 'dsl_data_rate') >= 0);
		});
	});

	it('passes on the ubus error on a device without a DSL modem', () => {
		with_collector(ltq_dsl, { ubus: { errors: { 'dsl:metrics': 'Not found' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'dsl metrics: Not found' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for an empty reply', () => {
		run(() => null, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});
});

'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/ltq-dsl.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

export const meta = {
	name: 'ltq-dsl',
	title: 'Lantiq DSL line',
	help: 'Lantiq DSL line state, rates and errors, from ubus dsl metrics.',
	needs: [ 'ubus' ],
};

// The downstream and upstream samples of one family, from x.{down,up}stream[key].
function both(sample, x, key) {
	sample({ direction: 'down' }, x.downstream?.[key]);
	sample({ direction: 'up' }, x.upstream?.[key]);
}

// The near and far end samples of one kind of error, from x.errors.{near,far}[key].
function per_end(sample, x, err, key) {
	sample({ err, loc: 'near' }, x.errors?.near?.[key]);
	sample({ err, loc: 'far' }, x.errors?.far?.[key]);
}

export function collect(deps, out) {
	let res = deps.ubus.call('dsl', 'metrics');

	if (!res.ok)
		return res;

	let x = res.data;
	if (type(x) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'dsl metrics: not an object');

	out.gauge('dsl_info', 'The DSL modem: chipset, firmware and the DSLAM vendor.')({
		atuc_vendor: x.atu_c?.vendor,
		atuc_system_vendor: x.atu_c?.system_vendor,
		chipset: x.chipset,
		firmware_version: x.firmware_version,
		api_version: x.api_version,
		driver_version: x.driver_version,
	}, 1);

	out.gauge('dsl_line_info', 'The DSL line: annex, standard, mode and profile.')({
		annex: x.annex,
		standard: x.standard,
		mode: x.mode,
		profile: x.profile,
	}, 1);

	// The state apart from dsl_up, so that a state change starts no new dsl_up series.
	out.gauge('dsl_up', 'Whether the DSL line is up (showtime).')(null, x.up);
	out.gauge('dsl_state_info', 'The state of the DSL line, as the driver names it.')({ state: x.state }, 1);
	out.gauge('dsl_uptime_seconds', 'Time the DSL line has been up.')(null, x.uptime);

	both(out.gauge('dsl_line_attenuation_db', 'Line attenuation.'), x, 'latn');
	both(out.gauge('dsl_signal_attenuation_db', 'Signal attenuation.'), x, 'satn');
	both(out.gauge('dsl_signal_to_noise_margin_db', 'Signal to noise margin.'), x, 'snr');
	both(out.gauge('dsl_aggregated_transmit_power_dbm', 'Aggregated transmit power, in dBm.'), x, 'actatp');

	// The driver reports the delay in microseconds; none on a fast-path line.
	if (x.downstream?.interleave_delay) {
		let latency = out.gauge('dsl_latency_seconds', 'Interleaving delay.');
		for (let dir in [ 'down', 'up' ]) {
			let us = x[dir + 'stream']?.interleave_delay;
			latency({ direction: dir }, type(us) in [ 'int', 'double' ] ? us / 1000000.0 : null);
		}
	}

	both(out.gauge('dsl_data_rate_bits_per_second', 'Data rate, in bits per second.'), x, 'data_rate');
	both(out.gauge('dsl_max_data_rate_bits_per_second', 'Attainable data rate, in bits per second.'), x, 'attndr');

	let seconds = out.counter('dsl_error_seconds_total', 'Seconds with errors, by kind.');
	per_end(seconds, x, 'forward error correction', 'fecs');
	per_end(seconds, x, 'errored', 'es');
	per_end(seconds, x, 'severely errored', 'ses');
	per_end(seconds, x, 'loss of signal', 'loss');
	per_end(seconds, x, 'unavailable', 'uas');

	let errs = out.counter('dsl_errors_total', 'Errors, by kind.');
	per_end(errs, x, 'header error code error', 'hec');
	per_end(errs, x, 'non pre-emptive crc error', 'crc_p');
	per_end(errs, x, 'pre-emptive crc error', 'crcp_p');

	// Only with vectoring.
	if (x.erb)
		out.counter('dsl_erb_total', 'Error reporting blocks for vectoring.')
			({ counter: 'sent' }, x.erb.sent)
			({ counter: 'discarded' }, x.erb.discarded);

	return Result.ok();
};

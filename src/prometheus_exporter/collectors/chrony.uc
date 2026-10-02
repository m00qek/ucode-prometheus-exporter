'use strict';

// chronyd: what it tracks, its sources and, where it serves time, its server
// statistics, from `chronyc -c tracking`, `-c sources` and `-c serverstats`
// (CSV, addresses as numbers), named as SuperQ/chrony_exporter names them
// (collector/tracking.go, sources.go, serverstats.go), with its help texts and
// labels, so its dashboards work; as it does without DNS lookups (its
// default), a source's name is its address. Its `_ppms` names are kept: ppm is
// the unit chrony speaks in. chrony_up is not: node_scrape_collector_success
// is the exporter's.
//
// chronyd disabled (its init script), or not installed, is nothing to
// observe: chronyc is run first, and rpcd's rc asked only when it fails.
// Enabled, a chronyd that does not answer fails the collector.
//
// chronyd answers serverstats on its Unix command socket only (over UDP it
// refuses: 501 Not authorised), and chronyc reaches the socket only where it
// can make its own socket beside it, in /var/run/chrony. The exporter's jail
// does not give it that directory (writing there is commanding chronyd,
// which can set the clock): under procd chronyc asks over UDP, as it does
// for tracking and sources, and serverstats are left out. Outside the jail
// (where ujail cannot be had, and `collector check` of a module) they are
// read, when chronyd serves time: /etc/config/chrony has an `allow` section.
// SOCKET is so a path it looks for without declaring it, knowing the jail
// never has it; its tests say so (test/context.uc's outside_jail).

import { Result, errors, services } from 'prometheus_exporter.api';

// chronyd's command socket (chrony's --chronyrundir, /var/run/chrony).
export const SOCKET = '/var/run/chrony/chronyd.sock';

export const meta = {
	name: 'chrony',
	title: 'chrony NTP daemon',
	help: 'chronyd\'s tracking and sources, and its server statistics where it serves time, from chronyc.',
	needs: [ 'ubus', 'uci', 'fs', 'exec' ],
	configs: [ 'chrony' ],
	commands: [ 'chronyc' ],
};

// The reference of chronyd's own clock, as chrony_exporter knows it, and the
// refid chrony 4 gives it (LOCL).
const LOCAL_ADDRESS = '127.127.1.1';
const LOCAL_REFID = '4C4F434C';

// chronyc's mode and state characters (client.c, process_cmd_sources), as
// chrony_exporter spells them (facebook/time's ntp/chrony).
const MODES = { '^': 'client', '=': 'peer', '#': 'reference clock' };
const STATES = { '*': 'sync', '?': 'unreach', 'x': 'falseticker', '~': 'jittery', '+': 'candidate', '-': 'outlier' };

// A source that has no sample yet: its seconds since the last are (uint32_t)-1.
const NO_SAMPLE = 4294967295;

// [ field, family, type, help ] of tracking's CSV fields, in chrony_exporter's
// order; the stratum (2) is last there too.
const TRACKING = [
	[ 5, 'chrony_tracking_last_offset_seconds', 'gauge', 'Chrony tracking last offset in seconds' ],
	[ 3, 'chrony_tracking_reference_timestamp_seconds', 'gauge', 'Chrony tracking Reference timestamp' ],
	[ 4, 'chrony_tracking_system_time_seconds', 'gauge', 'Chrony tracking System time' ],
	[ null, 'chrony_tracking_remote_reference', 'gauge', 'Chrony tracking is connected to a remote source' ],
	[ 6, 'chrony_tracking_rms_offset_seconds', 'gauge', 'Chrony tracking long-term average of the offset' ],
	[ 10, 'chrony_tracking_root_delay_seconds', 'gauge', 'This is the total of the network path delays to the stratum-1 computer from which the computer is ultimately synchronised' ],
	[ 11, 'chrony_tracking_root_dispersion_seconds', 'gauge', 'Chrony tracking total of all measurement errors to the NTP root' ],
	[ 7, 'chrony_tracking_frequency_ppms', 'gauge', 'Rate by which the system\'s clock would be wrong if chronyd was not correcting it, in PPMs' ],
	[ 8, 'chrony_tracking_residual_frequency_ppms', 'gauge', 'For the currently selected reference source, the difference between the frequency it suggests and the one currently in use, in PPMs' ],
	[ 9, 'chrony_tracking_skew_ppms', 'gauge', 'The estimated error bound on the frequency, in PPMs' ],
	[ 12, 'chrony_tracking_update_interval_seconds', 'gauge', 'The time elapsed since the last measurement from the reference source was processed, in seconds' ],
	[ 2, 'chrony_tracking_stratum', 'gauge', 'Chrony tracking client stratum' ],
];

// [ field, family, type, help ] of serverstats' CSV fields, chrony 4.8's
// (client.c, process_cmd_serverstats): an older chronyc prints fewer.
const SERVERSTATS = [
	[ 0, 'chrony_serverstats_ntp_packets_received_total', 'counter', 'The number of valid NTP requests received by the server.' ],
	[ 5, 'chrony_serverstats_nts_ke_connections_accepted_total', 'counter', 'The number of NTS-KE connections accepted by the server.' ],
	[ 2, 'chrony_serverstats_command_packets_received_total', 'counter', 'The number of command requests received by the server.' ],
	[ 1, 'chrony_serverstats_ntp_packets_dropped_total', 'counter', 'The number of NTP requests dropped by the server due to rate limiting.' ],
	[ 6, 'chrony_serverstats_nts_ke_connections_dropped_total', 'counter', 'The number of NTS-KE connections dropped by the server due to rate limiting.' ],
	[ 3, 'chrony_serverstats_command_packets_dropped_total', 'counter', 'The number of command requests dropped by the server due to rate limiting.' ],
	[ 4, 'chrony_serverstats_client_log_records_dropped_total', 'counter', 'The number of client log records dropped by the server to limit the memory use.' ],
	[ 7, 'chrony_serverstats_authenticated_ntp_packets_total', 'counter', 'The number of received NTP requests that were authenticated (with a symmetric key or NTS).' ],
	[ 8, 'chrony_serverstats_interleaved_ntp_packets_total', 'counter', 'The number of received NTP requests that were detected to be in the interleaved mode.' ],
	[ 9, 'chrony_serverstats_ntp_timestamps_held', 'gauge', 'The number of pairs of receive and transmit timestamps that the server is currently holding in memory for clients using the interleaved mode.' ],
	[ 10, 'chrony_serverstats_ntp_timestamp_span_seconds', 'gauge', 'The interval (in seconds) covered by the currently held NTP timestamps.' ],
	[ 11, 'chrony_serverstats_ntp_daemon_rx_timestamps_total', 'counter', 'The number of NTP responses which included a receive timestamp captured by the daemon.' ],
	[ 12, 'chrony_serverstats_ntp_daemon_tx_timestamps_total', 'counter', 'The number of NTP responses which included a transmit timestamp captured by the daemon.' ],
	[ 13, 'chrony_serverstats_ntp_kernel_rx_timestamps_total', 'counter', 'The number of NTP responses which included a receive timestamp captured by the kernel.' ],
	[ 14, 'chrony_serverstats_ntp_kernel_tx_timestamps_total', 'counter', 'The number of NTP responses (in the interleaved mode) which included a transmit timestamp captured by the kernel.' ],
	[ 15, 'chrony_serverstats_ntp_hw_rx_timestamps_total', 'counter', 'The number of NTP responses which included a receive timestamp captured by the NIC.' ],
	[ 16, 'chrony_serverstats_ntp_hw_tx_timestamps_total', 'counter', 'The number of NTP responses (in the interleaved mode) which included a transmit timestamp captured by the NIC.' ],
];

// A number spelled as a string, or null.
function number(s) {
	let n = (type(s) == 'string' && s != '') ? +s : null;

	return (n != null && n == n) ? n : null;
}

// The CSV lines of a chronyc report, each split in its fields.
function rows(text) {
	return map(filter(split(text ?? '', '\n'), length), (l) => split(l, ','));
}

// chronyc's argv for a report: as CSV, run as root, the jail's user, as
// timesync's (-u root: it would look up the chrony user, and the jail has
// no /etc/passwd).
export function argv(report) {
	return [ 'chronyc', '-u', 'root', '-c', report ];
};

function run(deps, report) {
	let res = deps.exec.run(argv(report));

	return res.ok ? Result.ok(rows(res.data)) : res;
}

function invalid(report, msg) {
	return Result.err(errors.SOURCE_INVALID, `chronyc -c ${report}: ${msg}`);
}

// An octal reachability register's last 8 polls: [ ratio reached, last reached ].
function reachability(octal) {
	let n = 0;

	for (let i = 0; i < length(octal); i++) {
		let d = ord(octal, i) - 48;

		if (d < 0 || d > 7)
			return null;
		n = n * 8 + d;
	}

	let reached = 0;
	for (let bits = n & 0xff; bits; bits >>= 1)
		reached += bits & 1;

	return [ reached / 8.0, n & 1 ];
}

// 2 to the power of a log2 polling interval, which may be negative.
function pow2(e) {
	let v = 1.0;

	for (let i = 0; i < e; i++)
		v *= 2;
	for (let i = 0; i > e; i--)
		v /= 2;

	return v;
}

function tracking(out, f) {
	if (length(f) < 14)
		return `${length(f)} fields, not 14`;
	if (number(f[2]) == null)
		return `stratum ${sprintf('%J', f[2])} is not a number`;

	out.gauge('chrony_tracking_info', 'Chrony tracking info')(
		{ tracking_address: f[1], tracking_name: f[1], tracking_refid: f[0] }, 1);

	let remote = (f[1] == LOCAL_ADDRESS || f[0] == LOCAL_REFID) ? 0 : 1;

	for (let t in TRACKING)
		out[t[2]](t[1], t[3])(null, t[0] == null ? remote : f[t[0]]);

	return null;
}

function sources(out, list) {
	let fam = {
		age: out.gauge('chrony_sources_last_sample_age_seconds', 'Chrony sources last good sample age in seconds'),
		ratio: out.gauge('chrony_sources_reachability_ratio', 'Chrony sources ratio of packet reachability'),
		success: out.gauge('chrony_sources_reachability_success', 'Chrony sources last poll reachability success'),
		offset: out.gauge('chrony_sources_last_sample_offset_seconds', 'Chrony sources last sample offset in seconds'),
		error: out.gauge('chrony_sources_last_sample_error_margin_seconds', 'Chrony sources last sample margin of error in seconds'),
		poll: out.gauge('chrony_sources_polling_interval_seconds', 'Chrony sources polling interval in seconds'),
		state: out.gauge('chrony_sources_state_info', 'Chrony sources state info'),
		stratum: out.gauge('chrony_sources_stratum', 'Chrony sources stratum'),
	};

	for (let i, f in list) {
		if (length(f) < 10)
			return `line ${i + 1}: ${length(f)} fields, not 10`;

		let reach = reachability(f[5]);
		let poll = number(f[4]);
		if (!reach || type(poll) != 'int')
			return `line ${i + 1}: ${sprintf('%J', join(',', f))}`;

		let address = f[2];
		let labels = out.labels({ source_address: address, source_name: address });
		let age = number(f[6]);

		if (age != null && age != NO_SAMPLE)
			fam.age(labels, age);
		fam.ratio(labels, reach[0]);
		fam.success(labels, reach[1]);
		fam.offset(labels, f[7]);
		fam.error(labels, f[9]);
		fam.poll(labels, pow2(poll));
		fam.state({ source_address: address, source_name: address,
			source_state: STATES[f[1]] ?? 'unknown', source_mode: MODES[f[0]] ?? 'unknown' }, 1);
		fam.stratum(labels, f[3]);
	}

	return null;
}

function serverstats(out, f) {
	for (let s in SERVERSTATS)
		if (s[0] < length(f))
			out[s[2]](s[1], s[3])(null, f[s[0]]);
}

// Whether chronyd serves time: an `allow` section in /etc/config/chrony, which
// its init script makes allow directives of.
function serves(uci) {
	return length(uci.chrony.sections('allow')) > 0;
}

export function collect(deps, out) {
	let res = run(deps, 'tracking');

	if (!res.ok)
		return services.unless_disabled(deps.ubus, 'chronyd', res);
	if (length(res.data) != 1)
		return invalid('tracking', `${length(res.data)} lines, not 1`);

	let why = tracking(out, res.data[0]);
	if (why)
		return invalid('tracking', why);

	res = run(deps, 'sources');
	if (!res.ok)
		return res;

	why = sources(out, res.data);
	if (why)
		return invalid('sources', why);

	if (!serves(deps.uci) || deps.fs.stat(SOCKET) == null)
		return Result.ok();

	res = run(deps, 'serverstats');
	if (!res.ok)
		return res;
	if (length(res.data) != 1)
		return invalid('serverstats', `${length(res.data)} lines, not 1`);

	serverstats(out, res.data[0]);

	return Result.ok();
};

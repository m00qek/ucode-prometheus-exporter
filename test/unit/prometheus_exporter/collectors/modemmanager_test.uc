'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, jail_of, outcome } from 'context';
import { rc } from 'lib.rc';
import * as fixtures from 'lib.fixtures';
import * as commands from 'lib.commands';
import * as modemmanager from 'prometheus_exporter.collectors.modemmanager';

// Neither caju device has a cellular modem. An LTE modem as mmcli prints it with
// -J (ModemManager's mmcli-output.c: every value a string, '--' for none): the
// modem list, the modem, and its --signal-get. Identifiers are zeroed.
const LIST = fixtures.file('synthetic', '/commands/mmcli-L-J.json');
const MODEM = fixtures.file('synthetic', '/commands/mmcli-m-0-J.json');
const SIGNAL = fixtures.file('synthetic', '/commands/mmcli-m-0-signal-get-J.json');

const PATH = '/org/freedesktop/ModemManager1/Modem/0';

function outputs(list, modem, signal) {
	let o = { [commands.line([ 'mmcli', '-L', '-J' ])]: list };
	if (modem)
		o[commands.line([ 'mmcli', '-m', PATH, '-J' ])] = modem;
	if (signal)
		o[commands.line([ 'mmcli', '-m', PATH, '--signal-get', '-J' ])] = signal;
	return o;
}

// ModemManager enabled, unless `scripts` says otherwise.
function run(o, cb, scripts) {
	with_collector(modemmanager, { fs: commands.fs(o), ubus: { data: rc(scripts ?? { modemmanager: true }) } }, cb);
}

describe('collectors.modemmanager', () => {
	it('exports the signal quality, as a ratio, and every signal measure an LTE modem reports, with its unit', () => {
		run(outputs({ out: LIST }, { out: MODEM }, { out: SIGNAL }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP modemmanager_signal_quality_ratio Signal quality of the modem, from 0 to 1.',
				'# TYPE modemmanager_signal_quality_ratio gauge',
				`modemmanager_signal_quality_ratio{modem="${PATH}"} 0.67`,
				'# HELP modemmanager_signal_lte_rsrp_dbm The lte rsrp of the modem signal.',
				'# TYPE modemmanager_signal_lte_rsrp_dbm gauge',
				`modemmanager_signal_lte_rsrp_dbm{modem="${PATH}"} -101`,
				'# HELP modemmanager_signal_lte_rsrq_db The lte rsrq of the modem signal.',
				'# TYPE modemmanager_signal_lte_rsrq_db gauge',
				`modemmanager_signal_lte_rsrq_db{modem="${PATH}"} -12`,
				'# HELP modemmanager_signal_lte_rssi_dbm The lte rssi of the modem signal.',
				'# TYPE modemmanager_signal_lte_rssi_dbm gauge',
				`modemmanager_signal_lte_rssi_dbm{modem="${PATH}"} -71`,
				'# HELP modemmanager_signal_lte_snr_db The lte snr of the modem signal.',
				'# TYPE modemmanager_signal_lte_snr_db gauge',
				`modemmanager_signal_lte_snr_db{modem="${PATH}"} 8.4`,
				'# HELP modemmanager_signal_refresh_rate_seconds The refresh rate of the modem signal.',
				'# TYPE modemmanager_signal_refresh_rate_seconds gauge',
				`modemmanager_signal_refresh_rate_seconds{modem="${PATH}"} 10`,
				'# HELP modemmanager_signal_threshold_rssi_dbm The threshold rssi of the modem signal.',
				'# TYPE modemmanager_signal_threshold_rssi_dbm gauge',
				`modemmanager_signal_threshold_rssi_dbm{modem="${PATH}"} 0`,
			], r.lines);
		});
	});

	it('has nothing to observe when ModemManager lists no modem', () => {
		run(outputs({ out: '{"modem-list":[]}' }), (r) => {
			assert.match({ ok: true, none: 'ModemManager lists no modems', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('has nothing to observe when mmcli fails where ModemManager is disabled', () => {
		run(outputs({ out: '', status: 1 }), (r) => {
			assert.match({ ok: true, none: 'modemmanager is disabled', error: null, lines: [], logs: [] }, outcome(r));
		}, { modemmanager: false });
	});

	it('fails with COMMAND_FAILED when mmcli fails, as with ModemManager enabled and not running', () => {
		run(outputs({ out: '', status: 1 }), (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'mmcli: exit status 1' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with COMMAND_TIMEOUT when mmcli does not answer in time', () => {
		run(outputs({ hangs: true }), (r) => {
			assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'mmcli: still running after 5 s, killed' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_INVALID when mmcli prints no JSON', () => {
		run(outputs({ out: 'error: couldn\'t find the ModemManager process in the bus\n' }), (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
			assert.match(true, index(r.result.details, 'mmcli -L -J: ') == 0);
		});
	});

	it('fails with SOURCE_INVALID for a list without modem-list', () => {
		run(outputs({ out: '{}' }), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: 'mmcli -L: no modem-list' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('keeps the signal measures when the modem itself cannot be read', () => {
		run(outputs({ out: LIST }, { out: '', status: 1 }, { out: SIGNAL }), (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match(false, index(r.text, 'modemmanager_signal_quality') >= 0);
			assert.match(contains([ `modemmanager_signal_lte_snr_db{modem="${PATH}"} 8.4` ]), r.lines);
		});
	});

	it('keeps the signal quality when --signal-get prints bad JSON', () => {
		run(outputs({ out: LIST }, { out: MODEM }, { out: '{"modem":' }), (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
			assert.match(contains([ `modemmanager_signal_quality_ratio{modem="${PATH}"} 0.67` ]), r.lines);
		});
	});

	prop('exports every number mmcli prints for a measure, and skips what it prints as --',
		gen.oneof(gen.float(-140, 40), gen.int(-140, 40), gen.constant(null)), (v) => {
			let value = v == null ? '--' : sprintf('%.2f', v);
			let signal = sprintf('%J', { modem: { signal: { lte: { rsrp: value } } } });

			run(outputs({ out: LIST }, { out: '{}' }, { out: signal }), (r) => {
				assert.match(true, r.result.ok);
				assert.match(v == null ? [] : [ `modemmanager_signal_lte_rsrp_dbm{modem="${PATH}"} ${+value}` ],
					filter(r.lines, (l) => substr(l, 0, 1) != '#'));
			});
		});

	it('names a measure with its unit, and one it does not know, or of a 5G modem, as a metric name', () => {
		assert.match([
			'modemmanager_signal_umts_ecio_db', 'modemmanager_signal_evdo_io_dbm', 'modemmanager_signal_nr5g_sinr_db',
			'modemmanager_signal_lte_error_rate', 'modemmanager_signal_5g_rsrp_dbm',
		], [
			modemmanager.family_of('umts', 'ecio'), modemmanager.family_of('evdo', 'io'), modemmanager.family_of('nr5g', 'sinr'),
			modemmanager.family_of('lte', 'error-rate'), modemmanager.family_of('5g', 'rsrp'),
		]);
	});

	prop('gives any signal quality in percent as a ratio', gen.int(0, 100), (q) => {
		let modem = sprintf('%J', { modem: { generic: { 'signal-quality': { value: `${q}`, recent: 'yes' } } } });

		run(outputs({ out: LIST }, { out: modem }, { out: '{}' }), (r) => {
			assert.match([ `modemmanager_signal_quality_ratio{modem="${PATH}"} ${q / 100.0}` ],
				filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});
});

describe('modemmanager in the jail', () => {
	it('gets the shell, mmcli and the D-Bus system socket\'s directory', () => {
		assert.match([ '/bin/sh', '/usr/bin/mmcli', '/var/run/dbus' ], jail_of(modemmanager, { files: [ '/usr/bin/mmcli' ] }).mounts);
	});
});

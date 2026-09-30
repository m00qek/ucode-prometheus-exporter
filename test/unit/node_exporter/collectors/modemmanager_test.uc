'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as commands from 'lib.commands';
import * as modemmanager from 'node_exporter.collectors.modemmanager';

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

function run(o, cb) {
	with_collector(modemmanager, { fs: commands.fs(o) }, cb);
}

describe('collectors.modemmanager', () => {
	it('exports the signal quality and every signal measure an LTE modem reports', () => {
		run(outputs({ out: LIST }, { out: MODEM }, { out: SIGNAL }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP modemmanager_signal_quality Signal quality of the modem, in percent.',
				'# TYPE modemmanager_signal_quality gauge',
				`modemmanager_signal_quality{modem="${PATH}"} 67`,
				'# HELP modemmanager_signal_lte_rsrp The lte rsrp of the modem signal.',
				'# TYPE modemmanager_signal_lte_rsrp gauge',
				`modemmanager_signal_lte_rsrp{modem="${PATH}"} -101`,
				'# HELP modemmanager_signal_lte_rsrq The lte rsrq of the modem signal.',
				'# TYPE modemmanager_signal_lte_rsrq gauge',
				`modemmanager_signal_lte_rsrq{modem="${PATH}"} -12`,
				'# HELP modemmanager_signal_lte_rssi The lte rssi of the modem signal.',
				'# TYPE modemmanager_signal_lte_rssi gauge',
				`modemmanager_signal_lte_rssi{modem="${PATH}"} -71`,
				'# HELP modemmanager_signal_lte_snr The lte snr of the modem signal.',
				'# TYPE modemmanager_signal_lte_snr gauge',
				`modemmanager_signal_lte_snr{modem="${PATH}"} 8.4`,
				'# HELP modemmanager_signal_refresh_rate The refresh rate of the modem signal.',
				'# TYPE modemmanager_signal_refresh_rate gauge',
				`modemmanager_signal_refresh_rate{modem="${PATH}"} 10`,
				'# HELP modemmanager_signal_threshold_rssi The threshold rssi of the modem signal.',
				'# TYPE modemmanager_signal_threshold_rssi gauge',
				`modemmanager_signal_threshold_rssi{modem="${PATH}"} 0`,
			], r.lines);
		});
	});

	it('exports nothing when there is no modem', () => {
		run(outputs({ out: '{"modem-list":[]}' }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('fails with COMMAND_FAILED when mmcli fails, as without ModemManager running', () => {
		run(outputs({ out: '', status: 1 }), (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'mmcli: exit status 1' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
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
			assert.match(contains([ `modemmanager_signal_lte_snr{modem="${PATH}"} 8.4` ]), r.lines);
		});
	});

	it('keeps the signal quality when --signal-get prints bad JSON', () => {
		run(outputs({ out: LIST }, { out: MODEM }, { out: '{"modem":' }), (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
			assert.match(contains([ `modemmanager_signal_quality{modem="${PATH}"} 67` ]), r.lines);
		});
	});

	prop('exports every number mmcli prints for a measure, and skips what it prints as --',
		gen.oneof(gen.float(-140, 40), gen.int(-140, 40), gen.constant(null)), (v) => {
			let value = v == null ? '--' : sprintf('%.2f', v);
			let signal = sprintf('%J', { modem: { signal: { lte: { rsrp: value } } } });

			run(outputs({ out: LIST }, { out: '{}' }, { out: signal }), (r) => {
				assert.match(true, r.result.ok);
				assert.match(v == null ? [] : [ `modemmanager_signal_lte_rsrp{modem="${PATH}"} ${+value}` ],
					filter(r.lines, (l) => substr(l, 0, 1) != '#'));
			});
		});
});

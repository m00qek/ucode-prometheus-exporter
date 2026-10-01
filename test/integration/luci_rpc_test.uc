'use strict';

// The LuCI app's plugin module over every collector of the source tree: what
// the settings page renders from must be there for each, and what it writes
// back must pass.

import { describe, it, assert } from 'utest';
import { lsdir } from 'fs';
import * as rpc from 'prometheus_exporter.luci.rpc';
import * as loader from 'prometheus_exporter.loader';
import * as deps from 'prometheus_exporter.deps';
import * as config from 'prometheus_exporter.config';
import * as jail from 'prometheus_exporter.jail';
import { with_mods } from 'context';

const SOURCES = 'src/prometheus_exporter/collectors';
const COLLECTORS = loader.load({ lsdir }, SOURCES, loader.import_module, (msg) => die(msg));

// uci's spelling of a typed value.
function as_uci(v) {
	return (type(v) == 'bool') ? (v ? '1' : '0') : `${v}`;
}

function with_sys(cb) {
	with_mods({ uci: { data: { [config.NAME]: {}, dhcp: {}, network: {} } } }, function(mods) {
		cb({
			uci: mods.uci.cursor(),
			fs: { stat: () => null, glob: () => [], readfile: () => null },
			path: jail.PATH,
			collectors: COLLECTORS,
			skipped: [],
			ubus: deps.ubus_channel(mods.ubus.connect),
		});
	});
}

describe('the LuCI plugin over the real collectors', () => {
	it('describes every collector with a title, help and typed options', () => {
		with_sys((sys) => {
			let res = rpc.collectors(sys);

			assert.match(length(COLLECTORS), length(res.collectors));
			for (let c in res.collectors) {
				assert.match(true, type(c.title) == 'string' && c.title != '', `${c.name}: title`);
				assert.match(true, type(c.help) == 'string' && c.help != '', `${c.name}: help`);
				assert.match([ true, null ], [ c.enabled, c.error ], c.name);

				for (let o in c.options) {
					assert.match(true, o.type in [ 'bool', 'int', 'string' ], `${c.name}.${o.name}: type ${o.type}`);
					assert.match(o.type, type(o.default), `${c.name}.${o.name}: default`);
					assert.match([ o.default, false, null ], [ o.value, o.set, o.error ], `${c.name}.${o.name}`);
				}
			}
		});
	});

	it('passes every option at its default, as the settings page would write it', () => {
		with_sys((sys) => {
			let given = {};

			for (let c in COLLECTORS) {
				given[c.id] = { enabled: '0' };
				for (let o in rpc.options_of(c.meta))
					given[c.id][o.name] = as_uci(o.default);
			}

			let main = {};
			for (let name in rpc.MAIN_OPTIONS)
				main[name] = as_uci({ ...config.SERVICE_OPTIONS, ...config.MAIN_OPTIONS }[name].default);

			assert.match({ ok: true, errors: { main: {}, collectors: {} } }, rpc.validate(sys, { main, collectors: given }));
		});
	});
});

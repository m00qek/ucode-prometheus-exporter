'use strict';

import { describe, it, assert } from 'utest';
import { readfile } from 'fs';
import * as source from 'docs_gen.source';

const COLLECTOR = join('\n', [
	"let load1 = out.gauge('node_load1', '1m load average.');",
	"let n = out.counter( 'node_things_total',",
	"	'Things, it\\'s said.');",
	"let dyn = out.untyped(`node_${name}`, help);",
	"let again = out.gauge('node_load1', '1m load average.');",
	"let built = out.gauge('node_built', 'Built ' + 'help.');",
	"if (!x) return Result.none('no such thing');",
	"return services.unless_disabled(deps.ubus, 'dnsmasq', res);",
	"let why = services.idle(deps.ubus, 'odhcpd');",
]);

describe('docs_gen.source.declared', () => {
	it('finds the families declared by a literal name, once each, with a literal help', () => {
		assert.match([
			{ name: 'node_load1', type: 'gauge', help: '1m load average.' },
			{ name: 'node_things_total', type: 'counter', help: 'Things, it\'s said.' },
			{ name: 'node_built', type: 'gauge', help: null },
		], source.declared(COLLECTOR));
	});
});

describe('docs_gen.source.reasons', () => {
	it('gives the literal reasons and what services says of each service asked', () => {
		assert.match([
			'no such thing',
			'dnsmasq is disabled', 'dnsmasq is not installed',
			'odhcpd is disabled', 'odhcpd is not installed',
		], source.reasons(COLLECTOR, [ 'disabled', 'not installed' ]));
	});

	it('tells a collector that can have nothing to observe', () => {
		assert.match([ true, false ], [ source.has_none(COLLECTOR), source.has_none("out.gauge('x', 'y');") ]);
	});
});

describe('docs_gen.source.error_codes', () => {
	it('groups the codes under the comment above them, and drops a heading with none', () => {
		let text = join('\n', [
			'// What this file is.',
			'',
			'// Sources',
			"export const SOURCE_A = 'SOURCE_A';",
			"export const SOURCE_B = 'SOURCE_B';",
			'',
			'// Configuration',
			"export const CONFIG_X = 'CONFIG_X';",
		]);

		assert.match([
			{ group: 'Sources', codes: [ 'SOURCE_A', 'SOURCE_B' ] },
			{ group: 'Configuration', codes: [ 'CONFIG_X' ] },
		], source.error_codes(text));
	});

	it('reads every code of errors.uc', () => {
		let groups = source.error_codes(readfile('src/prometheus_exporter/errors.uc'));
		let codes = [];

		for (let g in groups)
			push(codes, ...g.codes);

		assert.match(true, 'COMMAND_TIMEOUT' in codes);
		assert.match(true, 'CONFIG_INVALID' in codes);
	});

	it('tells where a code is raised, as a whole word', () => {
		assert.match([ true, false, true ], [
			source.raises('return Result.err(errors.SOURCE_INVALID, x);', 'SOURCE_INVALID'),
			source.raises('errors.SOURCE_INVALID_MORE', 'SOURCE_INVALID'),
			source.raises('x = errors.SOURCE_INVALID', 'SOURCE_INVALID'),
		]);
	});
});

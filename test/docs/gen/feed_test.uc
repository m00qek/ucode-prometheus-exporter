'use strict';

// What make feed-inventory reads of the feed exporters' sources, on lines as
// their collectors write them.

import { describe, it, assert } from 'utest';
import * as feed from 'docs_gen.feed';

describe('docs_gen.feed.lua_families', () => {
	it('takes a family of each metric() call, with its type', () => {
		assert.match([ { name: 'node_load1', type: 'gauge' }, { name: 'nft_counter_bytes', type: 'counter' } ],
			feed.lua_families('  metric("node_load1", "gauge", nil, x)\n  local m = metric(\'nft_counter_bytes\', \'counter\')\n'));
	});

	it('writes a computed part <>, and resolves a local string constant', () => {
		assert.match([ { name: 'node_memory_<>_bytes', type: 'gauge' }, { name: 'realtek_poe_switch_info', type: 'gauge' }, { name: '<>', type: 'untyped' } ],
			feed.lua_families('local METRIC_NAMESPACE = "realtek_poe"\n' +
				'metric("node_memory_"..name:gsub("[):]", ""):gsub("[(]", "_").."_bytes", "gauge")\n' +
				'metric(METRIC_NAMESPACE .. "_switch_info", "gauge", { mcu=mcu }, 1)\n' +
				'm = metric(fqname, "untyped")\n'));
	});

	it('leaves out the definition of metric() and names that end in metric', () => {
		assert.match([], feed.lua_families('function metric(name, mtype, labels, value)\nget_metric("all")\n'));
	});
});

describe('docs_gen.feed.ucode_families', () => {
	it('takes a family of each gauge() and counter() call, a template\'s ${...} <>', () => {
		assert.match([ { name: 'wireguard_latest_handshake_seconds', type: 'gauge' }, { name: 'snmp6_<>', type: 'counter' } ],
			feed.ucode_families('let m = gauge ("wireguard_latest_handshake_seconds");\ncounter(`snmp6_${x[0]}`, null, skipdecl)(labels, x[1]);\n' +
				'function counter(name, help, skipdecl) {\n'));
	});
});

describe('docs_gen.feed.keys_of', () => {
	it('takes the keys of tables and objects, shorthand ones, and those set on labels', () => {
		assert.match([ 'device', 'ifname', 'mac', 'mode', 'radio', 'zone' ],
			feed.keys_of('m({ radio, ifname }, 1); m({ device: d }); labels.mode = x; labels["mac"] = y; t = {zone = i}', /\/\/[^\n]*/g));
	});

	it('leaves out the line comments', () => {
		assert.match([ 'a', 'b' ], feed.keys_of('{\n  a = 1, -- note, c = 2\n  b = 3,\n}', /--[^\n]*/g));
	});
});

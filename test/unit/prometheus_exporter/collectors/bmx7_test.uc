'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, jail_of } from 'context';
import * as fixtures from 'lib.fixtures';
import * as bmx7 from 'prometheus_exporter.collectors.bmx7';

// Neither caju device runs bmx7. A node with three links and two tunIn networks,
// as bmx7's JSON plugin writes /var/run/bmx7/json/{status,links,parameters}:
// fields as src/bmx.c (bmx_status) and src/link.c (link_status) declare them,
// rates and memory as umetric_to_human() (src/metrics.c) spells them ("300M",
// "56789K", "98765"), options as the plugin nests them (OPTIONS, INSTANCES,
// CHILD_INSTANCES). Identifiers and addresses are made up.
const DIR = bmx7.DIR;
const NODE = fixtures.files('synthetic', [ `${DIR}/status`, `${DIR}/links`, `${DIR}/parameters` ]);

function run(files, cb) {
	with_collector(bmx7, { fs: { data: files } }, cb);
}

describe('collectors.bmx7', () => {
	it('exports the node, its links and its tunnels', () => {
		run(NODE, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP bmx7_info The bmx7 node.',
				'# TYPE bmx7_info gauge',
				'bmx7_info{id="3A7F92C1",name="node-a",address="fd70:3a7f:92c1:4e0b:1d5a:77c2:e3f4:a5b6",revision="7a0c2bb"} 1',
				'# HELP bmx7_cpu_usage_ratio CPU usage of bmx7, from 0 to 1.',
				'# TYPE bmx7_cpu_usage_ratio gauge',
				'bmx7_cpu_usage_ratio 0.004',
				'# HELP bmx7_memory_usage_bytes Memory used by bmx7, in bytes.',
				'# TYPE bmx7_memory_usage_bytes gauge',
				'bmx7_memory_usage_bytes 2932000',
				'# HELP bmx7_link_receive_rate_bits_per_second The receive rate of a link to a neighbour, in bits per second.',
				'# TYPE bmx7_link_receive_rate_bits_per_second gauge',
				'bmx7_link_receive_rate_bits_per_second{source="3A7F92C1",target="8B1D4E3B",name="node-b",device="wlan0-mesh"} 300000000',
				'bmx7_link_receive_rate_bits_per_second{source="3A7F92C1",target="C47E0A92",name="node-c",device="br-lan"} 1000000000',
				'bmx7_link_receive_rate_bits_per_second{source="3A7F92C1",target="E015F3A8",name="node-d",device="wlan0-mesh"} 56789000',
				'# HELP bmx7_link_transmit_rate_bits_per_second The transmit rate of a link to a neighbour, in bits per second.',
				'# TYPE bmx7_link_transmit_rate_bits_per_second gauge',
				'bmx7_link_transmit_rate_bits_per_second{source="3A7F92C1",target="8B1D4E3B",name="node-b",device="wlan0-mesh"} 270000000',
				'bmx7_link_transmit_rate_bits_per_second{source="3A7F92C1",target="C47E0A92",name="node-c",device="br-lan"} 1000000000',
				'bmx7_link_transmit_rate_bits_per_second{source="3A7F92C1",target="E015F3A8",name="node-d",device="wlan0-mesh"} 98765',
				'# HELP bmx7_tun_in_info A network this node announces with tunIn.',
				'# TYPE bmx7_tun_in_info gauge',
				'bmx7_tun_in_info{name="inet4",network="10.22.1.0/24"} 1',
				'bmx7_tun_in_info{name="inet6",network="2001:db8:3a7f::/48"} 1',
				'# HELP bmx7_plugin_info A plugin bmx7 has loaded.',
				'# TYPE bmx7_plugin_info gauge',
				'bmx7_plugin_info{name="bmx7_config.so"} 1',
				'bmx7_plugin_info{name="bmx7_json.so"} 1',
				'bmx7_plugin_info{name="bmx7_sms.so"} 1',
				'bmx7_plugin_info{name="bmx7_tun.so"} 1',
			], r.lines);
		});
	});

	it('exports the node alone when it has no links and no options', () => {
		run({ ...NODE, [`${DIR}/links`]: '{"links":[]}', [`${DIR}/parameters`]: '{"OPTIONS":[]}' }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'bmx7_info', 'bmx7_cpu_usage_ratio', 'bmx7_memory_usage_bytes' ],
				map(filter(r.families, (f) => length(f.samples)), (f) => f.name));
		});
	});

	it('fails with SOURCE_UNREADABLE when bmx7 is not running', () => {
		run({ [`${DIR}/status`]: null }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/var/run/bmx7/json/status' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('keeps the node status when the links file is missing', () => {
		run({ ...NODE, [`${DIR}/links`]: null }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE' }, { ok: r.result.ok, error: r.result.error });
			assert.match(contains([ 'bmx7_memory_usage_bytes 2932000' ]), r.lines);
		});
	});

	it('keeps the links when the parameters are not JSON', () => {
		run({ ...NODE, [`${DIR}/parameters`]: '{"OPTIONS":[' }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
			assert.match(true, index(r.text, 'bmx7_link_transmit_rate_bits_per_second{') >= 0);
			assert.match(false, index(r.text, 'bmx7_plugin') >= 0);
		});
	});

	it('fails with SOURCE_INVALID for a status file without its status', () => {
		run({ [`${DIR}/status`]: '{"links":[]}' }, (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: '/var/run/bmx7/json/status: no status' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('reads a rate without a suffix, or an unroutable one, as it is', () => {
		assert.match('98765', bmx7.interpret_suffix('98765'));
		assert.match('-1', bmx7.interpret_suffix('-1'));
		assert.match(null, bmx7.interpret_suffix(null));
	});

	prop('scales a K, M or G rate by 10^3, 10^6 or 10^9',
		gen.tuple(gen.int(0, 99999), gen.elements([ 'K', 1000 ], [ 'M', 1000000 ], [ 'G', 1000000000 ])), (t) => {
			assert.match(t[0] * t[1][1], bmx7.interpret_suffix(`${t[0]}${t[1][0]}`));
		});

	it('reads the CPU usage, a percentage, as a ratio', () => {
		assert.match([ 0.004, 1.0, null, null ], map([ '0.4', 100, '--', null ], bmx7.ratio));
	});

	prop('gives any percentage as a ratio', gen.int(0, 10000), (tenths) => {
		let r = bmx7.ratio(sprintf('%d.%d', tenths / 10, tenths % 10));
		let delta = r * 1000 - tenths;

		assert.match(true, delta > -1e-6 && delta < 1e-6, `${tenths} -> ${r}`);
	});
});

describe('bmx7 in the jail', () => {
	it('gets its JSON status directory', () => {
		assert.match([ '/var/run/bmx7/json' ], jail_of(bmx7, {}).mounts);
	});
});

'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as rpc_describe from 'prometheus.exporter.rpc.describe';
import * as config from 'prometheus.exporter.config';
import * as jail from 'prometheus.exporter.jail';
import { NAME, PACKAGE, collector, LOADAVG, NFT, with_sys, entry } from 'lib.rpc';

describe('rpc.describe.option_spec', () => {
	it('takes a bare default, typed by it, titled by its name, with no help or datatype', () => {
		assert.match([
			{ name: 'stations', core: false, title: 'stations', type: 'bool', default: true, help: null, datatype: null },
			{ name: 'retries', core: false, title: 'retries', type: 'int', default: 3, help: null, datatype: null },
			{ name: 'directory', core: false, title: 'directory', type: 'string', default: '/var/prometheus', help: null, datatype: null },
		], [
			rpc_describe.option_spec('stations', true),
			rpc_describe.option_spec('retries', 3),
			rpc_describe.option_spec('directory', '/var/prometheus'),
		]);
	});

	it('takes { default, title, help, datatype }, and leaves out an empty help or datatype', () => {
		assert.match([
			{ name: 'directory', core: false, title: 'Metrics directory', type: 'string', default: '/var/prometheus', help: 'Where the .prom files are.', datatype: 'directory' },
			{ name: 'fields', core: false, title: 'fields', type: 'string', default: '^pg', help: null, datatype: 'regex' },
			{ name: 'stations', core: false, title: 'stations', type: 'bool', default: false, help: null, datatype: null },
		], [
			rpc_describe.option_spec('directory', { default: '/var/prometheus', title: 'Metrics directory', help: 'Where the .prom files are.', datatype: 'directory' }),
			rpc_describe.option_spec('fields', { default: '^pg', title: '', help: '', datatype: 'regex' }),
			rpc_describe.option_spec('stations', { default: false }),
		]);
	});

	prop('gives the same spec for a bare default and the object that holds only it',
		gen.oneof(gen.bool(), gen.int(-1000, 1000), gen.string({ min_len: 0, max_len: 12 })), (v) => {
			assert.match(rpc_describe.option_spec('o', { default: v }), rpc_describe.option_spec('o', v));
			assert.match({ name: 'o', core: false, title: 'o', type: type(v), default: v, help: null, datatype: null }, rpc_describe.option_spec('o', v));
		});
});

describe('rpc.describe.options_of and title_of', () => {
	it('lists the options in the order the collector declares them, in either shape', () => {
		let meta = { options: { stations: true, directory: { default: '/x', help: 'Dir.', datatype: 'directory' }, retries: 3 } };

		assert.match([ 'stations', 'directory', 'retries' ], map(rpc_describe.options_of(meta), (o) => o.name));
		assert.match([ null, 'directory', null ], map(rpc_describe.options_of(meta), (o) => o.datatype));
		assert.match([], rpc_describe.options_of({}));
	});

	it('gives meta.title, or the name without one', () => {
		assert.match([ 'Wi-Fi', 'wifi', 'wifi' ], [
			rpc_describe.title_of({ name: 'wifi', title: 'Wi-Fi' }),
			rpc_describe.title_of({ name: 'wifi' }),
			rpc_describe.title_of({ name: 'wifi', title: '' }),
		]);
	});
});

describe('rpc.describe.collectors', () => {
	it('describes each installed collector as the exporter sees it', () => {
		with_sys({ wifi: { '.type': 'collector', stations: '0' } }, {}, (sys) => {
			assert.match({
				name: 'wifi', id: 'wifi', title: 'wifi', help: 'The wifi test collector.',
				enabled: true,
				package: `${PACKAGE}-wifi`, base: false,
				options: [ {
					name: 'stations', core: false, title: 'stations', type: 'bool', default: true, help: 'The stations option.', datatype: null,
					value: false, set: true, error: null,
				} ],
				needs: [ 'ubus' ], configs: [], commands: [],
				jail: {
					paths: [], owned: [], commands: {}, mounts: [], problems: [], missing: [],
					ubus: { 'network.wireless': [ 'status' ] }, capabilities: [], groups: [], proc_files: [],
				},
				error: null,
			}, entry(sys, 'wifi'));
		});
	});

	it('lists every installed collector, in order, with what the loader skipped', () => {
		with_sys({}, { skipped: [ 'skipping collector: COLLECTOR_INVALID (odd: exports no meta)' ] }, (sys) => {
			let res = rpc_describe.collectors(sys);

			assert.match([ 'loadavg', 'wifi', 'textfile', 'wireguard', 'nft-counters', 'sampler' ], map(res.collectors, (c) => c.name));
			assert.match([ 'skipping collector: COLLECTOR_INVALID (odd: exports no meta)' ], res.skipped);
		});
	});

	it('says which package installed a collector: the base one, its own, or none', () => {
		with_sys({}, {}, (sys) => {
			assert.match([ PACKAGE, true ], [ entry(sys, 'loadavg').package, entry(sys, 'loadavg').base ]);
			assert.match([ `${PACKAGE}-textfile`, false ], [ entry(sys, 'textfile').package, entry(sys, 'textfile').base ]);
			assert.match([ null, null ], [ entry(sys, 'sampler').package, entry(sys, 'sampler').base ]);
		});
	});

	it('gives unset options their defaults, and set ones the typed value', () => {
		with_sys({ sampler: { '.type': 'collector', retries: '7' } }, {}, (sys) => {
			assert.match([
				{ name: 'retries', value: 7, set: true },
				{ name: 'verbose', value: false, set: false },
				{ name: 'label', value: 'x', set: false },
			], map(entry(sys, 'sampler').options, (o) => ({ name: o.name, value: o.value, set: o.set })));
		});
	});

	it('takes the enabled switch from the config', () => {
		with_sys({ loadavg: { '.type': 'collector', enabled: '0' }, wifi: { '.type': 'collector', enabled: 'yes' } }, {}, (sys) => {
			assert.match([ false, true, true ], [ entry(sys, 'loadavg').enabled, entry(sys, 'wifi').enabled, entry(sys, 'textfile').enabled ]);
		});
	});

	it('reports an invalid value as it stands, with the exporter\'s reason', () => {
		with_sys({ sampler: { '.type': 'collector', retries: 'many' } }, {}, (sys) => {
			let e = entry(sys, 'sampler');

			assert.match({ value: 'many', set: true, error: 'expected an integer, got "many"' },
				{ value: e.options[0].value, set: e.options[0].set, error: e.options[0].error });
			assert.match('CONFIG_INVALID (retries: expected an integer, got "many")', e.error);
		});
	});

	it('ignores a section of another type under the collector\'s name, as the exporter does', () => {
		with_sys({ wifi: { '.type': 'interface', stations: 'maybe' } }, {}, (sys) => {
			assert.match([ true, false, null ], [ entry(sys, 'wifi').options[0].value, entry(sys, 'wifi').options[0].set, entry(sys, 'wifi').error ]);
		});
	});

	it('gives the configs, commands and what the jail mounts', () => {
		with_sys({ textfile: { '.type': 'collector', directory: '/srv/prom' } }, { files: [ '/usr/sbin/nft' ] }, (sys) => {
			assert.match([ [ 'network' ], [ '/etc/config/network' ] ], [ entry(sys, 'wireguard').configs, entry(sys, 'wireguard').jail.mounts ]);
			assert.match({ paths: [], owned: [], commands: { nft: '/usr/sbin/nft' }, mounts: [ '/bin/sh', '/usr/sbin/nft' ], problems: [], missing: [],
				ubus: {}, capabilities: [], groups: [], proc_files: [] }, entry(sys, 'nft-counters').jail);
			assert.match({ wireguard: [ 'status' ] }, entry(sys, 'wireguard').jail.ubus);
			assert.match([ 'nft' ], entry(sys, 'nft-counters').commands);
			assert.match({ paths: [ '/srv/prom' ], missing: [ '/srv/prom' ] },
				{ paths: entry(sys, 'textfile').jail.paths, missing: entry(sys, 'textfile').jail.missing });
		});
	});

	it('names a command that is missing among the jail\'s problems', () => {
		with_sys({}, {}, (sys) => {
			assert.match({ nft: null }, entry(sys, 'nft-counters').jail.commands);
			assert.match([ `command nft is not on ${jail.PATH}` ], entry(sys, 'nft-counters').jail.problems);
		});
	});

	it('gives a collector that runs programs the core\'s timeout, after its own options', () => {
		let radio = collector('ubnt-manager', { needs: [ 'exec' ], commands: [ 'ubnt-manager' ], timeout: 12, options: { verbose: false } });

		with_sys({ main: { '.type': NAME, exec_timeout: '8' } }, { collectors: [ NFT, radio, LOADAVG ] }, (sys) => {
			assert.match([
				{ name: 'timeout', core: true, title: 'Program timeout', type: 'int', default: 8, default_from: 'exec_timeout', help: config.TIMEOUT.help,
				  datatype: 'range(1,30)', value: 8, set: false, error: null },
			], entry(sys, 'nft-counters').options);
			assert.match([ [ 'verbose', false ], [ 'timeout', true ] ], map(entry(sys, 'ubnt-manager').options, (o) => [ o.name, o.core ]));
			let t = entry(sys, 'ubnt-manager').options[1];
			assert.match({ default: 12, default_from: 'meta.timeout', value: 12, set: false },
				{ default: t.default, default_from: t.default_from, value: t.value, set: t.set });
			assert.match([], entry(sys, 'loadavg').options);
		});
	});

	it('gives a timeout set in the section, or what is wrong with it', () => {
		with_sys({ nft_counters: { '.type': 'collector', timeout: '3' }, ubnt_manager: { '.type': 'collector', timeout: '99' } }, {
			collectors: [ NFT, collector('ubnt-manager', { needs: [ 'exec' ], commands: [ 'ubnt-manager' ], timeout: 12 }) ],
		}, (sys) => {
			let nft = entry(sys, 'nft-counters').options[0];
			let radio = entry(sys, 'ubnt-manager');

			assert.match({ value: 3, set: true, error: null, default: 5 }, { value: nft.value, set: nft.set, error: nft.error, default: nft.default });
			assert.match({ value: '99', set: true, error: 'expected an integer from 1 to 30, got 99' },
				{ value: radio.options[0].value, set: radio.options[0].set, error: radio.options[0].error });
			assert.match('CONFIG_INVALID (timeout: expected an integer from 1 to 30, got 99)', radio.error);
		});
	});

	it('takes the title of a collector that declares one', () => {
		let titled = collector('dawn', { needs: [], title: 'DAWN' });

		with_sys({}, { collectors: [ titled ] }, (sys) => {
			assert.match('DAWN', entry(sys, 'dawn').title);
		});
	});
});

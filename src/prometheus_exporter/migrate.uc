'use strict';

// Takes over the settings of the feed's exporters this one replaces, once: what
// /etc/config/prometheus-node-exporter-ucode or, without it,
// /etc/config/prometheus-node-exporter-lua configures goes into
// /etc/config/prometheus-exporter. The package's uci-defaults script runs it
// when the package is installed (or an image that has it first boots).
//
// It changes this exporter's config only while that is as the package ships
// it: on the first install, not over what someone has set since. The old
// configs are left as they are. apk keeps a feed exporter's config when it is
// removed only if it was changed, so what is there to import is what someone
// set.
//
// From the main section: listen_interface, listen_port, http_keepalive, cert,
// key and omit_zero_values, each only if this exporter takes its value. A port
// that is the old exporter's default (9101 for the ucode one) is left at this
// one's, 9100: only a port someone chose is kept. From the ucode exporter, each
// named `config collector` section too (wifi's stations, say), option for
// option.
//
// uci: a uci cursor that can write and commit.

import * as config from 'prometheus_exporter.config';

// The feed's exporters, the ucode one first: its config, the port it listens
// on by default, and whether it has `config collector` sections.
export const SOURCES = [
	{ name: 'prometheus-node-exporter-ucode', port: '9101', collectors: true },
	{ name: 'prometheus-node-exporter-lua', port: '9100', collectors: false },
];

// The collectors the feed's exporters had that this one has not, by module:
// a section of one is not taken over, and the log says what does its job.
export const GONE = {
	wifi_stations: 'wifi writes the stations, with its option stations, on by default',
};

// The main section's options taken over, as this exporter declares them.
export const OPTIONS = [ 'listen_interface', 'listen_port', 'http_keepalive', 'cert', 'key', 'omit_zero_values' ];

// The main section as the package ships it (files/etc/config/prometheus-exporter).
export const SHIPPED = {
	enabled: '1', listen_interface: 'loopback', listen_port: '9100', http_keepalive: '70', omit_zero_values: '0', exec_timeout: '5',
	scrape_timeout: '10', collector_budget: '5', max_samples: '20000', compress: '1',
};

const SPECS = { ...config.SERVICE_OPTIONS, ...config.MAIN_OPTIONS };

// A section's options, without uci's own .name, .type, .anonymous and .index.
function options_of(s) {
	let out = {};

	for (let k, v in s)
		if (substr(k, 0, 1) != '.')
			out[k] = v;

	return out;
}

// Whether two sections' options are the same, in any order.
function same(a, b) {
	if (length(a) != length(b))
		return false;

	for (let k, v in a)
		if (sprintf('%J', v) != sprintf('%J', b[k]))
			return false;

	return true;
}

// Every section of config `name`, or null when there is no such config.
function sections(uci, name) {
	let all = [];

	if (!uci.load(name))
		return null;

	uci.foreach(name, null, (s) => { push(all, s); });

	return all;
}

// Whether this exporter's config is as the package ships it: its main section
// alone, with the shipped values. A missing config is not: there is nothing to
// write into.
export function pristine(uci) {
	let all = sections(uci, config.NAME);

	if (all == null || length(all) != 1)
		return false;

	let s = all[0];

	return s['.name'] == 'main' && s['.type'] == config.NAME && !s['.anonymous'] && same(options_of(s), SHIPPED);
};

// What to import from the main section `main` of `source`: { set: { option:
// value }, skipped: [ why ] }. A value this exporter would refuse is skipped,
// saying why; one it already ships, and the old exporter's default port, are
// left out.
export function main_options(source, main) {
	let set = {};
	let skipped = [];

	for (let name in OPTIONS) {
		let value = main?.[name];

		if (value == null || (name == 'listen_port' && value === source.port) || value === SHIPPED[name])
			continue;

		let res = config.convert(name, value, SPECS[name]);

		if (res.ok && name == 'listen_interface' && value == '')
			res = { ok: false, details: 'listen_interface: expected an interface name or *, got ""' };

		if (res.ok)
			set[name] = value;
		else
			push(skipped, `${source.name}: option ${res.details}; left at the default`);
	}

	return { set, skipped };
};

// { from, main: { option: value }, collectors: { id: { option: value } }, skipped }
// of what the first source that has a config would bring, or null when none has.
export function plan(uci) {
	for (let source in SOURCES) {
		let all = sections(uci, source.name);

		if (all == null)
			continue;

		let main = filter(all, (s) => s['.name'] == 'main' && s['.type'] == source.name)[0];
		let res = main_options(source, main ? options_of(main) : {});
		let collectors = {};

		for (let s in (source.collectors ? all : [])) {
			if (s['.type'] != 'collector' || s['.anonymous'])
				continue;

			if (GONE[s['.name']])
				push(res.skipped, `${source.name}: collector ${s['.name']} is not this exporter's: ${GONE[s['.name']]}`);
			else
				collectors[s['.name']] = options_of(s);
		}

		return { from: source.name, main: res.set, collectors, skipped: res.skipped };
	}

	return null;
};

// Writes plan `p` into this exporter's config, and commits it.
export function apply(uci, p) {
	for (let name, value in p.main)
		uci.set(config.NAME, 'main', name, value);

	for (let id, options in p.collectors) {
		uci.set(config.NAME, id, 'collector');
		for (let name, value in options)
			uci.set(config.NAME, id, name, value);
	}

	uci.commit(config.NAME);
};

function describe(p) {
	let parts = map(sort(keys(p.main)), (k) => `${k}=${p.main[k]}`);

	for (let id in sort(keys(p.collectors)))
		push(parts, `collector ${id}`);

	return length(parts) ? join(', ', parts) : 'nothing it changed from the defaults';
}

// Imports what a feed exporter's config holds, if this exporter's config is as
// shipped. Returns { imported, lines }: whether it wrote anything, and what to
// log.
export function run(uci) {
	let p = plan(uci);

	if (p == null)
		return { imported: false, lines: [] };

	if (!pristine(uci))
		return { imported: false, lines: [ `/etc/config/${config.NAME} is not as the package ships it: nothing imported from /etc/config/${p.from}` ] };

	let lines = [ ...p.skipped ];
	let imported = length(p.main) > 0 || length(p.collectors) > 0;

	if (imported)
		apply(uci, p);

	push(lines, `imported from /etc/config/${p.from}: ${describe(p)}`);

	return { imported, lines };
};

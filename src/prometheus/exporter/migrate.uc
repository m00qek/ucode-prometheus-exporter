/**
 * Takes over the settings of the feed's exporters this one replaces, once.
 *
 * @module prometheus_exporter_migrate
 */

'use strict';

import * as config from 'prometheus.exporter.config';

/**
 * A feed exporter a config is taken over from (SOURCES).
 *
 * @typedef {{ name: string, port: string, collectors: boolean }} MigrationSource
 */

/**
 * What plan() would bring; values as uci holds them.
 *
 * @typedef {{
 *   from: string,
 *   main: Object<string, string>,
 *   collectors: Object<string, Object<string, (string|string[])>>,
 *   skipped: string[]
 * }} MigrationPlan
 */

/** The feed's exporters, the ucode one first. */
export const SOURCES = [
	{ name: 'prometheus-node-exporter-ucode', port: '9101', collectors: true },
	{ name: 'prometheus-node-exporter-lua', port: '9100', collectors: false },
];

/** The collectors the feed's exporters had that this one has not, by module. */
export const GONE = {
	wifi_stations: 'wifi writes the stations, with its option stations, on by default',
};

/**
 * The options of the feed's ucode exporter's collector sections, by collector, as this exporter's collectors declare them:
 * what one not installed when they are imported is checked against.
 */
export const FEED_OPTIONS = {
	wifi: { stations: { default: true } },
};

/** The main section's options taken over, as this exporter declares them. */
export const OPTIONS = [ 'listen_interface', 'listen_port', 'http_keepalive', 'cert', 'key', 'omit_zero_values' ];

/** The main section as the package ships it (files/etc/config/prometheus-exporter). */
export const SHIPPED = {
	enabled: '1', listen_interface: 'loopback', listen_port: '9100', http_keepalive: '70', omit_zero_values: '0', exec_timeout: '5',
	scrape_timeout: '10', collector_budget: '5', max_samples: '20000', max_scrape_samples: '200000', compress: '1',
};

const SPECS = { ...config.SERVICE_OPTIONS, ...config.MAIN_OPTIONS };

function options_of(s) {
	let out = {};

	for (let k, v in s)
		if (substr(k, 0, 1) != '.')
			out[k] = v;

	return out;
}

function same(a, b) {
	if (length(a) != length(b))
		return false;

	for (let k, v in a)
		if (sprintf('%J', v) != sprintf('%J', b[k]))
			return false;

	return true;
}

function sections(uci, name) {
	let all = [];

	if (!uci.load(name))
		return null;

	uci.foreach(name, null, (s) => { push(all, s); });

	return all;
}

/**
 * Whether this exporter's config is as the package ships it.
 *
 * @param {UciCursor} uci
 * @returns {boolean}
 */
export function pristine(uci) {
	let all = sections(uci, config.NAME);

	if (all == null || length(all) != 1)
		return false;

	let s = all[0];

	return s['.name'] == 'main' && s['.type'] == config.NAME && !s['.anonymous'] && same(options_of(s), SHIPPED);
};

/**
 * What to import from the main section `main` of `source`, and what is skipped, and why.
 *
 * @param {MigrationSource} source
 * @param {?Object} main
 * @returns {{ set: Object<string, string>, skipped: string[] }}
 */
export function main_options(source, main) {
	let set = {};
	let skipped = [];

	for (let name in OPTIONS) {
		let value = main?.[name];

		if (value == null || (name == 'listen_port' && value === source.port) || value === SHIPPED[name])
			continue;

		let res = config.convert(name, value, SPECS[name]);

		if (res.ok && name == 'listen_interface' && value == '')
			res = config.invalid(name, config.problem('INTERFACE'), value, SPECS[name]);

		if (res.ok)
			set[name] = value;
		else
			push(skipped, `${source.name}: option ${res.details}; left at the default`);
	}

	return { set, skipped };
};

function specs_of(id, meta) {
	if (meta != null)
		return { ...(meta.options ?? {}), ...config.core(meta, config.EXEC_TIMEOUT, null, null) };

	return { ...(FEED_OPTIONS[id] ?? {}), ...config.core(null, null, null, null) };
}

/**
 * What to import of collector `id`'s section, its options `options`, and what is skipped, and why.
 *
 * @param {MigrationSource} source
 * @param {string} id
 * @param {Object<string, (string|string[])>} options
 * @param {?Meta} meta
 * @returns {{ set: Object<string, (string|string[])>, skipped: string[] }}
 */
export function collector_options(source, id, options, meta) {
	let specs = specs_of(id, meta);
	let set = {};
	let skipped = [];

	for (let name, value in options) {
		let spec = specs[name];

		if (spec == null) {
			push(skipped, (meta != null)
				? `${source.name}: collector ${id} has no option ${name}; left out`
				: `${source.name}: collector ${id} is not installed, and ${name} is not an option it is known to have; left out`);
			continue;
		}

		let res = config.convert(name, value, spec);

		if (res.ok)
			set[name] = value;
		else
			push(skipped, `${source.name}: collector ${id}, option ${res.details}; left at its default`);
	}

	return { set, skipped };
};

/**
 * What the first source that has a config would bring, or null when none has.
 *
 * @param {UciCursor} uci
 * @param {?(Object<string, Meta>|function(): Object<string, Meta>)} metas
 * @returns {?MigrationPlan}
 */
export function plan(uci, metas) {
	for (let source in SOURCES) {
		let all = sections(uci, source.name);

		if (all == null)
			continue;

		let main = filter(all, (s) => s['.name'] == 'main' && s['.type'] == source.name)[0];
		let res = main_options(source, main ? options_of(main) : {});
		let collectors = {};
		let installed = null;

		for (let s in (source.collectors ? all : [])) {
			if (s['.type'] != 'collector' || s['.anonymous'])
				continue;

			let id = s['.name'];

			if (GONE[id]) {
				push(res.skipped, `${source.name}: collector ${id} is not this exporter's: ${GONE[id]}`);
				continue;
			}

			installed ??= ((type(metas) == 'function') ? metas() : metas) ?? {};

			let options = options_of(s);
			let taken = collector_options(source, id, options, installed[id]);

			push(res.skipped, ...taken.skipped);
			if (length(taken.set) || !length(options))
				collectors[id] = taken.set;
		}

		return { from: source.name, main: res.set, collectors, skipped: res.skipped };
	}

	return null;
};

/**
 * Writes plan `p` into this exporter's config, and commits it.
 *
 * @param {UciCursor} uci
 * @param {MigrationPlan} p
 */
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

/**
 * Imports what a feed exporter's config holds, if this exporter's config is as shipped.
 *
 * @param {UciCursor} uci
 * @param {?(Object<string, Meta>|function(): Object<string, Meta>)} metas
 * @returns {{ imported: boolean, lines: string[] }}
 */
export function run(uci, metas) {
	let p = plan(uci, metas);

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

/**
 * Moves the main section's auth_password, where 0.2.0 kept it, into config.AUTH_CONFIG.
 *
 * @param {UciCursor} uci
 * @returns {{ moved: boolean, lines: string[] }}
 */
export function move_hash(uci) {
	let hash = uci.get(config.NAME, 'main', 'auth_password');

	if (hash == null)
		return { moved: false, lines: [] };

	let from = `/etc/config/${config.NAME}`, to = `/etc/config/${config.AUTH_CONFIG}`;

	if (!uci.load(config.AUTH_CONFIG))
		return { moved: false, lines: [ `${to} is not there: auth_password left in ${from}, where it is not read; set it again` ] };

	let saved = uci.get(config.AUTH_CONFIG, config.AUTH_SECTION, 'auth_password');
	let keep = saved != null && saved != '';

	if (!keep) {
		uci.set(config.AUTH_CONFIG, config.AUTH_SECTION, config.AUTH_TYPE);
		uci.set(config.AUTH_CONFIG, config.AUTH_SECTION, 'auth_password', hash);
		uci.commit(config.AUTH_CONFIG);
	}

	uci.delete(config.NAME, 'main', 'auth_password');
	uci.commit(config.NAME);

	return { moved: true, lines: [ keep
		? `auth_password removed from ${from}: ${to} has one already, which is kept`
		: `auth_password moved from ${from} to ${to}` ] };
};

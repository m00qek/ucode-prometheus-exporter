'use strict';

// Options from /etc/config/prometheus-node-exporter-ucode, typed by their
// defaults: a boolean default takes uci's boolean spellings, an integer default
// an integer, a string default any single value. Unset options take the default;
// options nobody declared are ignored, so an older config never breaks a scrape.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const PACKAGE = 'prometheus-node-exporter-ucode';

// The main section's options the exporter itself reads; the listen options are
// the init script's.
export const MAIN_OPTIONS = { omit_zero_values: false };

const TRUE = [ '1', 'yes', 'on', 'true', 'enabled' ];
const FALSE = [ '0', 'no', 'off', 'false', 'disabled' ];

function invalid(name, expected, value) {
	return Result.err(errors.CONFIG_INVALID, `${name}: expected ${expected}, got ${sprintf('%J', value)}`);
}

// A uci value as the type of `fallback`.
export function convert(name, value, fallback) {
	switch (type(fallback)) {
	case 'bool':
		if (value in TRUE)
			return Result.ok(true);
		if (value in FALSE)
			return Result.ok(false);
		return invalid(name, 'a boolean', value);

	case 'int':
		if (type(value) == 'string' && match(value, /^-?[0-9]+$/))
			return Result.ok(int(value));
		return invalid(name, 'an integer', value);

	case 'string':
		if (type(value) == 'string')
			return Result.ok(value);
		return invalid(name, 'a single value', value);
	}

	die(`option ${name}: unsupported default ${sprintf('%J', fallback)}`);
};

// The options of section `name`, of section type `stype`, as declared by `defaults`.
export function section(uci, name, stype, defaults) {
	let s = uci.get_all(PACKAGE, name);
	let options = {};

	if (type(s) != 'object' || s['.type'] != stype)
		s = {};

	for (let key, fallback in defaults) {
		if (!(key in s)) {
			options[key] = fallback;
			continue;
		}

		let res = convert(key, s[key], fallback);
		if (!res.ok)
			return res;
		options[key] = res.data;
	}

	return Result.ok(options);
};

export function main(uci) {
	return section(uci, 'main', PACKAGE, MAIN_OPTIONS);
};

// `config collector '<id>'`: the collector's module name, as a uci section name
// cannot hold the '-' of ltq-dsl.
//
// Every collector also has `enabled`, the core's: it is checked here like the
// collector's own options, and left out of what the collector gets.
export function collector(uci, id, defaults) {
	let res = section(uci, id, 'collector', { enabled: true, ...defaults });

	if (res.ok)
		delete res.data.enabled;

	return res;
};

// Whether a collector is enabled: true unless its section says otherwise. A
// value that is not a boolean counts as enabled, so the collector runs and
// fails with CONFIG_INVALID, saying what is wrong.
export function enabled(uci, id) {
	let res = section(uci, id, 'collector', { enabled: true });

	return !res.ok || res.data.enabled;
};

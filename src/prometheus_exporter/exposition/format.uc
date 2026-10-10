/**
 * The Prometheus text exposition format 0.0.4, as it is written.
 *
 * @module prometheus_exporter_exposition_format
 */

'use strict';

/**
 * The ordered set of families: `list` in the order added, `by_name` by their names.
 *
 * @typedef {{ list: (Family|RecordedFamily)[], by_name: Object<string, (Family|RecordedFamily)> }} FamilySet
 */

/** The family types of the format, as a TYPE line names them. */
export const TYPES = [ 'counter', 'gauge', 'histogram', 'summary', 'untyped' ];

/** A valid metric name. */
export const METRIC_NAME = /^[a-zA-Z_:][a-zA-Z0-9_:]*$/;
const LABEL_NAME = /^[a-zA-Z_][a-zA-Z0-9_]*$/;
const NUMBER = /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/;
const HEX = /^0[xX][0-9a-fA-F]+$/;
const NOT_METRIC = /[^a-zA-Z0-9_:]/g;
const NOT_LABEL = /[^a-zA-Z0-9_]/g;
const LEADING_DIGIT = /^[0-9]/;
const HIGH = regexp('[\x80-\xff]');

/** What a label value may hold that is not written as it is. */
export const SPECIAL = regexp('[\\\n"\x80-\xff]');

const SANITIZED = [ {}, {} ];

/** sanitize()'s memo of metric names, by the name asked for. */
export const METRIC_NAMES = SANITIZED[0];
const LABEL_NAMES = SANITIZED[1];
const SANITIZED_MAX = 4096;
let sanitized = 0;

/** What a label starts with in a set, `",name="`, by the name as written. */
export const LABEL_PREFIXES = {};

/**
 * A name with every character the format does not allow made an underscore.
 *
 * @param {*} name
 * @param {?boolean} is_label
 * @returns {string}
 */
export function sanitize(name, is_label) {
	name = '' + name;

	let memo = SANITIZED[is_label ? 1 : 0];
	let s = memo[name];

	if (s == null) {
		if (match(name, is_label ? LABEL_NAME : METRIC_NAME)) {
			s = name;
		} else {
			s = replace(name, is_label ? NOT_LABEL : NOT_METRIC, '_');
			if (s == '' || match(s, LEADING_DIGIT))
				s = '_' + s;
		}

		if (sanitized++ < SANITIZED_MAX)
			memo[name] = s;
	}

	return s;
};

/**
 * The value as the format spells it, or null for what is not a number.
 *
 * @param {*} value
 * @returns {?string}
 */
export function format_value(value) {
	switch (type(value)) {
	case 'int':
		return '' + value;

	case 'double':
		let s = '' + value;

		if (+s == value && value - value == 0)
			return s;
		if (value != value)
			return 'NaN';
		if (value == Infinity)
			return '+Inf';
		if (value == -Infinity)
			return '-Inf';

		for (let digits = 15; digits <= 17 && +s != value; digits++)
			s = sprintf(`%.${digits}g`, value);

		return s;

	case 'bool':
		return value ? '1' : '0';

	case 'string':
		value = trim(value);

		let n = +value;
		if (type(n) == 'int' && '' + n == value)
			return value;

		if (value in [ 'NaN', '+Inf', '-Inf' ])
			return value;
		if (value == 'Inf')
			return '+Inf';
		if (match(value, NUMBER) || match(value, HEX))
			return format_value(+value);
		return null;
	}

	return null;
};

function sequence(b) {
	if (b >= 0xc2 && b <= 0xdf)
		return [ 1, 0x80, 0xbf ];
	if (b >= 0xe0 && b <= 0xef)
		return [ 2, (b == 0xe0) ? 0xa0 : 0x80, (b == 0xed) ? 0x9f : 0xbf ];
	if (b >= 0xf0 && b <= 0xf4)
		return [ 3, (b == 0xf0) ? 0x90 : 0x80, (b == 0xf4) ? 0x8f : 0xbf ];

	return null;
}

/**
 * Whether `text` is valid UTF-8, as Prometheus wants a label value and HELP text.
 *
 * @param {string} text
 * @returns {boolean}
 */
export function utf8_valid(text) {
	if (!match(text, HIGH))
		return true;

	let n = length(text);

	for (let i = 0; i < n; i++) {
		let b = ord(text, i);

		if (b < 0x80)
			continue;

		let s = sequence(b);

		if (s == null || i + s[0] >= n)
			return false;

		let c = ord(text, i + 1);

		if (c < s[1] || c > s[2])
			return false;
		for (let k = 2; k <= s[0]; k++) {
			c = ord(text, i + k);
			if (c < 0x80 || c > 0xbf)
				return false;
		}

		i += s[0];
	}

	return true;
};

/**
 * Most values have nothing to escape, and index() is cheaper than replace().
 *
 * @param {string} value
 * @returns {string}
 */
export function escape_label(value) {
	if (index(value, '\\') < 0 && index(value, '"') < 0 && index(value, '\n') < 0)
		return value;

	return replace(replace(replace(value, '\\', '\\\\'), '"', '\\"'), '\n', '\\n');
};

function escape_help(text) {
	if (index(text, '\\') < 0 && index(text, '\n') < 0)
		return text;

	return replace(replace(text, '\\', '\\\\'), '\n', '\\n');
}

/**
 * A family's HELP and TYPE lines.
 *
 * @param {(Family|RecordedFamily)} fam
 * @returns {string}
 */
export function header(fam) {
	return (fam.help ? `# HELP ${fam.name} ${escape_help(fam.help)}\n` : '') + `# TYPE ${fam.name} ${fam.type}`;
};

/**
 * The label set `pairs` as the format writes it, each value escaped.
 *
 * @param {string[][]} pairs
 * @returns {string}
 */
export function format_labels(pairs) {
	let n = length(pairs);

	if (!n)
		return '';

	let s = `{${pairs[0][0]}="${escape_label(pairs[0][1])}"`;
	for (let i = 1; i < n; i++)
		s += `,${pairs[i][0]}="${escape_label(pairs[i][1])}"`;

	return s + '}';
};

function label_pairs(labels) {
	let pairs = [];

	for (let name, value in labels) {
		let t = type(value);

		if (t != 'string') {
			if (t != 'int' && t != 'double' && t != 'bool')
				continue;
			value = format_value(value);
		}

		push(pairs, [ LABEL_NAMES[name] ?? sanitize(name, true), value, name ]);
	}

	return pairs;
}

function clash(labels) {
	let seen = {};

	for (let p in label_pairs(labels)) {
		let had = seen[p[0]];

		if (had != null)
			return [ p[2], had, p[0] ];
		seen[p[0]] = p[2];
	}

	return null;
}

function label_prefix(name) {
	if ((LABEL_NAMES[name] ?? sanitize(name, true)) != name)
		return null;

	let p = `",${name}="`;

	if (sanitized++ < SANITIZED_MAX)
		LABEL_PREFIXES[name] = p;

	return p;
}

/**
 * A collector's labels as the format writes them, '' for none, null for an invalid set.
 *
 * @param {?Object} labels
 * @returns {?string}
 */
export function label_text(labels) {
	if (labels == null)
		return '';

	let text = '';
	let values = '';
	let renamed = false;

	for (let name, value in labels) {
		if (type(value) != 'string') {
			let t = type(value);

			if (t != 'int' && t != 'double' && t != 'bool')
				continue;
			value = format_value(value);
		}

		let p = LABEL_PREFIXES[name] ?? label_prefix(name);

		if (p == null) {
			renamed = true;
			p = `",${sanitize(name, true)}="`;
		}

		text += p + value;
		values += value;
	}

	if (text == '')
		return '';
	if (renamed && clash(labels) != null)
		return null;
	if (match(values, SPECIAL))
		return utf8_valid(text) ? format_labels(label_pairs(labels)) : null;

	return '{' + substr(text, 2) + '"}';
};

/**
 * What makes `labels` a set the format cannot write, or null for a valid set.
 *
 * @param {*} labels
 * @returns {?{ label: ?string, why: string }}
 */
export function label_problem(labels) {
	let t = type(labels);

	if (labels != null && t != 'object')
		return { label: null, why: `labels must be an object, or what out.labels() made, not ${t == 'string' ? 'a string of its own' : t}` };

	let c = clash(labels ?? {});

	if (c != null)
		return { label: c[2], why: `labels '${c[1]}' and '${c[0]}' are both '${c[2]}' once sanitized` };

	for (let p in label_pairs(labels ?? {}))
		if (!utf8_valid(p[1]))
			return { label: p[0], why: 'its value is not valid UTF-8' };

	return null;
};

/**
 * A sample of parse() as the format writes it.
 *
 * @param {Sample} sample
 * @returns {string}
 */
export function sample_line(sample) {
	return sample.name + format_labels(sample.labels) + ' ' + sample.value + (sample.ts != null ? ' ' + sample.ts : '');
};

/**
 * Adds a family to `into`, merging its samples; false when the types disagree.
 *
 * @param {FamilySet} into
 * @param {(Family|RecordedFamily)} fam
 * @returns {boolean}
 */
export function add_family(into, fam) {
	let have = into.by_name[fam.name];

	if (!have) {
		have = into.by_name[fam.name] = (fam.lines != null)
			? { name: fam.name, type: fam.type, help: fam.help, lines: [], values: [] }
			: { name: fam.name, type: fam.type, help: fam.help, samples: [] };
		push(into.list, have);
	}

	if (have.type != fam.type)
		return false;

	have.help ??= fam.help;
	if (fam.lines != null) {
		push(have.lines, ...fam.lines);
		push(have.values, ...fam.values);
	} else {
		push(have.samples, ...fam.samples);
	}

	return true;
};

/**
 * The families in the order they were first added, and by name.
 *
 * @returns {FamilySet}
 */
export function family_set() {
	return { list: [], by_name: {} };
};

/**
 * The families of a set, in the order they were first added.
 *
 * @param {FamilySet} set
 * @returns {(Family|RecordedFamily)[]}
 */
export function families_of(set) {
	return set.list;
};

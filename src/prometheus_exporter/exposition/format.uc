'use strict';

// The Prometheus text exposition format, version 0.0.4, as it is spelled: a
// name made valid (sanitize), a value (format_value), a label set and HELP
// text escaped, a sample's line and a family's header. And the ordered set of
// families by name that a recorder, merge() and parse() add families to
// (prometheus_exporter.exposition, prometheus_exporter.exposition.parse).

export const TYPES = [ 'counter', 'gauge', 'histogram', 'summary', 'untyped' ];

// Every regex is a constant: ucode compiles a regex literal each time it is
// evaluated, which costs more than the match. And no sample takes a regex at
// all where it can be helped: musl's regexec costs microseconds even on a
// short string, and a scrape writes thousands of samples.
export const METRIC_NAME = /^[a-zA-Z_:][a-zA-Z0-9_:]*$/;
const LABEL_NAME = /^[a-zA-Z_][a-zA-Z0-9_]*$/;
const NUMBER = /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/;
const HEX = /^0[xX][0-9a-fA-F]+$/;
const NOT_METRIC = /[^a-zA-Z0-9_:]/g;
const NOT_LABEL = /[^a-zA-Z0-9_]/g;
const LEADING_DIGIT = /^[0-9]/;

// sanitize()'s answers, [ metric names, label names ]: a scrape asks for the
// same names again and again (a label name in every sample). uhttpd runs each
// request in a process of its own, forked from the one that loaded the
// exporter, so this lives for one scrape there; the memo stops growing at
// SANITIZED_MAX names all the same, for a process that scrapes many times.
const SANITIZED = [ {}, {} ];
export const METRIC_NAMES = SANITIZED[0];
const LABEL_NAMES = SANITIZED[1];
const SANITIZED_MAX = 4096;
let sanitized = 0;

// A name with every character the format does not allow made an underscore, and
// a leading digit (or nothing at all) prefixed with one.
export function sanitize(name, is_label) {
	name = '' + name;

	let memo = SANITIZED[is_label ? 1 : 0];
	let s = memo[name];

	if (s == null) {
		// Most names are valid already: one regex, not two.
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

// The value as the format spells it, or null for what is not a number: an empty
// string, a word, an object. Strings are procfs and sysfs readings, so the
// surrounding whitespace goes and hex (as in sysfs flags) is read.
export function format_value(value) {
	switch (type(value)) {
	case 'int':
		return '' + value;

	case 'double':
		if (value != value)
			return 'NaN';
		if (value == Infinity)
			return '+Inf';
		if (value == -Infinity)
			return '-Inf';
		return '' + value;

	case 'bool':
		return value ? '1' : '0';

	case 'string':
		value = trim(value);

		// Most are integers as the format spells them already: no regex.
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

// Most values have nothing to escape, and index() is cheaper than replace().
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

// A family's HELP and TYPE lines.
export function header(fam) {
	return (fam.help ? `# HELP ${fam.name} ${escape_help(fam.help)}\n` : '') + `# TYPE ${fam.name} ${fam.type}`;
};

// The label set `pairs` as the format writes it, each value escaped.
export function format_labels(pairs) {
	let n = length(pairs);

	if (!n)
		return '';

	let s = `{${pairs[0][0]}="${escape_label(pairs[0][1])}"`;
	for (let i = 1; i < n; i++)
		s += `,${pairs[i][0]}="${escape_label(pairs[i][1])}"`;

	return s + '}';
};

// A collector's labels as [ name, value ] pairs. A null label is left out,
// which is what Prometheus makes of an empty one anyway.
function label_pairs(labels) {
	let pairs = [];

	for (let name, value in labels) {
		let t = type(value);

		if (t != 'string') {
			if (t != 'int' && t != 'double' && t != 'bool')
				continue;
			value = format_value(value);
		}

		push(pairs, [ LABEL_NAMES[name] ?? sanitize(name, true), value ]);
	}

	return pairs;
}

// A collector's labels as the format writes them, '' for none: what
// format_labels(label_pairs(labels)) gives.
//
// In one pass, and with the values written as they are: the set is written
// again with each value escaped only when one needs it, when the text holds a
// backslash or a newline, or more quotes than its own (sanitized names hold
// neither). One check for the set is cheaper than one for each value.
export function label_text(labels) {
	if (labels == null)
		return '';

	let text = '';
	let n = 0;

	for (let name, value in labels) {
		let t = type(value);

		if (t != 'string') {
			if (t != 'int' && t != 'double' && t != 'bool')
				continue;
			value = format_value(value);
		}

		text += `,${LABEL_NAMES[name] ?? sanitize(name, true)}="${value}"`;
		n++;
	}

	if (!n)
		return '';
	if (index(text, '\\') >= 0 || index(text, '\n') >= 0 || length(split(text, '"')) != 2 * n + 1)
		return format_labels(label_pairs(labels));

	return '{' + substr(text, 1) + '}';
};

// A sample of parse() as the format writes it.
export function sample_line(s) {
	return s.name + format_labels(s.labels) + ' ' + s.value + (s.ts != null ? ' ' + s.ts : '');
};

// Adds a family to `into` (an ordered set: { list, by_name }), merging its
// samples into a family already there, as parse() keeps them ({ samples })
// or as a recorder does ({ lines, values }). False when the types disagree;
// the samples are then dropped.
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

// The families in the order they were first added, and by name.
export function family_set() {
	return { list: [], by_name: {} };
};

export function families_of(set) {
	return set.list;
};

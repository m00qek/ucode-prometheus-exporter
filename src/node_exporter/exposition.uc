'use strict';

// The Prometheus text exposition format, version 0.0.4.
//
// A family is { name, type, help, samples }; a sample is { name, labels, value, ts }
// with labels as [ name, value ] pairs in order and value and ts already spelled
// as the format wants them. Collectors record families (recorder), the scrape
// merges them by name (merge) and writes them once (render). parse() reads the
// format back, strictly: textfile uses it for *.prom files, the tests for every
// scrape they make.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const TYPES = [ 'counter', 'gauge', 'histogram', 'summary', 'untyped' ];

const METRIC_NAME = /^[a-zA-Z_:][a-zA-Z0-9_:]*$/;
const LABEL_NAME = /^[a-zA-Z_][a-zA-Z0-9_]*$/;
const NUMBER = /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/;
const HEX = /^0[xX][0-9a-fA-F]+$/;

// A name with every character the format does not allow made an underscore, and
// a leading digit (or nothing at all) prefixed with one.
export function sanitize(name, is_label) {
	name = replace('' + name, is_label ? /[^a-zA-Z0-9_]/g : /[^a-zA-Z0-9_:]/g, '_');

	return (name == '' || match(name, /^[0-9]/)) ? '_' + name : name;
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

export function escape_label(value) {
	return replace(replace(replace(value, '\\', '\\\\'), '"', '\\"'), '\n', '\\n');
};

function escape_help(text) {
	return replace(replace(text, '\\', '\\\\'), '\n', '\\n');
}

// In one pass, left to right: undoing \n first would read the \\n of a
// backslash followed by n as a newline.
function unescape_help(text) {
	return replace(text, /\\(\\|n)/g, (m, c) => c == 'n' ? '\n' : '\\');
}

// Labels as [ name, value ] pairs. A null label is left out, which is what
// Prometheus makes of an empty one anyway.
function label_pairs(labels) {
	let pairs = [];

	for (let name, value in labels) {
		let s;

		switch (type(value)) {
		case 'string':
			s = value;
			break;
		case 'int':
		case 'double':
		case 'bool':
			s = format_value(value);
			break;
		default:
			continue;
		}

		push(pairs, [ sanitize(name, true), s ]);
	}

	return pairs;
}

function format_labels(pairs) {
	if (!length(pairs))
		return '';

	return '{' + join(',', map(pairs, (p) => `${p[0]}="${escape_label(p[1])}"`)) + '}';
}

// Adds a family to `into` (an ordered set: { order, by_name }), merging its
// samples into a family already there. False when the types disagree; the
// samples are then dropped.
function add_family(into, fam) {
	let have = into.by_name[fam.name];

	if (!have) {
		have = into.by_name[fam.name] = { name: fam.name, type: fam.type, help: fam.help, samples: [] };
		push(into.order, fam.name);
	}

	if (have.type != fam.type)
		return false;

	have.help ??= fam.help;
	push(have.samples, ...fam.samples);
	return true;
}

function family_set() {
	return { order: [], by_name: {} };
}

function families_of(set) {
	return map(set.order, (n) => set.by_name[n]);
}

// { pairs, rest } for the label set that starts `s` (after its '{'), or a string
// saying what is wrong with it.
function scan_labels(s) {
	let pairs = [];
	let seen = {};
	let i = 0;

	while (true) {
		let m = match(substr(s, i), /^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*"/);

		// `{}`, or the close after a trailing comma.
		if (!m) {
			m = match(substr(s, i), /^\s*\}/);
			return m ? { pairs, rest: substr(s, i + length(m[0])) } : 'malformed label set';
		}

		let name = m[1];
		let value = '';
		i += length(m[0]);

		while (true) {
			let c = substr(s, i, 1);

			if (c == '')
				return 'unterminated label value';
			if (c == '"')
				break;
			if (c == '\\') {
				let e = substr(s, i + 1, 1);
				if (e == 'n')
					value += '\n';
				else if (e == '\\' || e == '"')
					value += e;
				else
					return `invalid escape '\\${e}' in label value`;
				i += 2;
				continue;
			}

			value += c;
			i++;
		}

		i++;
		if (seen[name])
			return `duplicate label '${name}'`;
		seen[name] = true;
		push(pairs, [ name, value ]);

		let sep = match(substr(s, i), /^\s*(,|\})/);
		if (!sep)
			return 'malformed label set';
		i += length(sep[0]);
		if (sep[1] == '}')
			return { pairs, rest: substr(s, i) };
	}
}

// The family a sample belongs to: its own name, or for a histogram's or
// summary's _bucket/_sum/_count series, the declared base name.
function family_of(name, declared) {
	let m = match(name, /^(.*)_(bucket|sum|count)$/);

	if (m && declared[m[1]]?.type in [ 'histogram', 'summary' ])
		return m[1];

	return name;
}

function series_key(name, pairs) {
	return name + format_labels(sort([ ...pairs ], (a, b) => a[0] < b[0] ? -1 : 1));
}

// The families in exposition text, or EXPOSITION_INVALID naming the first line
// that breaks the format: a malformed line, a TYPE or HELP given twice or after
// the family's samples, a family whose lines are not all together, a value that
// is not a number, or the same series twice.
export function parse(text) {
	let set = family_set();
	let declared = {};
	let closed = {};
	let series = {};
	let current = null;
	let n = 0;

	function fail(msg) {
		return Result.err(errors.EXPOSITION_INVALID, `line ${n}: ${msg}`);
	}

	function enter(name) {
		if (name == current)
			return true;
		if (closed[name])
			return false;
		if (current != null)
			closed[current] = true;
		current = name;
		return true;
	}

	function family(name) {
		if (!set.by_name[name])
			add_family(set, { name, type: declared[name]?.type ?? 'untyped', help: declared[name]?.help, samples: [] });
		return set.by_name[name];
	}

	for (let line in split(text ?? '', '\n')) {
		n++;
		line = rtrim(line, '\r');

		if (trim(line) == '')
			continue;

		if (substr(line, 0, 1) == '#') {
			let m = match(line, /^#\s+(HELP|TYPE)\s+(\S+)( (.*))?$/);

			if (!m)
				continue;

			let kind = m[1], name = m[2], arg = m[4] ?? '';
			if (kind == 'TYPE')
				arg = trim(arg);

			if (!match(name, METRIC_NAME))
				return fail(`invalid metric name '${name}'`);
			if (!enter(name))
				return fail(`lines of '${name}' are not together`);

			declared[name] ??= {};

			if (kind == 'TYPE') {
				if (declared[name].type)
					return fail(`second TYPE for '${name}'`);
				if (set.by_name[name] && length(set.by_name[name].samples))
					return fail(`TYPE for '${name}' after its samples`);
				if (!(arg in TYPES))
					return fail(`unknown type '${arg}'`);
				declared[name].type = arg;
				if (set.by_name[name])
					set.by_name[name].type = arg;
			} else {
				if (declared[name].help != null)
					return fail(`second HELP for '${name}'`);
				declared[name].help = unescape_help(arg);
				if (set.by_name[name])
					set.by_name[name].help = declared[name].help;
			}

			continue;
		}

		let m = match(line, /^([a-zA-Z_:][a-zA-Z0-9_:]*)(.*)$/);
		if (!m)
			return fail('malformed sample');

		let name = m[1];
		let rest = m[2];
		let pairs = [];

		if (substr(rest, 0, 1) == '{') {
			let scanned = scan_labels(substr(rest, 1));

			if (type(scanned) == 'string')
				return fail(scanned);

			pairs = scanned.pairs;
			rest = scanned.rest;
		}

		let v = match(rest, /^\s+(\S+)(\s+(-?[0-9]+))?\s*$/);
		if (!v)
			return fail('malformed sample');

		let value = format_value(v[1]);
		if (value == null)
			return fail(`value '${v[1]}' is not a number`);

		let fname = family_of(name, declared);
		if (!enter(fname))
			return fail(`lines of '${fname}' are not together`);

		let key = series_key(name, pairs);
		if (series[key])
			return fail(`second sample for ${key}`);
		series[key] = true;

		push(family(fname).samples, { name, labels: pairs, value, ts: v[3] });
	}

	return Result.ok(filter(families_of(set), (f) => length(f.samples)));
};

// What a collector writes to. counter/gauge/untyped(name, help) returns
// (labels, value) => itself, so samples chain; a value that is not a number is
// skipped. parse(text) adds exposition text, which must be valid as a whole.
export function recorder() {
	let set = family_set();
	let conflicts = [];

	function family(name, mtype, help) {
		name = sanitize(name);

		let fam = { name, type: mtype, help, samples: [] };
		if (!add_family(set, fam))
			push(conflicts, name);

		let target = set.by_name[name].type == mtype ? set.by_name[name] : null;
		function sample(labels, value) {
			let v = format_value(value);

			if (target && v != null)
				push(target.samples, { name, labels: label_pairs(labels), value: v, ts: null });

			return sample;
		}

		return sample;
	}

	return {
		counter: (name, help) => family(name, 'counter', help),
		gauge: (name, help) => family(name, 'gauge', help),
		untyped: (name, help) => family(name, 'untyped', help),

		parse: function(text) {
			let res = parse(text);

			if (!res.ok)
				return res;

			for (let fam in res.data)
				if (!add_family(set, fam))
					push(conflicts, fam.name);

			return Result.ok();
		},

		families: () => families_of(set),
		conflicts: () => uniq(conflicts),
	};
};

// The families of several recorders as one list, merged by name in the order
// they first appear. { families, conflicts }: the names declared with two types.
export function merge(lists) {
	let set = family_set();
	let conflicts = [];

	for (let list in lists)
		for (let fam in list)
			if (!add_family(set, fam))
				push(conflicts, fam.name);

	return { families: families_of(set), conflicts: uniq(conflicts) };
};

// opts.omit_zero_counters leaves out counter samples whose value is 0 (the lua
// exporter's omit_zero_values). A family left without samples is not written.
export function render(families, opts) {
	let lines = [];

	for (let fam in families) {
		let samples = fam.samples;

		if (opts?.omit_zero_counters && fam.type == 'counter')
			samples = filter(samples, (s) => +s.value != 0);

		if (!length(samples))
			continue;

		if (fam.help)
			push(lines, `# HELP ${fam.name} ${escape_help(fam.help)}`);
		push(lines, `# TYPE ${fam.name} ${fam.type}`);

		for (let s in samples)
			push(lines, s.name + format_labels(s.labels) + ' ' + s.value + (s.ts != null ? ' ' + s.ts : ''));
	}

	return length(lines) ? join('\n', lines) + '\n' : '';
};

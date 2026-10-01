'use strict';

// The Prometheus text exposition format, version 0.0.4.
//
// A family is { name, type, help, samples }; a sample is { name, labels, value, ts }
// with labels as [ name, value ] pairs in order and value and ts already spelled
// as the format wants them. Collectors record families (recorder), the scrape
// merges them by name (merge) and writes them once (render). parse() reads the
// format back, strictly: textfile uses it for *.prom files, the tests for every
// scrape they make.
//
// A recorded sample also has its `line`, written when it is recorded: every
// operation of ucode's VM costs about a microsecond on a router's CPU, and a
// scrape writes thousands of samples, so a sample costs as few as can be. A
// collector that writes several families of the same labels (a device's
// statistics, a station's) makes them once with labels() and passes that:
// they are then checked and written once, not once per family.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

export const TYPES = [ 'counter', 'gauge', 'histogram', 'summary', 'untyped' ];

// Every regex is a constant: ucode compiles a regex literal each time it is
// evaluated, which costs more than the match. And no sample takes a regex at
// all where it can be helped: musl's regexec costs microseconds even on a
// short string, and a scrape writes thousands of samples.
const METRIC_NAME = /^[a-zA-Z_:][a-zA-Z0-9_:]*$/;
const LABEL_NAME = /^[a-zA-Z_][a-zA-Z0-9_]*$/;
const NUMBER = /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/;
const HEX = /^0[xX][0-9a-fA-F]+$/;
const NOT_METRIC = /[^a-zA-Z0-9_:]/g;
const NOT_LABEL = /[^a-zA-Z0-9_]/g;
const LEADING_DIGIT = /^[0-9]/;
const LABEL_START = /^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*"/;
const LABELS_END = /^\s*\}/;
const LABEL_SEPARATOR = /^\s*(,|\})/;
const SERIES_SUFFIX = /^(.*)_(bucket|sum|count)$/;
const COMMENT = /^#\s+(HELP|TYPE)\s+(\S+)( (.*))?$/;
const SAMPLE_NAME = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(.*)$/;
const SAMPLE_VALUE = /^\s+(\S+)(\s+(-?[0-9]+))?\s*$/;
const HELP_ESCAPE = /\\(\\|n)/g;

// sanitize()'s answers, [ metric names, label names ]: a scrape asks for the
// same names again and again (a label name in every sample). uhttpd runs each
// request in a process of its own, forked from the one that loaded the
// exporter, so this lives for one scrape there; the memo stops growing at
// SANITIZED_MAX names all the same, for a process that scrapes many times.
const SANITIZED = [ {}, {} ];
const METRIC_NAMES = SANITIZED[0];
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
function header(fam) {
	return (fam.help ? `# HELP ${fam.name} ${escape_help(fam.help)}\n` : '') + `# TYPE ${fam.name} ${fam.type}`;
}

// In one pass, left to right: undoing \n first would read the \\n of a
// backslash followed by n as a newline.
function unescape_help(text) {
	return replace(text, HELP_ESCAPE, (m, c) => c == 'n' ? '\n' : '\\');
}

// The label set `pairs` as the format writes it, each value escaped.
function format_labels(pairs) {
	let n = length(pairs);

	if (!n)
		return '';

	let s = `{${pairs[0][0]}="${escape_label(pairs[0][1])}"`;
	for (let i = 1; i < n; i++)
		s += `,${pairs[i][0]}="${escape_label(pairs[i][1])}"`;

	return s + '}';
}

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
function label_text(labels) {
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
}

// A sample of parse() as the format writes it.
function sample_line(s) {
	return s.name + format_labels(s.labels) + ' ' + s.value + (s.ts != null ? ' ' + s.ts : '');
}

// A family of parse() ({ samples }) as a recorder keeps one: its samples as
// lines, and a counter's values, which omit_zero_counters reads.
function as_lines(fam) {
	return {
		name: fam.name, type: fam.type, help: fam.help,
		lines: map(fam.samples, sample_line),
		values: fam.type == 'counter' ? map(fam.samples, (s) => s.value) : [],
	};
}

// Adds a family to `into` (an ordered set: { list, by_name }), merging its
// samples into a family already there, as parse() keeps them ({ samples })
// or as a recorder does ({ lines, values }). False when the types disagree;
// the samples are then dropped.
function add_family(into, fam) {
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
}

// The families in the order they were first added, and by name.
function family_set() {
	return { list: [], by_name: {} };
}

function families_of(set) {
	return set.list;
}

// A label value, from after its opening quote: [ value, the rest after its
// closing quote ], or a string saying what is wrong with it. It is copied up
// to each backslash or the closing quote at once, not a character at a time.
function scan_value(s) {
	let value = '';

	while (true) {
		let q = index(s, '"'), b = index(s, '\\');

		if (b >= 0 && (q < 0 || b < q)) {
			let e = substr(s, b + 1, 1);

			if (e == 'n')
				value += substr(s, 0, b) + '\n';
			else if (e == '\\' || e == '"')
				value += substr(s, 0, b) + e;
			else
				return `invalid escape '\\${e}' in label value`;

			s = substr(s, b + 2);
			continue;
		}

		if (q < 0)
			return 'unterminated label value';

		return [ value + substr(s, 0, q), substr(s, q + 1) ];
	}
}

// { pairs, rest } for the label set that starts `s` (after its '{'), or a string
// saying what is wrong with it.
function scan_labels(s) {
	let pairs = [];
	let seen = {};

	while (true) {
		let m = match(s, LABEL_START);

		// `{}`, or the close after a trailing comma.
		if (!m) {
			m = match(s, LABELS_END);
			return m ? { pairs, rest: substr(s, length(m[0])) } : 'malformed label set';
		}

		let name = m[1];
		let scanned = scan_value(substr(s, length(m[0])));

		if (type(scanned) == 'string')
			return scanned;

		s = scanned[1];
		if (seen[name])
			return `duplicate label '${name}'`;
		seen[name] = true;
		push(pairs, [ name, scanned[0] ]);

		let sep = match(s, LABEL_SEPARATOR);
		if (!sep)
			return 'malformed label set';
		s = substr(s, length(sep[0]));
		if (sep[1] == '}')
			return { pairs, rest: s };
	}
}

// The family a sample belongs to: its own name, or for a histogram's or
// summary's _bucket/_sum/_count series, the declared base name.
function family_of(name, declared) {
	let m = match(name, SERIES_SUFFIX);

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
			let m = match(line, COMMENT);

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

		let m = match(line, SAMPLE_NAME);
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

		let v = match(rest, SAMPLE_VALUE);
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
// skipped. labels(labels) is the labels for several samples (a station's,
// a device's), written once: pass it where the labels go. parse(text) adds
// exposition text, which must be valid as a whole; add(families) adds what
// parse() gave.
//
// A family it records is { name, type, help, lines, values }: each sample as
// the line the format writes, and for a counter the values, which render()'s
// omit_zero_counters reads.
export function recorder() {
	let set = family_set();
	let conflicts = [];

	// As add_family() would add an empty family, without making it first:
	// netstat and ethtool make hundreds of families.
	function family(name, mtype, help) {
		name = METRIC_NAMES[name] ?? sanitize(name);

		let target = set.by_name[name];

		if (!target) {
			target = set.by_name[name] = { name, type: mtype, help, lines: [], values: [] };
			push(set.list, target);
		} else if (target.type != mtype) {
			push(conflicts, name);
			target = null;
		} else {
			target.help ??= help;
		}

		let lines = target?.lines;
		let values = (mtype == 'counter') ? target?.values : null;

		// labels: an object, or what labels() made of one.
		function sample(labels, value) {
			let v = type(value) == 'int' ? '' + value : format_value(value);

			if (target && v != null) {
				push(lines, name + (type(labels) == 'string' ? labels : label_text(labels)) + ' ' + v);
				if (values)
					push(values, v);
			}

			return sample;
		}

		return sample;
	}

	function add(families) {
		for (let fam in families)
			if (!add_family(set, as_lines(fam)))
				push(conflicts, fam.name);
	}

	return {
		counter: (name, help) => family(name, 'counter', help),
		gauge: (name, help) => family(name, 'gauge', help),
		untyped: (name, help) => family(name, 'untyped', help),
		labels: label_text,

		parse: function(text) {
			let res = parse(text);

			if (!res.ok)
				return res;

			add(res.data);
			return Result.ok();
		},

		// For a caller that read the text itself, so it is not read twice.
		add,

		families: () => families_of(set),
		conflicts: () => uniq(conflicts),
	};
};

// The families of several recorders as one list, merged by name in the order
// they first appear. { families, conflicts }: the names declared with two types.
//
// A family only one list has (most) is taken as it is, not copied; it is
// copied when a second list has it too, so no list's family is changed.
export function merge(lists) {
	let set = family_set();
	// By name: where its family is in set.list, and whether that is a copy.
	let at = {}, copied = {};
	let conflicts = [];

	for (let list in lists)
		for (let fam in list) {
			let name = fam.name;
			let i = at[name];

			if (i == null) {
				// A family of parse() is made a recorder's, which is a copy.
				if (fam.lines == null) {
					fam = as_lines(fam);
					copied[name] = true;
				}

				at[name] = length(set.list);
				set.by_name[name] = fam;
				push(set.list, fam);
				continue;
			}

			if (!copied[name]) {
				let have = set.list[i];

				set.by_name[name] = set.list[i] = { name, type: have.type, help: have.help, lines: [ ...have.lines ], values: [ ...have.values ] };
				copied[name] = true;
			}

			if (!add_family(set, fam.lines == null ? as_lines(fam) : fam))
				push(conflicts, name);
		}

	return { families: set.list, conflicts: uniq(conflicts) };
};

// The text of families as a recorder or merge() keeps them, or as parse()
// gives them. opts.omit_zero_counters leaves out counter samples whose value is
// 0 (the lua exporter's omit_zero_values). A family left without samples is
// not written.
export function render(families, opts) {
	let parts = [];
	let omit = opts?.omit_zero_counters;

	for (let fam in families) {
		let lines = fam.lines ?? map(fam.samples, sample_line);

		if (omit && fam.type == 'counter') {
			let values = fam.values ?? map(fam.samples, (s) => s.value);
			let kept = [];

			for (let i, line in lines)
				if (+values[i] != 0)
					push(kept, line);

			lines = kept;
		}

		if (length(lines))
			push(parts, header(fam), join('\n', lines));
	}

	return length(parts) ? join('\n', parts) + '\n' : '';
};

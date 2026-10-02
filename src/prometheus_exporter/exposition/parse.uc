'use strict';

// The Prometheus text exposition format, version 0.0.4, read back, strictly:
// textfile reads its *.prom files with parse(), a recorder's parse() the text
// a collector adds, and the tests every scrape they make.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { TYPES, METRIC_NAME, format_value, format_labels, add_family, family_set, families_of } from 'prometheus_exporter.exposition.format';

// Constants, as format.uc's are: ucode compiles a regex literal each time it
// is evaluated.
const LABEL_START = /^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*"/;
const LABELS_END = /^\s*\}/;
const LABEL_SEPARATOR = /^\s*(,|\})/;
const SERIES_SUFFIX = /^(.*)_(bucket|sum|count)$/;
const COMMENT = /^#\s+(HELP|TYPE)\s+(\S+)( (.*))?$/;
const SAMPLE_NAME = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(.*)$/;
const SAMPLE_VALUE = /^\s+(\S+)(\s+(-?[0-9]+))?\s*$/;
const HELP_ESCAPE = /\\(\\|n)/g;

// In one pass, left to right: undoing \n first would read the \\n of a
// backslash followed by n as a newline.
function unescape_help(text) {
	return replace(text, HELP_ESCAPE, (m, c) => c == 'n' ? '\n' : '\\');
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

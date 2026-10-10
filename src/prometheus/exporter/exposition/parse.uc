/**
 * The Prometheus text exposition format 0.0.4, read back, strictly.
 *
 * @module prometheus_exporter_exposition_parse
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import { TYPES, METRIC_NAME, format_value, format_labels, utf8_valid, reserved, add_family, family_set, families_of } from 'prometheus.exporter.exposition.format';

const LABEL_START = /^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*"/;
const LABELS_END = /^\s*\}/;
const LABEL_SEPARATOR = /^\s*(,|\})/;
const SERIES_SUFFIX = /^(.*)_(bucket|sum|count)$/;
const COMMENT = /^#\s+(HELP|TYPE)\s+(\S+)( (.*))?$/;
const SAMPLE_NAME = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(.*)$/;
const SAMPLE_VALUE = /^\s+(\S+)(\s+(-?[0-9]+))?\s*$/;
const HELP_ESCAPE = /\\(\\|n)/g;

function unescape_help(text) {
	return replace(text, HELP_ESCAPE, (m, c) => c == 'n' ? '\n' : '\\');
}

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

function scan_labels(s, utf8) {
	let pairs = [];
	let seen = {};

	while (true) {
		let m = match(s, LABEL_START);

		if (!m) {
			m = match(s, LABELS_END);
			return m ? { pairs, rest: substr(s, length(m[0])) } : 'malformed label set';
		}

		let name = m[1];

		if (reserved(name))
			return `reserved label name '${name}'`;

		let scanned = scan_value(substr(s, length(m[0])));

		if (type(scanned) == 'string')
			return scanned;

		s = scanned[1];
		if (seen[name])
			return `duplicate label '${name}'`;
		if (utf8 && !utf8_valid(scanned[0]))
			return `label '${name}': its value is not valid UTF-8`;
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

function family_of(name, declared) {
	let m = match(name, SERIES_SUFFIX);

	if (m && declared[m[1]]?.type in [ 'histogram', 'summary' ])
		return m[1];

	return name;
}

function series_key(name, pairs) {
	return name + format_labels(sort([ ...pairs ], (a, b) => a[0] < b[0] ? -1 : 1));
}

/**
 * The families in exposition text, or EXPOSITION_INVALID naming the first bad line.
 *
 * @param {?string} text
 * @returns {Result<Family[]>}
 */
export function parse(text) {
	let set = family_set();
	let declared = {};
	let closed = {};
	let series = {};
	let current = null;
	let n = 0;
	let utf8 = !utf8_valid(text ?? '');
	let nul = index(text ?? '', '\0') >= 0;

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
		if (nul && index(line, '\0') >= 0)
			return fail('holds a NUL byte');

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
				if (utf8 && !utf8_valid(arg))
					return fail(`HELP for '${name}' is not valid UTF-8`);
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
			let scanned = scan_labels(substr(rest, 1), utf8);

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

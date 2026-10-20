/**
 * The Prometheus text exposition format, version 0.0.4.
 *
 * @module prometheus_exporter_exposition
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as format from 'prometheus.exporter.exposition.format';
import { METRIC_NAME, METRIC_NAMES, LABEL_PREFIXES, SPECIAL, label_text, label_problem, utf8_valid, sample_line, header, add_family, family_set, families_of } from 'prometheus.exporter.exposition.format';

/**
 * A sample as parse() reads it: labels as [ name, value ] pairs, value and ts as spelled.
 *
 * @typedef {{ name: string, labels: string[][], value: string, ts: ?string }} Sample
 */

/**
 * A family as parse() reads it: { name, type, help, samples }, type one of TYPES.
 *
 * @typedef {{ name: string, type: string, help: ?string, samples: Sample[] }} Family
 */

/**
 * A family as a recorder keeps it: each sample's line, and a counter's values.
 *
 * @typedef {{ name: string, type: string, help: ?string, lines: string[], values: string[] }} RecordedFamily
 */

/**
 * What counter(), gauge() and untyped() return: records a sample, and returns itself.
 *
 * @typedef {(labels: ?(Object|string), value: *) => SampleWriter} SampleWriter
 */

/**
 * What a collector writes to, as recorder() makes it: what collect() gets as `out`.
 *
 * @typedef {{
 *   counter: (name: string, help: ?string) => SampleWriter,
 *   gauge: (name: string, help: ?string) => SampleWriter,
 *   untyped: (name: string, help: ?string) => SampleWriter,
 *   batch: (type: string, rows: Array<[string, ?string, *, ?(Object|string)]>) => void,
 *   labels: (labels: ?Object) => string,
 *   parse: (text: string) => Result<null>,
 *   add: (families: Family[]) => void,
 *   families: () => RecordedFamily[],
 *   conflicts: () => string[],
 *   over: () => ?{ family: string, samples: int },
 *   invalid: () => ?{ family: string, label: ?string, why: string }
 * }} Recorder
 */

export const TYPES = format.TYPES;
export const sanitize = format.sanitize;
export const format_value = format.format_value;
export const escape_label = format.escape_label;

let parser = null;

/**
 * The families in exposition text, or EXPOSITION_INVALID naming the first bad line.
 *
 * @param {?string} text exposition text; null reads as none.
 * @returns {Result<Family[]>} its families, in the order they first appear.
 */
export function parse(text) {
	parser ??= loadstring("import { parse } from 'prometheus.exporter.exposition.parse';\nreturn parse;", { raw_mode: true })();

	return parser(text);
};

function as_lines(fam) {
	return {
		name: fam.name, type: fam.type, help: fam.help,
		lines: map(fam.samples, sample_line),
		values: fam.type == 'counter' ? map(fam.samples, (s) => s.value) : [],
	};
}

/**
 * What a recorder dies with at the sample past its `max` (see recorder).
 *
 * @type {string}
 */
export const OVER_LIMIT = 'prometheus_exporter: over the sample limit';

/**
 * What a recorder dies with at text Prometheus would refuse (see recorder).
 *
 * @type {string}
 */
export const INVALID = 'prometheus_exporter: text Prometheus refuses';

const TYPES_RECORDED = [ 'counter', 'gauge', 'untyped' ];
const HIGH_BYTE = regexp('[\x80-\xff]');
const METRIC_NAME_LINES = /^[a-zA-Z_:][a-zA-Z0-9_:]*(\n[a-zA-Z_:][a-zA-Z0-9_:]*)*$/;

function dropped(labels, value) {
	return dropped;
}

/**
 * What a collector writes to.
 *
 * @param {?int} max the most samples it takes; null for no limit.
 * @returns {Recorder} the recorder.
 */
export function recorder(max) {
	let set = family_set();
	let conflicts = [];
	let count = 0;
	let cap = max ?? Infinity;
	let over = null;
	let bad = null;
	let made = { '': '' };

	function stop(name) {
		if (bad == null)
			over ??= { family: name, samples: count };
		die(bad ? INVALID : OVER_LIMIT);
	}

	function refuse(name, label, why) {
		bad ??= { family: name, label, why };
		cap = -1;
		die(INVALID);
	}

	function refuse_labels(name, labels) {
		let p = label_problem(labels);

		refuse(name, p?.label, p?.why ?? 'labels the format cannot write');
	}

	function help_of(name, help) {
		if (type(help) == 'string') {
			if (index(help, '\0') >= 0)
				refuse(name, null, 'its HELP text holds a NUL byte');
			if (!utf8_valid(help))
				refuse(name, null, 'its HELP text is not valid UTF-8');
		}
		return help;
	}

	function named(name) {
		if (type(name) == 'string' && index(name, '\0') >= 0)
			refuse(join('\\0', split(name, '\0')), null, 'its name holds a NUL byte');
	}

	function family(name, mtype, help) {
		let s = (type(name) == 'string');
		let target = s ? set.by_name[name] : null;

		if (!target || target.name != name) {
			target = null;
			if (!s || index(name, '\0') >= 0 || !match(name, METRIC_NAME)) {
				named(name);
				name = METRIC_NAMES[name] ?? sanitize(name);
				target = set.by_name[name];
			}
		}

		if (!target) {
			if (type(help) == 'string' && (index(help, '\0') >= 0 || match(help, HIGH_BYTE)))
				help_of(name, help);

			target = set.by_name[name] = { name, type: mtype, help, lines: [], values: [] };
			push(set.list, target);
		} else if (target.type != mtype) {
			push(conflicts, name);
			return dropped;
		} else if (target.help == null && help != null) {
			target.help = help_of(name, help);
		}

		let lines = target.lines;
		let values = (mtype == 'counter') ? target.values : null;

		let head = name + '{';

		function sample(labels, value) {
			let v = (type(value) == 'int') ? '' + value : format_value(value);

			if (v == null)
				return sample;
			if (++count > cap)
				stop(name);

			let t = type(labels);
			let text;

			if (t == 'string') {
				text = made[labels];
			} else if (t == 'object') {
				let vals = '';

				text = '';
				for (let k, x in labels) {
					let p = LABEL_PREFIXES[k];

					if (p == null || type(x) != 'string') {
						vals = null;
						break;
					}

					text += p + x;
					vals += x;
				}

				if (vals != null && text != '' && !match(vals, SPECIAL) && index(vals, '\0') < 0) {
					push(lines, head + substr(text, 2) + '"} ' + v);
					if (values)
						push(values, v);

					return sample;
				}

				text = label_text(labels);
			} else {
				text = (labels == null) ? '' : null;
			}

			if (text == null)
				refuse_labels(name, labels);
			push(lines, name + text + ' ' + v);
			if (values)
				push(values, v);

			return sample;
		}

		return sample;
	}

	function batch(mtype, rows) {
		if (!(mtype in TYPES_RECORDED))
			die(`batch: not a type of family a collector writes: ${mtype}`);

		let helps = [];
		let names = [];
		let strings = true;

		for (let r in rows) {
			if (type(r[1]) == 'string')
				push(helps, r[1]);
			if (type(r[0]) == 'string')
				push(names, r[0]);
			else
				strings = false;
		}

		let joined = join('', helps);
		let read = match(joined, HIGH_BYTE) != null || index(joined, '\0') >= 0;
		let counter = (mtype == 'counter');
		let listed = (strings && index(join('', names), '\0') < 0) ? uniq(names) : [];
		let all = join('\n', listed);
		let valid = length(listed) > 0 && match(all, METRIC_NAME_LINES) != null && length(split(all, '\n')) == length(listed);

		for (let r in rows) {
			let name = r[0], help = r[1], value = r[2], labels = r[3];

			if (!valid) {
				named(name);
				name = METRIC_NAMES[name] ?? ((type(name) == 'string' && match(name, METRIC_NAME)) ? name : sanitize(name));
			}

			let target = set.by_name[name];

			if (!target) {
				target = set.by_name[name] = { name, type: mtype, help: read ? help_of(name, help) : help, lines: [], values: [] };
				push(set.list, target);
			} else if (target.type != mtype) {
				push(conflicts, name);
				continue;
			} else if (target.help == null && help != null) {
				target.help = help_of(name, help);
			}

			let v = (type(value) == 'int') ? '' + value : format_value(value);

			if (v == null)
				continue;
			if (++count > cap)
				stop(name);

			let text = '';

			if (labels != null) {
				text = (type(labels) == 'string') ? made[labels] : ((type(labels) == 'object') ? label_text(labels) : null);
				if (text == null)
					refuse_labels(name, labels);
			}

			push(target.lines, name + text + ' ' + v);
			if (counter)
				push(target.values, v);
		}
	}

	function add(families) {
		for (let fam in families) {
			count += length(fam.samples);
			if (count > cap)
				stop(fam.name);
			if (!add_family(set, as_lines(fam)))
				push(conflicts, fam.name);
		}
	}

	return {
		counter: (name, help) => family(name, 'counter', help),
		gauge: (name, help) => family(name, 'gauge', help),
		untyped: (name, help) => family(name, 'untyped', help),
		batch,
		labels: function(labels) {
			let text = (type(labels) == 'object' || labels == null) ? label_text(labels) : null;

			if (text == null)
				refuse_labels(null, labels);
			made[text] = text;
			return text;
		},

		parse: function(text) {
			let res = parse(text);

			if (!res.ok)
				return res;

			add(res.data);
			return Result.ok();
		},

		add,

		families: () => families_of(set),
		conflicts: () => uniq(conflicts),
		over: () => over,
		invalid: () => bad,
	};
};

function render_into(parts, names, families, omit) {
	for (let fam in families) {
		let name = fam.name;

		if (names)
			push(names, name);

		let lines = fam.lines ?? map(fam.samples, sample_line);

		if (omit && fam.type == 'counter') {
			let values = fam.values ?? map(fam.samples, (s) => s.value);
			let kept = [];

			for (let i, line in lines)
				if (+values[i] != 0)
					push(kept, line);

			lines = kept;
		}

		let n = length(lines);

		if (!n)
			continue;

		let help = fam.help;
		let body = (n == 1) ? lines[0] : join('\n', lines);

		if (!help)
			push(parts, '# TYPE ', name, ' ', fam.type, '\n', body, '\n');
		else if (type(help) != 'string' || index(help, '\\') >= 0 || index(help, '\n') >= 0)
			push(parts, header(fam), '\n', body, '\n');
		else
			push(parts, '# HELP ', name, ' ', help, '\n# TYPE ', name, ' ', fam.type, '\n', body, '\n');
	}
}

/**
 * The text of families as a recorder keeps them, or as parse() gives them.
 *
 * @param {(RecordedFamily|Family)[]} families the families.
 * @param {?{ omit_zero_counters: ?boolean }} opts the options; null for none.
 * @returns {string} the text, each line ended by a newline; '' for none.
 */
export function render(families, opts) {
	let parts = [];

	render_into(parts, null, families, opts?.omit_zero_counters);
	return join('', parts);
};

/**
 * A collector's families as a scrape keeps its run: their names, and their text.
 *
 * @param {RecordedFamily[]} families the collector's families.
 * @param {?boolean} omit omit_zero_values.
 * @returns {{ families: string[], text: string }} its families' names, and their text.
 */
export function pack(families, omit) {
	if (!length(families))
		return { families: [], text: '' };

	let names = [];
	let parts = [];

	render_into(parts, names, families, omit);
	return { families: names, text: join('', parts) };
};

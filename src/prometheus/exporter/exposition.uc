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
		named(name);
		name = METRIC_NAMES[name] ?? ((type(name) == 'string' && match(name, METRIC_NAME)) ? name : sanitize(name));

		let target = set.by_name[name];

		if (!target) {
			target = set.by_name[name] = { name, type: mtype, help: help_of(name, help), lines: [], values: [] };
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

		for (let r in rows)
			if (type(r[1]) == 'string')
				push(helps, r[1]);

		let joined = join('', helps);
		let read = match(joined, HIGH_BYTE) != null || index(joined, '\0') >= 0;
		let counter = (mtype == 'counter');

		for (let r in rows) {
			let name = r[0], help = r[1], value = r[2], labels = r[3];

			named(name);
			name = METRIC_NAMES[name] ?? ((type(name) == 'string' && match(name, METRIC_NAME)) ? name : sanitize(name));

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

/**
 * The text of families as a recorder keeps them, or as parse() gives them.
 *
 * @param {(RecordedFamily|Family)[]} families the families.
 * @param {?{ omit_zero_counters: ?boolean }} opts the options; null for none.
 * @returns {string} the text, each line ended by a newline; '' for none.
 */
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

		if (!length(lines))
			continue;

		let help = fam.help;

		if (help && (type(help) != 'string' || index(help, '\\') >= 0 || index(help, '\n') >= 0))
			push(parts, header(fam), join('\n', lines));
		else
			push(parts, (help ? '# HELP ' + fam.name + ' ' + help + '\n# TYPE ' : '# TYPE ') + fam.name + ' ' + fam.type, join('\n', lines));
	}

	return length(parts) ? join('\n', parts) + '\n' : '';
};

/**
 * A collector's families as a scrape keeps its run: their names, and their text.
 *
 * @param {RecordedFamily[]} families the collector's families.
 * @param {?boolean} omit omit_zero_values.
 * @returns {{ families: string[], text: string }} its families' names, and their text.
 */
export function pack(families, omit) {
	let names = [];

	for (let f in families)
		push(names, f.name);

	return { families: names, text: render(families, { omit_zero_counters: omit }) };
};

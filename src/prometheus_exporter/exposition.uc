/**
 * The Prometheus text exposition format, version 0.0.4.
 *
 * A family is { name, type, help, samples }; a sample is { name, labels, value, ts }
 * with labels as [ name, value ] pairs in order and value and ts already spelled
 * as the format wants them. A collector records its families (recorder), and
 * its run carries their text (pack, render): a family is one collector's
 * (prometheus_exporter.ownership), so the reply is each collector's text one
 * after the other, with nothing to merge. parse() reads the format back,
 * strictly (prometheus_exporter.exposition.parse): textfile uses it for *.prom
 * files, the tests for every scrape they make. How names, values and labels
 * are spelled is prometheus_exporter.exposition.format's.
 *
 * It is the format's module for every other: the modules of exposition/
 * are its own, and what others take of them it exports (TYPES, sanitize,
 * format_value, escape_label, parse).
 *
 * A recorded sample also has its `line`, written when it is recorded: every
 * operation of ucode's VM costs about a microsecond on a router's CPU, and a
 * scrape writes thousands of samples, so a sample costs as few as can be. A
 * collector that writes several families of the same labels (a device's
 * statistics, a station's) makes them once with labels() and passes that:
 * they are then checked and written once, not once per family.
 *
 * @module prometheus_exporter_exposition
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as format from 'prometheus_exporter.exposition.format';
import * as parser from 'prometheus_exporter.exposition.parse';
import { METRIC_NAMES, LABEL_PREFIXES, SPECIAL, label_text, label_problem, utf8_valid, sample_line, header, add_family, family_set, families_of } from 'prometheus_exporter.exposition.format';

/**
 * A sample as parse() reads it: its name, its labels as [ name, value ]
 * pairs in order, and its value and timestamp as the format spells them.
 *
 * @typedef {{ name: string, labels: string[][], value: string, ts: ?string }} Sample
 */

/**
 * A family as parse() reads it: { name, type, help, samples }, type one of
 * TYPES.
 *
 * @typedef {{ name: string, type: string, help: ?string, samples: Sample[] }} Family
 */

/**
 * A family as a recorder keeps it: each sample as the line the format writes,
 * and for a counter the values, which render()'s omit_zero_counters reads.
 *
 * @typedef {{ name: string, type: string, help: ?string, lines: string[], values: string[] }} RecordedFamily
 */

/**
 * What counter(), gauge() and untyped() return: (labels, value) records a
 * sample and returns itself, so samples chain. `labels` is an object, or
 * what labels() made of one, or null for none; `value` is anything, and is
 * skipped when it is not a number (format_value).
 *
 * @typedef {(labels: ?(Object|string), value: *) => SampleWriter} SampleWriter
 */

/**
 * What a collector writes to, as recorder() makes it: what collect() gets as
 * `out`.
 *
 * @typedef {{
 *   counter: (name: string, help: ?string) => SampleWriter,
 *   gauge: (name: string, help: ?string) => SampleWriter,
 *   untyped: (name: string, help: ?string) => SampleWriter,
 *   labels: (labels: ?Object) => string,
 *   parse: (text: string) => Result<null>,
 *   add: (families: Family[]) => void,
 *   families: () => RecordedFamily[],
 *   conflicts: () => string[],
 *   over: () => ?{ family: string, samples: int },
 *   invalid: () => ?{ family: string, label: ?string, why: string }
 * }} Recorder
 */

// The format's types, a name made valid, a value as the format spells it, a
// label value escaped, and exposition text read back.
export const TYPES = format.TYPES;
export const sanitize = format.sanitize;
export const format_value = format.format_value;
export const escape_label = format.escape_label;
export const parse = parser.parse;

// A family of parse() ({ samples }) as a recorder keeps one: its samples as
// lines, and a counter's values, which omit_zero_counters reads.
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

// The samples of a family declared again with another type: dropped, as
// conflicts() says.
function dropped(labels, value) {
	return dropped;
}

/**
 * What a collector writes to. counter/gauge/untyped(name, help) returns
 * (labels, value) => itself, so samples chain; a value that is not a number is
 * skipped. labels(labels) is the labels for several samples (a station's,
 * a device's), written once: pass it where the labels go. parse(text) adds
 * exposition text, which must be valid as a whole; add(families) adds what
 * parse() gave.
 *
 * A family it records is { name, type, help, lines, values }: each sample as
 * the line the format writes, and for a counter the values, which render()'s
 * omit_zero_counters reads.
 *
 * It takes at most `max` samples (none: no limit). The sample past them is not
 * recorded, and stops the collector: it throws, and so does every sample after
 * it, should the collector catch that. over() is then { family, samples }: the
 * family it was writing and the samples it had written with that one, or null
 * while it is under. A runaway costs neither the time nor the memory of what it
 * would have gone on writing.
 *
 * It takes nothing that would have Prometheus refuse the whole scrape, every
 * collector's samples with it: a label value or HELP text that is not valid
 * UTF-8, two label names that are one once sanitized, or labels that are
 * neither an object nor what labels() made (a string of the collector's own
 * would be written as it is, a line of whatever it holds). That stops the
 * collector as the sample past `max` does, and invalid() is then { family,
 * label, why }, or null while there is none.
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
	// The label sets labels() made, each its own text: the only strings taken
	// where labels go.
	let made = { '': '' };

	function stop(name) {
		if (bad == null)
			over ??= { family: name, samples: count };
		die(bad ? INVALID : OVER_LIMIT);
	}

	// Stops the collector at text Prometheus refuses; every sample after it
	// stops it again (stop()), should it catch that.
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
		if (type(help) == 'string' && !utf8_valid(help))
			refuse(name, null, 'its HELP text is not valid UTF-8');
		return help;
	}

	// As add_family() would add an empty family, without making it first:
	// netstat and ethtool make hundreds of families.
	function family(name, mtype, help) {
		name = METRIC_NAMES[name] ?? sanitize(name);

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

		// The text a sample's line starts with when it has labels.
		let head = name + '{';

		// labels: an object, or what labels() made of one. An object of
		// strings whose names label_text() has written already, as they are
		// (LABEL_PREFIXES), with nothing in its values to escape or to read
		// as UTF-8, is written here, without a call: what label_text() would
		// write of it. Any other is label_text()'s.
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

				if (vals != null && text != '' && !match(vals, SPECIAL)) {
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

		// For a caller that read the text itself, so it is not read twice.
		add,

		families: () => families_of(set),
		conflicts: () => uniq(conflicts),
		over: () => over,
		invalid: () => bad,
	};
};

/**
 * The text of families as a recorder keeps them, or as parse() gives them. opts.omit_zero_counters leaves out counter samples whose value
 * is 0 (the lua exporter's omit_zero_values). A family left without samples
 * is not written.
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

		if (length(lines))
			push(parts, header(fam), join('\n', lines));
	}

	return length(parts) ? join('\n', parts) + '\n' : '';
};

/**
 * A collector's families as a scrape keeps its run: { families, text }, the
 * families' names, which a scrape needs to say whose each family is
 * (prometheus_exporter.ownership), and the text render() writes of them,
 * with `omit` (omit_zero_values). The reply is the text of each collector,
 * one after the other: a family is one collector's, so the reply has it once
 * without a merge.
 *
 * @param {RecordedFamily[]} families the collector's families.
 * @param {?boolean} omit omit_zero_values.
 * @returns {{ families: string[], text: string }} its families' names, and
 *   their text.
 */
export function pack(families, omit) {
	let names = [];

	// A loop, not map(): a function call for each of hundreds of families,
	// and a name each, not an object, which costs ucode a table.
	for (let f in families)
		push(names, f.name);

	return { families: names, text: render(families, { omit_zero_counters: omit }) };
};

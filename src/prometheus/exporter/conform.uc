/**
 * `prometheus-exporter collector check <path>`: whether a module keeps the contract.
 *
 * @module prometheus_exporter_conform
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as loader from 'prometheus.exporter.loader';
import * as config from 'prometheus.exporter.config';
import * as scrape from 'prometheus.exporter.scrape';
import * as exposition from 'prometheus.exporter.exposition';

/**
 * What `collector check` takes of the system, and load_timeout.
 *
 * @typedef {{
 *   fs: module:fs,
 *   uci: UciCursor,
 *   env: ScrapeEnv,
 *   import_path: function(string): CollectorModule,
 *   probe: function(string, function(string): CollectorModule): ProbeOutcome,
 *   installed: Collector[],
 *   clock: () => int[],
 *   load_timeout: int
 * }} ConformSys
 */

const LABELS = { ok: 'ok  ', warn: 'warn', fail: 'FAIL' };

const FAMILIES_SHOWN = 8;

/** What a run fails with that breaks the contract, whatever the device. */
export const BROKEN = [
	errors.COLLECTOR_CANCELLED, errors.COLLECTOR_KILLED, errors.SAMPLE_LIMIT, errors.FAMILY_CONFLICT,
	errors.COLLECTOR_CRASHED, errors.COLLECTOR_NO_RESULT, errors.SCRAPE_DEADLINE, errors.CONFIG_INVALID,
	errors.COMMAND_NOT_ALLOWED,
];

/**
 * A module's file's name, less .uc: its module name, which meta.name follows.
 *
 * @param {?string} path
 * @returns {?string}
 */
export function id_of_path(path) {
	let m = match(path ?? '', /(^|\/)([^\/]+)\.uc$/);

	return m ? m[2] : null;
};

function writers(runs) {
	let out = {};

	for (let r in runs)
		for (let f in r?.families ?? [])
			push(out[f] ??= [], r.name);

	return out;
}

/**
 * { ok, report }: ok unless a rule is broken.
 *
 * @param {ConformSys} sys
 * @param {string} path
 * @returns {{ ok: boolean, report: string }}
 */
export function run(sys, path) {
	let lines = [];
	let ok = true;
	let add = function(level, text) {
		if (level == 'fail')
			ok = false;
		push(lines, `${LABELS[level]} ${text}`);
	};
	let done = () => ({ ok, report: join('\n', lines) });
	let id = id_of_path(path);

	if (id == null || !match(id, /^[a-z0-9_]+$/)) {
		add('fail', `${path}: a collector is a file <module>.uc, its module named of a-z, 0-9 and _`);
		return done();
	}

	let real = sys.fs.realpath(path);
	let text = real ? sys.fs.readfile(real) : null;

	if (text == null) {
		add('fail', `${path}: cannot be read`);
		return done();
	}

	if (!loader.is_strict(text)) {
		add('fail', "strict mode: its first statement must be 'use strict'");
		return done();
	}
	add('ok', "strict mode: 'use strict' first");

	let why = loader.import_problem(text);

	if (why != null) {
		add('fail', why);
		return done();
	}
	add('ok', `imports: ${loader.API} alone`);

	why = loader.purity_problem(text);

	if (why != null) {
		add('fail', why);
		return done();
	}
	add('ok', 'top level: declarations alone');

	let load = () => sys.import_path(real);
	let probed = sys.probe(id, load);

	if (probed?.hung) {
		add('fail', `load: ${probed.error}: its top level must only declare, in at most ${sys.load_timeout} s`);
		return done();
	}
	if (!probed?.ok) {
		add('fail', `load: ${probed?.error ?? 'it does not load'}`);
		return done();
	}
	add('ok', sprintf('load: %.3f s, of at most %d s', probed.seconds, sys.load_timeout));

	let mod = load();
	let valid = loader.validate(id, mod);

	if (!valid.ok) {
		add('fail', `meta: ${Result.describe(valid)}`);
		return done();
	}

	let c = valid.data;
	let settings = config.settings(sys.uci, c.id, c.meta);

	add('ok', `meta: ${c.meta.name} (${c.meta.title}), needs ${join(' ', c.meta.needs) || 'nothing'}` +
		(settings.ok ? `, budget ${settings.data.budget} s, max_samples ${settings.data.max_samples}` : ''));

	let others = filter(sys.installed, (x) => x.id != c.id);
	let enabled = filter(others, (x) => config.enabled(sys.uci, x.id));
	let r = scrape.trial(sys.env, sys.uci, null, [ c ], [ ...others, c ])[0];
	let res = r.result;
	let run_line = sprintf('run: %.3f s, %d sample%s in %d famil%s', r.duration, r.samples, (r.samples == 1) ? '' : 's',
		length(r.families), (length(r.families) == 1) ? 'y' : 'ies');

	if (Result.is_none(res))
		add('warn', `${run_line}: nothing to observe on this device: ${res.none}`);
	else if (res.ok)
		add('ok', run_line);
	else
		add((res.error in BROKEN) ? 'fail' : 'warn', `${run_line}: ${Result.describe(res)}` +
			((res.error in BROKEN) ? '' : ' (on this device: it may do its job on another)'));

	if (length(r.families)) {
		let names = r.families;
		let shown = slice(names, 0, FAMILIES_SHOWN);

		add('ok', `families: ${join(' ', shown)}` + ((length(names) > length(shown)) ? `, and ${length(names) - length(shown)} more` : ''));

		let parsed = exposition.parse(r.text);

		if (parsed.ok)
			add('ok', 'exposition: valid text, each series once');
		else
			add('fail', `exposition: ${Result.describe(parsed)}`);

		let written = writers(scrape.trial(sys.env, sys.uci, null, enabled, others));

		for (let f in r.families)
			if (written[f])
				add('fail', `family ${f}: written by the installed ${join(', ', written[f])} too; the first of the reply keeps it`);
	}

	return done();
};

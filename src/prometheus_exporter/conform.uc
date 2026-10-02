'use strict';

// `prometheus-exporter collector check <path>`: whether a collector module,
// one not installed yet, keeps the collector contract, checked as the
// exporter would load and run it on this device. For whoever writes one.
//
// It loads the module under the load timer (probe.probe, LOAD_TIMEOUT),
// validates its meta, and runs it under the guards a scrape runs it under: in
// a process of its own, stopped at its budget, at most its max_samples
// (scrape.trial); then it checks what it wrote is valid exposition text, each
// series once, and that no family is one an installed collector writes, nor
// one the exporter keeps for itself. It says how long it took to load and to
// run, how many samples it wrote, and in which families.
//
// A rule broken fails it (FAIL); a collector that fails on this device for
// what the device has or lacks (a file, a service, a program: SOURCE_*,
// UBUS_*, COMMAND_*, NEED_MISSING) only warns, as it may do its job on
// another; so does one with nothing to observe here.
//
// sys: { fs: { readfile, realpath }, uci: a cursor, env: a scrape env (app.scrape_env),
//        import_path(path) -> the module's exports, probe(id, import_fn) -> probe.probe's
//        entry for it, installed: the loaded collectors, clock() -> [ s, ns ] }

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as loader from 'prometheus_exporter.loader';
import * as config from 'prometheus_exporter.config';
import * as scrape from 'prometheus_exporter.scrape';
import * as exposition from 'prometheus_exporter.exposition';

const LABELS = { ok: 'ok  ', warn: 'warn', fail: 'FAIL' };

// The families the report names, at most: a line, not a page.
const FAMILIES_SHOWN = 8;

// What a run fails with that breaks the contract, whatever the device: the
// exporter stopped it, or it did not answer as a collector does.
export const BROKEN = [
	errors.COLLECTOR_CANCELLED, errors.COLLECTOR_KILLED, errors.SAMPLE_LIMIT, errors.FAMILY_CONFLICT,
	errors.COLLECTOR_CRASHED, errors.COLLECTOR_NO_RESULT, errors.SCRAPE_DEADLINE, errors.CONFIG_INVALID,
	errors.COMMAND_NOT_ALLOWED,
];

// A module's file's name, less .uc: its module name, which meta.name follows.
export function id_of_path(path) {
	let m = match(path ?? '', /(^|\/)([^\/]+)\.uc$/);

	return m ? m[2] : null;
};

// The families each installed collector of `runs` writes, by name:
// { family: [ collector ] }.
function writers(runs) {
	let out = {};

	for (let r in runs)
		for (let f in r?.families ?? [])
			push(out[f.name] ??= [], r.name);

	return out;
}

// { ok, report }: ok unless a rule is broken.
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
		let names = map(r.families, (f) => f.name);
		let shown = slice(names, 0, FAMILIES_SHOWN);

		add('ok', `families: ${join(' ', shown)}` + ((length(names) > length(shown)) ? `, and ${length(names) - length(shown)} more` : ''));

		let parsed = exposition.parse(r.text);

		if (parsed.ok)
			add('ok', 'exposition: valid text, each series once');
		else
			add('fail', `exposition: ${Result.describe(parsed)}`);

		let written = writers(scrape.trial(sys.env, sys.uci, null, enabled, others));

		for (let f in r.families)
			if (written[f.name])
				add('fail', `family ${f.name}: written by the installed ${join(', ', written[f.name])} too; the first of the reply keeps it`);
	}

	return done();
};

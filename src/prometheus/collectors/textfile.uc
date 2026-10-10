'use strict';

import { Result, exposition } from 'prometheus.exporter';

export const meta = {
	name: 'textfile',
	title: 'Text files',
	help: 'Metrics from *.prom files in a directory, as node_exporter\'s textfile collector.',
	needs: [ 'fs', 'log' ],
	options: {
		directory: {
			default: '/var/prometheus', title: 'Metrics directory', datatype: 'owned_directory',
			help: 'The directory of the *.prom files, under /var, /tmp or /etc/prometheus-exporter.',
		},
	},
	paths: [ { path: '{directory}', owned: true } ],
};

const OWN = [ 'node_textfile_mtime_seconds', 'node_textfile_scrape_error' ];

function series_key(s) {
	let pairs = sort([ ...s.labels ], (a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);

	return s.name + sprintf('%J', pairs);
}

function misfit(families, types, series) {
	let keys = [];

	for (let fam in families) {
		if (fam.name in OWN)
			return `writes this collector's own ${fam.name}`;
		if (types[fam.name] && types[fam.name] != fam.type)
			return `gives ${fam.name} type ${fam.type}, an earlier file ${types[fam.name]}`;

		for (let s in fam.samples) {
			let k = series_key(s);
			if (series[k] || k in keys)
				return `repeats a series of ${s.name}`;
			push(keys, k);
		}
	}

	for (let fam in families)
		types[fam.name] = fam.type;
	for (let k in keys)
		series[k] = true;

	return null;
}

function problem(text, st, parsed, types, series) {
	if (st == null)
		return 'cannot be stat()ed';
	if (st.type != 'file')
		return `is not a regular file (${st.type}): not read`;
	if (text == null)
		return 'cannot be read';
	if (!parsed.ok)
		return Result.describe(parsed);

	return misfit(parsed.data, types, series);
}

export function collect(deps, out, options) {
	let fs = deps.fs;
	let dir = rtrim(options.directory, '/');
	let files = sort(fs.glob(`${dir}/*.prom`) ?? []);
	let types = {}, series = {};
	let mtimes = [];
	let failed = false;

	for (let path in files) {
		let st = fs.stat(path);
		let text = (st?.type == 'file') ? fs.readfile(path) : null;
		let parsed = text == null ? null : exposition.parse(text);
		let why = problem(text, st, parsed, types, series);

		if (why != null) {
			deps.log(`skipped ${path}: ${why}`);
			failed = true;
			continue;
		}

		out.add(parsed.data);
		push(mtimes, [ path, st.mtime ]);
	}

	let mtime = out.gauge('node_textfile_mtime_seconds', 'Unixtime mtime of textfiles successfully read.');
	for (let m in mtimes)
		mtime({ file: m[0] }, m[1]);

	out.gauge('node_textfile_scrape_error', '1 if there was an error opening or reading a file, 0 otherwise.')(null, failed);

	return Result.ok();
};

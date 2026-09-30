'use strict';

// node_exporter's textfile collector: the metrics in every *.prom file in a
// directory (option `directory`, /var/prometheus by default), the time each
// file was last changed, and whether any file could not be used.
//
// As in node_exporter, a file that cannot be used is left out whole and the
// collector still succeeds: node_textfile_scrape_error is 1, and no
// node_textfile_mtime_seconds is written for that file. A file cannot be used
// when it cannot be read, is not valid exposition text, gives a family a type
// an earlier file gave another one, repeats a series an earlier file has, or
// writes one of this collector's own families. A missing directory is no files,
// not an error. Unlike node_exporter, samples with timestamps are kept, as the
// Lua exporter kept them.

import * as Result from 'node_exporter.result';
import * as exposition from 'node_exporter.exposition';

export const meta = {
	name: 'textfile',
	help: 'Metrics from *.prom files in a directory, as node_exporter\'s textfile collector.',
	needs: [ 'fs' ],
	options: { directory: '/var/prometheus' },
};

const OWN = [ 'node_textfile_mtime_seconds', 'node_textfile_scrape_error' ];

function series_key(s) {
	let pairs = sort([ ...s.labels ], (a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);

	return s.name + sprintf('%J', pairs);
}

// Whether the families of one file fit with those of the files already added
// (`types`: family name to type, `series`: the series keys); if so, they are
// recorded there.
function fits(families, types, series) {
	let keys = [];

	for (let fam in families) {
		if (fam.name in OWN || (types[fam.name] && types[fam.name] != fam.type))
			return false;

		for (let s in fam.samples) {
			let k = series_key(s);
			if (series[k] || k in keys)
				return false;
			push(keys, k);
		}
	}

	for (let fam in families)
		types[fam.name] = fam.type;
	for (let k in keys)
		series[k] = true;

	return true;
}

export function collect(deps, out, options) {
	let fs = deps.fs;
	let dir = rtrim(options.directory, '/');
	let files = sort(fs.glob(`${dir}/*.prom`) ?? []);
	let types = {}, series = {};
	let mtimes = [];
	let failed = false;

	for (let path in files) {
		let text = fs.readfile(path);
		let st = fs.stat(path);
		let parsed = text == null ? null : exposition.parse(text);

		if (!parsed?.ok || st == null || !fits(parsed.data, types, series) || !out.parse(text).ok) {
			failed = true;
			continue;
		}

		push(mtimes, [ path, st.mtime ]);
	}

	let mtime = out.gauge('node_textfile_mtime_seconds', 'Unixtime mtime of textfiles successfully read.');
	for (let m in mtimes)
		mtime({ file: m[0] }, m[1]);

	out.gauge('node_textfile_scrape_error', '1 if there was an error opening or reading a file, 0 otherwise.')(null, failed);

	return Result.ok();
};

'use strict';

// What each program of the package loads, by its static imports: the
// handler, which uhttpd runs per scrape, and the rpcd plugin, which rpcd
// keeps loaded, never load the command line's parser.

import { describe, it, assert } from 'utest';
import { readfile } from 'fs';

const IMPORT = /(^|\n)[ \t]*import[^'"\n;]*from[ \t]*(['"])([^'"]+)['"]/g;

// The module names a source imports.
function imports_of(text) {
	return map(match(text ?? '', IMPORT) ?? [], (m) => m[3]);
}

// Every module `path`'s program loads, statically: its imports, and theirs,
// of the exporter's own modules, followed into src/.
function loaded_by(path) {
	let seen = {};
	let queue = imports_of(readfile(path));

	while (length(queue)) {
		let name = shift(queue);

		if (seen[name])
			continue;
		seen[name] = true;

		if (substr(name, 0, 20) == 'prometheus_exporter.')
			push(queue, ...imports_of(readfile(`src/${replace(name, '.', '/')}.uc`)));
	}

	return sort(keys(seen));
}

describe('what the programs load', () => {
	it('finds the imports it follows', () => {
		assert.match(true, 'prometheus_exporter.app' in loaded_by('files/usr/libexec/prometheus-exporter/handler.uc'));
		assert.match(true, 'docopt' in loaded_by('files/usr/bin/prometheus-exporter'));
	});

	it('never loads docopt in the handler, rpcd or the helpers rpcd runs', () => {
		for (let path in [
			'files/usr/libexec/prometheus-exporter/handler.uc',
			'files/usr/share/rpcd/ucode/prometheus-exporter.uc',
			'files/usr/libexec/prometheus-exporter/rpc-status.uc',
			'files/usr/libexec/prometheus-exporter/probe.uc',
		])
			assert.match(false, 'docopt' in loaded_by(path), path);
	});
});

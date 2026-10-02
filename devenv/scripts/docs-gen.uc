#!/usr/bin/ucode
'use strict';

// make docs-gen, and the check in make lint: writes the reference pages the
// code holds as data (docs/reference/collectors.md, metrics.md, uci-config.md,
// error-codes.md and command.md) from the collectors' meta, the package Makefile,
// config.uc and errors.uc, with docs/gen/notes.uc for what the code does not
// say. The metrics are what the collectors write on the fixture sets of
// test/fixtures/. Run from the repository root, on OpenWrt's ucode:
//
//   ucode -L src -L test -L devenv/scripts devenv/scripts/docs-gen.uc [--check]
//
// --check writes nothing, and fails when a page is not what it would write.
// Both fail, writing nothing, when the notes contradict the code.

import * as fs from 'fs';
import * as main from 'docs_gen.main';

const check = ARGV[0] == '--check';

if (length(ARGV) > (check ? 1 : 0)) {
	warn('usage: docs-gen.uc [--check]\n');
	exit(2);
}

const res = main.run(fs, main.load_notes(`${fs.getcwd()}/${main.NOTES}`));

if (length(res.problems)) {
	warn(`docs-gen: ${main.NOTES} and the code disagree:\n`);
	for (let p in res.problems)
		warn(`  ${p}\n`);
	exit(1);
}

const stale = main.stale(fs, res.pages);

if (check) {
	for (let path in stale)
		warn(`${path} is out of date: run make docs-gen\n`);
	exit(length(stale) ? 1 : 0);
}

for (let path in stale) {
	if (!fs.writefile(path, res.pages[path])) {
		warn(`docs-gen: cannot write ${path}: ${fs.error()}\n`);
		exit(1);
	}
	print(`wrote ${path}\n`);
}

'use strict';

// What the package Makefile (openwrt/ucode-prometheus-exporter/Makefile)
// declares of the collectors, read as devenv/scripts/package-info.sh reads it:
// the version, the base package's collectors, a subpackage per other
// collector, and the group packages.

export const MAKEFILE = 'openwrt/ucode-prometheus-exporter/Makefile';

function words(s) {
	return filter(split(trim(s ?? ''), /[ \t]+/), (w) => w != '');
}

function field(text, name) {
	let m = match(text, regexp(`(^|\n)${name}:=([^\n]*)`));

	return m ? trim(m[2]) : null;
}

// A list variable's words, with each $(X_GROUP) it names expanded.
function expand(vars, value, depth) {
	let out = [];

	if (depth > 8)
		die(`${MAKEFILE}: a group list names itself`);

	for (let w in words(value)) {
		let m = match(w, /^\$\(([A-Z_]+)\)$/);

		if (m)
			push(out, ...expand(vars, vars[m[1]] ?? '', depth + 1));
		else
			push(out, w);
	}

	return out;
}

// { name, version, release, base: [ module ], collectors: { module: { name,
// what, depends } }, groups: [ { name, purpose, members: [ collector name ] } ] }
// of the Makefile's text.
export function parse(text) {
	let vars = {};
	let collectors = {};
	let groups = [];

	for (let line in split(text, '\n')) {
		let v = match(line, /^([A-Z_]+_GROUP):=(.*)$/);

		if (v) {
			vars[v[1]] = v[2];
			continue;
		}

		let c = match(line, /^\$\(eval \$\(call Collector,([^,]*),([^,]*),([^,]*),(.*)\)\)$/);

		if (c) {
			collectors[c[1]] = { name: c[2], what: c[3], depends: words(c[4]) };
			continue;
		}

		let g = match(line, /^\$\(eval \$\(call Group,([^,]*),([^,]*),(.*)\)\)$/);

		if (g)
			push(groups, { name: g[1], purpose: g[2], list: g[3] });
	}

	for (let g in groups) {
		g.members = expand(vars, g.list, 0);
		delete g.list;
	}

	return {
		name: field(text, 'PKG_NAME'),
		version: field(text, 'PKG_VERSION'),
		release: field(text, 'PKG_RELEASE'),
		base: words(field(text, 'BASE_COLLECTORS')),
		collectors,
		groups,
	};
};

// Where the collector of module `id` (named `name`) is: { package, base,
// depends, groups }; the package's name, whether it is the base package, the
// subpackage's own dependencies, and the group packages that install it.
// Null for a collector the Makefile does not package.
export function placement(pkg, id, name) {
	let groups = map(filter(pkg.groups, (g) => name in g.members), (g) => `${pkg.name}-${g.name}`);

	if (id in pkg.base)
		return { package: pkg.name, base: true, depends: [], groups };

	let sub = pkg.collectors[id];

	if (!sub)
		return null;

	return { package: `${pkg.name}-${sub.name}`, base: false, depends: sub.depends, groups };
};

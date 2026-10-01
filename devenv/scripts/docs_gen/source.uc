'use strict';

// What the generator reads off the source text, where the code holds it in
// statements rather than in data: the families a collector declares by a
// literal name, the reasons it gives for nothing to observe, and the error
// codes of errors.uc and where they are raised.

const DECLARATION = /out\.(gauge|counter|untyped)\(\s*'([a-zA-Z_:][a-zA-Z0-9_:]*)'(\s*,\s*'(([^'\\]|\\.)*)'\s*\))?/g;
const NONE = /Result\.none\(\s*'([^'\\]*)'/g;
const SERVICE = /services\.(unless_disabled|idle)\(\s*[^,]+,\s*'([^']+)'/g;

// [ { name, type, help } ] of the families `text` declares with a literal name,
// as out.gauge('node_load1', '1m load average.') does, once each, in order;
// help is null unless it is a literal too.
export function declared(text) {
	let out = [];
	let seen = {};

	for (let m in match(text, DECLARATION) ?? []) {
		if (seen[m[2]])
			continue;
		seen[m[2]] = true;
		push(out, { name: m[2], type: m[1], help: (m[4] != null) ? replace(m[4], /\\(.)/g, '$1') : null });
	}

	return out;
};

// Whether a collector's `text` can answer that it has nothing to observe.
export function has_none(text) {
	return match(text, /Result\.none\(|services\.(unless_disabled|idle)\(/) != null;
};

// The reasons a collector's `text` gives for nothing to observe: its literal
// Result.none() reasons, and for each service it asks rpcd's rc about, what
// prometheus_exporter.services says of one that is not enabled.
export function reasons(text, states) {
	let out = [];

	for (let m in match(text, NONE) ?? [])
		push(out, m[1]);

	for (let m in match(text, SERVICE) ?? [])
		for (let s in states)
			push(out, `${m[2]} is ${s}`);

	return uniq(out);
};

// [ { group, codes: [ code ] } ] of errors.uc's text: each `export const` in
// the group its comment above names.
export function error_codes(text) {
	let groups = [];
	let group = null;

	for (let line in split(text, '\n')) {
		let c = match(line, /^\/\/ (.+)$/);

		if (c) {
			group = { group: c[1], codes: [] };
			push(groups, group);
			continue;
		}

		let e = match(line, /^export const ([A-Z0-9_]+)\s*=/);

		if (e) {
			if (!group)
				die('errors.uc: a code before any group comment');
			push(group.codes, e[1]);
		}
	}

	// Comments above no code, as the file's own heading, are no group.
	return filter(groups, (g) => length(g.codes));
};

// Whether `text` raises error `code`: errors.<code> as a word.
export function raises(text, code) {
	return match(text, regexp(`errors\\.${code}([^A-Z0-9_]|$)`)) != null;
};

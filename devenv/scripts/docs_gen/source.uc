'use strict';

// What the generator reads off the source text, where the code holds it in
// statements rather than in data: the families a collector declares by a
// literal name, the reasons it gives for nothing to observe, and the error
// codes of errors.uc and where they are raised.

const DECLARATION = /out\.(gauge|counter|untyped)\(\s*'([a-zA-Z_:][a-zA-Z0-9_:]*)'(\s*,\s*'(([^'\\]|\\.)*)'\s*\))?/g;
// out.batch('gauge', [ [ 'node_x', 'Help.', value ], ... ]): the call, its
// type and its rows, up to the bracket that closes them; and each row's
// literal name and help in them.
const BATCH = /out\.batch\(\s*'(gauge|counter|untyped)'\s*,\s*\[(([^\]]|\][^)])*)\]\s*\)/g;
const BATCH_ROW = /\[\s*'([a-zA-Z_:][a-zA-Z0-9_:]*)'\s*,\s*'(([^'\\]|\\.)*)'/g;
const NONE = /Result\.none\(\s*'([^'\\]*)'/g;
const SERVICE = /services\.(unless_disabled|idle)\(\s*[^,]+,\s*'([^']+)'/g;

// [ { name, type, help } ] of the families `text` declares with a literal name,
// as out.gauge('node_load1', '1m load average.') does, once each, in order;
// help is null unless it is a literal too. Then those of out.batch()
// calls, a row [ 'node_x', 'Help.', value ] each, whose name and help are
// literals.
export function declared(text) {
	let out = [];
	let seen = {};

	for (let m in match(text, DECLARATION) ?? []) {
		if (seen[m[2]])
			continue;
		seen[m[2]] = true;
		push(out, { name: m[2], type: m[1], help: (m[4] != null) ? replace(m[4], /\\(.)/g, '$1') : null });
	}

	for (let b in match(text, BATCH) ?? [])
		for (let r in match(b[2], BATCH_ROW) ?? []) {
			if (seen[r[1]])
				continue;
			seen[r[1]] = true;
			push(out, { name: r[1], type: b[1], help: replace(r[2], /\\(.)/g, '$1') });
		}

	return out;
};

// Whether a collector's `text` can answer that it has nothing to observe.
export function has_none(text) {
	return match(text, /Result\.none\(|services\.(unless_disabled|idle)\(/) != null;
};

// The reasons a collector's `text` gives for nothing to observe: its literal
// Result.none() reasons, and for each service it asks rpcd's rc about, what
// prometheus.exporter.services says of one that is not enabled.
export function reasons(text, states) {
	let out = [];

	for (let m in match(text, NONE) ?? [])
		push(out, m[1]);

	for (let m in match(text, SERVICE) ?? [])
		for (let s in states)
			push(out, `${m[2]} is ${s}`);

	return uniq(out);
};

// [ code ] of errors.uc's text: each `export const`, in order.
export function error_codes(text) {
	return map(match(text, /(^|\n)export const ([A-Z0-9_]+)\s*=/g) ?? [], (m) => m[2]);
};

// Whether `text` raises error `code`: errors.<code> as a word.
export function raises(text, code) {
	return match(text, regexp(`errors\\.${code}([^A-Z0-9_]|$)`)) != null;
};

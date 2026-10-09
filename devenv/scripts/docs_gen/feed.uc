'use strict';

// What the packages feed's exporters write, read from their sources, for the
// migration page (docs/reference/migration.md, which make docs-gen writes
// from what make feed-inventory saved of it): for prometheus-node-exporter-lua and
// prometheus-node-exporter-ucode, the version, each package and the
// collectors it installs, and each collector's metric families, with the
// sha256 of its source, so that a change upstream shows.
//
// A family is a call of the Lua exporter's metric(name, type) or the ucode
// one's gauge(name) and counter(name): its name as the call has it, each part
// computed at run time `<>` (`node_memory_<>_bytes`), a Lua local string
// constant it names resolved; its type, the call's. The exporters' own,
// node_scrape_collector_*, are the collector `(scrape)`'s.
//
// A collector's `keys` are the label names it can write, and more: the keys
// of its tables and objects (`{ device = dev }`, `{ radio, ifname }`) and
// those it sets on a table of labels (`labels.mode = mode`). docs-gen checks
// that each label the migration notes give a family is one of them.
//
// devenv/scripts/feed-inventory.uc prints inventory() as JSON.

import { sha256 } from 'digest';

const LUA = 'utils/prometheus-node-exporter-lua';
const UCODE = 'utils/prometheus-node-exporter-ucode';

function read(fs, path) {
	return fs.readfile(path) ?? die(`feed-inventory: cannot read ${path}: ${fs.error()}\n`);
}

function field(text, name) {
	let m = match(text, regexp(`(^|\n)${name}:=([^\n]*)`));

	return m ? trim(m[2]) : null;
}

function version(mk) {
	return `${field(mk, 'PKG_VERSION')}-r${field(mk, 'PKG_RELEASE')}`;
}

// The text of `s` from `i` to the first `,` or `)` outside brackets and
// strings: [ text, the index of that character ].
function argument(s, i) {
	let depth = 0, quote = null, start = i;

	for (; i < length(s); i++) {
		let c = substr(s, i, 1);

		if (quote) {
			if (c == '\\')
				i++;
			else if (c == quote)
				quote = null;
		}
		else if (c == '"' || c == "'" || c == '`')
			quote = c;
		else if (c == '(' || c == '{' || c == '[')
			depth++;
		else if ((c == ')' || c == '}' || c == ']') && depth > 0)
			depth--;
		else if (depth == 0 && (c == ',' || c == ')'))
			break;
	}

	return [ trim(substr(s, start, i - start)), i ];
}

// The parts of a Lua expression joined by `..`, outside brackets and strings.
function concatenation(expr) {
	let parts = [], depth = 0, quote = null, start = 0;

	for (let i = 0; i < length(expr); i++) {
		let c = substr(expr, i, 1);

		if (quote) {
			if (c == '\\')
				i++;
			else if (c == quote)
				quote = null;
		}
		else if (c == '"' || c == "'")
			quote = c;
		else if (c == '(' || c == '{' || c == '[')
			depth++;
		else if (c == ')' || c == '}' || c == ']')
			depth--;
		else if (depth == 0 && substr(expr, i, 2) == '..') {
			push(parts, trim(substr(expr, start, i - start)));
			start = ++i + 1;
		}
	}

	push(parts, trim(substr(expr, start)));

	return parts;
}

// A family's name of a computed one's parts: each that is not a string `<>`.
function pattern(parts) {
	let out = '';

	for (let p in parts)
		if (p != '<>' || substr(out, -2) != '<>')
			out += p;

	return out;
}

function lua_string(e) {
	let m = match(e, /^"([^"\\]*)"$/) ?? match(e, /^'([^'\\]*)'$/);

	return m ? m[1] : null;
}

// The families of a Lua collector's text: each metric(name, type) call.
export function lua_families(text) {
	let constants = {};

	for (let m in match(text, /local[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*("[^"\n]*"|'[^'\n]*')/g))
		constants[m[1]] = lua_string(m[2]);

	let out = [];

	for (let i = index(text, 'metric('); i >= 0; ) {
		let before = substr(text, max(0, i - 9), min(i, 9));
		let at = i;

		i = index(substr(text, at + 7), 'metric(');
		i = i < 0 ? -1 : at + 7 + i;

		// A call, not a definition, nor a name that ends in metric.
		if (match(before, /[A-Za-z0-9_]$/) || match(before, /function[ \t]+$/))
			continue;

		let name = argument(text, at + 7);

		if (substr(text, name[1], 1) != ',')
			continue;

		let type = lua_string(argument(text, name[1] + 1)[0]);
		let parts = map(concatenation(name[0]), (p) => lua_string(p) ?? constants[p] ?? '<>');

		push(out, { name: pattern(parts), type });
	}

	return out;
};

// The families of a ucode collector's text: each gauge(name) and
// counter(name) call, a template's ${...} `<>`.
export function ucode_families(text) {
	let out = [];

	for (let m in match(text, /(^|[^A-Za-z0-9_.])(gauge|counter)[ \t]*\([ \t]*("[^"]*"|`[^`]*`)/g)) {
		let name = replace(substr(m[3], 1, length(m[3]) - 2), /\$\{[^}]*\}/g, '<>');

		push(out, { name, type: m[2] });
	}

	return out;
};

function uniq_families(list) {
	let seen = {}, out = [];

	for (let f in list) {
		let k = `${f.name} ${f.type}`;

		if (!seen[k]) {
			seen[k] = true;
			push(out, f);
		}
	}

	return sort(out, (a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
}

// The keys of the innermost tables and objects of `text`, and of those set on
// labels: `{ device = dev }` (Lua), `{ device: dev }` and `{ radio, ifname }`
// (ucode), `labels.mode = ` and `labels["mac"] = `; the line comments of
// `comment` left out.
export function keys_of(text, comment) {
	let seen = {};

	text = replace(text, comment, '');

	for (let block in match(text, /\{([^{}]*)\}/g))
		for (let entry in split(block[1], ','))
			for (let m in [ match(entry, /^[ \t\n]*\[?["']?([A-Za-z_][A-Za-z0-9_]*)["']?\]?[ \t]*[=:]/), match(entry, /^[ \t\n]*([A-Za-z_][A-Za-z0-9_]*)[ \t\n]*$/) ])
				if (m)
					seen[m[1]] = true;

	for (let m in match(text, /labels(\.([A-Za-z_][A-Za-z0-9_]*)|\[["']([A-Za-z_][A-Za-z0-9_]*)["']\])[ \t]*=[^=]/g))
		seen[m[2] || m[3]] = true;

	return sort(keys(seen));
};

function collector(fs, path, families, comment) {
	let text = read(fs, path);

	return { sha256: sha256(text), families: uniq_families(families(text)), keys: keys_of(text, comment) };
}

function lua(fs, dir) {
	let mk = read(fs, `${dir}/Makefile`);
	let packages = {};
	let collectors = {};
	let pkg = null;

	for (let line in split(mk, '\n')) {
		let d = match(line, /^define Package\/(prometheus-node-exporter-lua[^\/]*)\/install$/);

		if (d) {
			pkg = d[1];
			packages[pkg] = [];
			continue;
		}
		if (line == 'endef')
			pkg = null;

		let f = pkg && match(line, /prometheus-collectors\/([A-Za-z0-9_-]+)\.lua/);

		if (f) {
			push(packages[pkg], f[1]);
			collectors[f[1]] = collector(fs, `${dir}/files/usr/lib/lua/prometheus-collectors/${f[1]}.lua`, lua_families, /--[^\n]*/g);
		}
	}

	collectors['(scrape)'] = collector(fs, `${dir}/files/usr/bin/prometheus-node-exporter-lua`, lua_families, /--[^\n]*/g);

	return { package: field(mk, 'PKG_NAME'), version: version(mk), packages, collectors };
}

function ucode(fs, dir) {
	let mk = read(fs, `${dir}/Makefile`);
	let name = 'prometheus-node-exporter-ucode';
	let packages = { [name]: [] };
	let collectors = {};

	for (let f in sort(fs.lsdir(`${dir}/files/base`) ?? [])) {
		let id = replace(f, /\.uc$/, '');

		push(packages[name], id);
		collectors[id] = collector(fs, `${dir}/files/base/${f}`, ucode_families, /\/\/[^\n]*/g);
	}

	for (let m in match(mk, /\$\(eval \$\(call Collector,([^,]+),/g)) {
		packages[`${name}-${m[1]}`] = [ m[1] ];
		collectors[m[1]] = collector(fs, `${dir}/files/extra/${m[1]}.uc`, ucode_families, /\/\/[^\n]*/g);
	}

	collectors['(scrape)'] = collector(fs, `${dir}/files/metrics.uc`, ucode_families, /\/\/[^\n]*/g);

	return { package: name, version: version(mk), packages, collectors };
}

// { source, exporters: { lua, ucode } } of the checkout of openwrt/packages
// at `dir`, `source` saying what it is (openwrt/packages@<commit>).
export function inventory(fs, dir, source) {
	return {
		source,
		exporters: {
			lua: lua(fs, `${dir}/${LUA}`),
			ucode: ucode(fs, `${dir}/${UCODE}`),
		},
	};
};

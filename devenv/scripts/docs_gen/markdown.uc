'use strict';

// Markdown for the generated pages, as MkDocs (Python-Markdown) reads it.

// Text in a table cell or a paragraph: the characters Markdown or HTML would
// read as markup are escaped. Backticked spans are left as they are, which a
// table splits its cells around.
export function text(s) {
	let parts = split('' + (s ?? ''), '`');

	for (let i = 0; i < length(parts); i += 2)
		parts[i] = replace(replace(replace(replace(replace(parts[i], '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
			/([*_\\])/g, '\\$1'), '|', '\\|');

	return join('`', parts);
};

// A code span of `s`, with as many backticks around it as it needs.
export function code(s) {
	s = '' + s;

	let fence = '`';

	while (index(s, fence) >= 0)
		fence += '`';

	let pad = (substr(s, 0, 1) == '`' || substr(s, -1) == '`') ? ' ' : '';

	// A table finds its cells around code spans: a '|' in one stays.
	return `${fence}${pad}${s}${pad}${fence}`;
};

// Code spans of `items`, comma-separated; `none` when there are none.
export function codes(items, none) {
	return length(items) ? join(', ', map(items, code)) : (none ?? '—');
};

// A table: `head` the column titles, `rows` arrays of cells already written.
export function table(head, rows) {
	let lines = [
		`| ${join(' | ', head)} |`,
		`| ${join(' | ', map(head, () => ':---'))} |`,
	];

	for (let r in rows)
		push(lines, `| ${join(' | ', map(r, (c) => (c == null || c == '') ? '—' : c))} |`);

	return join('\n', lines);
};

// A heading with an explicit anchor (attr_list), so links survive any
// change to how MkDocs makes anchors.
export function heading(level, title, anchor) {
	let hashes = '';

	for (let i = 0; i < level; i++)
		hashes += '#';

	return anchor ? `${hashes} ${title} {#${anchor}}` : `${hashes} ${title}`;
};

// The anchor of a collector's section: its name, which may hold '-' and '_'.
export function anchor(name) {
	return replace(lc(name), /[^a-z0-9_-]/g, '-');
};

// Paragraphs, headings and tables joined into a page that ends in a newline.
export function page(blocks) {
	return join('\n\n', filter(blocks, (b) => b != null && b != '')) + '\n';
};

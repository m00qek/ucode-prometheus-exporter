/**
 * What a module's text imports and loads, read without compiling it.
 *
 * @module prometheus_exporter_loader_imports
 */

'use strict';

const KEYWORDS = [ 'import', 'require', 'loadfile', 'loadstring', 'include', 'system' ];
const CALLS = [ 'require', 'loadfile', 'loadstring', 'include', 'system' ];

const NOT_NAMED = [ 'loadstring', 'system' ];

const BEFORE_EXPRESSION = [ 'return', 'typeof', 'in', 'of', 'case', 'delete', 'void', 'throw', 'else', 'do' ];

const SLASH = 47, STAR = 42, BACKSLASH = 92, QUOTE = 39, DQUOTE = 34, BACKTICK = 96;
const OPEN_BRACKET = 91, CLOSE_BRACKET = 93, CLOSE_PAREN = 41, DOT = 46;

const COMMENT_LINE = /^[ \t]*\/\//;
const IMPORT_LINE = /^[ \t]*import[ \t]*(\*[ \t]*as[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]+from|\{[^}'"`\/]*\}[ \t]*from|[A-Za-z_$][A-Za-z0-9_$]*[ \t]+from)?[ \t]*('([^'\\\n]*)'|"([^"\\\n]*)")[ \t]*;?[ \t]*(\/\/.*)?\r?$/;

const CALL = /^[ \t]*\([ \t]*(('([^'\\]|\\.)*')|("([^"\\]|\\.)*"))?/;

function word_char(c) {
	return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 || c == 36;
}

function string_end(line, i, q) {
	let n = length(line);

	for (let j = i + 1; j < n; j++) {
		let c = ord(line, j);

		if (c == BACKSLASH)
			j++;
		else if (c == q)
			return j + 1;
	}

	return n;
}

function regex_end(line, i) {
	let n = length(line);
	let in_class = false;

	for (let j = i + 1; j < n; j++) {
		let c = ord(line, j);

		if (c == BACKSLASH)
			j++;
		else if (in_class)
			in_class = (c != CLOSE_BRACKET);
		else if (c == OPEN_BRACKET)
			in_class = true;
		else if (c == SLASH) {
			j++;
			while (j < n && word_char(ord(line, j)))
				j++;
			return j;
		}
	}

	return -1;
}

function literal(s) {
	return substr(s, 1, length(s) - 2);
}

function read_line(st, found, line, at, i) {
	let n = length(line);

	while (i < n) {
		let c = ord(line, i);

		if (c == 32 || c == 9 || c == 13) {
			i++;
			continue;
		}

		if (c == SLASH) {
			let d = ord(line, i + 1);

			if (d == SLASH)
				return;

			if (d == STAR) {
				let e = index(substr(line, i + 2), '*/');

				if (e < 0) {
					st.comment = true;
					return;
				}

				i += e + 4;
				continue;
			}

			let e = st.expression ? regex_end(line, i) : -1;

			st.expression = (e < 0);
			st.dot = false;
			i = (e < 0) ? i + 1 : e;
			continue;
		}

		if (c == QUOTE || c == DQUOTE || c == BACKTICK) {
			let e = string_end(line, i, c);

			if (st.pending != null && c != BACKTICK && ord(line, e - 1) == c && e > i + 1) {
				push(found, { at: st.pending, module: literal(substr(line, i, e - i)) });
				st.pending = null;
			}

			i = e;
			st.expression = false;
			st.dot = false;
			continue;
		}

		if (word_char(c)) {
			let j = i + 1;

			while (j < n && word_char(ord(line, j)))
				j++;

			let word = substr(line, i, j - i);

			if (!st.dot && word == 'import' && substr(ltrim(substr(line, j), ' \t'), 0, 1) != ':')
				st.pending = at + i;
			else if (!st.dot && word in CALLS) {
				let m = match(substr(line, j), CALL);

				if (m)
					push(found, { at: at + i, fn: word, module: (m[1] && !(word in NOT_NAMED)) ? literal(m[1]) : null });
			}

			i = j;
			st.expression = (word in BEFORE_EXPRESSION);
			st.dot = false;
			continue;
		}

		st.expression = !(c == CLOSE_PAREN || c == CLOSE_BRACKET);
		st.dot = (c == DOT);
		i++;
	}
}

function offsets(text, needle) {
	let out = [];
	let at = 0;
	let rest = text;

	for (let k = index(rest, needle); k >= 0; k = index(rest, needle)) {
		at += k;
		push(out, at);
		at += length(needle);
		rest = substr(rest, k + length(needle));
	}

	return out;
}

function number(text, found) {
	let line = 1, at = 0;

	for (let f in sort(found, (a, b) => a.at - b.at)) {
		line += length(split(substr(text, at, f.at - at), '\n')) - 1;
		at = f.at;
		f.line = line;
		delete f.at;
	}
}

/**
 * Each import of a module's text, and each call that loads code or runs a program.
 *
 * @param {*} text
 * @returns {{ imports: { module: string, line: int }[], loads: { fn: string, module: ?string, line: int }[] }}
 */
export function imports(text) {
	let found = [];

	if (type(text) != 'string')
		return { imports: [], loads: [] };

	let starts = [];

	for (let w in [ ...KEYWORDS, '/*' ])
		push(starts, ...offsets(text, w));

	let st = { comment: false, pending: null, expression: true, dot: false };
	let done = 0;
	let n = length(text);

	for (let p in sort(starts, (a, b) => a - b)) {
		if (p < done)
			continue;

		let start = rindex(substr(text, 0, p), '\n') + 1;
		let from = (done > start) ? done : start;

		while (true) {
			let e = index(substr(text, start), '\n');
			let end = (e < 0) ? n : start + e;
			let line = substr(text, start, end - start);
			let m = (from == start && st.pending == null) ? match(line, IMPORT_LINE) : null;

			st.expression = true;
			st.dot = false;

			if (m)
				push(found, { at: start + index(line, 'import'), module: m[3] ?? m[4] });
			else if (from > start || st.pending != null || !match(line, COMMENT_LINE))
				read_line(st, found, line, start, from - start);

			done = end + 1;

			if (st.comment) {
				let close = index(substr(text, end), '*/');

				st.comment = false;
				done = (close < 0) ? n : end + close + 2;
				break;
			}

			if (st.pending == null || end >= n)
				break;

			start = from = end + 1;
		}
	}

	number(text, found);

	return {
		imports: map(filter(found, (f) => f.fn == null), (f) => ({ module: f.module, line: f.line })),
		loads: filter(found, (f) => f.fn != null),
	};
};

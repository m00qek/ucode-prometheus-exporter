/**
 * What a collector module's top level does, read without compiling it: the purity rule.
 *
 * @module prometheus_exporter_loader_purity
 */

'use strict';

const SLASH = 47, STAR = 42, BACKSLASH = 92, QUOTE = 39, DQUOTE = 34, BACKTICK = 96, NEWLINE = 10;
const DOLLAR = 36, OPEN_BRACE = 123, CLOSE_BRACE = 125, OPEN_BRACKET = 91, CLOSE_BRACKET = 93;

const BEFORE_EXPRESSION = [ 'return', 'typeof', 'in', 'of', 'case', 'delete', 'void', 'throw', 'else', 'do' ];

const NOT_CALLEE = [
	'if', 'for', 'while', 'switch', 'catch', 'function', 'return', 'typeof', 'in', 'of', 'delete', 'void', 'do',
	'else', 'case', 'throw', 'let', 'const', 'export', 'import',
];

const PUNCTUATORS = [
	'>>>=', '...', '===', '!==', '**=', '<<=', '>>=', '>>>', '&&=', '||=', '??=',
	'=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '++', '--', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=',
	'**', '<<', '>>',
];

/** The functions of ucode a collector's top level may call. */
export const PURE = [
	'arrtoip', 'assert', 'b64dec', 'b64enc', 'chr', 'exists', 'filter', 'hex', 'hexdec', 'hexenc', 'index', 'int',
	'iptoarr', 'join', 'json', 'keys', 'lc', 'length', 'ltrim', 'map', 'match', 'max', 'min', 'ord', 'pop',
	'push', 'regexp', 'replace', 'reverse', 'rindex', 'rtrim', 'shift', 'slice', 'sort', 'splice', 'split',
	'sprintf', 'substr', 'trim', 'type', 'uc', 'uchr', 'uniq', 'unshift', 'values', 'wildcard',
];

/** The collector API's functions a collector's top level may call. */
export const PURE_API = [
	'Result.ok', 'Result.err', 'Result.none', 'Result.is', 'Result.is_none', 'Result.describe',
	'proc.fields', 'proc.auxv', 'u16', 'u32',
];

const DOES = {
	sleep: 'blocks the process',
	system: 'runs a program',
	exit: 'ends the process',
	die: 'throws: a collector whose top level throws is left out',
	print: 'writes to the process\'s output',
	printf: 'writes to the process\'s output',
	warn: 'writes to the process\'s output',
	trace: 'writes to the process\'s output',
	require: 'loads code',
	include: 'loads code',
	loadfile: 'loads code',
	loadstring: 'loads code',
	render: 'loads code, or writes',
	signal: 'changes how the process takes a signal',
	gc: 'runs the garbage collector',
	call: 'calls a function it is given',
	getenv: 'reads the environment, which is not the same in each process that loads it',
	clock: 'reads the clock, which is not the same in each process that loads it',
	time: 'reads the clock, which is not the same in each process that loads it',
	localtime: 'reads the clock, which is not the same in each process that loads it',
	gmtime: 'reads the clock, which is not the same in each process that loads it',
	timelocal: 'reads the time zone',
	timegm: 'computes a time; call it in collect()',
	sourcepath: 'reads where the module is',
	proto: 'reads or sets a prototype, which for a Result is one every collector shares',
};

const API_DOES = {
	proc: 'reads a file through deps.fs, which collect() alone gets',
	services: 'calls ubus through deps.ubus, which collect() alone gets',
	exposition: 'loads the exposition format, the first time one of its functions is called',
};

function word_char(c) {
	return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 || c == DOLLAR;
}

function space(c) {
	return c == 32 || c == 9 || c == 13 || c == NEWLINE || c == 11 || c == 12;
}

function regex_may_start(prev) {
	if (prev == null)
		return true;
	if (prev.t == 'name')
		return prev.v in BEFORE_EXPRESSION;
	if (prev.t == 'punct')
		return !(prev.v in [ ')', ']', '}' ]);

	return false;
}

function quoted_end(text, i, q, n) {
	let lines = 0, in_class = false;

	for (let j = i + 1; j < n; j++) {
		let c = ord(text, j);

		if (c == BACKSLASH) {
			if (ord(text, j + 1) == NEWLINE)
				lines++;
			j++;
		}
		else if (c == NEWLINE) {
			lines++;
			if (q == SLASH)
				return [ j, lines ];
		}
		else if (q == SLASH && in_class)
			in_class = (c != CLOSE_BRACKET);
		else if (q == SLASH && c == OPEN_BRACKET)
			in_class = true;
		else if (c == q)
			return [ j + 1, lines ];
	}

	return [ n, lines ];
}

/**
 * A module's tokens, without blank space and comments: { t, v, line }.
 *
 * @param {string} text
 * @returns {{ t: string, v: string, line: int }[]}
 */
export function tokens(text) {
	let out = [];
	let n = length(text);
	let line = 1;
	let i = 0;
	let braces = [];
	let prev = null;

	function template(from) {
		let start = line;

		for (let j = from; j < n; j++) {
			let c = ord(text, j);

			if (c == BACKSLASH)
				j++;
			else if (c == NEWLINE)
				line++;
			else if (c == BACKTICK) {
				push(out, prev = { t: 'str', v: substr(text, from, j - from), line: start });
				return j + 1;
			}
			else if (c == DOLLAR && ord(text, j + 1) == OPEN_BRACE) {
				push(out, { t: 'str', v: substr(text, from, j - from), line: start });
				push(out, prev = { t: 'punct', v: '(', line });
				push(braces, 'template');
				return j + 2;
			}
		}

		return n;
	}

	if (substr(text, 0, 2) == '#!') {
		let nl = index(text, '\n');
		i = (nl < 0) ? n : nl;
	}

	while (i < n) {
		let c = ord(text, i);

		if (space(c)) {
			if (c == NEWLINE)
				line++;
			i++;
			continue;
		}

		if (c == SLASH && ord(text, i + 1) == SLASH) {
			let e = index(substr(text, i), '\n');
			i = (e < 0) ? n : i + e;
			continue;
		}

		if (c == SLASH && ord(text, i + 1) == STAR) {
			let e = index(substr(text, i + 2), '*/');
			let body = (e < 0) ? substr(text, i + 2) : substr(text, i + 2, e);

			line += length(split(body, '\n')) - 1;
			i = (e < 0) ? n : i + e + 4;
			continue;
		}

		if (c == QUOTE || c == DQUOTE || (c == SLASH && regex_may_start(prev))) {
			let e = quoted_end(text, i, c, n);

			push(out, prev = { t: (c == SLASH) ? 'regex' : 'str', v: substr(text, i + 1, e[0] - i - 2), line });
			line += e[1];
			i = e[0];

			while (c == SLASH && i < n && word_char(ord(text, i)))
				i++;
			continue;
		}

		if (c == BACKTICK) {
			i = template(i + 1);
			continue;
		}

		if (word_char(c)) {
			let j = i + 1;

			while (j < n && word_char(ord(text, j)))
				j++;

			let v = substr(text, i, j - i);

			push(out, prev = { t: (c >= 48 && c <= 57) ? 'num' : 'name', v, line });
			i = j;

			while (prev.t == 'num' && i < n && (ord(text, i) == 46 || word_char(ord(text, i)) ||
			       ((ord(text, i) == 43 || ord(text, i) == 45) && match(chr(ord(text, i - 1)), /[eE]/))))
				i++;
			continue;
		}

		if (c == OPEN_BRACE) {
			push(braces, 'brace');
		}
		else if (c == CLOSE_BRACE && pop(braces) == 'template') {
			push(out, { t: 'punct', v: ')', line });
			i = template(i + 1);
			continue;
		}

		let p = chr(c);

		for (let q in PUNCTUATORS)
			if (substr(text, i, length(q)) == q) {
				p = q;
				break;
			}

		if (p == '?.' && match(substr(text, i + 2, 1), /[0-9]/))
			p = '?';

		push(out, prev = { t: 'punct', v: p, line });
		i += length(p);
	}

	return out;
};

const OPENERS = { '(': ')', '[': ']', '{': '}' };

const STATEMENTS = [ 'for', 'while', 'do', 'if', 'switch', 'try', 'with', 'return', 'throw', 'break', 'continue', 'delete' ];

function past_group(toks, i) {
	let depth = 0;

	for (; i < length(toks); i++) {
		let tok = toks[i];

		if (tok.t != 'punct')
			continue;
		if (OPENERS[tok.v])
			depth++;
		else if (tok.v in [ ')', ']', '}' ] && --depth <= 0)
			return i + 1;
	}

	return i;
}

function past_function(toks, i) {
	i++;
	if (toks[i]?.t == 'name')
		i++;
	if (toks[i]?.v == '(')
		i = past_group(toks, i);

	return (toks[i]?.v == '{') ? past_group(toks, i) : i;
}

function past_arrow(toks, i) {
	i++;
	if (toks[i]?.v == '{')
		return past_group(toks, i);

	let depth = 0;

	for (; i < length(toks); i++) {
		let tok = toks[i];

		if (tok.t != 'punct')
			continue;
		if (OPENERS[tok.v])
			depth++;
		else if (tok.v in [ ')', ']', '}' ]) {
			if (depth == 0)
				return i;
			depth--;
		}
		else if (depth == 0 && tok.v in [ ',', ';' ])
			return i;
	}

	return i;
}

function callee(toks, i) {
	let j = i - 1;

	if (toks[j]?.v == '?.')
		j--;
	if (toks[j]?.t != 'name')
		return '(...)';

	let parts = [ toks[j].v ];

	while (toks[j - 1]?.v in [ '.', '?.' ] && toks[j - 2]?.t == 'name') {
		unshift(parts, toks[j - 2].v);
		j -= 2;
	}

	return (toks[j - 1]?.v in [ '.', '?.', ')', ']' ]) ? '(...)' : join('.', parts);
}

function is_call(toks, i) {
	let prev = toks[i - 1];

	if (prev == null)
		return false;
	if (prev.t == 'name')
		return !(prev.v in NOT_CALLEE);

	return prev.t == 'punct' && prev.v in [ ')', ']', '?.' ];
}

function read_expression(toks, i, calls) {
	let depth = 0;
	let n = length(toks);

	while (i < n) {
		let tok = toks[i];

		if (tok.t == 'name' && tok.v == 'function') {
			i = past_function(toks, i);
			continue;
		}

		if (tok.t != 'punct') {
			i++;
			continue;
		}

		if (tok.v == '=>') {
			i = past_arrow(toks, i);
			continue;
		}

		if (tok.v == '(' && is_call(toks, i))
			push(calls, { callee: callee(toks, i), line: tok.line });

		if (OPENERS[tok.v])
			depth++;
		else if (tok.v in [ ')', ']', '}' ])
			depth--;
		else if (tok.v == ';' && depth <= 0)
			return i + 1;

		i++;
	}

	return i;
}

function past_statement(toks, i) {
	let n = length(toks);
	let w = toks[i];

	if (w.v == '{')
		return past_group(toks, i);

	if (w.t == 'name' && w.v in [ 'for', 'while', 'if', 'switch', 'with' ]) {
		i++;
		if (toks[i]?.v == '(')
			i = past_group(toks, i);
		i = (i < n) ? past_statement(toks, i) : i;

		return (w.v == 'if' && toks[i]?.v == 'else') ? past_statement(toks, i + 1) : i;
	}

	if (w.t == 'name' && w.v in [ 'try', 'do' ]) {
		i = past_statement(toks, i + 1);
		while (toks[i]?.v in [ 'catch', 'finally', 'while' ]) {
			i++;
			if (toks[i]?.v == '(')
				i = past_group(toks, i);
			if (toks[i]?.v == '{')
				i = past_group(toks, i);
		}

		return (toks[i]?.v == ';') ? i + 1 : i;
	}

	return read_expression(toks, i, []);
}

function statement_word(toks, i) {
	let tok = toks[i];

	if (tok.v == '{')
		return 'a block';
	if (tok.t == 'name' && tok.v in STATEMENTS)
		return `'${tok.v}'`;
	if (tok.t == 'name' && toks[i + 1]?.v == '(')
		return `${tok.v}()`;

	return 'an expression';
}

function read_import(toks, i, api, module) {
	let names = {};
	let n = length(toks);

	for (i = i + 1; i < n; i++) {
		let tok = toks[i];

		if (tok.t == 'str') {
			if (tok.v == module)
				for (let k, v in names)
					api[k] = v;
			return (toks[i + 1]?.v == ';') ? i + 2 : i + 1;
		}

		if (tok.v == '*' && toks[i + 1]?.v == 'as' && toks[i + 2]?.t == 'name') {
			names[toks[i + 2].v] = '*';
			i += 2;
		}
		else if (tok.t == 'name' && !(tok.v in [ 'from', 'as' ])) {
			if (toks[i + 1]?.v == 'as' && toks[i + 2]?.t == 'name') {
				names[toks[i + 2].v] = tok.v;
				i += 2;
			} else {
				names[tok.v] = tok.v;
			}
		}
	}

	return i;
}

/**
 * What a module's text does at its top level: statements, calls, API imports, declarations.
 *
 * @param {*} text
 * @param {string} api_module
 * @returns {{ statements: { word: string, line: int }[], calls: { callee: string, line: int }[], api: Object<string, string>, declared: string[] }}
 */
export function top_level(text, api_module) {
	let found = { statements: [], calls: [], api: {}, declared: [] };

	if (type(text) != 'string')
		return found;

	let toks = tokens(text);
	let n = length(toks);
	let i = 0;

	while (i < n) {
		let tok = toks[i];

		if (tok.v == ';' && tok.t == 'punct') {
			i++;
			continue;
		}

		if (tok.t == 'str' && (toks[i + 1] == null || toks[i + 1].v == ';' || toks[i + 1].line > tok.line)) {
			i += (toks[i + 1]?.v == ';') ? 2 : 1;
			continue;
		}

		if (tok.t == 'name' && tok.v == 'import' && toks[i + 1]?.v != '(') {
			i = read_import(toks, i, found.api, api_module);
			continue;
		}

		if (tok.t == 'name' && tok.v == 'export') {
			i++;
			if (toks[i]?.v == '{') {
				i = past_group(toks, i);
				continue;
			}
			if (toks[i]?.v == 'default') {
				i = read_expression(toks, i + 1, found.calls);
				continue;
			}
			tok = toks[i];
			if (tok == null)
				break;
		}

		if (tok.t == 'name' && tok.v == 'function') {
			if (toks[i + 1]?.t == 'name')
				push(found.declared, toks[i + 1].v);
			i = past_function(toks, i);
			continue;
		}

		if (tok.t == 'name' && tok.v in [ 'const', 'let', 'var' ]) {
			for (let j = i + 1; j < n && toks[j].v != ';'; j++)
				if (toks[j].t == 'name' && toks[j + 1]?.v == '=' && toks[j - 1]?.v in [ tok.v, ',' ])
					push(found.declared, toks[j].v);
			i = read_expression(toks, i + 1, found.calls);
			continue;
		}

		push(found.statements, { word: statement_word(toks, i), line: tok.line });
		i = past_statement(toks, i);
	}

	return found;
};

function call_problem(name, api, declared) {
	if (name == '(...)')
		return 'what it calls cannot be told from its text';

	let parts = split(name, '.');
	let root = api[parts[0]];

	if (root == '*') {
		shift(parts);
		root = parts[0];
	} else if (root != null) {
		parts[0] = root;
	}

	if (root != null) {
		let full = join('.', parts);

		if (full in PURE_API)
			return null;

		return `the collector API's ${full}() ${API_DOES[parts[0]] ?? 'is for collect()'}`;
	}

	if (length(parts) == 1 && name in PURE)
		return null;
	if (length(parts) == 1 && DOES[name])
		return `${name}() ${DOES[name]}`;
	if (parts[0] in declared)
		return `${name}() is the module's own: what it does is collect()'s, or a value it can declare`;

	return `${name}() is not one of ucode's functions that compute alone`;
}

/**
 * Why a collector module's text does more at its top level than declare, or null.
 *
 * @param {*} text
 * @param {string} api_module
 * @returns {?string}
 */
export function problem(text, api_module) {
	let found = top_level(text, api_module);
	let problems = [];

	for (let s in found.statements)
		push(problems, { line: s.line, text: `its top level runs ${s.word} (line ${s.line}): ` +
			'a collector\'s top level only declares, and leaves what it does to collect()' });

	for (let c in found.calls) {
		let why = call_problem(c.callee, found.api, found.declared);

		if (why != null)
			push(problems, { line: c.line, text: `its top level calls ${(c.callee == '(...)') ? 'the value of an expression' : `${c.callee}()`} (line ${c.line}): ${why}` });
	}

	return length(problems) ? join('; ', map(sort(problems, (a, b) => a.line - b.line), (p) => p.text)) : null;
};

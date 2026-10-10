'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as purity from 'prometheus.exporter.loader.purity';

const API = 'prometheus.exporter';
const HEAD = "'use strict';\n\nimport { Result, errors, proc, services, exposition, u32 } from 'prometheus.exporter';\n\n";

function problem(body) {
	return purity.problem(HEAD + body, API);
}

// The problems of `body`, one each.
function problems(body) {
	let why = problem(body);

	return (why == null) ? [] : split(why, '; ');
}

describe('loader.purity.tokens', () => {
	it('passes over comments, and reads strings, regular expressions and templates whole', () => {
		let toks = purity.tokens("// sleep(1)\n/* print(\n2) */ let a = 'x(y)', b = /\\/(c)/g, c = a / b / 2, d = `t ${ f(1) } u`;");

		assert.match([
			[ 'name', 'let', 3 ], [ 'name', 'a', 3 ], [ 'punct', '=', 3 ], [ 'str', 'x(y)', 3 ], [ 'punct', ',', 3 ],
			[ 'name', 'b', 3 ], [ 'punct', '=', 3 ], [ 'regex', '\\/(c)', 3 ], [ 'punct', ',', 3 ],
			[ 'name', 'c', 3 ], [ 'punct', '=', 3 ], [ 'name', 'a', 3 ], [ 'punct', '/', 3 ], [ 'name', 'b', 3 ],
			[ 'punct', '/', 3 ], [ 'num', '2', 3 ], [ 'punct', ',', 3 ],
			[ 'name', 'd', 3 ], [ 'punct', '=', 3 ], [ 'str', 't ', 3 ], [ 'punct', '(', 3 ], [ 'name', 'f', 3 ],
			[ 'punct', '(', 3 ], [ 'num', '1', 3 ], [ 'punct', ')', 3 ], [ 'punct', ')', 3 ], [ 'str', ' u', 3 ],
			[ 'punct', ';', 3 ],
		], map(toks, (t) => [ t.t, t.v, t.line ]));
	});

	it('counts the lines of multi-line strings, templates and comments', () => {
		let toks = purity.tokens("let a = `x\ny`;\n/*\n\n*/\nlet b = 'p\\\nq';\nlet c = 1;");

		assert.match([ 1, 6, 8 ], map(filter(toks, (t) => t.v == 'let'), (t) => t.line));
	});

	it('skips a first line that starts with #!', () => {
		assert.match([ 'let' ], map(slice(purity.tokens('#!/usr/bin/ucode sleep(1)\nlet a;'), 0, 1), (t) => t.v));
	});
});

describe('loader.purity.problem', () => {
	it('lets a top level that only declares through', () => {
		assert.match(null, problem(
			"const A = 1, B = 'two', C = [ 1, 2 ], D = { a: 1 }, E = /x/i, F = `t${A}`, G = A * 2 + (B ? 1 : 0);\n" +
			'let state = 0;\n' +
			'function helper(x) { sleep(1); print(x); return system(x); }\n' +
			'export const meta = {\n' +
			"\tname: 'mine', paths: [ function(o) { return [ sprintf('%s', o.dir) ]; } ],\n" +
			"\tubus: { 'x': (o) => o.on ? [ 'status' ] : [] },\n" +
			'};\n' +
			'export function collect(deps, out) { warn(1); return proc.first_line(deps.fs, A); };\n'));
	});

	it('lets calls of ucode\'s functions that compute alone through, and of the API\'s', () => {
		assert.match(null, problem(
			"const A = regexp('^a' + sprintf('%d', 1) + '$'), B = map([ 1, 2 ], (x) => x * 2), C = join(',', keys({ a: 1 }));\n" +
			"const D = Result.ok(), E = Result.err(errors.SOURCE_INVALID, 'x'), F = proc.fields('a b'), G = u32(-1);\n" +
			"const H = length(filter(split('a b', ' '), (s) => s != '')), I = replace(lc('A'), /a/, 'b');\n"));
	});

	it('names each statement that is not a declaration, and its line', () => {
		assert.match([
			"its top level runs sleep() (line 5): a collector's top level only declares, and leaves what it does to collect()",
			"its top level runs 'for' (line 6): a collector's top level only declares, and leaves what it does to collect()",
			"its top level runs 'while' (line 7): a collector's top level only declares, and leaves what it does to collect()",
			"its top level runs 'if' (line 8): a collector's top level only declares, and leaves what it does to collect()",
			"its top level runs an expression (line 9): a collector's top level only declares, and leaves what it does to collect()",
			"its top level runs a block (line 10): a collector's top level only declares, and leaves what it does to collect()",
			"its top level runs push() (line 11): a collector's top level only declares, and leaves what it does to collect()",
			"its top level runs 'try' (line 12): a collector's top level only declares, and leaves what it does to collect()",
		], problems('sleep(1);\nfor (let i = 0; i < 3; i++) { f(i); }\nwhile (true) ;\nif (a) b(); else c();\n' +
			'X.y = 1;\n{ let z = 1; }\npush(LIST, 1);\ntry { a(); } catch (e) { }\n'));
	});

	it('names each call of what may do more than compute, and why', () => {
		assert.match([
			'its top level calls getenv() (line 5): getenv() reads the environment, which is not the same in each process that loads it',
			'its top level calls time() (line 5): time() reads the clock, which is not the same in each process that loads it',
			"its top level calls proc.first_line() (line 6): the collector API's proc.first_line() reads a file through deps.fs, which collect() alone gets",
			"its top level calls services.state() (line 7): the collector API's services.state() calls ubus through deps.ubus, which collect() alone gets",
			"its top level calls exposition.sanitize() (line 8): the collector API's exposition.sanitize() loads the exposition format, the first time one of its functions is called",
			"its top level calls helper() (line 10): helper() is the module's own: what it does is collect()'s, or a value it can declare",
			"its top level calls TABLE.get() (line 11): TABLE.get() is not one of ucode's functions that compute alone",
			'its top level calls the value of an expression (line 12): what it calls cannot be told from its text',
			'its top level calls print() (line 13): print() writes to the process\'s output',
		], problems("const H = getenv('HOME'), T = time();\nconst L = proc.first_line(null, '/x');\nconst S = services.state(null, 'x');\n" +
			"const N = exposition.sanitize('a-b');\nfunction helper() { return 1; }\nconst V = helper();\nconst W = TABLE.get(1);\n" +
			'const X = (f)(2);\nexport default print(1);\n'));
	});

	it('reads a template\'s ${} as code', () => {
		assert.match([ "its top level calls getenv() (line 5): getenv() reads the environment, which is not the same in each process that loads it" ],
			problems("const T = `home: ${ getenv('HOME') } and ${ { a: 1 }.a }`;\n"));
	});

	it('finds the API by the names the module imports it under, a namespace included', () => {
		let text = "'use strict'\nimport { proc as p, Result as R } from 'prometheus.exporter';\nimport * as api from 'prometheus.exporter';\n" +
			"const A = p.fields('a'), B = R.ok(), C = api.proc.fields('b'), D = api.Result.none('x');\nconst E = api.proc.lines(null, '/x');\n";

		assert.match("its top level calls api.proc.lines() (line 5): the collector API's proc.lines() reads a file through deps.fs, which collect() alone gets",
			purity.problem(text, API));
	});

	it('does not read a function\'s body, whether declared, given as a value or an arrow\'s', () => {
		assert.match(null, problem('function f() { while (true) sleep(1); }\nconst g = function() { system(1); }, h = (x) => print(x), i = (x) => { exit(x); };\n' +
			'const J = map([ 1 ], (x) => x + 1), K = sort([ 2, 1 ], function(a, b) { return a - b; });\n'));
	});

	it('takes words in strings, comments and regular expressions for none', () => {
		assert.match(null, problem("// sleep(1);\n/* for (;;) print(1); */\nconst A = 'sleep(1); for (;;)', B = /sleep\\(1\\)/, C = \"exit()\";\n"));
	});

	it('holds nothing of what is not a string', () => {
		assert.match(null, purity.problem(null, API));
		assert.match({ statements: [], calls: [], api: {}, declared: [] }, purity.top_level(42, API));
	});

	prop('lets any declaration of literals and calls of PURE through',
		gen.array(gen.tuple(gen.elements(...purity.PURE), gen.int(0, 9)), { min_len: 1, max_len: 12 }), (decls) => {
			let body = join('\n', map(decls, (d, i) => `const V${i} = ${d[0]}(${d[1]}, 'x', [ ${d[1]} ]);`)) + '\n';

			assert.match(null, problem(body), body);
		});

	prop('names a statement or call slipped in among declarations, at its line',
		gen.tuple(gen.int(0, 5), gen.elements('sleep(1);', 'for (;;) ;', 'const Q = getenv(1);', 'X.y = 2;', 'const Q = proc.lines(null, 1);')), (t) => {
			let lines = map([ 0, 1, 2, 3, 4, 5 ], (i) => `const V${i} = ${i};`);

			splice(lines, t[0], 0, t[1]);

			let why = problem(join('\n', lines) + '\n');

			assert.match(true, why != null && index(why, `(line ${t[0] + 5})`) > 0, why);
		});
});

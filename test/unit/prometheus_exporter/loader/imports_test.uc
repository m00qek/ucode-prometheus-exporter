'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { readfile, glob } from 'fs';
import { imports } from 'prometheus_exporter.loader.imports';

function modules(text) {
	return map(imports(text).imports, (i) => [ i.module, i.line ]);
}

function loads(text) {
	return map(imports(text).loads, (l) => [ l.fn, l.module, l.line ]);
}

describe('loader.imports', () => {
	it('finds each import statement, by the line it starts on', () => {
		assert.match([ [ 'prometheus_exporter.api', 3 ], [ 'fs', 4 ], [ 'ubus', 5 ], [ 'uci', 6 ], [ 'math', 6 ] ], modules(join('\n', [
			"'use strict';",
			'',
			"import { Result, errors } from 'prometheus_exporter.api';",
			"import * as fs from 'fs';",
			'import { connect } from "ubus";',
			"import 'uci'; import { abs } from 'math';",
		])));
	});

	it('finds an import whose names take several lines, and one after other statements', () => {
		assert.match([ [ 'fs', 2 ], [ 'socket', 7 ] ], modules(join('\n', [
			"'use strict';",
			'import {',
			'\treadfile,',
			'\tlsdir as ls',
			"} from 'fs';",
			'let x = 1;',
			"export const y = 2; import * as s from 'socket';",
		])));
	});

	it('passes over what only looks like an import: comments, strings, templates, regular expressions, keys', () => {
		assert.match([ [ 'prometheus_exporter.api', 13 ] ], modules(join('\n', [
			"'use strict';",
			"// import * as fs from 'fs';",
			'/*',
			"import * as fs from 'fs';",
			'*/',
			"/* import * as a from 'a'; */ let s = 'import * as b from \"b\"';",
			"let t = `import ${s} from 'c'`;",
			"let r = /import x from 'd'/;",
			"let o = { import: 'e' };",
			"o.import; let important = 'f';",
			"let u = \"it's\" + '/*' + \"*/\";",
			'let d = 4 / 2; let q = d / 2;',
			"import { Result } from 'prometheus_exporter.api';",
		])));
	});

	it('finds an import after a block comment that ends on its line, or before a comment of its own', () => {
		assert.match([ [ 'fs', 3 ], [ 'uci', 4 ], [ 'ubus', 5 ] ], modules(join('\n', [
			"'use strict';",
			"/* import * as a from 'a';",
			"   import * as b from 'b'; */ import * as fs from 'fs';",
			"import * as uci from 'uci'; // import * as c from 'c';",
			"import * as ubus from 'ubus'; /* import * as d from 'd'; */",
		])));
	});

	it('reads a regular expression that holds a quote or a comment\'s opening as one', () => {
		assert.match([ [ 'ubus', 4 ] ], modules(join('\n', [
			"'use strict';",
			"const Q = /['\"]/, C = /\\/\\*[^*]*/, K = /[/*]/;",
			'let n = (1) / 2 / 3;',
			"import * as u from 'ubus';",
		])));
	});

	it('finds the calls that load code past the imports', () => {
		assert.match([ [ 'require', 'fs', 2 ], [ 'loadstring', null, 3 ], [ 'loadfile', '/tmp/x.uc', 4 ], [ 'require', null, 5 ] ], loads(join('\n', [
			"'use strict';",
			"let fs = require('fs');",
			"let f = loadstring(\"import * as u from 'ubus'; return u;\")();",
			'let g = loadfile("/tmp/x.uc");',
			'let h = require (name);',
			"let k = o.require('fs'); // require('uci')",
			"let m = 'require(\"x\")';",
		])));
		assert.match([], modules("let f = loadstring(\"import * as u from 'ubus'; return u;\");"));
	});

	it('finds nothing in a text without the words, or no text', () => {
		assert.match({ imports: [], loads: [] }, imports("'use strict';\nexport const x = 1;\n"));
		assert.match({ imports: [], loads: [] }, imports(null));
	});

	prop('finds an import whatever comments and strings come before it',
		gen.array(gen.elements("// import x from 'a'\n", "/* import y from 'b' */\n", "let s = \"import z from 'c'\";\n",
			"/*\nimport w from 'd'\n*/\n", 'let d = 1 / 2;\n', '\n'), { min_len: 0, max_len: 6 }), (lead) => {
			let text = join('', lead);
			let line = length(split(text, '\n'));

			assert.match([ [ 'fs', line ] ], modules(text + "import * as fs from 'fs';\n"));
		});

	it('finds in each collector of the source tree its import of the API', () => {
		for (let f in glob('src/prometheus_exporter/collectors/*.uc')) {
			let found = imports(readfile(f));

			assert.match([ 'prometheus_exporter.api' ], map(found.imports, (i) => i.module), f);
			assert.match([], found.loads, f);
		}
	});
});

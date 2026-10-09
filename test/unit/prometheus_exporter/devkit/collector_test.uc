'use strict';

// What the devkit's collector module adds to with_collector, which
// contract_test.uc holds to the collector contract: the module's text, as
// the loader and `collector check` read it.

import { describe, it, assert } from 'utest';
import { module_problems, assert_module, MOCKED } from 'prometheus_exporter.devkit.collector';
import * as fs from 'fs';

const STRICT = "'use strict';\nimport { Result } from 'prometheus_exporter.api';\n";

describe('devkit.collector.module_problems', () => {
	it('finds none in a module the loader takes', () => {
		assert.match([], module_problems(STRICT + "const A = regexp('x');\nexport const meta = {};\n"));
	});

	it('names each problem of strict mode, imports and the top level, with its line', () => {
		assert.match([ "not in strict mode: its first statement must be 'use strict'" ], module_problems("import * as fs from 'fs';\n"));
		assert.match([
			"imports fs (line 3): a collector reads files through deps.fs, with 'fs' in meta.needs",
			"calls require(\"ubus\") (line 4): a collector calls ubus through deps.ubus, with 'ubus' in meta.needs",
		], module_problems(STRICT + "import * as fs from 'fs';\nconst U = require('ubus');\n"));
		assert.match([
			"its top level runs sleep() (line 3): a collector's top level only declares, and leaves what it does to collect()",
			"its top level calls getenv() (line 4): getenv() reads the environment, which is not the same in each process that loads it",
		], module_problems(STRICT + "sleep(1);\nconst H = getenv('HOME');\n"));
		assert.match([ 'the module cannot be read' ], module_problems(null));
	});

	it('passes every collector the packages ship', () => {
		for (let f in fs.glob('src/prometheus_exporter/collectors/*.uc'))
			assert_module(f);
	});

	it('mocks what with_collector builds capabilities from', () => {
		assert.match([ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'socket' ], MOCKED);
	});
});

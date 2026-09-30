'use strict';

import { describe, it, assert } from 'utest';
import * as cli from 'node_exporter.cli';

// A fake node_exporter.app: records what it was asked, answers `reply`.
function app_factory(reply, seen) {
	return function(log, dir) {
		seen.dir = dir;
		log('loaded');
		return {
			collectors: [ { meta: { name: 'cpu', help: 'CPU time.' } }, { meta: { name: 'ltq-dsl', help: 'DSL line.' } } ],
			scrape: function(q) { seen.query = q; return reply; },
		};
	};
}

function run(argv, reply) {
	let seen = {}, out = [], err = [];
	let status = cli.run(argv, app_factory(reply ?? { status: '200 OK', body: 'x 1\n' }, seen), (s) => push(out, s), (s) => push(err, s));
	return { status, seen, out: join('', out), err: join('', err) };
}

describe('cli.parse_args', () => {
	it('takes flags and collector names in any order', () => {
		assert.match({ help: false, list: true, dir: '/src', names: [ 'cpu', 'wifi' ] }, cli.parse_args([ 'cpu', '-l', '-d', '/src', 'wifi' ]));
	});

	it('refuses an unknown flag and a -d without a directory', () => {
		assert.match([ null, null ], [ cli.parse_args([ '-x' ]), cli.parse_args([ '-d' ]) ]);
	});
});

describe('cli.run', () => {
	it('prints a scrape of the named collectors', () => {
		let r = run([ 'cpu', 'a b' ]);

		assert.match([ 0, 'x 1\n', 'collect[]=cpu&collect[]=a%20b' ], [ r.status, r.out, r.seen.query ]);
		assert.match('loaded\n', r.err);
	});

	it('lists the collectors with their help', () => {
		let r = run([ '-l', '-d', '/src' ]);

		assert.match([ 0, '/src' ], [ r.status, r.seen.dir ]);
		assert.match(sprintf('%-24s CPU time.\n%-24s DSL line.\n', 'cpu', 'ltq-dsl'), r.out);
	});

	it('prints what went wrong and exits 1 when the scrape is refused', () => {
		let r = run([ 'nope' ], { status: '400 Bad Request', body: "unknown collector 'nope'\n" });
		assert.match([ 1, '' ], [ r.status, r.out ]);
		assert.match(true, index(r.err, "unknown collector 'nope'") >= 0);
	});

	it('shows usage: on -h to stdout, on bad arguments to stderr with status 2', () => {
		assert.match([ 0, cli.USAGE ], [ run([ '-h' ]).status, run([ '-h' ]).out ]);
		assert.match([ 2, cli.USAGE ], [ run([ '--verbose' ]).status, run([ '--verbose' ]).err ]);
	});
});

'use strict';

// A collector of the browser tests, installed by no package, that runs a program
// and has no option of its own: the core's timeout is all its dialog has.

import { Result } from 'prometheus.exporter';

export const meta = {
	name: 'runner',
	title: 'Runner',
	help: 'Runs true, and records nothing.',
	needs: [ 'exec' ],
	commands: [ 'true' ],
};

export function collect(deps, out, options) {
	let res = deps.exec.run([ 'true' ]);

	return res.ok ? Result.ok() : res;
};

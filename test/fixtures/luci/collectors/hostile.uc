'use strict';

// A collector of the browser tests, installed by no package, whose help, option
// default and error are markup: the pages must show them as text.

import * as Result from 'node_exporter.result';

const HOSTILE = '<img src=x onerror=window.__xss=1>';

export const meta = {
	name: 'hostile',
	help: HOSTILE,
	needs: [],
	options: { note: HOSTILE },
};

export function collect(deps, out, options) {
	return Result.err('SOURCE_INVALID', HOSTILE);
};

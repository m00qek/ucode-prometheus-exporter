'use strict';

// A collector of the browser tests, installed by no package: an option of each type.

import * as Result from 'node_exporter.result';

export const meta = {
	name: 'sampler',
	help: 'Samples nothing, with an option of each type.',
	needs: [ 'fs' ],
	options: { retries: 3, verbose: false, label: 'node' },
};

export function collect(deps, out, options) {
	out.gauge('node_sampler_retries', 'The retries option.')({ label: options.label }, options.retries);
	return Result.ok();
};

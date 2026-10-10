'use strict';

// A collector of the browser tests, installed by no package: an option of each type.

import { Result } from 'prometheus.exporter';

export const meta = {
	name: 'sampler',
	title: 'Sampler',
	help: 'Samples nothing, with an option of each type.',
	needs: [ 'fs' ],
	options: {
		retries: { default: 3, title: 'Retries', help: 'How many times to try.' },
		verbose: { default: false, title: 'Verbose', help: 'Say more.' },
		label: { default: 'node', title: 'Label', help: 'The label of the sample.' },
	},
};

export function collect(deps, out, options) {
	out.gauge('node_sampler_retries', 'The retries option.')({ label: options.label }, options.retries);
	return Result.ok();
};

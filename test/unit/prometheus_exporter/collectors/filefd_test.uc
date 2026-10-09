'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'prometheus_exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as filefd from 'prometheus_exporter.collectors.filefd';

const PATH = '/proc/sys/fs/file-nr';

const ROUTER = fixtures.files('caju-router', [ PATH ]);
const AP = fixtures.files('caju-ap', [ PATH ]);

function file_nr(text) {
	return { fs: { data: { [PATH]: text } } };
}

describe('collectors.filefd', () => {
	it('exports the allocated and the most file descriptors of the caju router', () => {
		with_collector(filefd, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_filefd_allocated File descriptor statistics: allocated.',
				'# TYPE node_filefd_allocated gauge',
				'node_filefd_allocated 704',
				'# HELP node_filefd_maximum File descriptor statistics: maximum.',
				'# TYPE node_filefd_maximum gauge',
				'node_filefd_maximum 400922',
			], r.lines);
		});
	});

	it('reads the caju AP too', () => {
		with_collector(filefd, { fs: { data: AP } }, (r) => {
			assert.match([ 'node_filefd_allocated 256', 'node_filefd_maximum 23864' ],
				filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('fails with SOURCE_UNREADABLE when file-nr cannot be read', () => {
		with_collector(filefd, file_nr(null), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: PATH },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
			assert.match([ `collector 'filefd': SOURCE_UNREADABLE (${PATH})` ], r.logs);
		});
	});

	it('fails with SOURCE_INVALID for fewer than three fields', () => {
		with_collector(filefd, file_nr('704\t0\n'), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: `${PATH}: "704\\t0"` },
				{ error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for a field that is not a count', () => {
		with_collector(filefd, file_nr('704\t0\tmany\n'), (r) => assert.match('SOURCE_INVALID', r.result.error));
	});

	prop('exports the first and third fields, whatever the whitespace between them',
		gen.tuple(gen.int(0, 1 << 40), gen.int(0, 1 << 40), gen.elements(' ', '\t', '  \t')), (t) => {
			with_collector(filefd, file_nr(`${t[0]}${t[2]}0${t[2]}${t[1]}\n`), (r) => {
				assert.match(true, r.result.ok);
				assert.match([ `node_filefd_allocated ${t[0]}`, `node_filefd_maximum ${t[1]}` ],
					filter(r.lines, (l) => substr(l, 0, 1) != '#'));
			});
		});
});

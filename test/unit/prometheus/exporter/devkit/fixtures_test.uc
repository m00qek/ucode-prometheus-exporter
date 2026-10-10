'use strict';

import { describe, it, assert } from 'utest';
import { reader } from 'prometheus.exporter.devkit.fixtures';
import * as fs from 'fs';

describe('devkit.fixtures.reader', () => {
	const ROUTER = reader('test/fixtures/caju-router');

	it('reads a file by the path it has on the device, and several as an fs mock\'s data', () => {
		let loadavg = fs.readfile('test/fixtures/caju-router/proc/loadavg');

		assert.match(loadavg, ROUTER.file('/proc/loadavg'));
		assert.match({ '/proc/loadavg': loadavg }, ROUTER.files([ '/proc/loadavg' ]));
	});

	it('reads a ubus reply as JSON', () => {
		assert.match(json(fs.readfile('test/fixtures/caju-router/ubus/system.board.json')), ROUTER.ubus('system', 'board'));
	});

	it('fails, naming it, for a fixture that is not there', () => {
		let why = null;

		try {
			ROUTER.file('/proc/nope');
		} catch (e) {
			why = e.message;
		}

		assert.match('no fixture test/fixtures/caju-router/proc/nope: capture it from a device, at that path under test/fixtures/caju-router', why);
	});
});

'use strict';

// Captures from real devices under test/fixtures/<device>/, as `make fixtures`
// writes them: files at their own paths, ubus replies as ubus/<object>.<method>.json.
// Read these before a mock is active: fs is mocked too.

import { readfile } from 'fs';

const ROOT = 'test/fixtures';

export function file(device, path) {
	let s = readfile(`${ROOT}/${device}${path}`);

	if (s == null)
		die(`no fixture ${device}${path}; add it to test/fixtures/SOURCES and run make fixtures`);

	return s;
};

// { path: content } for several files: an fs mock's data.
export function files(device, paths) {
	let data = {};

	for (let path in paths)
		data[path] = file(device, path);

	return data;
};

export function ubus(device, object, method) {
	return json(file(device, `/ubus/${object}.${method}.json`));
};

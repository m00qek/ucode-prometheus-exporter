'use strict';

// Captures from real devices under test/fixtures/<device>/, as `make fixtures`
// writes them: files at their own paths, ubus replies as ubus/<object>.<method>.json.
// Read these before a mock is active: fs is mocked too.

import { readfile, lsdir } from 'fs';

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

// A uci cursor of a device's uci/<config>.json captures, read-only, the
// sections in the order of their file, as uci gives a config's.
export function cursor(device) {
	let configs = {};

	function data(config) {
		if (!(config in configs)) {
			let s = readfile(`${ROOT}/${device}/uci/${config}.json`);

			configs[config] = (s == null) ? null : json(s);
		}

		return configs[config];
	}

	return {
		load: (config) => data(config) != null,
		foreach: function(config, stype, cb) {
			for (let name, s in data(config) ?? {})
				if (stype == null || s['.type'] == stype)
					cb({ '.name': name, '.anonymous': false, ...s });
		},
	};
};

// fs's lsdir, readfile and realpath over a device's captures: realpath as
// its links.json has where each link leads.
export function sysfs(device) {
	let root = `${ROOT}/${device}`;
	let links = json(readfile(`${root}/links.json`) ?? '{}');

	return {
		lsdir: (p) => lsdir(root + p),
		readfile: (p) => readfile(root + p),
		realpath: (p) => links[p],
	};
};

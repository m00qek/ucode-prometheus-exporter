'use strict';

// utest's fs mock opens files without lock(), which the state's lock takes
// (prometheus_exporter.state). open is a behavior for the fs mock that opens
// a state's lock file as one that is always taken, and nothing else: for the
// tests of what runs the handler, whose collectors read without fs.open.
//
// mkstemp is the real fs.mkstemp, taken before any test patches fs: the
// runner's temporary file (prometheus_exporter.runner), made and removed at
// once in /tmp, which the mock refuses to make. behavior is both.
//
//   mock.global.patch('fs', { data, behavior: lockable.behavior })

// Under utest, `fs` is its proxy: the real module is real_fs, as utest
// itself loads it.
function real_fs() {
	try {
		return require('real_fs');
	} catch (e) {
		return require('fs');
	}
}

const REAL = real_fs();

export function mkstemp(template) {
	return REAL.mkstemp(template);
};

export function open(path) {
	return (substr(path, -5) == '.lock') ? { lock: () => true, close: () => true } : null;
};

export const behavior = { open, mkstemp };

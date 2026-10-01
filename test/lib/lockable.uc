'use strict';

// utest's fs mock opens files without lock(), which the state's lock takes
// (prometheus_exporter.state). open is a behavior for the fs mock that opens
// a state's lock file as one that is always taken, and nothing else: for the
// tests of what runs the handler, whose collectors read without fs.open.
//
//   mock.global.patch('fs', { data, behavior: { open: lockable.open } })

export function open(path) {
	return (substr(path, -5) == '.lock') ? { lock: () => true, close: () => true } : null;
};

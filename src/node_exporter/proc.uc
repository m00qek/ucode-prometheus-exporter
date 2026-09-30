'use strict';

// Reading procfs and sysfs through a collector's fs capability.

// The first line, without its newline; null when the file cannot be read.
export function first_line(fs, path) {
	let s = fs.readfile(path);

	return s == null ? null : split(s, '\n')[0];
};

// Every line, without newlines; null when the file cannot be read.
export function lines(fs, path) {
	let s = fs.readfile(path);

	if (s == null)
		return null;

	let l = split(s, '\n');
	if (l[-1] == '')
		pop(l);

	return l;
};

// cb(line) for each line, read one at a time, for files as long as the
// conntrack table. False when the file cannot be read.
export function each_line(fs, path, cb) {
	let f = fs.open(path, 'r');

	if (!f)
		return false;

	let line;
	while (length(line = f.read('line')))
		cb(rtrim(line, '\n'));

	f.close();
	return true;
};

// The whitespace-separated fields of a line; [] for none or for null.
export function fields(line) {
	line = trim(line ?? '');

	return line == '' ? [] : split(line, /\s+/);
};

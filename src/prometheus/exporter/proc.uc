/**
 * Reading procfs and sysfs through a collector's fs capability.
 *
 * @module prometheus_exporter_proc
 */

'use strict';

/**
 * The first line, without its newline; null when the file cannot be read.
 *
 * @param {FsCapability} fs
 * @param {string} path
 * @returns {?string}
 */
export function first_line(fs, path) {
	let s = fs.readfile(path);

	return s == null ? null : split(s, '\n')[0];
};

/**
 * Every line, without newlines; null when the file cannot be read.
 *
 * @param {FsCapability} fs
 * @param {string} path
 * @returns {?string[]}
 */
export function lines(fs, path) {
	let s = fs.readfile(path);

	if (s == null)
		return null;

	let l = split(s, '\n');
	if (l[-1] == '')
		pop(l);

	return l;
};

/**
 * cb(line) for each line, read one at a time, for files as long as the conntrack table.
 *
 * @param {FsCapability} fs
 * @param {string} path
 * @param {function(string)} cb
 * @returns {boolean}
 */
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

const AT_NULL = 0;

/** The auxiliary vector's type of the page size, in bytes. */
export const AT_PAGESZ = 6;

/** The auxiliary vector's type of the clock tick, in ticks a second (USER_HZ). */
export const AT_CLKTCK = 17;
const AT_MAX = 64;

const LAYOUTS = [ [ 8, true ], [ 4, true ], [ 8, false ], [ 4, false ] ];

function word(s, at, size, le) {
	if (size == 8)
		return le
			? ((((((ord(s, at + 7) * 256 + ord(s, at + 6)) * 256 + ord(s, at + 5)) * 256 + ord(s, at + 4)) * 256 +
				ord(s, at + 3)) * 256 + ord(s, at + 2)) * 256 + ord(s, at + 1)) * 256 + ord(s, at)
			: ((((((ord(s, at) * 256 + ord(s, at + 1)) * 256 + ord(s, at + 2)) * 256 + ord(s, at + 3)) * 256 +
				ord(s, at + 4)) * 256 + ord(s, at + 5)) * 256 + ord(s, at + 6)) * 256 + ord(s, at + 7);
	if (size == 4)
		return le
			? ((ord(s, at + 3) * 256 + ord(s, at + 2)) * 256 + ord(s, at + 1)) * 256 + ord(s, at)
			: ((ord(s, at) * 256 + ord(s, at + 1)) * 256 + ord(s, at + 2)) * 256 + ord(s, at + 3);

	let v = 0;

	for (let i = 0; i < size; i++)
		v = v * 256 + ord(s, le ? at + size - 1 - i : at + i);

	return v;
}

const ZEROS = '\0\0\0\0\0\0\0';

function type_of(s, at, size, le) {
	if (substr(s, le ? at + 1 : at, size - 1) != substr(ZEROS, 0, size - 1))
		return AT_MAX;

	return ord(s, le ? at : at + size - 1);
}

/**
 * An auxiliary vector as /proc/self/auxv gives it, { type: value }, or null.
 *
 * @param {?string} bytes
 * @returns {?Object<string, int>}
 */
export function auxv(bytes) {
	let n = length(bytes ?? '');

	for (let l in LAYOUTS) {
		let size = l[0], le = l[1], pair = size * 2, out = {};

		if (!n || n % pair)
			continue;

		for (let at = 0; at < n; at += pair) {
			let t = type_of(bytes, at, size, le);

			if (t >= AT_MAX || t < 0)
				break;
			if (t == AT_NULL) {
				let ps = out[AT_PAGESZ];

				if (at + pair == n && ps >= 1024 && !(ps & (ps - 1)))
					return out;
				break;
			}

			out[t] = word(bytes, at + size, size, le);
		}
	}

	return null;
};

const SPACE_RUN = /\s+/;
const RARE_SPACE = /[\n\v\f\r]/;

/**
 * The whitespace-separated fields of a line; [] for none or for null.
 *
 * @param {?string} line
 * @returns {string[]}
 */
export function fields(line) {
	line = trim(line ?? '');

	if (line == '')
		return [];
	if (index(line, '  ') < 0 && index(line, '\t') < 0 && !match(line, RARE_SPACE))
		return split(line, ' ');

	return split(line, SPACE_RUN);
};

/**
 * The whitespace-separated fields of every line; null when the file cannot be read.
 *
 * @param {FsCapability} fs
 * @param {string} path
 * @returns {?string[][]}
 */
export function rows(fs, path) {
	let s = fs.readfile(path);

	if (s == null)
		return null;

	let l = split(s, '\n');

	if (l[-1] == '')
		pop(l);

	if (index(s, '  ') >= 0 || index(s, '\t') >= 0 || index(s, '\v') >= 0 || index(s, '\f') >= 0 || index(s, '\r') >= 0 ||
	    index(s, ' \n') >= 0 || index(s, '\n ') >= 0 || substr(s, 0, 1) == ' ' || substr(s, -1) == ' ')
		return map(l, fields);

	let out = [];

	for (let line in l)
		push(out, (line == '') ? [] : split(line, ' '));

	return out;
};

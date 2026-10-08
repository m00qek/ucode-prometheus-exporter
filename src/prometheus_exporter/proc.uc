/**
 * Reading procfs and sysfs through a collector's fs capability.
 *
 * @module prometheus_exporter_proc
 */

'use strict';

/**
 * The first line, without its newline; null when the file cannot be read.
 *
 * @param {FsCapability} fs the collector's deps.fs.
 * @param {string} path the file.
 * @returns {?string} its first line.
 */
export function first_line(fs, path) {
	let s = fs.readfile(path);

	return s == null ? null : split(s, '\n')[0];
};

/**
 * Every line, without newlines; null when the file cannot be read.
 *
 * @param {FsCapability} fs the collector's deps.fs.
 * @param {string} path the file.
 * @returns {?string[]} its lines; a last empty one, after the last newline,
 *   is left out.
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
 * cb(line) for each line, read one at a time, for files as long as the
 * conntrack table. False when the file cannot be read.
 *
 * @param {FsCapability} fs the collector's deps.fs.
 * @param {string} path the file.
 * @param {function(string)} cb called with each line, without its newline.
 * @returns {boolean} whether the file could be read.
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

// The auxiliary vector's types (linux/auxvec.h): the vector ends with AT_NULL,
// and no type the kernel defines is as large as AT_MAX.
const AT_NULL = 0;

/**
 * The auxiliary vector's type of the page size, in bytes.
 *
 * @type {int}
 */
export const AT_PAGESZ = 6;

/**
 * The auxiliary vector's type of the clock tick, in ticks a second
 * (USER_HZ).
 *
 * @type {int}
 */
export const AT_CLKTCK = 17;
const AT_MAX = 64;

// The layouts an auxiliary vector may have: [ bytes of a word, little-endian ].
const LAYOUTS = [ [ 8, true ], [ 4, true ], [ 8, false ], [ 4, false ] ];

function word(s, at, size, le) {
	let v = 0;

	for (let i = 0; i < size; i++)
		v = v * 256 + ord(s, le ? at + size - 1 - i : at + i);

	return v;
}

/**
 * An auxiliary vector as /proc/self/auxv gives it, { type: value }: pairs of
 * words (a type, a value) in the process's own word size and byte order,
 * which nothing says, ending with AT_NULL. The layout is the one by which
 * every type is one the kernel could define, the vector ends at AT_NULL and
 * AT_PAGESZ is a power of two; any other reads a value or an address as a
 * type, and stops at its first. Null when none fits.
 *
 * @param {?string} s the bytes of /proc/self/auxv (exporter's system()).
 * @returns {?Object<string, int>} each value by its type.
 */
export function auxv(s) {
	let n = length(s ?? '');

	for (let l in LAYOUTS) {
		let size = l[0], le = l[1], pair = size * 2, out = {};

		if (!n || n % pair)
			continue;

		for (let at = 0; at < n; at += pair) {
			let t = word(s, at, size, le);

			if (t >= AT_MAX || t < 0)
				break;
			if (t == AT_NULL) {
				let ps = out[AT_PAGESZ];

				if (at + pair == n && ps >= 1024 && !(ps & (ps - 1)))
					return out;
				break;
			}

			out[t] = word(s, at + size, size, le);
		}
	}

	return null;
};

const SPACE_RUN = /\s+/;
const RARE_SPACE = /[\n\v\f\r]/;

/**
 * The whitespace-separated fields of a line; [] for none or for null.
 *
 * What split(line, /\s+/) gives. A line whose fields are separated by single
 * spaces (most of /proc: stat, netstat, the conntrack table) is split on ' ',
 * several times cheaper than musl's regexec on a long line; any other takes
 * the regex, which is then cheaper than dropping the empty strings a split on
 * ' ' would leave between padding spaces (meminfo, dev_snmp6).
 *
 * @param {?string} line the line.
 * @returns {string[]} its fields.
 */
export function fields(line) {
	line = trim(line ?? '');

	if (line == '')
		return [];
	if (index(line, '  ') < 0 && index(line, '\t') < 0 && !match(line, RARE_SPACE))
		return split(line, ' ');

	return split(line, SPACE_RUN);
};

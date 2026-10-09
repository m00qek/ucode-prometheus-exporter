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

// A word of `size` bytes at `at`, its most significant byte first: the
// loop a word took, a turn of it a byte, written out, for the 4 and 8 bytes
// a vector's words have. A vector is some 40 of them, a scrape's exporter
// and sockstat read one each, and a turn costs more than the byte's ord().
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

// The bytes a type's word has besides its least significant, which are 0
// for every type the kernel defines (AT_MAX): such a word is its least
// significant byte, and any other at least AT_MAX, without a word read.
const ZEROS = '\0\0\0\0\0\0\0';

function type_of(s, at, size, le) {
	if (substr(s, le ? at + 1 : at, size - 1) != substr(ZEROS, 0, size - 1))
		return AT_MAX;

	return ord(s, le ? at : at + size - 1);
}

/**
 * An auxiliary vector as /proc/self/auxv gives it, { type: value }: pairs of
 * words (a type, a value) in the process's own word size and byte order,
 * which nothing says, ending with AT_NULL. The layout is the one by which
 * every type is one the kernel could define, the vector ends at AT_NULL and
 * AT_PAGESZ is a power of two; any other reads a value or an address as a
 * type, and stops at its first. Null when none fits.
 *
 * @param {?string} bytes the bytes of /proc/self/auxv (exporter's system()).
 * @returns {?Object<string, int>} each value by its type.
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

/**
 * The whitespace-separated fields of every line, [] for a blank one; null
 * when the file cannot be read: what fields() gives of each of lines().
 *
 * A file whose fields are separated by single spaces, without spaces at a
 * line's ends or any other whitespace, as most of /proc and sysfs (vmstat,
 * stat, softnet_stat, the netstat tables), is looked at once, by a few
 * index() of its whole text, and each line split on ' ': fields() looks at
 * each line, three calls before its split, and a scrape reads hundreds.
 *
 * @param {FsCapability} fs the collector's deps.fs.
 * @param {string} path the file.
 * @returns {?string[][]} each line's fields.
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

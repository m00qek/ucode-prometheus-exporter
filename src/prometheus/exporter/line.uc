/**
 * Matching that means the same on every ucode.
 *
 * ucode 2026.07.09, which every 25.12 release's package index has, compiles a
 * regular expression without the s flag with REG_NEWLINE: its ^ and $ match
 * at each line, and its . and [^...] match no newline. The ucode before it,
 * which an older device or rootfs image holds, does the opposite, and the s
 * flag swaps the two on each. Both read text without a newline alike, so text
 * a regular expression is to match whole is first refused one.
 *
 * @module prometheus_exporter_line
 */

'use strict';

/**
 * match(text, re), but null for a text of more than one line.
 *
 * As match(), it reads anything but null as its string.
 *
 * @param {*} text anything; null matches nothing.
 * @param {regexp} re the regular expression.
 * @returns {?string[]} the match, or null.
 */
export function match_line(text, re) {
	if (text == null)
		return null;

	let s = (type(text) == 'string') ? text : `${text}`;

	return (index(s, '\n') < 0) ? match(s, re) : null;
};

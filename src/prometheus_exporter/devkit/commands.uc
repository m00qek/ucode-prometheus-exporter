/**
 * The devkit's programs, for a collector that needs exec: an fs mock whose popen answers.
 *
 * @module prometheus_exporter_devkit_commands
 */

'use strict';

import { shell_quote, exec_script, EXEC_KILLED } from 'prometheus_exporter.deps';

const real = require('fs');

/**
 * A command line as the exec capability runs it, each argument single-quoted.
 *
 * @param {string[]} argv
 * @returns {string}
 */
export function line(argv) {
	return join(' ', map(argv, shell_quote));
};

const TAIL = substr(exec_script([ '' ], 1), length("set -- 1 ''"));

/**
 * { seconds, line } of a script deps' exec runs, or null for any other command.
 *
 * @param {string} script
 * @returns {?{ seconds: int, line: string }}
 */
export function parse(script) {
	let head = match(script, /^set -- ([0-9]+) /);

	if (!head || length(script) < length(head[0]) + length(TAIL) || substr(script, -length(TAIL)) != TAIL)
		return null;

	return {
		seconds: +head[1],
		line: substr(script, length(head[0]), length(script) - length(head[0]) - length(TAIL)),
	};
};

/**
 * An fs mock config whose popen runs the programs of `outputs`, by command line.
 *
 * @param {Object<string, { out: ?string, status: ?int, hangs: ?boolean, run: ?string[], seconds: ?int }>} outputs
 * @param {?Object} extra
 * @returns {Object}
 */
export function fs(outputs, extra) {
	return {
		...(extra ?? {}),
		behavior: {
			...(extra?.behavior ?? {}),
			popen: function(cmd, mode) {
				let script = parse(cmd);
				let o = script ? outputs[script.line] : null;

				if (o == null)
					return null;
				if (o.run)
					return real.popen(exec_script(o.run, o.seconds ?? script.seconds), mode);

				return { read: () => o.out ?? '', close: () => o.hangs ? EXEC_KILLED : (o.status ?? 0) };
			},
		},
	};
};

/**
 * The processes whose command line holds `text`, to see that none a program started outlives it.
 *
 * @param {string} text
 * @returns {string[]}
 */
export function running(text) {
	let found;

	for (let tries = 0; tries < 20; tries++) {
		found = [];
		for (let f in real.glob('/proc/[0-9]*/cmdline')) {
			let cmdline = join(' ', split(real.readfile(f) ?? '', '\0'));
			if (index(cmdline, text) >= 0)
				push(found, trim(cmdline));
		}
		if (!length(found))
			break;
		sleep(50);
	}

	return found;
};

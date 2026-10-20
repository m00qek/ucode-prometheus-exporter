/**
 * The devkit's programs, for a collector that needs exec: an fs mock whose popen answers.
 *
 * @module prometheus_exporter_devkit_commands
 */

'use strict';

import { shell_quote, exec_script, EXEC_KILLED, BATCH } from 'prometheus.exporter.deps';

const real = require('fs');

/**
 * A command line as the exec capability runs it, each argument single-quoted.
 *
 * @param {string[]} argv the program and its arguments.
 * @returns {string} the command line.
 */
export function line(argv) {
	return join(' ', map(argv, shell_quote));
};

const TAIL = substr(exec_script([ '' ], 1), length("set -- 1 ''"));

/**
 * { seconds, line } of a script deps' exec runs, or null for any other command.
 *
 * @param {string} script what popen was given.
 * @returns {?{ seconds: int, line: string }} its limit and command line.
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

const BATCH_HEAD = `${BATCH}() {\n`;
const BATCH_LINE = "\nprintf '\\n%s %d\\n' '";

/**
 * { seconds, mark, lines } of a script deps' exec runs for run_all(), or null for any other command.
 *
 * @param {string} script what popen was given.
 * @returns {?{ seconds: int, mark: string, lines: string[] }} its limit, the mark after each output, and its command lines.
 */
export function parse_batch(script) {
	let end = index(script, '\n}\nset -- ');

	if (substr(script, 0, length(BATCH_HEAD)) != BATCH_HEAD || end < 0)
		return null;

	let run = parse(substr(script, end + 3));
	let body = substr(script, length(BATCH_HEAD), end + 1 - length(BATCH_HEAD));
	let at = index(body, BATCH_LINE);

	if (run?.line != shell_quote(BATCH) || at < 0)
		return null;

	let mark = substr(body, at + length(BATCH_LINE));
	mark = substr(mark, 0, index(mark, "'"));

	let lines = split(body, `${BATCH_LINE}${mark}' "$?"\n`);

	if (pop(lines) != '')
		return null;

	return { seconds: run.seconds, mark, lines };
};

function answer(o, seconds) {
	if (o.run) {
		let p = real.popen(exec_script(o.run, o.seconds ?? seconds), 'r');
		let out = p.read('all');
		let status = p.close();

		return { out, status, killed: status == EXEC_KILLED };
	}

	return { out: o.out ?? '', status: o.status ?? 0, killed: o.hangs == true };
}

function batch_handle(outputs, b) {
	for (let line in b.lines)
		if (outputs[line] == null)
			return null;

	let text = '';
	let killed = false;

	for (let line in b.lines) {
		let a = answer(outputs[line], b.seconds);

		text += a.out;
		if (a.killed) {
			killed = true;
			break;
		}
		text += `\n${b.mark} ${a.status}\n`;
	}

	return { read: () => text, close: () => killed ? EXEC_KILLED : 0 };
}

/**
 * An fs mock config whose popen runs the programs of `outputs`, by command line, alone or in a batch (run_all()).
 *
 * @param {Object<string, { out: ?string, status: ?int, hangs: ?boolean, run: ?string[], seconds: ?int }>} outputs
 * @param {?Object} extra the rest of the fs mock's config.
 * @returns {Object} the fs mock's config.
 */
export function fs(outputs, extra) {
	return {
		...(extra ?? {}),
		behavior: {
			...(extra?.behavior ?? {}),
			popen: function(cmd, mode) {
				let b = parse_batch(cmd);

				if (b)
					return batch_handle(outputs, b);

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
 * @param {string} text what their command line holds.
 * @returns {string[]} their command lines.
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

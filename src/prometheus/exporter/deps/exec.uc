/**
 * The exec capability: a collector's programs, under a watchdog.
 *
 * @module prometheus_exporter_deps_exec
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import { EXEC_TIMEOUT } from 'prometheus.exporter.config';

/**
 * deps.exec: exec_channel's object.
 *
 * @typedef {{ run: (argv: string[]) => Result<string>, run_all: (argvs: string[][]) => Result<string>[] }} ExecCapability
 */

/**
 * `arg` single-quoted for the shell, its own single quotes escaped.
 *
 * @param {*} arg anything: it is made a string first.
 * @returns {string} the quoted string.
 */
export function shell_quote(arg) {
	return "'" + replace('' + arg, "'", "'\\''") + "'";
};

/**
 * The seconds a collector's programs get in all in a scrape, by default.
 *
 * @type {int}
 */
export const EXEC_SECONDS = EXEC_TIMEOUT;

/**
 * What a program's handle closes with when the watchdog killed it.
 *
 * @type {int}
 */
export const EXEC_KILLED = -9;

const WALK = [
	'all=$pid new=$pid',
	'while [ -n "$new" ]; do',
	'	parents=" $new " new=',
	'	for f in /proc/[0-9]*/stat; do',
	'		read -r s <"$f" || continue',
	'		set -- ${s##*) }',
	'		case $parents in *" $2 "*)',
	'			p=${f#/proc/} p=${p%/stat}',
	'			kill -STOP "$p" && new="$new $p" all="$all $p";;',
	'		esac',
	'	done',
	'done',
];

const WATCHDOG = join('\n', [
	't=$1; shift',
	'exec 3>&1 2>/dev/null',
	'{ "$@" >&3 3>&- & echo $!; wait $!; echo $?; } | {',
	'	read -r pid',
	'	if read -r -t "$t" st; then exit "$st"; fi',
	'	kill -STOP "$pid"',
	...map(WALK, (l) => '\t' + l),
	'	kill -KILL $all',
	'	kill -KILL $$',
	'}',
	'',
]);

/**
 * The watchdog script popen runs for `argv`, given `seconds`.
 *
 * @param {string[]} argv the program and its arguments.
 * @param {int} seconds what the program may take, in whole seconds.
 * @returns {string} the script.
 */
export function exec_script(argv, seconds) {
	return `set -- ${seconds} ${join(' ', map(argv, shell_quote))}\n${WATCHDOG}`;
};

/**
 * The shell function a batch's programs run in, one after the other.
 *
 * @type {string}
 */
export const BATCH = '_prometheus_exporter_batch';

/**
 * The watchdog script popen runs for the programs of `argvs`, one after the other, given `seconds` for all: each one's output, then a line of `mark` and its exit status.
 *
 * @param {string[][]} argvs the programs and their arguments, one or more.
 * @param {int} seconds what the programs may take together, in whole seconds.
 * @param {string} mark what the line after each program's output starts with.
 * @returns {string} the script.
 */
export function batch_script(argvs, seconds, mark) {
	let body = '';

	for (let argv in argvs)
		body += `${join(' ', map(argv, shell_quote))}\nprintf '\\n%s %d\\n' ${shell_quote(mark)} "$?"\n`;

	return `${BATCH}() {\n${body}}\n${exec_script([ BATCH ], seconds)}`;
};

/**
 * Kills process `pid` and every process under it, as the watchdog kills a program.
 *
 * @param {function(string, string): ?FsProc} popen_fn fs's popen, or a test's.
 * @param {int} pid the process.
 */
export function kill_tree(popen_fn, pid) {
	let p = popen_fn(join('\n', [ `pid=${int(pid)}`, 'kill -STOP "$pid" 2>/dev/null || exit 0', ...WALK, 'kill -KILL $all', '' ]), 'r');

	p?.read('all');
	p?.close();
};

function milliseconds(t) {
	return t[0] * 1000 + t[1] / 1000000;
}

/**
 * The exec channel of one collector in one scrape: run(argv) of the `allowed` programs, and run_all(argvs) of several, one after the other in one watchdog.
 *
 * @param {function(string, string): ?FsProc} popen_fn fs's popen, or a test's.
 * @param {string[]} allowed the programs it may run (meta.commands).
 * @param {?int} seconds the seconds its programs get in all; EXEC_SECONDS when null.
 * @param {?function(): int[]} clock_fn a monotonic clock, [ s, ns ]; clock(true) when null.
 * @param {?float} cutoff when the collector must be done (monotonic seconds); null for no deadline.
 * @returns {ExecCapability} the channel.
 */
export function exec_channel(popen_fn, allowed, seconds, clock_fn, cutoff) {
	seconds ??= EXEC_SECONDS;
	clock_fn ??= () => clock(true);

	let deadline = null;
	let batches = 0;

	function timed_out(details) {
		return Result.err(errors.COMMAND_TIMEOUT, details, { status: null, timed_out: true });
	}

	function cut(details) {
		return Result.err(errors.SCRAPE_DEADLINE, details, { status: null, timed_out: true, deadline: true });
	}

	function not_run(name, at_cutoff) {
		return at_cutoff
			? cut(`${name}: not run, less than a second is left before the scrape's deadline`)
			: timed_out(`${name}: not run, the collector's ${seconds} s for commands are spent`);
	}

	function limit_for() {
		let t = clock_fn();
		let now = milliseconds(t);
		deadline ??= now + seconds * 1000;

		if (now >= deadline)
			return { refused: false };

		let limit = (deadline - now + 999) / 1000;

		if (cutoff != null) {
			let left = int((cutoff * 1000 - now) / 1000);

			if (left < 1)
				return { refused: true };
			if (left < limit)
				return { limit: left, at_cutoff: true, t };
		}

		return { limit, at_cutoff: false, t };
	}

	function killed(name, lim) {
		return lim.at_cutoff
			? cut(`${name}: still running at the scrape's deadline, after ${lim.limit} s, killed`)
			: timed_out(`${name}: still running after ${lim.limit} s, killed`);
	}

	function exited(name, status, out) {
		return status == 0
			? Result.ok(out)
			: Result.err(errors.COMMAND_FAILED, `${name}: exit status ${status}`, { status });
	}

	function cannot_start(name) {
		return Result.err(errors.COMMAND_FAILED, `${name}: cannot start`, { status: null });
	}

	return {
		run: function(argv) {
			if (!(argv[0] in allowed))
				return Result.err(errors.COMMAND_NOT_ALLOWED, argv[0]);

			let lim = limit_for();

			if (lim.limit == null)
				return not_run(argv[0], lim.refused);

			let p = popen_fn(exec_script(argv, lim.limit), 'r');

			if (!p)
				return cannot_start(argv[0]);

			let out = p.read('all');
			let status = p.close();

			return (status == EXEC_KILLED) ? killed(argv[0], lim) : exited(argv[0], status, out);
		},

		run_all: function(argvs) {
			let results = map(argvs, (argv) => (argv[0] in allowed) ? null : Result.err(errors.COMMAND_NOT_ALLOWED, argv[0]));
			let batch = [], at = [];

			for (let i, argv in argvs)
				if (results[i] == null) {
					push(batch, argv);
					push(at, i);
				}

			if (!length(batch))
				return results;

			let lim = limit_for();

			if (lim.limit == null) {
				for (let k, i in at)
					results[i] = not_run(batch[k][0], lim.refused);
				return results;
			}

			let mark = sprintf('%s-%x-%x-%d', BATCH, lim.t[0], lim.t[1], batches++);
			let p = popen_fn(batch_script(batch, lim.limit, mark), 'r');

			if (!p) {
				for (let k, i in at)
					results[i] = cannot_start(batch[k][0]);
				return results;
			}

			let parts = split(p.read('all') ?? '', `\n${mark} `);
			let status = p.close();

			for (let k, i in at) {
				let name = batch[k][0];

				if (k + 1 < length(parts)) {
					let out = (k == 0) ? parts[0] : substr(parts[k], index(parts[k], '\n') + 1);

					results[i] = exited(name, int(substr(parts[k + 1], 0, index(parts[k + 1], '\n'))), out);
				} else if (status == EXEC_KILLED) {
					results[i] = (k + 1 == length(parts)) ? killed(name, lim) : not_run(name, lim.at_cutoff);
				} else {
					results[i] = cannot_start(name);
				}
			}

			return results;
		},
	};
};

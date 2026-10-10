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
 * @typedef {{ run: (argv: string[]) => Result<string> }} ExecCapability
 */

/**
 * `arg` single-quoted for the shell, its own single quotes escaped.
 *
 * @param {*} arg
 * @returns {string}
 */
export function shell_quote(arg) {
	return "'" + replace('' + arg, "'", "'\\''") + "'";
};

/** The seconds a collector's programs get in all in a scrape, by default. */
export const EXEC_SECONDS = EXEC_TIMEOUT;

/** What a program's handle closes with when the watchdog killed it. */
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
 * @param {string[]} argv
 * @param {int} seconds
 * @returns {string}
 */
export function exec_script(argv, seconds) {
	return `set -- ${seconds} ${join(' ', map(argv, shell_quote))}\n${WATCHDOG}`;
};

/**
 * Kills process `pid` and every process under it, as the watchdog kills a program.
 *
 * @param {function(string, string): ?FsProc} popen_fn
 * @param {int} pid
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
 * The exec channel of one collector in one scrape: run(argv) of the `allowed` programs.
 *
 * @param {function(string, string): ?FsProc} popen_fn
 * @param {string[]} allowed
 * @param {?int} seconds
 * @param {?function(): int[]} clock_fn
 * @param {?float} cutoff
 * @returns {ExecCapability}
 */
export function exec_channel(popen_fn, allowed, seconds, clock_fn, cutoff) {
	seconds ??= EXEC_SECONDS;
	clock_fn ??= () => clock(true);

	let deadline = null;

	function timed_out(details) {
		return Result.err(errors.COMMAND_TIMEOUT, details, { status: null, timed_out: true });
	}

	function cut(details) {
		return Result.err(errors.SCRAPE_DEADLINE, details, { status: null, timed_out: true, deadline: true });
	}

	return {
		run: function(argv) {
			if (!(argv[0] in allowed))
				return Result.err(errors.COMMAND_NOT_ALLOWED, argv[0]);

			let now = milliseconds(clock_fn());
			deadline ??= now + seconds * 1000;

			if (now >= deadline)
				return timed_out(`${argv[0]}: not run, the collector's ${seconds} s for commands are spent`);

			let limit = (deadline - now + 999) / 1000;
			let at_cutoff = false;

			if (cutoff != null) {
				let left = int((cutoff * 1000 - now) / 1000);

				if (left < 1)
					return cut(`${argv[0]}: not run, less than a second is left before the scrape's deadline`);
				if (left < limit) {
					limit = left;
					at_cutoff = true;
				}
			}

			let p = popen_fn(exec_script(argv, limit), 'r');

			if (!p)
				return Result.err(errors.COMMAND_FAILED, `${argv[0]}: cannot start`, { status: null });

			let out = p.read('all');
			let status = p.close();

			if (status == EXEC_KILLED)
				return at_cutoff
					? cut(`${argv[0]}: still running at the scrape's deadline, after ${limit} s, killed`)
					: timed_out(`${argv[0]}: still running after ${limit} s, killed`);

			return status == 0
				? Result.ok(out)
				: Result.err(errors.COMMAND_FAILED, `${argv[0]}: exit status ${status}`, { status });
		},
	};
};

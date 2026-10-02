'use strict';

// The exec capability: the programs a collector declares, run without a
// shell's interpretation of their arguments, under a watchdog that kills one
// still running when its seconds are spent.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { EXEC_TIMEOUT } from 'prometheus_exporter.config';

export function shell_quote(arg) {
	return "'" + replace('' + arg, "'", "'\\''") + "'";
};

// The seconds a collector's commands get in all, in one scrape, when nobody
// says otherwise: the main section's exec_timeout by default (see config).
export const EXEC_SECONDS = EXEC_TIMEOUT;

// What a program's handle closes with when the watchdog killed it: the shell
// that ran it, killed by SIGKILL, which nothing else sends it.
export const EXEC_KILLED = -9;

// The shell script popen runs for a program, after a first line that sets $1 to
// the seconds it may take and the rest to its argv (exec_script). Only ash's
// builtins, as procd's jail has /bin/sh and the collectors' programs alone (no
// timeout, sleep or kill programs), and no process groups: ash turns job
// control off without a terminal. So:
//
// - the program runs in the background with its output on popen's pipe (fd 3),
//   while a subshell prints its pid and then its exit status into a pipe;
// - the other end reads the pid, then the status, for at most $1 seconds:
//   read -t, the shell's only clock, which counts whole seconds;
// - when no status came, it stops the program and every process under it,
//   found by their parent in /proc/<pid>/stat, until it finds no more (a
//   stopped process starts no other), then kills them all, and the shell popen
//   started with them: EXEC_KILLED. ssh under a script dies with the script.
//
// Otherwise the script exits with the program's status.
const WATCHDOG = join('\n', [
	't=$1; shift',
	'exec 3>&1 2>/dev/null',
	'{ "$@" >&3 3>&- & echo $!; wait $!; echo $?; } | {',
	'	read -r pid',
	'	if read -r -t "$t" st; then exit "$st"; fi',
	'	kill -STOP "$pid"',
	'	all=$pid new=$pid',
	'	while [ -n "$new" ]; do',
	'		parents=" $new " new=',
	'		for f in /proc/[0-9]*/stat; do',
	'			read -r s <"$f" || continue',
	'			set -- ${s##*) }',
	'			case $parents in *" $2 "*)',
	'				p=${f#/proc/} p=${p%/stat}',
	'				kill -STOP "$p" && new="$new $p" all="$all $p";;',
	'			esac',
	'		done',
	'	done',
	'	kill -KILL $all',
	'	kill -KILL $$',
	'}',
	'',
]);

// What popen runs for argv, given `seconds`: the first line sets the watchdog's
// arguments, each one single-quoted, so no shell interprets them.
export function exec_script(argv, seconds) {
	return `set -- ${seconds} ${join(' ', map(argv, shell_quote))}\n${WATCHDOG}`;
};

function milliseconds(t) {
	return t[0] * 1000 + t[1] / 1000000;
}

// run(argv): the standard output of one of the `allowed` programs, run without a
// shell's interpretation of its arguments. Its standard error is discarded. A
// failure's data is { status }: the exit status, null when it could not start.
//
// The channel's programs get `seconds` (EXEC_SECONDS by default) in all, from
// its first run; a channel is one collector's in one scrape. A program still
// running when they are spent is killed, with whatever it started, and fails
// with COMMAND_TIMEOUT; so does one asked to run after that, without running.
// Their data is { status: null, timed_out: true }. The shell counts whole
// seconds: a program gets what is left rounded up, so the commands of a channel
// take at most a second more than `seconds`. clock_fn: [ s, ns ], monotonic.
//
// `cutoff`, when given, is the time (monotonic seconds) the collector must be
// done by, for its scrape to answer in time: a program never runs past it. It
// gets the whole seconds left before it when they are fewer than its own, and
// does not run when not one is left; killed at the cutoff, or not run, it fails
// with SCRAPE_DEADLINE, its data { status: null, timed_out: true, deadline: true }.
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

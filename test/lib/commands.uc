'use strict';

// Programs for the exec capability to run: an fs mock config whose popen answers
// `outputs[command line]` = { out, status }. utest's own popen mock closes a
// handle without the exit status 25.12's ucode gives, so this replaces it.
// A command line is argv as prometheus_exporter.deps quotes it, each argument
// single-quoted (line()); popen gets it inside deps' watchdog script, which
// parse() takes apart. A command line not listed cannot start (popen gives null).
//
// An output may instead be
// - { hangs: true }: a program the watchdog killed, still running when its
//   seconds were spent;
// - { run: argv, seconds }: argv run for real, under the real watchdog script,
//   with `seconds` (or the seconds deps gave) as its limit: a program that
//   hangs for real, say, without a test waiting for deps' own limit.
//
//   with_collector(nft_counters, { fs: commands.fs({ [commands.line([ 'nft', '--json', 'list', 'counters' ])]: { out: '{}', status: 0 } }) }, ...)

import { shell_quote, exec_script, EXEC_KILLED } from 'prometheus_exporter.deps';

// The real fs: under utest, an import of fs reaches whatever mock is patched in.
const real = require('fs');

export function line(argv) {
	return join(' ', map(argv, shell_quote));
};

// What follows the command line in every script exec_script makes.
const TAIL = substr(exec_script([ '' ], 1), length("set -- 1 ''"));

// { seconds, line } of a script deps' exec runs, or null for any other command.
export function parse(script) {
	let head = match(script, /^set -- ([0-9]+) /);

	if (!head || length(script) < length(head[0]) + length(TAIL) || substr(script, -length(TAIL)) != TAIL)
		return null;

	return {
		seconds: +head[1],
		line: substr(script, length(head[0]), length(script) - length(head[0]) - length(TAIL)),
	};
};

// `extra` is merged into the fs mock config: its data, say.
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

// The processes whose command line holds `text`, to see that none a program
// started outlives it. Ones just killed may take a moment to go: they are looked
// for again for up to a second.
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

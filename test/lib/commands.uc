'use strict';

// Programs for the exec capability to run: an fs mock config whose popen answers
// `outputs[command line]` = { out, status }. utest's own popen mock closes a
// handle without the exit status 25.12's ucode gives, so this replaces it.
// Command lines are as prometheus_exporter.deps runs them: each argument single-quoted,
// then ' 2>/dev/null'. A command line not listed cannot start (popen gives null).
//
//   with_collector(nft_counters, { fs: commands.fs({ [commands.line([ 'nft', '--json', 'list', 'counters' ])]: { out: '{}', status: 0 } }) }, ...)

import { shell_quote } from 'prometheus_exporter.deps';

export function line(argv) {
	return join(' ', map(argv, shell_quote)) + ' 2>/dev/null';
};

// `extra` is merged into the fs mock config: its data, say.
export function fs(outputs, extra) {
	return {
		...(extra ?? {}),
		behavior: {
			...(extra?.behavior ?? {}),
			popen: function(cmd, mode) {
				let o = outputs[cmd];
				return o == null ? null : { read: () => o.out, close: () => o.status ?? 0 };
			},
		},
	};
};

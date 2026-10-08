'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import * as cli from 'prometheus_exporter.cli';
import * as config from 'prometheus_exporter.config';
import * as crypt from 'prometheus_exporter.crypt';
import { with_mods } from 'context';
import { shell_quote } from 'prometheus_exporter.deps';

const COMMAND = 'files/usr/bin/prometheus-exporter';
// ucode takes a module path that is absolute.
const SRC = require('fs').realpath('src');

// A fake prometheus_exporter.app: records what it was asked, answers `reply`.
function app_factory(reply, seen, uci) {
	return function(log, dir) {
		seen.dir = dir;
		log('info', 'loaded');
		return {
			collectors: () => [
				{ id: 'cpu', meta: { name: 'cpu', help: 'CPU time.' } },
				{ id: 'ltq_dsl', meta: { name: 'ltq-dsl', help: 'DSL line.' } },
			],
			scrape: function(q, opts) { seen.query = q; seen.opts = opts; return reply; },
			mods: { uci: { cursor: () => uci } },
		};
	};
}

// cli.run on `argv` as docopt parses it, against a fake system.
function run(argv, extra) {
	let seen = {}, out = [], err = [];
	let status;

	with_mods({ main: extra?.main, uci: { data: { [config.NAME]: { ltq_dsl: { '.type': 'collector', enabled: '0' } } } } }, (mods) => {
		let sys = {
			out: (s) => push(out, s),
			err: (s) => push(err, s),
			clock: () => [ 100, 0 ],
			create: app_factory(extra?.reply ?? { status: '200 OK', body: 'x 1\n' }, seen, mods.uci.cursor()),
			check: function(opts) { seen.check = opts; return extra?.report ?? { ok: true, report: 'ok   main: fine' }; },
			conform: function(path) { seen.conform = path; return extra?.report ?? { ok: false, report: 'FAIL strict mode' }; },
			read_password: () => extra?.password,
			random: (n) => join('', map(split(sprintf('%0' + n + 'd', 0), ''), () => 'r')),
		};

		status = cli.run(cli.parse(argv, 'test'), sys);
	});

	return { status, seen, out: join('', out), err: join('', err) };
}

// The command itself, in a process of its own: docopt exits it on -h,
// --version and arguments it does not take.
function command(args) {
	let p = require('fs').popen(`ucode -L ${SRC} ${COMMAND} ${args} 2>&1; echo "exit $?"`, 'r');
	let out = p.read('all');

	p.close();
	return out;
}

describe('cli.run scrape', () => {
	it('prints a scrape of the named collectors, in that order, within scrape_timeout', () => {
		let r = run([ 'scrape', 'cpu', 'a b' ]);

		assert.match([ 0, 'x 1\n', 'collect[]=cpu&collect[]=a%20b' ], [ r.status, r.out, r.seen.query ]);
		assert.match({ deadline: 109.5, budget: 9.5 }, r.seen.opts);
		assert.match('loaded\n', r.err);
	});

	it('scrapes every enabled collector without names, from --dir when given', () => {
		let r = run([ 'scrape', '--dir', '/src' ], { main: { scrape_timeout: '4' } });

		assert.match([ 0, '', '/src', 3.5 ], [ r.status, r.seen.query, r.seen.dir, r.seen.opts.budget ]);
	});

	it('prints what went wrong and exits 1 when the scrape is refused', () => {
		let r = run([ 'scrape', 'nope' ], { reply: { status: '400 Bad Request', body: "unknown collector 'nope'\n" } });

		assert.match([ 1, '' ], [ r.status, r.out ]);
		assert.match(true, index(r.err, "unknown collector 'nope'") >= 0);
	});
});

describe('cli.run collector list', () => {
	it('lists the installed collectors, whether each is enabled, and what it collects', () => {
		let r = run([ 'collector', 'list', '-d', '/src' ]);

		assert.match([ 0, '/src' ], [ r.status, r.seen.dir ]);
		assert.match(sprintf('%-24s %-8s CPU time.\n%-24s %-8s DSL line.\n', 'cpu', 'enabled', 'ltq-dsl', 'disabled'), r.out);
	});
});

describe('cli.run check', () => {
	it('prints the report, and exits 1 only when the configuration is invalid', () => {
		let good = run([ 'check' ]);
		let bad = run([ 'check', '--config' ], { report: { ok: false, report: 'FAIL main: x' } });

		assert.match([ 0, 'ok   main: fine\n', { config_only: false } ], [ good.status, good.out, good.seen.check ]);
		assert.match([ 1, 'FAIL main: x\n', { config_only: true } ], [ bad.status, bad.out, bad.seen.check ]);
	});
});

describe('cli.run collector check', () => {
	it('checks the module at the path, and exits 1 when it breaks a rule', () => {
		let r = run([ 'collector', 'check', '/tmp/mine.uc' ]);

		assert.match([ 1, 'FAIL strict mode\n', '/tmp/mine.uc' ], [ r.status, r.out, r.seen.conform ]);
		assert.match(0, run([ 'collector', 'check', 'x.uc' ], { report: { ok: true, report: 'ok' } }).status);
	});
});

describe('cli.run hash-password', () => {
	it('prints the hash of the password it read, and never the password', () => {
		let r = run([ 'hash-password' ], { password: 'a long passphrase' });

		assert.match([ 0, '' ], [ r.status, r.err ]);
		assert.match(true, crypt.verify('a long passphrase', rtrim(r.out, '\n')));
		assert.match(-1, index(r.out, 'passphrase'));
	});

	it('refuses an empty password, or none, as hash_password does', () => {
		for (let password in [ '', null ]) {
			let r = run([ 'hash-password' ], { password });

			assert.match([ 1, '' ], [ r.status, r.out ], password);
			assert.match(0, index(r.err, 'password: '), r.err);
		}
	});
});

describe('cli.read_password', () => {
	const quiet = () => null;

	// fs with a terminal, or not, on standard input: the terminal's line is
	// what READ_PASSWORD prints, `line` either way.
	function fs_of(tty, line) {
		let ran = [];
		let fs = {
			stdin: { isatty: () => tty, read: (what) => (what == 'line') ? line : null },
			popen: function(cmd) {
				push(ran, cmd);
				return { read: () => (line == null) ? null : rtrim(line, '\n'), close: () => true };
			},
		};

		return { fs, ran };
	}

	it('reads the terminal by a shell read that keeps the spaces', () => {
		let t = fs_of(true, '  two words  \n');

		assert.match('  two words  ', cli.read_password(t.fs, quiet));
		assert.match([ cli.READ_PASSWORD ], t.ran);
		assert.match(0, index(cli.READ_PASSWORD, 'IFS= read -rs p'));
	});

	prop('the terminal and standard input agree: only the CRs and LFs that end the line go',
		gen.elements('  lead', 'trail  ', ' both ', 'tab\tin', 'cr\r', 'crlf\r\n', ''), (password) => {
			let line = password + '\n';
			let want = rtrim(password, '\r\n');

			want = (want == '') ? null : want;
			assert.match([ want, want ], [ cli.read_password(fs_of(true, line).fs, quiet), cli.read_password(fs_of(false, line).fs, quiet) ], password);
		});

	it('the shell keeps the spaces of the line it reads', () => {
		let p = require('fs').popen(`printf '  two words  \\n' | sh -c ${shell_quote(cli.READ_PASSWORD)}`, 'r');
		let out = p.read('all');

		p.close();
		assert.match('  two words  ', out);
	});

	it('gives null for nothing read', () => {
		assert.match([ null, null ], [ cli.read_password(fs_of(true, null).fs, quiet), cli.read_password(fs_of(false, null).fs, quiet) ]);
	});
});

describe('the prometheus-exporter command', () => {
	it('shows the usage on -h, and the version on --version', () => {
		assert.match(`${trim(cli.USAGE)}\nexit 0\n`, command('-h'));
		assert.match('prometheus-exporter dev\nexit 0\n', command('--version'));
	});

	it('refuses arguments it does not take, and the old form without a command', () => {
		for (let args in [ 'bogus', 'cpu', '-l', 'scrape --nope', 'collector' ]) {
			let out = command(args);

			assert.match([ true, true ], [ index(out, 'prometheus-exporter scrape [--dir=<dir>] [<collector>...]') >= 0, index(out, 'exit 1\n') >= 0 ], args);
		}
	});

	it('hashes a password read from standard input', () => {
		let p = require('fs').popen(`printf 'from stdin\\n' | ucode -L ${SRC} ${COMMAND} hash-password`, 'r');
		let hash = rtrim(p.read('all'), '\n');

		p.close();
		assert.match(true, crypt.verify('from stdin', hash), hash);
	});

	prop('parses every command its usage lists', gen.elements(
		[ 'scrape' ], [ 'scrape', 'cpu', 'wifi' ], [ 'scrape', '-d', '/x', 'cpu' ], [ 'check' ], [ 'check', '--config' ],
		[ 'collector', 'list' ], [ 'collector', 'check', 'a.uc' ], [ 'hash-password' ]), (argv) => {
		let args = cli.parse(argv, 'test');

		assert.match(argv[0], (argv[0] == 'collector') ? (args.collector ? 'collector' : null) : (args[argv[0]] ? argv[0] : null));
	});
});

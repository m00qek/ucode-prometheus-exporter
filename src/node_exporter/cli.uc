'use strict';

// The command line tool: prints a scrape, of every collector or of those named.

export const USAGE = 'usage: prometheus-node-exporter-ucode [-h] [-l] [-d DIR] [COLLECTOR...]\n' +
	'  -h      show this help\n' +
	'  -l      list the installed collectors\n' +
	'  -d DIR  load the collectors from DIR\n';

function urlencode(s) {
	return replace(s, /[^A-Za-z0-9_.~-]/g, (c) => sprintf('%%%02X', ord(c)));
}

// { help, list, dir, names }, or null for arguments it does not take.
export function parse_args(argv) {
	let args = { help: false, list: false, dir: null, names: [] };

	for (let i = 0; i < length(argv); i++) {
		let a = argv[i];

		if (a == '-h')
			args.help = true;
		else if (a == '-l')
			args.list = true;
		else if (a == '-d' && i + 1 < length(argv))
			args.dir = argv[++i];
		else if (substr(a, 0, 1) == '-')
			return null;
		else
			push(args.names, a);
	}

	return args;
};

// The exit status. create(log, dir) is node_exporter.app's.
export function run(argv, create, out, err) {
	let args = parse_args(argv);

	if (!args) {
		err(USAGE);
		return 2;
	}

	if (args.help) {
		out(USAGE);
		return 0;
	}

	let app = create((msg) => err(msg + '\n'), args.dir);

	if (args.list) {
		for (let c in app.collectors)
			out(sprintf('%-24s %s\n', c.meta.name, c.meta.help));
		return 0;
	}

	let res = app.scrape(join('&', map(args.names, (n) => 'collect[]=' + urlencode(n))));
	if (substr(res.status, 0, 3) != '200') {
		err(res.body);
		return 1;
	}

	out(res.body);
	return 0;
};

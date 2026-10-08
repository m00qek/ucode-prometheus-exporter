'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as jail from 'prometheus_exporter.jail';
import * as loader from 'prometheus_exporter.loader';
import * as config from 'prometheus_exporter.config';
import * as Result from 'prometheus_exporter.result';
import { readfile } from 'fs';

function collector(name, meta) {
	let res = loader.validate(loader.id_of(name), { meta: { name, title: 'Test', help: 'Test.', needs: [], ...meta }, collect: () => Result.ok() });

	if (!res.ok)
		die(Result.describe(res));

	return res.data;
}

// A filesystem of regular files at these paths, for which().
function files(paths) {
	return { stat: (p) => p in paths ? { type: 'file' } : (p == '/usr/sbin' ? { type: 'directory' } : null) };
}

// sys over a uci mock with these configs, the exporter's sections in `own`.
function with_sys(own, configs, fs, cb) {
	mock.inject('uci', { strict: true, data: { ...configs, [config.NAME]: own } }, (uci) => {
		cb({ uci: uci.cursor(), fs: fs ?? files([]), path: jail.PATH });
	});
}

const NFT = collector('nft-counters', { needs: [ 'exec' ], commands: [ 'nft' ] });
const TEXTFILE = collector('textfile', { needs: [ 'fs' ], options: { directory: { default: '/var/prometheus', datatype: 'directory', title: 'T', help: 'Where.' } }, paths: [ '{directory}' ] });
const OWNER = collector('owner', { needs: [ 'fs' ], options: { directory: { default: '/var/own', datatype: 'directory', title: 'T', help: 'Where.' } },
	paths: [ { path: '{directory}', owned: true }, '/var/other' ] });
const DHCP = collector('uci_dhcp_host', { needs: [ 'uci' ], configs: [ 'dhcp' ] });
const LOADAVG = collector('loadavg', { needs: [ 'fs' ] });

describe('jail.path_problem', () => {
	it('takes a plain absolute path', () => {
		assert.match([ null, null, null ], map([ '/var/prometheus', '/tmp/dhcp.leases', '/var/run/bmx7/json' ], jail.path_problem));
	});

	it('says what is wrong with anything else', () => {
		assert.match([
			'"var/x" is not an absolute path',
			'null is not an absolute path',
			'"/var/my files" holds a space, a control or a glob character',
			'"/var/x\\n" holds a space, a control or a glob character',
			'"/var/*.prom" holds a space, a control or a glob character',
			'"/var/[ab]" holds a space, a control or a glob character',
			'/var//x is not a plain path (no //, . or .., nor a trailing /)',
			'/var/../etc is not a plain path (no //, . or .., nor a trailing /)',
			'/var/./x is not a plain path (no //, . or .., nor a trailing /)',
			'/var/x/ is not a plain path (no //, . or .., nor a trailing /)',
			'/run is too broad to mount for one collector',
			'/ is too broad to mount for one collector',
		], map([ 'var/x', null, '/var/my files', '/var/x\n', '/var/*.prom', '/var/[ab]', '/var//x', '/var/../etc', '/var/./x', '/var/x/', '/run', '/' ],
			jail.path_problem));
	});

	prop('takes any path of plain names under a directory of its own',
		gen.array(gen.string({ charset: 'abcxyz019_-.', min_len: 1, max_len: 6 }), { min_len: 2, max_len: 4 }), (parts) => {
			let p = '/' + join('/', parts);
			let plain = length(filter(parts, (s) => s == '.' || s == '..')) == 0;

			assert.match(plain, jail.path_problem(p) == null, p);
		});
});

describe('jail.fill', () => {
	it('fills each {option} with its value', () => {
		assert.match('/srv/prom/x', jail.fill('/srv/{dir}/{name}', { dir: 'prom', name: 'x' }));
		assert.match('/var/prometheus', jail.fill('{directory}', { directory: '/var/prometheus' }));
	});

	it('gives null when an option it names is not a string', () => {
		assert.match([ null, null ], [ jail.fill('{directory}', {}), jail.fill('{n}', { n: 1 }) ]);
	});

	it('lists the options a path names', () => {
		assert.match([ 'dir', 'name' ], jail.placeholders('/srv/{dir}/{name}'));
		assert.match([], jail.placeholders('/srv'));
	});
});

describe('jail.which', () => {
	const FS = files([ '/usr/sbin/nft', '/usr/bin/nft', '/bin/busybox' ]);

	it('finds a command in the first directory of the PATH that has it', () => {
		assert.match('/usr/sbin/nft', jail.which(FS, jail.PATH, 'nft'));
		assert.match('/usr/bin/nft', jail.which(FS, '/usr/bin:/usr/sbin', 'nft'));
	});

	it('takes a path as it is, when it is a file', () => {
		assert.match([ '/bin/busybox', null ], [ jail.which(FS, jail.PATH, '/bin/busybox'), jail.which(FS, jail.PATH, '/bin/nope') ]);
	});

	it('gives null for a command no directory has, or a directory', () => {
		assert.match([ null, null ], [ jail.which(FS, jail.PATH, 'ethtool'), jail.which(FS, '/usr:', 'sbin') ]);
	});
});

describe('jail.resolve_paths', () => {
	it('fills strings and calls functions, with the options and the uci handles', () => {
		let seen = [];
		let meta = { paths: [ '{directory}', '/var/run/x', (options, uci) => { push(seen, [ options, uci ]); return [ '/tmp/a', '/var/run/x' ]; } ] };
		let res = jail.resolve_paths(meta, { directory: '/srv/prom' }, { dhcp: 'handle' });

		assert.match({ paths: [ '/srv/prom', '/tmp/a', '/var/run/x' ], owned: [], problems: [] }, res);
		assert.match([ [ { directory: '/srv/prom' }, { dhcp: 'handle' } ] ], seen);
	});

	it('takes an option\'s directory that ends in /, as the collector reads it, as the directory', () => {
		let meta = { paths: [ { path: '{directory}', owned: true } ] };

		assert.match({ paths: [ '/var/prom' ], owned: [ '/var/prom' ], problems: [] }, jail.resolve_paths(meta, { directory: '/var/prom//' }, {}));
		assert.match({ paths: [], owned: [], problems: [ '/ is too broad to mount for one collector' ] }, jail.resolve_paths(meta, { directory: '/' }, {}));
	});

	it('owns a path under /var, /tmp or /etc/prometheus-exporter alone, and makes and mounts no other', () => {
		let meta = { paths: [ { path: '{directory}', owned: true } ] };
		let owned = (d) => jail.resolve_paths(meta, { directory: d }, {});

		for (let d in [ '/var/prom', '/tmp/a/b', '/etc/prometheus-exporter/metrics' ])
			assert.match({ paths: [ d ], owned: [ d ], problems: [] }, owned(d), d);
		for (let d in [ '/srv/prom', '/etc/metrics', '/etc/prometheus-exporterx/a', '/root/prom', '/usr/lib/prom', '/etc/prometheus-exporter' ])
			assert.match({ paths: [], owned: [], problems: [ `${d} is not under /var, /tmp, /etc/prometheus-exporter: the service makes and mounts no other directory` ] },
				owned(d), d);
	});

	it('still takes a path of another service\'s outside them, which it does not own', () => {
		assert.match({ paths: [ '/srv/sock' ], owned: [], problems: [] }, jail.resolve_paths({ paths: [ '{directory}' ] }, { directory: '/srv/sock' }, {}));
	});

	it('says which paths are owned, and owns none that is not a mount', () => {
		let meta = { paths: [ { path: '{directory}', owned: true }, '/var/run/x' ] };

		assert.match({ paths: [ '/var/prom', '/var/run/x' ], owned: [ '/var/prom' ], problems: [] },
			jail.resolve_paths(meta, { directory: '/var/prom' }, {}));
		assert.match({ paths: [ '/var/run/x' ], owned: [], problems: [ '/tmp is too broad to mount for one collector' ] },
			jail.resolve_paths(meta, { directory: '/tmp' }, {}));
	});

	it('leaves out what is not a mount, and says why', () => {
		let meta = { paths: [
			'{directory}',
			() => die('no dhcp\nat line 3'),
			() => '/tmp/a',
			() => [ '/tmp/ok', 'relative', '/tmp' ],
		] };

		assert.match({ paths: [ '/tmp/ok' ], owned: [], problems: [
			'"" is not an absolute path',
			'a paths function failed: no dhcp',
			'a paths function returned string, not an array',
			'"relative" is not an absolute path',
			'/tmp is too broad to mount for one collector',
		] }, jail.resolve_paths(meta, { directory: '' }, {}));
	});
});

describe('jail.collector', () => {
	it('gives an exec collector the shell and its commands where the PATH has them', () => {
		with_sys({}, {}, files([ '/usr/sbin/nft' ]), (sys) => {
			let j = jail.collector(NFT, sys);

			assert.match({ enabled: true, configs: [], paths: [], commands: { nft: '/usr/sbin/nft' }, mounts: [ '/bin/sh', '/usr/sbin/nft' ], problems: [] },
				{ enabled: j.enabled, configs: j.configs, paths: j.paths, commands: j.commands, mounts: j.mounts, problems: j.problems });
		});
	});

	it('says which command is missing', () => {
		with_sys({}, {}, null, (sys) => {
			let j = jail.collector(NFT, sys);
			assert.match([ { nft: null }, [ '/bin/sh' ], [ 'command nft is not on /usr/sbin:/usr/bin:/sbin:/bin' ] ], [ j.commands, j.mounts, j.problems ]);
		});
	});

	it('does without an optional command that is not there, and mounts it when it is', () => {
		let ntp = collector('ntp', { needs: [ 'exec' ], commands: [ 'nft', 'chronyc' ], optional_commands: [ 'chronyc' ] });

		with_sys({}, {}, files([ '/usr/sbin/nft' ]), (sys) => {
			let j = jail.collector(ntp, sys);
			assert.match([ { nft: '/usr/sbin/nft', chronyc: null }, [ '/bin/sh', '/usr/sbin/nft' ], [] ], [ j.commands, j.mounts, j.problems ]);
		});
		with_sys({}, {}, files([ '/usr/bin/chronyc' ]), (sys) => {
			let j = jail.collector(ntp, sys);
			assert.match([ { nft: null, chronyc: '/usr/bin/chronyc' }, [ '/bin/sh', '/usr/bin/chronyc' ], [ 'command nft is not on /usr/sbin:/usr/bin:/sbin:/bin' ] ],
				[ j.commands, j.mounts, j.problems ]);
		});
	});

	it('mounts its paths that are there, and says which are not', () => {
		with_sys({}, {}, files([ '/var/prometheus' ]), (sys) => {
			let j = jail.collector(TEXTFILE, sys);
			assert.match([ [], [ '/var/prometheus' ] ], [ j.missing, j.mounts ]);
		});
		with_sys({}, {}, null, (sys) => {
			let j = jail.collector(TEXTFILE, sys);
			assert.match([ [ '/var/prometheus' ], [ '/var/prometheus' ], [] ], [ j.paths, j.missing, j.mounts ]);
		});
	});

	it('gives the configs a collector declares, and its paths for its options', () => {
		with_sys({ textfile: { '.type': 'collector', directory: '/srv/prom' } }, {}, files([ '/srv/prom' ]), (sys) => {
			assert.match([ '/etc/config/dhcp' ], jail.collector(DHCP, sys).mounts);
			assert.match([ '/srv/prom' ], jail.collector(TEXTFILE, sys).mounts);
			assert.match({ directory: '/srv/prom' }, jail.collector(TEXTFILE, sys).options.data);
		});
	});

	it('mounts an owned path, there or not, and does not wait for it', () => {
		with_sys({}, {}, null, (sys) => {
			let j = jail.collector(OWNER, sys);
			assert.match([ [ '/var/other', '/var/own' ], [ '/var/own' ], [ '/var/own' ], [ '/var/other' ] ], [ j.paths, j.owned, j.mounts, j.missing ]);
		});
	});

	it('owns an owned path where its option puts it', () => {
		with_sys({ owner: { '.type': 'collector', directory: '/var/own2' } }, {}, files([ '/var/other' ]), (sys) => {
			assert.match([ '/var/own2' ], jail.collector(OWNER, sys).owned);
		});
	});

	it('hands a paths function read-only handles for the configs declared', () => {
		let leases = collector('leases', {
			needs: [ 'fs', 'uci' ], configs: [ 'dhcp' ],
			paths: [ (options, uci) => map(uci.dhcp.sections('dnsmasq'), (s) => s.leasefile ?? '/tmp/dhcp.leases') ],
		});
		let dhcp = { dhcp: { a: { '.type': 'dnsmasq' }, b: { '.type': 'dnsmasq', leasefile: '/tmp/guest.leases' } } };

		with_sys({}, dhcp, files([ '/tmp/dhcp.leases', '/tmp/guest.leases' ]), (sys) => {
			assert.match([ '/etc/config/dhcp', '/tmp/dhcp.leases', '/tmp/guest.leases' ], jail.collector(leases, sys).mounts);
		});
	});

	it('cannot resolve the paths of a collector whose options are invalid', () => {
		with_sys({ textfile: { '.type': 'collector', directory: [ 'a', 'b' ] } }, {}, null, (sys) => {
			let j = jail.collector(TEXTFILE, sys);

			assert.match([ [], [ 'its paths are not known: CONFIG_INVALID (directory: expected a single value, got [ "a", "b" ])' ] ],
				[ j.mounts, j.problems ]);
		});
	});
});

describe('jail.mounts', () => {
	it('mounts the exporter config alone for collectors that read procfs, sysfs or ubus', () => {
		with_sys({}, {}, null, (sys) => {
			assert.match({ mounts: [ jail.OWN_CONFIG ], problems: [], missing: [], owned: [] }, jail.mounts([ LOADAVG ], sys));
		});
	});

	it('mounts what the enabled collectors get, sorted, once each, and names the collector of a problem', () => {
		let own = { uci_dhcp_host: { '.type': 'collector', enabled: '0' } };

		with_sys(own, {}, files([ '/usr/sbin/nft', '/var/prometheus' ]), (sys) => {
			let dhcp_too = collector('dhcp_leases', { needs: [ 'uci', 'exec' ], configs: [ 'dhcp' ], commands: [ 'nft', 'odhcpd' ] });

			assert.match({
				mounts: [ '/bin/sh', '/etc/config/dhcp', jail.OWN_CONFIG, '/usr/sbin/nft', '/var/prometheus' ],
				problems: [ 'dhcp_leases: command odhcpd is not on /usr/sbin:/usr/bin:/sbin:/bin' ],
				missing: [],
				owned: [],
			}, jail.mounts([ DHCP, LOADAVG, NFT, TEXTFILE, dhcp_too ], sys));
		});
	});

	it('leaves out the paths that are not there, and lists them', () => {
		let socket = collector('unbound', {
			needs: [ 'socket' ],
			options: { socket: { default: '/var/lib/unbound/unbound.ctl', datatype: 'file', title: 'T', help: 'Where.' } },
			paths: [ (options) => [ '/var/lib/unbound' ] ],
		});

		with_sys({}, {}, files([ '/var/prometheus' ]), (sys) => {
			assert.match({ mounts: [ jail.OWN_CONFIG, '/var/prometheus' ], problems: [], missing: [ '/var/lib/unbound' ], owned: [] },
				jail.mounts([ socket, TEXTFILE ], sys));
		});
	});

	it('does not wait for the paths of a disabled collector, nor make those it owns', () => {
		with_sys({ textfile: { '.type': 'collector', enabled: '0' }, owner: { '.type': 'collector', enabled: '0' } }, {}, null, (sys) => {
			assert.match([ [], [] ], [ jail.mounts([ TEXTFILE, OWNER ], sys).missing, jail.mounts([ TEXTFILE, OWNER ], sys).owned ]);
		});
	});

	it('lists what the enabled collectors own', () => {
		with_sys({}, {}, files([ '/var/other' ]), (sys) => {
			assert.match({ mounts: [ jail.OWN_CONFIG, '/var/other', '/var/own' ], problems: [], missing: [], owned: [ '/var/own' ] },
				jail.mounts([ OWNER ], sys));
		});
	});

	it('leaves out what a disabled collector would get', () => {
		with_sys({ uci_dhcp_host: { '.type': 'collector', enabled: 'off' } }, {}, null, (sys) => {
			assert.match([ jail.OWN_CONFIG ], jail.mounts([ DHCP ], sys).mounts);
		});
	});

	prop('mounts are sorted and unique, and always hold the exporter config',
		gen.array(gen.elements('dhcp', 'textfile', 'nft', 'loadavg'), { min_len: 0, max_len: 6 }), (picked) => {
			let all = { dhcp: DHCP, textfile: TEXTFILE, nft: NFT, loadavg: LOADAVG };

			with_sys({}, {}, files([ '/usr/sbin/nft' ]), (sys) => {
				let m = jail.mounts(map(picked, (k) => all[k]), sys).mounts;

				assert.match(sort(uniq([ ...m ])), m);
				assert.match(true, jail.OWN_CONFIG in m);
			});
		});
});

describe('jail.COMMON', () => {
	// The init script's lines that mount something, its variables filled in.
	function init_lines(text) {
		let vars = { NAME: config.NAME };
		let out = [];

		vars.STATE = `/var/run/${vars.NAME}/state`;

		for (let line in split(text, '\n')) {
			let m = match(line, /^\t(\[ [^]]* \] && )?(procd_add_jail[a-z_]*) (.*)$/);

			if (m)
				push(out, `${m[2]} ${replace(replace(m[3], /"/g, ''), /\$([A-Z]+)/g, (all, v) => vars[v] ?? all)}`);
		}

		return out;
	}

	it('is what the jail gives, the service\'s own mounts, its config and its state', () => {
		assert.match(sort([ ...jail.GIVEN, ...jail.SERVICE, jail.OWN_CONFIG, '/var/run/prometheus-exporter/state' ]), sort([ ...jail.COMMON ]));

		with_sys({}, {}, null, (sys) => {
			assert.match([ jail.OWN_CONFIG ], jail.mounts([], sys).mounts);
		});
	});

	it('is what the init script has procd mount: jail.uc\'s, but for TLS\'s, basic auth\'s and the state', () => {
		let text = readfile('files/etc/init.d/prometheus-exporter');

		assert.match([
			'procd_add_jail prometheus-exporter log procfs sysfs $ubus',
			'procd_add_jail_mount $(echo $mounts | grep -vx $UBUS_SOCKET)',
			'procd_add_jail_mount $cert $key /lib/libustream-*.so* /usr/lib/libustream-*.so*',
			'procd_add_jail_mount $auth',
			'procd_add_jail_mount_rw /var/run/prometheus-exporter/state',
		], init_lines(text));
		// The socket it takes for the jail's ubus option is the one a collector's mounts name.
		assert.match(true, index(text, `\nUBUS_SOCKET=${jail.UBUS_SOCKET}\n`) >= 0);
		assert.match(true, index(text, '\n\techo "$mounts" | grep -qx "$UBUS_SOCKET" && ubus=ubus\n') >= 0);
	});

	it('jail.uc prints the service\'s own mounts with the collectors\'', () => {
		let text = readfile('files/usr/libexec/prometheus-exporter/jail.uc');

		assert.match(true, index(text, "print(join('\\n', uniq([ ...jail.SERVICE, ...res.mounts ])), '\\n');") >= 0);
	});
});

describe('jail.mounts and ubus', () => {
	const UBUS = collector('openwrt', { needs: [ 'ubus' ] });

	it('the jail has it while a collector that needs ubus is enabled, and only then', () => {
		with_sys({}, {}, null, (sys) => {
			assert.match([ true, false ], [ jail.UBUS_SOCKET in jail.mounts([ UBUS, LOADAVG ], sys).mounts, jail.UBUS_SOCKET in jail.mounts([ LOADAVG, DHCP ], sys).mounts ]);
		});
		with_sys({ openwrt: { '.type': 'collector', enabled: '0' } }, {}, null, (sys) => {
			assert.match(false, jail.UBUS_SOCKET in jail.mounts([ UBUS, LOADAVG ], sys).mounts);
		});
	});

	it('is no path of the service\'s own', () => {
		assert.match(false, jail.UBUS_SOCKET in jail.COMMON);
	});
});

describe('jail.make', () => {
	// A filesystem with these directories, that records what it makes, and
	// cannot make those of `refuse`.
	function dirs(present, refuse) {
		let made = [];
		let fs = {
			stat: (p) => (p in present || p in made) ? { type: 'directory' } : null,
			mkdir: function(p, mode) {
				if (p in (refuse ?? []))
					return null;
				push(made, [ p, mode ]);
				push(made, p);
				return true;
			},
			error: () => 'Permission denied',
		};

		return { fs, made: () => filter(made, (m) => type(m) == 'array') };
	}

	it('makes a directory that is not there, and its parents', () => {
		let d = dirs([ '/var' ]);

		assert.match({ made: [ '/var/prometheus', '/srv/a/b' ], problems: [] }, jail.make(d.fs, [ '/var/prometheus', '/srv/a/b' ]));
		assert.match([ [ '/var/prometheus', 0755 ], [ '/srv', 0755 ], [ '/srv/a', 0755 ], [ '/srv/a/b', 0755 ] ], d.made());
	});

	it('leaves one that is there as it is', () => {
		let d = dirs([ '/var', '/var/prometheus' ]);

		assert.match({ made: [], problems: [] }, jail.make(d.fs, [ '/var/prometheus' ]));
		assert.match([], d.made());
	});

	it('says what it cannot make, and goes on', () => {
		let d = dirs([], [ '/ro' ]);

		assert.match({ made: [ '/w' ], problems: [ 'cannot make /ro: Permission denied' ] }, jail.make(d.fs, [ '/ro/x', '/w' ]));
	});
});

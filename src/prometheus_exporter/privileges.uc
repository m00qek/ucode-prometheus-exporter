/**
 * What the service's user may do besides reading what its jail mounts, as
 * the collectors declare it, and what the service makes of their
 * declarations when it starts.
 *
 * uhttpd runs in the jail as the user and group prometheus-exporter (USER,
 * GROUP), which the package makes, not as root: ubusd holds it to an ACL,
 * and the kernel to its capabilities and to what its groups may read. So a
 * collector declares, in its meta, what it needs of them (meta_problem()
 * says what is wrong with a declaration, for the loader):
 *
 *   ubus          the ubus objects and methods it calls, { object: [ method ] };
 *                 an object that ends in '.*' stands for every object whose
 *                 name starts with the rest (hostapd's, one per interface),
 *                 and the methods may be a function of its options, where an
 *                 option decides whether it calls them (wireguard's
 *                 peer_names). With 'ubus' in meta.needs, and only then.
 *   capabilities  the capabilities its reads or programs need, of
 *                 COLLECTOR_CAPABILITIES (nft's CAP_NET_ADMIN).
 *   groups        the groups whose sockets it connects to (unbound's).
 *   proc_files    the files of /proc that only root reads, which it reads
 *                 (/proc/net/nf_conntrack); with 'fs' in meta.needs.
 *
 * When the service starts, its init script has jail.uc --make grant, as
 * root, what its installed and enabled collectors declare, and nothing more
 * (make()):
 *
 * - the ubus ACL of their calls (acl()), in ACL_FILE, where the link the
 *   package installs in ubusd's ACL directory (ACL_LINK) points; ubusd reads
 *   it again (SIGHUP). It always has CANARY, by which a collector tells an
 *   ACL ubusd has not loaded from an object that is not there;
 * - the capabilities procd has ujail give the jail (capabilities_doc()), in
 *   CAPABILITIES_FILE: theirs, and CAP_NET_BIND_SERVICE when the service
 *   listens on a port under 1024;
 * - the user's membership of their groups, and of no other group a
 *   collector declares;
 * - read access for GROUP to the configs the jail mounts, the exporter's
 *   own among them, and to their proc files; taken back from those of the
 *   installed collectors that are not enabled. uci commit gives a config
 *   back to root's group, and the reload it triggers gives it to GROUP again,
 *   before procd restarts uhttpd with the new file;
 * - copies of the TLS certificate and key, which only root reads, as
 *   TLS_CERT and TLS_KEY, readable by GROUP.
 *
 * Stopped, the service takes the ACL, the capabilities and the copies away
 * (clean()). A collector is held to what it declared as it runs, too
 * (prometheus_exporter.deps): a ubus call it did not declare is refused
 * (UBUS_NOT_ALLOWED), and what the system refuses it fails as
 * PERMISSION_DENIED, never as nothing to observe.
 *
 * @module prometheus_exporter_privileges
 */

'use strict';

/**
 * What a collector's privileges add up to, for the enabled collectors
 * (prometheus_exporter.jail's grants): what make() grants, and what it takes
 * back.
 *
 * @typedef {{
 *   ubus: Object<string, string[]>,
 *   capabilities: string[],
 *   groups: string[],
 *   groups_off: string[],
 *   files: string[],
 *   files_off: string[],
 *   tls: ?{ cert: string, key: string },
 *   port: int,
 *   problems: string[]
 * }} Grants
 */

/**
 * The service's user, which uhttpd runs as in the jail: the service's name
 * (prometheus_exporter.config's NAME), made by the package (USERID).
 *
 * @type {string}
 */
export const USER = 'prometheus-exporter';

/**
 * The service's group, the user's own.
 *
 * @type {string}
 */
export const GROUP = USER;

/**
 * The capabilities a collector may declare, with their numbers: those that
 * read what the kernel keeps for an administrator. None that would let a
 * collector read past its jail (CAP_DAC_READ_SEARCH opens any file by
 * handle) or change the system.
 *
 * @type {Object<string, int>}
 */
export const COLLECTOR_CAPABILITIES = { CAP_NET_ADMIN: 12, CAP_NET_RAW: 13 };

/**
 * Every capability the service may grant, with its number: a collector's,
 * and the service's own, to listen on a port under 1024.
 *
 * @type {Object<string, int>}
 */
export const CAPABILITIES = { CAP_NET_BIND_SERVICE: 10, ...COLLECTOR_CAPABILITIES };

/**
 * The lowest port that needs no capability to listen on.
 *
 * @type {int}
 */
export const UNPRIVILEGED_PORT = 1024;

/**
 * The run directory of the service (prometheus_exporter.state's RUN_DIR).
 *
 * @type {string}
 */
export const RUN_DIR = `/var/run/${USER}`;

/**
 * The capabilities file procd has ujail apply to the jail (-C).
 *
 * @type {string}
 */
export const CAPABILITIES_FILE = `${RUN_DIR}/capabilities.json`;

/**
 * The copies of the TLS certificate and key uhttpd reads.
 *
 * @type {string}
 */
export const TLS_CERT = `${RUN_DIR}/tls.crt`;

/**
 * The copy of the TLS key, readable by GROUP.
 *
 * @type {string}
 */
export const TLS_KEY = `${RUN_DIR}/tls.key`;

/**
 * The ubus ACL, which ubusd, running as its own user, reads: outside the
 * service's run directory, which only root may enter.
 *
 * @type {string}
 */
export const ACL_FILE = `/var/run/${USER}.acl.json`;

/**
 * The link the package installs in ubusd's ACL directory, to ACL_FILE; while
 * the service is stopped it points nowhere, and ubusd skips it.
 *
 * @type {string}
 */
export const ACL_LINK = `/usr/share/acl.d/${USER}.json`;

/**
 * The call every ACL of the service allows, whatever the collectors declare:
 * a lookup of its object fails ('Not found') only when ubusd has not loaded
 * the ACL. The board's name and release, as luci-base's ACL allows `nobody`.
 *
 * @type {{ object: string, method: string }}
 */
export const CANARY = { object: 'system', method: 'board' };

/**
 * The file of the system's groups.
 *
 * @type {string}
 */
export const GROUP_FILE = '/etc/group';

/**
 * The lock OpenWrt's tools take to change GROUP_FILE (lock /var/lock/passwd).
 *
 * @type {string}
 */
export const GROUP_LOCK = '/var/lock/passwd';

// A ubus object's name, or a prefix of names ending in '.*'.
const OBJECT = /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*(\.\*)?$/;
const METHOD = /^[A-Za-z0-9_-]+$/;
const GROUP_NAME = /^[a-z_][a-z0-9_-]*$/;
const PROC_FILE = /^\/proc(\/[A-Za-z0-9_.:-]+)+$/;

function is_strings(v, pattern) {
	if (type(v) != 'array' || length(uniq(v)) != length(v))
		return false;

	for (let s in v)
		if (type(s) != 'string' || !match(s, pattern))
			return false;

	return true;
}

/**
 * What is wrong with a collector's declarations of meta.ubus,
 * meta.capabilities, meta.groups and meta.proc_files, or null.
 *
 * @param {Meta} meta the collector's meta; its needs already checked.
 * @returns {?string} what is wrong, as the loader says it.
 */
export function meta_problem(meta) {
	let needs = meta.needs ?? [];

	if ('ubus' in needs) {
		if (type(meta.ubus) != 'object' || !length(meta.ubus))
			return 'meta.ubus must list the ubus objects and methods it calls: { object: [ method ] }';

		for (let object, methods in meta.ubus) {
			if (!match(object, OBJECT))
				return `meta.ubus: '${object}' is not the name of a ubus object, nor a prefix of names that ends in '.*'`;
			if (type(methods) != 'function' && (!is_strings(methods, METHOD) || !length(methods)))
				return `meta.ubus: ${object}: its methods must be a list of names, or a function of its options that gives one`;
		}
	} else if (meta.ubus != null) {
		return 'meta.ubus without ubus in meta.needs';
	}

	if (meta.capabilities != null) {
		if (!is_strings(meta.capabilities, /^CAP_[A-Z_]+$/) || !length(meta.capabilities))
			return 'meta.capabilities must list capabilities once each';
		for (let cap in meta.capabilities)
			if (!(cap in keys(COLLECTOR_CAPABILITIES)))
				return `meta.capabilities: ${cap} is not one a collector may have: ${join(', ', keys(COLLECTOR_CAPABILITIES))}`;
	}

	if (meta.groups != null && (!is_strings(meta.groups, GROUP_NAME) || !length(meta.groups) || GROUP in meta.groups))
		return 'meta.groups must list the names of other groups, once each';

	if (meta.proc_files != null) {
		if (!('fs' in needs))
			return 'meta.proc_files without fs in meta.needs';
		if (!is_strings(meta.proc_files, PROC_FILE) || !length(meta.proc_files) ||
		    length(filter(meta.proc_files, (p) => match(p, /\/\.\.?(\/|$)/))))
			return 'meta.proc_files must list plain paths under /proc, once each';
	}

	return null;
};

/**
 * The ubus calls a collector declares, for its options: { ubus, problems },
 * ubus an object's methods by object, sorted, those a function gave none
 * left out.
 *
 * @param {Meta} meta the collector's meta.
 * @param {?Object} options its options, typed.
 * @returns {{ ubus: Object<string, string[]>, problems: string[] }} the
 *   calls, and what a function of them got wrong.
 */
export function ubus_of(meta, options) {
	let ubus = {};
	let problems = [];

	for (let object in sort(keys(meta.ubus ?? {}))) {
		let methods = meta.ubus[object];

		if (type(methods) == 'function') {
			try {
				methods = methods(options ?? {});
			} catch (e) {
				push(problems, `meta.ubus: ${object}: its function failed: ${split(e.message, '\n')[0]}`);
				continue;
			}

			if (type(methods) == 'array' && !length(methods))
				continue;
			if (!is_strings(methods, METHOD)) {
				push(problems, `meta.ubus: ${object}: its function returned ${sprintf('%J', methods)}, not a list of method names`);
				continue;
			}
		}

		ubus[object] = sort([ ...methods ]);
	}

	return { ubus, problems };
};

/**
 * Whether `declared` (ubus_of's ubus) allows `method` of `object`, as ubusd
 * matches an ACL: an object by its name, or by a prefix that ends in '.*'.
 *
 * @param {Object<string, string[]>} declared the calls.
 * @param {string} object the object called.
 * @param {string} method its method.
 * @returns {boolean} whether it is declared.
 */
export function allows(declared, object, method) {
	if (type(object) != 'string' || type(method) != 'string')
		return false;

	for (let o, methods in declared) {
		let named = (o == object) ||
			(substr(o, -2) == '.*' && substr(object, 0, length(o) - 1) == substr(o, 0, -1));

		if (named && method in methods)
			return true;
	}

	return false;
};

/**
 * One map of the ubus calls of many: each object's methods, sorted, once
 * each.
 *
 * @param {Object<string, string[]>[]} maps the calls, as ubus_of gives them.
 * @returns {Object<string, string[]>} their union, by object, sorted.
 */
export function merge(maps) {
	let all = {};

	for (let m in maps)
		for (let object, methods in m) {
			all[object] ??= [];
			push(all[object], ...methods);
		}

	let out = {};

	for (let object in sort(keys(all)))
		out[object] = sort(uniq(all[object]));

	return out;
};

/**
 * The ubus ACL of the service's user for these calls, as ubusd reads it
 * from /usr/share/acl.d: CANARY's and theirs.
 *
 * @param {Object<string, string[]>} ubus the calls (merge's).
 * @returns {Object} the ACL.
 */
export function acl(ubus) {
	let access = {};
	let calls = merge([ ubus, { [CANARY.object]: [ CANARY.method ] } ]);

	for (let object, methods in calls)
		access[object] = { methods };

	return { user: USER, access };
};

/**
 * The capabilities file of these capabilities, as procd hands ujail one
 * (-C): every set of them alike, so the jail and the programs it runs
 * (ambient) have them, and none other (bounding).
 *
 * @param {string[]} caps the capabilities.
 * @returns {Object} the file's contents.
 */
export function capabilities_doc(caps) {
	let set = sort(uniq(caps));

	return { bounding: set, effective: set, ambient: set, permitted: set, inheritable: set };
};

/**
 * The capabilities of `wanted` that a process lacks, by its
 * /proc/<pid>/status (CapEff); null when the text does not say.
 *
 * @param {?string} status the text of /proc/<pid>/status.
 * @param {string[]} wanted capabilities of CAPABILITIES.
 * @returns {?string[]} those it lacks, or null.
 */
export function lacking(status, wanted) {
	let m = match(status ?? '', /\nCapEff:\s*([0-9a-fA-F]+)/);

	if (!m)
		return null;

	let eff = int(m[1], 16);

	return filter(wanted, (cap) => CAPABILITIES[cap] == null || !((eff >> CAPABILITIES[cap]) & 1));
};

/**
 * The capabilities the jail has for these grants: the enabled collectors',
 * and CAP_NET_BIND_SERVICE when the service listens on a port under
 * UNPRIVILEGED_PORT; sorted.
 *
 * @param {Grants} grants the grants.
 * @returns {string[]} the capabilities.
 */
export function service_capabilities(grants) {
	let caps = [ ...grants.capabilities ];

	if (grants.port < UNPRIVILEGED_PORT)
		push(caps, 'CAP_NET_BIND_SERVICE');

	return sort(uniq(caps));
};

// ---- what the service grants, as root, when it starts ------------------------

/**
 * The text of /etc/group with `user` a member of the groups `want` says true
 * of, and of none it says false of: { text, missing }, text null when
 * nothing changes, missing the groups it would join that are not there.
 *
 * @param {string} text the file's text.
 * @param {string} user the user.
 * @param {Object<string, boolean>} want membership by group.
 * @returns {{ text: ?string, missing: string[] }} the new text, and what is
 *   not there.
 */
export function membership(text, user, want) {
	let changed = false;
	let seen = {};
	let lines = map(split(text, '\n'), function(line) {
		let f = split(line, ':');

		if (length(f) != 4 || want[f[0]] == null)
			return line;

		seen[f[0]] = true;

		let members = filter(split(f[3], ','), (m) => m != '');
		let is = user in members;

		if (is == want[f[0]])
			return line;

		changed = true;
		members = want[f[0]] ? [ ...members, user ] : filter(members, (m) => m != user);
		return join(':', [ f[0], f[1], f[2], join(',', members) ]);
	});

	return {
		text: changed ? join('\n', lines) : null,
		missing: sort(filter(keys(want), (g) => want[g] && !seen[g])),
	};
};

/**
 * The gid of `group` in the text of /etc/group, or null.
 *
 * @param {string} text the file's text.
 * @param {string} group the group's name.
 * @returns {?int} its gid.
 */
export function gid_of(text, group) {
	for (let line in split(text ?? '', '\n')) {
		let f = split(line, ':');

		if (length(f) == 4 && f[0] == group && match(f[2], /^[0-9]+$/))
			return +f[2];
	}

	return null;
};

// `text` as `path`, whole, `mode`, owned by root and `gid` (null: root's),
// unless it holds that already: whether it changed, or null when it failed.
function write(fs, path, text, mode, gid) {
	let st = fs.stat(path);

	if (st != null && st.mode == mode && st.gid == (gid ?? 0) && fs.readfile(path) == text)
		return false;

	let tmp = `${path}.new`;
	let f = fs.open(tmp, 'w', mode);
	let ok = f != null && f.write(text) == length(text);

	ok = (f?.close() ?? false) && ok && fs.chown(tmp, 0, gid ?? 0) && fs.chmod(tmp, mode) && fs.rename(tmp, path);
	if (!ok) {
		fs.unlink(tmp);
		return null;
	}

	return true;
}

// Gives `gid` read access to `path` (and nothing more of the group's), or
// takes it back (root's group again); whether it changed, null when it
// failed. A path that is not there is left alone.
function share(fs, path, gid, on) {
	let st = fs.stat(path);

	if (st == null)
		return false;

	if (on) {
		let mode = (st.mode & ~0o070) | 0o040;

		if (st.gid == gid && st.mode == mode)
			return false;

		return (fs.chown(path, -1, gid) && fs.chmod(path, mode)) ? true : null;
	}

	if (st.gid != gid)
		return false;

	return fs.chown(path, -1, 0) ? true : null;
}

/**
 * Grants what `grants` says, as the module's top comment does, and takes back
 * what it says to: { made, problems }, each a line for the log. sys: { fs:
 * the fs module, or an object of its stat, readfile, open, chown, chmod,
 * rename, unlink and error; lock: a function that takes GROUP_LOCK and
 * returns the function that lets go of it; reload_ubus: a function that has
 * ubusd read its ACLs again }.
 *
 * @param {{ fs: module:fs, lock: function(): function(): void, reload_ubus: function(): boolean }} sys
 *   the system.
 * @param {Grants} grants what to grant; port, the port the service listens
 *   on.
 * @returns {{ made: string[], problems: string[] }} what it did, and what it
 *   could not.
 */
export function make(sys, grants) {
	let fs = sys.fs;
	let made = [];
	let problems = [];
	let unlock = sys.lock();
	let groups_text = fs.readfile(GROUP_FILE);
	let gid = gid_of(groups_text, GROUP);

	if (gid == null) {
		unlock();
		return { made, problems: [ `no group ${GROUP} in ${GROUP_FILE}: reinstall the package, which makes it` ] };
	}

	let want = {};

	for (let g in grants.groups_off)
		want[g] = false;
	for (let g in grants.groups)
		want[g] = true;

	let m = membership(groups_text, USER, want);

	for (let g in m.missing)
		push(made, `no group ${g}: ${USER} joins it once it is there`);
	if (m.text != null) {
		if (write(fs, GROUP_FILE, m.text, fs.stat(GROUP_FILE)?.mode ?? 0o644, null) == null)
			push(problems, `cannot write ${GROUP_FILE}: ${fs.error() ?? 'unknown error'}`);
		else
			push(made, `${USER} is a member of ${length(grants.groups) ? join(', ', grants.groups) : 'no group a collector declares'}`);
	}

	unlock();

	for (let on in [ false, true ])
		for (let p in (on ? grants.files : grants.files_off)) {
			let changed = share(fs, p, gid, on);

			if (changed == null)
				push(problems, `cannot ${on ? 'give' : 'take'} ${GROUP} read access ${on ? 'to' : 'from'} ${p}: ${fs.error() ?? 'unknown error'}`);
			else if (changed)
				push(made, `${on ? 'gave' : 'took'} ${GROUP} read access ${on ? 'to' : 'from'} ${p}`);
		}

	if (write(fs, CAPABILITIES_FILE, sprintf('%.J\n', capabilities_doc(service_capabilities(grants))), 0o644, null) == null)
		push(problems, `cannot write ${CAPABILITIES_FILE}: ${fs.error() ?? 'unknown error'}`);

	for (let pair in [ [ grants.tls?.cert, TLS_CERT ], [ grants.tls?.key, TLS_KEY ] ]) {
		let text = (pair[0] != null) ? fs.readfile(pair[0]) : null;

		if (text == null) {
			fs.unlink(pair[1]);
			if (pair[0] != null)
				push(problems, `cannot read ${pair[0]}: ${fs.error() ?? 'unknown error'}`);
		} else if (write(fs, pair[1], text, 0o640, gid) == null) {
			push(problems, `cannot write ${pair[1]}: ${fs.error() ?? 'unknown error'}`);
		}
	}

	let changed = write(fs, ACL_FILE, sprintf('%.J\n', acl(grants.ubus)), 0o644, null);

	if (changed == null)
		push(problems, `cannot write ${ACL_FILE}: ${fs.error() ?? 'unknown error'}`);
	else if (changed && !sys.reload_ubus())
		push(problems, `cannot have ubusd read ${ACL_FILE}`);
	else if (changed)
		push(made, `ubus ACL of ${USER}: ${join(', ', map(keys(grants.ubus), (o) => `${o} ${join('|', grants.ubus[o])}`)) || 'none'}`);

	return { made, problems };
};

/**
 * Takes away what make() gave that only the running service needs: the ACL
 * (ubusd reads its ACLs again), the capabilities file and the TLS copies.
 * Whether ubusd was told.
 *
 * @param {{ fs: module:fs, reload_ubus: function(): boolean }} sys the
 *   system, as make()'s.
 * @returns {boolean} whether it took the ACL away, or there was none.
 */
export function clean(sys) {
	let had = sys.fs.stat(ACL_FILE) != null;

	for (let p in [ CAPABILITIES_FILE, TLS_CERT, TLS_KEY, ACL_FILE ])
		sys.fs.unlink(p);

	return had ? !!sys.reload_ubus() : true;
};

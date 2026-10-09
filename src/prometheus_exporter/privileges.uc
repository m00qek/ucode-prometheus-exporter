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
 * (prometheus_exporter.grant's make()):
 *
 * - the ubus ACL of their calls (grant's acl()), in ACL_FILE, where the link the
 *   package installs in ubusd's ACL directory (ACL_LINK) points; ubusd reads
 *   it again (SIGHUP). It always has CANARY, by which a collector tells an
 *   ACL ubusd has not loaded from an object that is not there;
 * - the capabilities procd has ujail give the jail (grant's capabilities_doc()), in
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
 * (grant's clean()). A collector is held to what it declared as it runs, too
 * (prometheus_exporter.deps): a ubus call it did not declare is refused
 * (UBUS_NOT_ALLOWED), and what the system refuses it fails as
 * PERMISSION_DENIED, never as nothing to observe.
 *
 * @module prometheus_exporter_privileges
 */

'use strict';

// What a scrape checks is here, which the handler holds for as long as
// uhttpd runs; what the service grants, as root, when it starts, is
// prometheus_exporter.grant's, which only jail.uc --make and --clean load.

/**
 * What a collector's privileges add up to, for the enabled collectors
 * (prometheus_exporter.jail's grants): what grant's make() grants, and what
 * it takes back.
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

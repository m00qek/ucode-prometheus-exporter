/**
 * What the service's user may do besides reading what its jail mounts, as collectors declare.
 *
 * @module prometheus_exporter_privileges
 */

'use strict';

/**
 * What the enabled collectors' privileges add up to: what grant's make() grants and takes back.
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

/** The service's user, which uhttpd runs as in the jail, made by the package. */
export const USER = 'prometheus-exporter';

/** The service's group, the user's own. */
export const GROUP = USER;

/** The capabilities a collector may declare, with their numbers. */
export const COLLECTOR_CAPABILITIES = { CAP_NET_ADMIN: 12, CAP_NET_RAW: 13 };

/** Every capability the service may grant, with its number. */
export const CAPABILITIES = { CAP_NET_BIND_SERVICE: 10, ...COLLECTOR_CAPABILITIES };

/** The lowest port that needs no capability to listen on. */
export const UNPRIVILEGED_PORT = 1024;

/** The run directory of the service (prometheus.exporter.state's RUN_DIR). */
export const RUN_DIR = `/var/run/${USER}`;

/** The capabilities file procd has ujail apply to the jail (-C). */
export const CAPABILITIES_FILE = `${RUN_DIR}/capabilities.json`;

/** The copies of the TLS certificate and key uhttpd reads. */
export const TLS_CERT = `${RUN_DIR}/tls.crt`;

/** The copy of the TLS key, readable by GROUP. */
export const TLS_KEY = `${RUN_DIR}/tls.key`;

/** The ubus ACL, outside the run directory, which ubusd's user may not enter. */
export const ACL_FILE = `/var/run/${USER}.acl.json`;

/** The link the package installs in ubusd's ACL directory, to ACL_FILE. */
export const ACL_LINK = `/usr/share/acl.d/${USER}.json`;

/** The call every ACL of the service allows: 'Not found' only when ubusd has not loaded it. */
export const CANARY = { object: 'system', method: 'board' };

/** The file of the system's groups. */
export const GROUP_FILE = '/etc/group';

/** The lock OpenWrt's tools take to change GROUP_FILE (lock /var/lock/passwd). */
export const GROUP_LOCK = '/var/lock/passwd';

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
 * What is wrong with a collector's declared privileges, or null.
 *
 * @param {Meta} meta
 * @returns {?string}
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
 * The ubus calls a collector declares for its options, and what a function got wrong.
 *
 * @param {Meta} meta
 * @param {?Object} options
 * @returns {{ ubus: Object<string, string[]>, problems: string[] }}
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
 * Whether `declared` allows `method` of `object`, as ubusd matches an ACL.
 *
 * @param {Object<string, string[]>} declared
 * @param {string} object
 * @param {string} method
 * @returns {boolean}
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
 * The capabilities of `wanted` that a process lacks, by its /proc/<pid>/status, or null.
 *
 * @param {?string} status
 * @param {string[]} wanted
 * @returns {?string[]}
 */
export function lacking(status, wanted) {
	let m = match(status ?? '', /\nCapEff:\s*([0-9a-fA-F]+)/);

	if (!m)
		return null;

	let eff = int(m[1], 16);

	return filter(wanted, (cap) => CAPABILITIES[cap] == null || !((eff >> CAPABILITIES[cap]) & 1));
};

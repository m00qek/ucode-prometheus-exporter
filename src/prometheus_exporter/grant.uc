/**
 * What the service grants its user when it starts, and takes away when it stops.
 *
 * @module prometheus_exporter_grant
 */

'use strict';

import { USER, GROUP, CANARY, UNPRIVILEGED_PORT, CAPABILITIES_FILE, TLS_CERT, TLS_KEY, ACL_FILE, GROUP_FILE } from 'prometheus_exporter.privileges';

/**
 * One map of the ubus calls of many: each object's methods, sorted, once each.
 *
 * @param {Object<string, string[]>[]} maps
 * @returns {Object<string, string[]>}
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
 * The ubus ACL of the service's user for these calls, and CANARY.
 *
 * @param {Object<string, string[]>} ubus
 * @returns {Object}
 */
export function acl(ubus) {
	let access = {};
	let calls = merge([ ubus, { [CANARY.object]: [ CANARY.method ] } ]);

	for (let object, methods in calls)
		access[object] = { methods };

	return { user: USER, access };
};

/**
 * The capabilities file of these capabilities, as procd hands ujail one (-C).
 *
 * @param {string[]} caps
 * @returns {Object}
 */
export function capabilities_doc(caps) {
	let set = sort(uniq(caps));

	return { bounding: set, effective: set, ambient: set, permitted: set, inheritable: set };
};

/**
 * The capabilities the jail has for these grants, sorted.
 *
 * @param {Grants} grants
 * @returns {string[]}
 */
export function service_capabilities(grants) {
	let caps = [ ...grants.capabilities ];

	if (grants.port < UNPRIVILEGED_PORT)
		push(caps, 'CAP_NET_BIND_SERVICE');

	return sort(uniq(caps));
};

/**
 * /etc/group's text with `user` in the groups `want` says true of, and out of the others.
 *
 * @param {string} text
 * @param {string} user
 * @param {Object<string, boolean>} want
 * @returns {{ text: ?string, missing: string[] }}
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
 * @param {string} text
 * @param {string} group
 * @returns {?int}
 */
export function gid_of(text, group) {
	for (let line in split(text ?? '', '\n')) {
		let f = split(line, ':');

		if (length(f) == 4 && f[0] == group && match(f[2], /^[0-9]+$/))
			return +f[2];
	}

	return null;
};

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
 * Grants what `grants` says, and takes back what it says to: lines for the log.
 *
 * @param {{ fs: module:fs, lock: function(): function(): void, reload_ubus: function(): boolean }} sys
 * @param {Grants} grants
 * @returns {{ made: string[], problems: string[] }}
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
 * Takes away what make() gave that only the running service needs.
 *
 * @param {{ fs: module:fs, reload_ubus: function(): boolean }} sys
 * @returns {boolean}
 */
export function clean(sys) {
	let had = sys.fs.stat(ACL_FILE) != null;

	for (let p in [ CAPABILITIES_FILE, TLS_CERT, TLS_KEY, ACL_FILE ])
		sys.fs.unlink(p);

	return had ? !!sys.reload_ubus() : true;
};

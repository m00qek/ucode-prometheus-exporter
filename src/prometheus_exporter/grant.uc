/**
 * What the service grants its user, as root, when it starts, of what the
 * enabled collectors declare (prometheus_exporter.privileges): the ubus ACL,
 * the capabilities file, the user's groups, its group's read access to
 * configs and proc files, and the TLS copies (make()); and what it takes
 * away when it stops (clean()). jail.uc --make and --clean, which the init
 * script runs, load it; the handler, which holds what it loads for as long
 * as uhttpd runs, never does.
 *
 * @module prometheus_exporter_grant
 */

'use strict';

import { USER, GROUP, CANARY, UNPRIVILEGED_PORT, CAPABILITIES_FILE, TLS_CERT, TLS_KEY, ACL_FILE, GROUP_FILE } from 'prometheus_exporter.privileges';

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

/**
 * What the service grants its user when it starts, and takes away when it stops.
 *
 * @module prometheus_exporter_grant
 */

'use strict';

import { USER, GROUP, CANARY, UNPRIVILEGED_PORT, CAPABILITIES_FILE, TLS_CERT, TLS_KEY, ACL_FILE, GROUP_FILE, AUTH_FILE, GRANTED_FILE, CONFIG_DIR } from 'prometheus.exporter.privileges';
import { TLS_FILE_MAX } from 'prometheus.exporter.config';

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
 * The groups of the text of /etc/group that `user` is a member of, but its own.
 *
 * @param {?string} text
 * @param {string} user
 * @returns {string[]}
 */
export function member_of(text, user) {
	let out = [];

	for (let line in split(text ?? '', '\n')) {
		let f = split(line, ':');

		if (length(f) == 4 && f[0] != user && user in split(f[3], ','))
			push(out, f[0]);
	}

	return out;
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

function shared_mode(mode) {
	return (mode & ~0o070) | 0o040;
}

function give(fs, path, gid, record) {
	let st = fs.stat(path);

	if (st == null)
		return false;
	if (st.gid != gid)
		record[path] ??= { gid: st.gid, mode: st.mode };
	if (st.gid == gid && st.mode == shared_mode(st.mode))
		return false;

	return (fs.chown(path, -1, gid) && fs.chmod(path, shared_mode(st.mode))) ? true : null;
}

function take(fs, path, gid, before) {
	let st = fs.stat(path);
	let back = (type(before?.mode) == 'int' && st?.mode == shared_mode(before.mode) && st.mode != before.mode);

	if (st == null || (st.gid != gid && !(back && st.gid == before.gid)))
		return false;

	let ok = (st.gid == gid) ? fs.chown(path, -1, before?.gid ?? 0) : true;

	if (ok && back)
		ok = fs.chmod(path, before.mode);

	return ok ? true : null;
}

function read_record(fs) {
	let r = null;

	try {
		r = json(fs.readfile(GRANTED_FILE) ?? 'null');
	} catch (e) {
		r = null;
	}

	return (type(r?.files) == 'object') ? r : { files: {} };
}

function save_record(fs, record) {
	if (!length(record.files)) {
		fs.unlink(GRANTED_FILE);
		return true;
	}

	return write(fs, GRANTED_FILE, sprintf('%.J\n', record), 0o600, null) != null;
}

function of_group(fs, gid) {
	let names = fs.lsdir ? fs.lsdir(CONFIG_DIR) : null;

	return filter(map(names ?? [], (n) => `${CONFIG_DIR}/${n}`), (p) => fs.stat(p)?.gid == gid);
}

function settle_groups(sys, want_on, want_off) {
	let fs = sys.fs;
	let unlock = sys.lock();
	let text = fs.readfile(GROUP_FILE);
	let gid = gid_of(text, GROUP);
	let want = {};

	for (let g in [ ...member_of(text, USER), ...want_off ])
		want[g] = false;
	for (let g in want_on)
		want[g] = true;

	let m = (gid != null) ? membership(text, USER, want) : { text: null, missing: [] };
	let wrote = (m.text == null) ? false : write(fs, GROUP_FILE, m.text, fs.stat(GROUP_FILE)?.mode ?? 0o644, null);

	unlock();
	return { gid, missing: m.missing, wrote };
}

function take_files(fs, gid, record, keep, extra, made, problems) {
	for (let p in sort(uniq([ ...extra, ...keys(record.files), ...of_group(fs, gid) ]))) {
		if (p in keep)
			continue;

		let changed = take(fs, p, gid, record.files[p]);

		if (changed == null) {
			push(problems, `cannot take ${GROUP} read access from ${p}: ${fs.error() ?? 'unknown error'}`);
			continue;
		}

		delete record.files[p];
		if (changed)
			push(made, `took ${GROUP} read access from ${p}`);
	}
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
	let g = settle_groups(sys, grants.groups, grants.groups_off);
	let gid = g.gid;

	if (gid == null)
		return { made, problems: [ `no group ${GROUP} in ${GROUP_FILE}: reinstall the package, which makes it` ] };

	for (let name in g.missing)
		push(made, `no group ${name}: ${USER} joins it once it is there`);
	if (g.wrote == null)
		push(problems, `cannot write ${GROUP_FILE}: ${fs.error() ?? 'unknown error'}`);
	else if (g.wrote)
		push(made, `${USER} is a member of ${length(grants.groups) ? join(', ', grants.groups) : 'no group a collector declares'}`);

	let record = read_record(fs);

	take_files(fs, gid, record, grants.files, grants.files_off, made, problems);

	for (let p in grants.files) {
		let changed = give(fs, p, gid, record.files);

		if (changed == null)
			push(problems, `cannot give ${GROUP} read access to ${p}: ${fs.error() ?? 'unknown error'}`);
		else if (changed)
			push(made, `gave ${GROUP} read access to ${p}`);
	}

	if (!save_record(fs, record))
		push(problems, `cannot write ${GRANTED_FILE}: ${fs.error() ?? 'unknown error'}`);

	if (write(fs, CAPABILITIES_FILE, sprintf('%.J\n', capabilities_doc(service_capabilities(grants))), 0o644, null) == null)
		push(problems, `cannot write ${CAPABILITIES_FILE}: ${fs.error() ?? 'unknown error'}`);

	let tls = [];

	for (let pair in [ [ grants.tls?.cert, TLS_CERT ], [ grants.tls?.key, TLS_KEY ] ]) {
		let st = (pair[0] != null) ? fs.stat(pair[0]) : null;
		let text = (st?.type == 'file' && st.size <= TLS_FILE_MAX) ? fs.readfile(pair[0], TLS_FILE_MAX + 1) : null;

		if (text != null && length(text) > TLS_FILE_MAX)
			text = null;
		if (pair[0] != null && text == null)
			push(problems, `cannot copy ${pair[0]}: not a regular file of at most ${TLS_FILE_MAX} bytes that root reads`);
		push(tls, [ text, pair[1] ]);
	}

	for (let t in tls)
		if (tls[0][0] == null || tls[1][0] == null)
			fs.unlink(t[1]);
		else if (write(fs, t[1], t[0], 0o640, gid) == null)
			push(problems, `cannot write ${t[1]}: ${fs.error() ?? 'unknown error'}`);

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
 * Takes away all make() gave, giving each file its group and mode back, and the files of the running service: lines for the log.
 *
 * @param {{ fs: module:fs, lock: function(): function(): void, reload_ubus: function(): boolean }} sys
 * @returns {{ ok: boolean, made: string[], problems: string[] }}
 */
export function clean(sys) {
	let fs = sys.fs;
	let made = [];
	let problems = [];
	let had = fs.stat(ACL_FILE) != null;
	let g = settle_groups(sys, [], []);

	if (g.wrote == null)
		push(problems, `cannot write ${GROUP_FILE}: ${fs.error() ?? 'unknown error'}`);
	else if (g.wrote)
		push(made, `${USER} is a member of no group a collector declares`);

	if (g.gid != null)
		take_files(fs, g.gid, read_record(fs), [], [], made, problems);

	for (let p in [ CAPABILITIES_FILE, TLS_CERT, TLS_KEY, ACL_FILE, AUTH_FILE, GRANTED_FILE ])
		fs.unlink(p);

	if (had && !sys.reload_ubus())
		push(problems, `cannot have ubusd forget ${ACL_FILE}`);

	return { ok: !length(problems), made, problems };
};

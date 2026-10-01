'use strict';

// The exporter's writable state: small files a uhttpd instance keeps between
// the requests it answers. uhttpd answers each request in a process forked
// from the one that loaded the handler, so nothing a request leaves in memory
// is there for the next; what must last goes here (basic auth's cache, see
// prometheus_exporter.auth).
//
// DIR is on tmpfs, never on flash, mode 0700 (root's alone), inside the
// directory of uhttpd's config file (also 0700). jail.uc --make makes it, and
// the init script mounts it read-write in the jail, the one path there that is.
//
// State is the instance's own, and lost when the service restarts, not only at
// reboot: the handler names its instance when uhttpd loads it, before any
// request forks (instance_id: the pid and start time of that process, which no
// later process has, even in a jail's own pid namespace, where the pid is the
// same each time). Each file is <id>.<name>, and opening the state of an
// instance removes every other instance's files. A reload that keeps the
// instance (procd restarts it only when its command, mounts or files change)
// keeps its state.
//
// fs: { readfile, writefile, rename, unlink, lsdir, chmod, stat, mkdir, error }, as
// the fs module has them.

// The run directory of uhttpd's config file (prometheus_exporter.auth's DIR).
export const RUN_DIR = '/var/run/prometheus-exporter';
export const DIR = `${RUN_DIR}/state`;

// The most bytes a state file holds: a name's state is small, or it is not
// kept.
export const SIZE_MAX = 4096;

const NAME = /^[a-z][a-z0-9_]*$/;
const DIGITS = /^[0-9]+$/;
// A state file's name: <pid>-<start time>.<name>, or its .new while written.
const FILE = /^[0-9]+-[0-9]+\.[a-z][a-z0-9_]*(\.new)?$/;

// This process's instance id, "<pid>-<start time>" (/proc/self/stat's first
// and 22nd fields), or null when /proc does not say.
export function instance_id(fs) {
	let stat = fs.readfile('/proc/self/stat');
	let close = (type(stat) == 'string') ? rindex(stat, ')') : -1;

	if (close < 0)
		return null;

	// After the command's ')', the fields from the 3rd on: the 22nd is the 20th.
	let pid = substr(stat, 0, index(stat, ' '));
	let start = split(substr(stat, close + 2), ' ')[19];

	if (!match(pid, DIGITS) || !match(start ?? '', DIGITS))
		return null;

	return `${pid}-${start}`;
};

// Makes DIR and RUN_DIR, as needed, and closes both to their owner (0700):
// a Result-like { ok, problem }.
export function make(fs) {
	for (let d in [ RUN_DIR, DIR ])
		if ((fs.stat(d) == null && !fs.mkdir(d, 0o700)) || !fs.chmod(d, 0o700))
			return { ok: false, problem: `cannot make ${d}: ${fs.error() ?? 'unknown error'}` };

	return { ok: true, problem: null };
};

// The state of instance `id` in `dir` (DIR, but for tests and the bench):
// { read(name), write(name, data) }. read gives what write last wrote, or
// null; write a string of at most SIZE_MAX bytes, whole (to <file>.new, then
// renamed), mode 0600, and says whether it did. Opening it removes the files
// of every other instance. Without an id it keeps nothing.
export function open(fs, dir, id) {
	let path = (name) => (id != null && type(name) == 'string' && match(name, NAME)) ? `${dir}/${id}.${name}` : null;

	if (id != null)
		for (let f in fs.lsdir(dir) ?? [])
			if (match(f, FILE) && substr(f, 0, length(id) + 1) != `${id}.`)
				fs.unlink(`${dir}/${f}`);

	return {
		read: function(name) {
			let p = path(name);

			return p ? fs.readfile(p, SIZE_MAX) : null;
		},
		write: function(name, data) {
			let p = path(name);

			if (!p || type(data) != 'string' || length(data) > SIZE_MAX)
				return false;

			// Mode 0600 once written, in a directory of 0700 all along.
			let tmp = `${p}.new`;
			let ok = fs.writefile(tmp, data) == length(data) && fs.chmod(tmp, 0o600) && fs.rename(tmp, p);

			if (!ok)
				fs.unlink(tmp);

			return !!ok;
		},
	};
};

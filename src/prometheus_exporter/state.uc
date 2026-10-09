/**
 * The exporter's writable state: small files a uhttpd instance keeps between
 * the requests it answers. uhttpd answers each request in a process forked
 * from the one that loaded the handler, so nothing a request leaves in memory
 * is there for the next; what must last goes here (basic auth's cache, see
 * prometheus_exporter.auth; the collectors' durations, breakers and counters,
 * see prometheus_exporter.ledger).
 *
 * DIR is on tmpfs, never on flash, mode 0700, the service's user's alone (the
 * user uhttpd runs as in the jail), inside the directory of uhttpd's config
 * file (0700, root's). jail.uc --make makes it, and the init script mounts it
 * read-write in the jail, the one path there that is.
 *
 * State is the instance's own, and lost when the service restarts, not only at
 * reboot: the handler names its instance when uhttpd loads it, before any
 * request forks (instance_id: the pid and start time of that process, which no
 * later process has, even in a jail's own pid namespace, where the pid is the
 * same each time). Each file is <id>.<name>, and opening the state of an
 * instance removes every other instance's files. A reload that keeps the
 * instance (procd restarts it only when its command, mounts or files change)
 * keeps its state.
 *
 * Requests run at once (a scraper, someone with curl), so every write takes
 * the instance's lock first, an exclusive flock() of <id>.lock, which the
 * kernel lets go of when the process holding it ends, however it ends: one
 * writer at a time writes <file>.new and renames it over <file>, and a read,
 * which takes no lock, sees one whole file or the other, never a torn one.
 * update() reads, changes and writes under the lock, so two requests that
 * count something both count it; write() alone, the last writer wins.
 *
 * A scrape keeps a progress file, <id>.p<pid>_<start>, named by its own process:
 * a line `start <collector> <pid>-<start>` appended before each collector it
 * starts, the pid and start time of the child process it runs in (O_APPEND,
 * one write; no rename, no lock), `collected` once they are done, and the
 * file removed when the reply is written. A scrape process that dies (killed
 * at uhttpd's timeout, out of memory) leaves its file behind, and a later
 * scrape of the instance finds it, its process gone (dead()): the collector it
 * last started, unless it says `collected`, was running when it died, in a
 * child that may be running still.
 *
 * fs: { readfile, writefile, rename, unlink, lsdir, chmod, stat, mkdir, open,
 * error }, as the fs module has them.
 *
 * @module prometheus_exporter_state
 */

'use strict';

/**
 * The state of an instance, as open() gives it: its id, its scrape
 * processes' progress files, and its named files, read, written and
 * updated under its lock.
 *
 * @typedef {{
 *   id: ?string,
 *   progress: () => ProgressFile,
 *   dead: () => DeadScrape[],
 *   claim: (file: string) => boolean,
 *   read: (name: string) => ?string,
 *   write: (name: string, data: string) => boolean,
 *   update: (name: string, fn: function(?string): ?string) => boolean
 * }} State
 */

/**
 * A scrape process's progress file, as State's progress() gives it.
 *
 * @typedef {{ start: (collector: string, pid: ?int) => void, collected: () => void, finish: () => void }} ProgressFile
 */

/**
 * The progress file of a scrape process that is gone, as State's dead()
 * finds it: its name, the collector it was running (its module name), or
 * null, and the child process that ran it, when it is there still.
 *
 * @typedef {{ file: string, running: ?string, child: ?{ pid: int, start: string } }} DeadScrape
 */

/**
 * The state of the instance that started last, to read only, as latest()
 * gives it.
 *
 * @typedef {{ id: string, read: (name: string) => ?string }} ReadOnlyState
 */

/**
 * The run directory of uhttpd's config file (prometheus_exporter.auth's DIR).
 *
 * @type {string}
 */
export const RUN_DIR = '/var/run/prometheus-exporter';

/**
 * The state's directory, under RUN_DIR.
 *
 * @type {string}
 */
export const DIR = `${RUN_DIR}/state`;

/**
 * The most bytes a state file holds: a name's state is small, or it is not
 * kept. The ledger (prometheus_exporter.ledger) is the largest: a duration, a
 * breaker and counters for each installed collector, 30 bytes for one that
 * never failed and some 300 for one that failed in every way it can. 32 KiB
 * holds a hundred of the latter, twice the collectors there are; it is RAM
 * (tmpfs), and json() reads it in a few milliseconds on a router.
 *
 * @type {int}
 */
export const SIZE_MAX = 32768;

const NAME = /^[a-z][a-z0-9_]*$/;
const DIGITS = /^[0-9]+$/;
// An instance id, its pid captured.
const ID = /^([0-9]+)-[0-9]+$/;
// A state file's name: <pid>-<start time>.<name>, or its .new while written.
const FILE = /^([0-9]+)-([0-9]+)\.[a-z][a-z0-9_]*(\.new)?$/;
// The lock's name, which no state takes.
const LOCK = 'lock';
// A progress file's name after <id>.p: the pid and start time of its process.
const PROGRESS = /^([0-9]+)_([0-9]+)$/;
// A progress file's line before a collector, and the process it runs in.
const STARTED = /^start ([a-z0-9_]+)( ([0-9]+)-([0-9]+))?$/;

/**
 * This process's instance id, "<pid>-<start time>" (/proc/self/stat's first
 * and 22nd fields), or null when /proc does not say.
 *
 * @param {module:fs} fs what reads /proc/self/stat: an object of fs's
 *   readfile.
 * @returns {?string} "<pid>-<start time>".
 */
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

/**
 * The start time of process `pid` (/proc/<pid>/stat's 22nd field), as a
 * string, or null when there is no such process.
 *
 * @param {module:fs} fs what reads /proc/<pid>/stat: an object of fs's
 *   readfile.
 * @param {(int|string)} pid the process.
 * @returns {?string} its start time, in clock ticks since boot.
 */
export function start_of(fs, pid) {
	let stat = fs.readfile(`/proc/${pid}/stat`);
	let close = (type(stat) == 'string') ? rindex(stat, ')') : -1;

	return (close < 0) ? null : split(substr(stat, close + 2), ' ')[19];
};

/**
 * The pid of instance `id`: the uhttpd that loaded the handler, whose
 * requests are its children.
 *
 * @param {?string} id the instance's id, "<pid>-<start time>".
 * @returns {?int} the pid, or null for what is not an id.
 */
export function pid_of(id) {
	let m = (type(id) == 'string') ? match(id, ID) : null;

	return m ? +m[1] : null;
};

/**
 * Makes DIR and RUN_DIR, as needed, and closes both to their owner (0700):
 * a Result-like { ok, problem }. With `owner`, DIR is that user's and its
 * group's: the service's (privileges.USER), which uhttpd runs as in the jail;
 * RUN_DIR stays root's, which only root enters.
 *
 * @param {module:fs} fs the fs module, or an object of its stat, mkdir,
 *   chmod, chown and error.
 * @param {?string} owner the user, and group, DIR is given to; null keeps it
 *   as it is.
 * @returns {{ ok: boolean, problem: ?string }} whether it made them, and
 *   what failed.
 */
export function make(fs, owner) {
	for (let d in [ RUN_DIR, DIR ])
		if ((fs.stat(d) == null && !fs.mkdir(d, 0o700)) || !fs.chmod(d, 0o700))
			return { ok: false, problem: `cannot make ${d}: ${fs.error() ?? 'unknown error'}` };

	if (owner != null && !fs.chown(DIR, owner, owner))
		return { ok: false, problem: `cannot give ${DIR} to ${owner}: ${fs.error() ?? 'unknown error'}` };

	return { ok: true, problem: null };
};

function file_of(dir, id, name) {
	return (id != null && type(name) == 'string' && name != LOCK && match(name, NAME)) ? `${dir}/${id}.${name}` : null;
}

// What cb() returns, called with the instance's lock held; false, without
// calling it, when the lock cannot be taken.
function locked(fs, dir, id, cb) {
	let h = fs.open(`${dir}/${id}.${LOCK}`, 'a');

	if (!h)
		return false;

	if (!h.lock('x')) {
		h.close();
		return false;
	}

	let out = cb();

	// Closing the file lets go of the lock.
	h.close();
	return out;
}

// `data` as `p`, whole, mode 0600; the lock held.
function replace_file(fs, p, data) {
	// Mode 0600 once written, in a directory of 0700 all along.
	let tmp = `${p}.new`;
	let ok = fs.writefile(tmp, data) == length(data) && fs.chmod(tmp, 0o600) && fs.rename(tmp, p);

	if (!ok)
		fs.unlink(tmp);

	return !!ok;
}

function writable(p, data) {
	return p != null && type(data) == 'string' && length(data) <= SIZE_MAX;
}

/**
 * The state of instance `id` in `dir` (DIR, but for tests and the bench):
 * { id, read(name), write(name, data), update(name, fn) }. read gives what
 * was last written, or null; write a string of at most SIZE_MAX bytes, whole,
 * mode 0600, and says whether it did. update(name, fn) calls fn with what is
 * there (or null), the lock held, writes the string fn returns (nothing for
 * anything else), and says whether it wrote. Opening it removes the files of
 * every other instance. Without an id it keeps nothing.
 *
 * @param {module:fs} fs the fs module, or an object of the functions the
 *   module's top comment names.
 * @param {string} dir the state's directory.
 * @param {?string} id the instance's id (instance_id), or null.
 * @returns {State} the state.
 */
export function open(fs, dir, id) {
	if (id != null)
		for (let f in fs.lsdir(dir) ?? [])
			if (match(f, FILE) && substr(f, 0, length(id) + 1) != `${id}.`)
				fs.unlink(`${dir}/${f}`);

	let prefix = `${id}.p`;

	return {
		id,

		// This process's progress file: { start(collector), collected(),
		// finish() }, which does nothing without an id.
		progress: function() {
			let self = instance_id(fs);
			let p = (id != null && self != null) ? `${dir}/${prefix}${replace(self, '-', '_')}` : null;
			let h = null;
			// The child the collectors run in, and its start time: the same
			// child runs one collector after another.
			let child = null, child_start = null;

			function line(text) {
				if (p == null)
					return;

				h ??= fs.open(p, 'a');
				h?.write(text + '\n');
				h?.flush();
			}

			return {
				start: function(collector, pid) {
					if (pid != child) {
						child = pid;
						child_start = (pid != null) ? start_of(fs, pid) : null;
					}

					let start = child_start;

					line(`start ${collector}` + ((start != null) ? ` ${pid}-${start}` : ''));
				},
				collected: () => line('collected'),
				finish: function() {
					h?.close();
					h = null;
					if (p != null)
						fs.unlink(p);
				},
			};
		},

		// The progress files of the instance's scrape processes that are
		// gone: [ { file, running, child } ], running the collector each was
		// running when it died, or null, and child the process it ran in,
		// when it is there still: { pid, start }. A process is gone when no
		// process has its pid and start time.
		dead: function() {
			let out = [];

			if (id == null)
				return out;

			for (let f in fs.lsdir(dir) ?? []) {
				if (substr(f, 0, length(prefix)) != prefix)
					continue;

				let m = match(substr(f, length(prefix)), PROGRESS);

				if (!m || start_of(fs, m[1]) == m[2])
					continue;

				let lines = split(trim(fs.readfile(`${dir}/${f}`, SIZE_MAX) ?? ''), '\n');
				let last = match(lines[-1] ?? '', STARTED);
				let child = (last?.[3] != null && start_of(fs, last[3]) == last[4]) ? { pid: +last[3], start: last[4] } : null;

				push(out, { file: f, running: last ? last[1] : null, child });
			}

			return out;
		},

		// Removes a progress file dead() found: whether this call did, so
		// that of scrapes that found it at once, one reckons it.
		claim: (file) => (substr(file, 0, length(prefix)) == prefix) && !!fs.unlink(`${dir}/${file}`),

		read: function(name) {
			let p = file_of(dir, id, name);

			return p ? fs.readfile(p, SIZE_MAX) : null;
		},
		write: function(name, data) {
			let p = file_of(dir, id, name);

			return writable(p, data) && locked(fs, dir, id, () => replace_file(fs, p, data));
		},
		update: function(name, fn) {
			let p = file_of(dir, id, name);

			if (p == null)
				return false;

			return locked(fs, dir, id, function() {
				let data = fn(fs.readfile(p, SIZE_MAX));

				return writable(p, data) && replace_file(fs, p, data);
			});
		},
	};
};

/**
 * The state of the instance that started last in `dir`, to read only, and
 * removing nothing: { id, read(name) }, or null when there is none. For what
 * runs outside the jail (check, the ubus object) and reads the running
 * instance's state: an instance removes the others' files when it starts, so
 * there is that one, or none before the service first answers.
 *
 * @param {module:fs} fs what reads the directory: an object of fs's lsdir
 *   and readfile.
 * @param {string} dir the state's directory.
 * @returns {?ReadOnlyState} the state, or null.
 */
export function latest(fs, dir) {
	let best = null, start = -1;

	for (let f in fs.lsdir(dir) ?? []) {
		let m = match(f, FILE);

		if (m && +m[2] > start) {
			start = +m[2];
			best = `${m[1]}-${m[2]}`;
		}
	}

	if (best == null)
		return null;

	return {
		id: best,
		read: function(name) {
			let p = file_of(dir, best, name);

			return p ? fs.readfile(p, SIZE_MAX) : null;
		},
	};
};

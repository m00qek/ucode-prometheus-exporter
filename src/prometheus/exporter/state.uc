/**
 * The exporter's writable state: small files an instance keeps between requests.
 *
 * @module prometheus_exporter_state
 */

'use strict';

/**
 * The state of an instance, as open() gives it.
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
 * The progress file of a scrape process that is gone, as dead() finds it.
 *
 * @typedef {{ file: string, running: ?string, child: ?{ pid: int, start: string } }} DeadScrape
 */

/**
 * The state of the instance that started last, to read only, as latest() gives it.
 *
 * @typedef {{ id: string, read: (name: string) => ?string }} ReadOnlyState
 */

/** The run directory of uhttpd's config file (prometheus.exporter.auth's DIR). */
export const RUN_DIR = '/var/run/prometheus-exporter';

/** The state's directory, under RUN_DIR. */
export const DIR = `${RUN_DIR}/state`;

/** The most bytes a state file holds. */
export const SIZE_MAX = 32768;

const NAME = /^[a-z][a-z0-9_]*$/;
const DIGITS = /^[0-9]+$/;
const ID = /^([0-9]+)-[0-9]+$/;
const FILE = /^([0-9]+)-([0-9]+)\.[a-z][a-z0-9_]*(\.new)?$/;
const LOCK = 'lock';
const PROGRESS = /^([0-9]+)_([0-9]+)$/;
const STARTED = /^start ([a-z0-9_]+)( ([0-9]+)-([0-9]+))?$/;

/**
 * This process's instance id, "<pid>-<start time>", or null.
 *
 * @param {module:fs} fs
 * @returns {?string}
 */
export function instance_id(fs) {
	let stat = fs.readfile('/proc/self/stat');
	let close = (type(stat) == 'string') ? rindex(stat, ')') : -1;

	if (close < 0)
		return null;

	let pid = substr(stat, 0, index(stat, ' '));
	let start = split(substr(stat, close + 2), ' ')[19];

	if (!match(pid, DIGITS) || !match(start ?? '', DIGITS))
		return null;

	return `${pid}-${start}`;
};

/**
 * The start time of process `pid`, as a string, or null.
 *
 * @param {module:fs} fs
 * @param {(int|string)} pid
 * @returns {?string}
 */
export function start_of(fs, pid) {
	let stat = fs.readfile(`/proc/${pid}/stat`);
	let close = (type(stat) == 'string') ? rindex(stat, ')') : -1;

	return (close < 0) ? null : split(substr(stat, close + 2), ' ')[19];
};

/**
 * The pid of instance `id`: the uhttpd that loaded the handler.
 *
 * @param {?string} id
 * @returns {?int}
 */
export function pid_of(id) {
	let m = (type(id) == 'string') ? match(id, ID) : null;

	return m ? +m[1] : null;
};

/**
 * Makes DIR and RUN_DIR, as needed, closed to their owner (0700).
 *
 * @param {module:fs} fs
 * @param {?string} owner
 * @returns {{ ok: boolean, problem: ?string }}
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

function locked(fs, dir, id, cb) {
	let h = fs.open(`${dir}/${id}.${LOCK}`, 'a');

	if (!h)
		return false;

	if (!h.lock('x')) {
		h.close();
		return false;
	}

	let out = cb();

	h.close();
	return out;
}

function replace_file(fs, p, data) {
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
 * The state of instance `id` in `dir`.
 *
 * @param {module:fs} fs
 * @param {string} dir
 * @param {?string} id
 * @returns {State}
 */
export function open(fs, dir, id) {
	if (id != null)
		for (let f in fs.lsdir(dir) ?? [])
			if (match(f, FILE) && substr(f, 0, length(id) + 1) != `${id}.`)
				fs.unlink(`${dir}/${f}`);

	let prefix = `${id}.p`;

	return {
		id,

		progress: function() {
			let self = instance_id(fs);
			let p = (id != null && self != null) ? `${dir}/${prefix}${replace(self, '-', '_')}` : null;
			let h = null;
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
 * At most `max` bytes of `path`, a regular file of `uid` with one link, opened so that no FIFO blocks; else null.
 *
 * @param {module:fs} fs
 * @param {string} path
 * @param {int} max
 * @param {?int} uid
 * @returns {?string}
 */
export function read_closed(fs, path, max, uid) {
	let st = fs.lstat(path);

	if (st?.type != 'file' || st.nlink != 1 || st.size > max || (uid != null && st.uid != uid))
		return null;

	let f = fs.open(path, 'r+');

	if (!f)
		return null;

	let at = fs.stat(`/proc/self/fd/${f.fileno()}`);
	let text = (at?.type == 'file' && at.inode == st.inode && at.dev?.major == st.dev?.major && at.dev?.minor == st.dev?.minor)
		? f.read(max) : null;

	f.close();
	return (text == null) ? null : substr(text, 0, max);
};

/**
 * The state of the instance that started last in `dir`, to read only.
 *
 * @param {module:fs} fs
 * @param {string} dir
 * @returns {?ReadOnlyState}
 */
export function latest(fs, dir) {
	let best = null, start = -1;
	let owner = fs.lstat(dir);

	if (owner?.type != 'directory')
		return null;

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

			return p ? read_closed(fs, p, SIZE_MAX, owner.uid) : null;
		},
	};
};

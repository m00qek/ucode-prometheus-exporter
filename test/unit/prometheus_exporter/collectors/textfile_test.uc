'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as fixtures from 'lib.fixtures';
import { with_collector, jail_of } from 'prometheus_exporter.devkit.collector';
import * as exposition from 'prometheus_exporter.exposition';
import * as textfile from 'prometheus_exporter.collectors.textfile';

const DIR = '/var/prometheus';
const APK = `${DIR}/apk.prom`;
const BACKUP = `${DIR}/backup.prom`;
const TRUNCATED = `${DIR}/truncated.prom`;
const FILES = fixtures.files('synthetic', [ APK, BACKUP, TRUNCATED ]);
const MTIMES = { [APK]: 1790812800, [BACKUP]: 1790809200, [TRUNCATED]: 1790816400 };

// The files, each changed at its MTIMES time (the mock's stat says 0).
function fs_of(data, behavior) {
	return {
		data,
		behavior: { stat: (p) => data[p] != null ? { size: length(data[p]), mtime: MTIMES[p] ?? 0, type: 'file' } : null,
			...(behavior ?? {}) },
	};
}

function pick(paths) {
	let data = {};

	for (let p in paths)
		data[p] = FILES[p];

	return data;
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.textfile', () => {
	it('adds the metrics of every *.prom file and when each was changed', () => {
		with_collector(textfile, { fs: fs_of(pick([ APK, BACKUP ])) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP apk_upgradable_packages Packages with an upgrade available.',
				'# TYPE apk_upgradable_packages gauge',
				'apk_upgradable_packages 3',
				'# HELP apk_installed_packages Installed packages.',
				'# TYPE apk_installed_packages gauge',
				'apk_installed_packages 212',
				'# HELP backup_last_success_timestamp_seconds When the last configuration backup finished.',
				'# TYPE backup_last_success_timestamp_seconds gauge',
				'backup_last_success_timestamp_seconds{target="nas"} 1790812800',
				'# HELP backup_runs_total Configuration backups run, by result.',
				'# TYPE backup_runs_total counter',
				'backup_runs_total{result="ok"} 41',
				'backup_runs_total{result="failed"} 2',
				'# HELP node_textfile_mtime_seconds Unixtime mtime of textfiles successfully read.',
				'# TYPE node_textfile_mtime_seconds gauge',
				'node_textfile_mtime_seconds{file="/var/prometheus/apk.prom"} 1790812800',
				'node_textfile_mtime_seconds{file="/var/prometheus/backup.prom"} 1790809200',
				'# HELP node_textfile_scrape_error 1 if there was an error opening or reading a file, 0 otherwise.',
				'# TYPE node_textfile_scrape_error gauge',
				'node_textfile_scrape_error 0',
			], r.lines);
		});
	});

	it('skips a file that is not valid exposition text whole, and still succeeds', () => {
		with_collector(textfile, { fs: fs_of(FILES) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(1, length(r.logs));
			assert.match(true, index(r.logs[0], `collector 'textfile': skipped ${TRUNCATED}: EXPOSITION_INVALID (line `) == 0, r.logs[0]);
			assert.match(false, index(r.text, 'speedtest') >= 0);
			assert.match([
				'apk_upgradable_packages 3',
				'apk_installed_packages 212',
				'backup_last_success_timestamp_seconds{target="nas"} 1790812800',
				'backup_runs_total{result="ok"} 41',
				'backup_runs_total{result="failed"} 2',
				'node_textfile_mtime_seconds{file="/var/prometheus/apk.prom"} 1790812800',
				'node_textfile_mtime_seconds{file="/var/prometheus/backup.prom"} 1790809200',
				'node_textfile_scrape_error 1',
			], samples(r.lines));
		});
	});

	it('counts a file it cannot read as an error', () => {
		let behavior = { readfile: (p) => p == APK ? null : FILES[p] };

		with_collector(textfile, { fs: fs_of(pick([ APK, BACKUP ]), behavior) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, index(r.text, 'apk_') >= 0);
			assert.match(true, index(r.text, 'node_textfile_mtime_seconds{file="/var/prometheus/backup.prom"}') >= 0);
			assert.match(true, index(r.text, 'node_textfile_scrape_error 1') >= 0);
			assert.match([ `collector 'textfile': skipped ${APK}: cannot be read` ], r.logs);
		});
	});

	// A FIFO with no writer would hold open() forever, a character device
	// read() forever: neither is opened.
	it('never opens what is not a regular file, and counts it as an error', () => {
		let fifo = `${DIR}/pipe.prom`, dev = `${DIR}/zero.prom`;
		let opened = [];
		let data = { ...pick([ APK ]), [fifo]: 'never read', [dev]: 'never read' };
		let types = { [fifo]: 'fifo', [dev]: 'char' };
		let behavior = {
			stat: (p) => data[p] != null ? { size: 0, mtime: MTIMES[p] ?? 0, type: types[p] ?? 'file' } : null,
			readfile: function(p) { push(opened, p); return data[p]; },
		};

		with_collector(textfile, { fs: fs_of(data, behavior) }, (r) => {
			assert.match([ true, [ APK ] ], [ r.result.ok, opened ]);
			assert.match(true, index(r.text, 'node_textfile_scrape_error 1') >= 0);
			assert.match([
				`collector 'textfile': skipped ${fifo}: is not a regular file (fifo): not read`,
				`collector 'textfile': skipped ${dev}: is not a regular file (char): not read`,
			], r.logs);
		});
	});

	it('writes only node_textfile_scrape_error 0 when the directory is missing', () => {
		with_collector(textfile, { fs: { data: {} } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_textfile_scrape_error 0' ], samples(r.lines));
		});
	});

	it('reads the directory the collector section names, and only its *.prom files', () => {
		let data = {
			'/etc/prometheus-exporter/metrics/router.prom': 'router_up 1\n',
			'/etc/prometheus-exporter/metrics/router.prom.tmp': 'router_up 0\n',
			'/etc/prometheus-exporter/metrics/README': 'not metrics\n',
		};

		with_collector(textfile, { fs: fs_of(data), options: { directory: '/etc/prometheus-exporter/metrics/' } }, (r) => {
			assert.match([
				'router_up 1',
				'node_textfile_mtime_seconds{file="/etc/prometheus-exporter/metrics/router.prom"} 0',
				'node_textfile_scrape_error 0',
			], samples(r.lines));
		});
	});

	it('skips a file that repeats a series or retypes a family an earlier file has', () => {
		let data = {
			'/var/prometheus/a.prom': '# TYPE jobs_total counter\njobs_total{job="x"} 1\n',
			'/var/prometheus/b.prom': 'jobs_total{job="x"} 2\n',
			'/var/prometheus/c.prom': '# TYPE jobs_total gauge\njobs_total{job="y"} 3\n',
			'/var/prometheus/d.prom': '# TYPE jobs_total counter\njobs_total{job="z"} 4\n',
		};

		with_collector(textfile, { fs: fs_of(data) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'jobs_total{job="x"} 1',
				'jobs_total{job="z"} 4',
				'node_textfile_mtime_seconds{file="/var/prometheus/a.prom"} 0',
				'node_textfile_mtime_seconds{file="/var/prometheus/d.prom"} 0',
				'node_textfile_scrape_error 1',
			], samples(r.lines));
			assert.match([
				"collector 'textfile': skipped /var/prometheus/b.prom: gives jobs_total type untyped, an earlier file counter",
				"collector 'textfile': skipped /var/prometheus/c.prom: gives jobs_total type gauge, an earlier file counter",
			], r.logs);
		});
	});

	it('skips a file that repeats a series an earlier file has', () => {
		let data = {
			'/var/prometheus/a.prom': '# TYPE jobs_total counter\njobs_total{job="x"} 1\n',
			'/var/prometheus/b.prom': '# TYPE jobs_total counter\njobs_total{job="x"} 2\n',
		};

		with_collector(textfile, { fs: fs_of(data) }, (r) => {
			assert.match([ "collector 'textfile': skipped /var/prometheus/b.prom: repeats a series of jobs_total" ], r.logs);
		});
	});

	it('skips a file that writes its own families', () => {
		let data = { '/var/prometheus/evil.prom': 'node_textfile_scrape_error 0\n' };

		with_collector(textfile, { fs: fs_of(data) }, (r) => {
			assert.match([ 'node_textfile_scrape_error 1' ], samples(r.lines));
			assert.match([ "collector 'textfile': skipped /var/prometheus/evil.prom: writes this collector's own node_textfile_scrape_error" ], r.logs);
		});
	});

	it('takes a file that declares its families but has no samples', () => {
		let data = { '/var/prometheus/empty.prom': '# HELP x_total X.\n# TYPE x_total counter\n' };

		with_collector(textfile, { fs: fs_of(data) }, (r) => {
			assert.match([
				'node_textfile_mtime_seconds{file="/var/prometheus/empty.prom"} 0',
				'node_textfile_scrape_error 0',
			], samples(r.lines));
		});
	});

	// Each file its own families (f<i>_...), gauges with any label value and integer.
	prop('adds every sample of any set of valid *.prom files',
		gen.array(gen.array(gen.tuple(gen.ascii({ min_len: 0, max_len: 10 }), gen.int(-1000000, 1000000)),
			{ min_len: 1, max_len: 4 }), { min_len: 1, max_len: 4 }), (files) => {
			let data = {}, want = [];

			for (let i, file in files) {
				let text = `# HELP f${i}_value File ${i}.\n# TYPE f${i}_value gauge\n`;

				for (let j, s in file) {
					let line = `f${i}_value{n="${j}",v="${exposition.escape_label(s[0])}"} ${s[1]}`;
					text += line + '\n';
					push(want, line);
				}

				data[sprintf('%s/%02d.prom', DIR, i)] = text;
			}

			with_collector(textfile, { fs: { data } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match([ ...want ], filter(samples(r.lines), (l) => match(l, /^f[0-9]+_value/)));
				assert.match(true, index(r.text, 'node_textfile_scrape_error 0') >= 0);
				assert.match(length(files), length(filter(r.lines, (l) => match(l, /^node_textfile_mtime_seconds/))));
			});
		});
});

describe('textfile in the jail', () => {
	it('gets its directory', () => {
		assert.match([ '/var/prometheus' ], jail_of(textfile, {}).mounts);
		assert.match([ '/tmp/metrics' ], jail_of(textfile, { options: { directory: '/tmp/metrics' } }).mounts);
	});

	it('owns it: the service makes it when it is not there, so it is mounted and not waited for', () => {
		let j = jail_of(textfile, { absent: [ '/var/prometheus' ] });
		assert.match([ [ '/var/prometheus' ], [ '/var/prometheus' ], [] ], [ j.owned, j.mounts, j.missing ]);
	});
});

'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

export const meta = {
	name: 'mmc',
	title: 'eMMC health',
	help: 'The health an eMMC of version 5.0 or later reports of itself, its life time used and its reserved blocks, from /sys/class/mmc_host.',
	needs: [ 'fs' ],
};

const ROOT = '/sys/class/mmc_host';
const HOST = /^mmc([0-9]+)$/;
const CARD = /^mmc[0-9]+:[0-9a-f]+$/;
const LIFE_TIME = /^0x([0-9a-fA-F]{2}) 0x([0-9a-fA-F]{2})$/;
const PRE_EOL = /^0x([0-9a-fA-F]{2})$/;
const STEP_MAX = 11;
const STATES = [ 'normal', 'warning', 'urgent' ];
const INFO = [ 'name', 'manfid', 'oemid', 'rev' ];

function read_value(fs, path) {
	let line = proc.first_line(fs, path);

	line = (line == null) ? null : trim(line);
	return (line == '') ? null : line;
}

function hosts(fs) {
	let numbered = [];

	for (let e in fs.lsdir(ROOT) ?? []) {
		let m = match(e, HOST);

		if (m)
			push(numbered, [ int(m[1]), e ]);
	}

	return map(sort(numbered, (a, b) => a[0] - b[0]), (h) => h[1]);
}

function cards(fs) {
	let out = [];

	for (let host in hosts(fs))
		for (let card in sort(filter(fs.lsdir(`${ROOT}/${host}`) ?? [], (e) => match(e, CARD))))
			push(out, { device: card, dir: `${ROOT}/${host}/${card}` });

	return out;
}

function defined(v, max) {
	return (v >= 1 && v <= max) ? v : null;
}

function health(fs, dir) {
	let life = read_value(fs, `${dir}/life_time`);
	let eol = read_value(fs, `${dir}/pre_eol_info`);
	let h = { a: null, b: null, eol: null, bad: null };

	if (life != null) {
		let m = match(life, LIFE_TIME);

		if (!m)
			return { ...h, bad: `${dir}/life_time: ${sprintf('%J', life)}` };

		h.a = defined(hex(m[1]), STEP_MAX);
		h.b = defined(hex(m[2]), STEP_MAX);
	}

	if (eol != null) {
		let m = match(eol, PRE_EOL);

		if (!m)
			return { ...h, bad: `${dir}/pre_eol_info: ${sprintf('%J', eol)}` };

		h.eol = defined(hex(m[1]), length(STATES));
	}

	return h;
}

export function collect(deps, out) {
	let fs = deps.fs;
	let info = out.gauge('node_mmc_info',
		'An eMMC that reports its health, by its sysfs device, product name, manufacturer and OEM IDs and revision: always 1.');
	let step = out.gauge('node_mmc_life_time_step',
		'Life time used of the eMMC\'s type A (SLC) or B (MLC) memory, as it estimates it in steps of 10%: 1 is 0-10% used, 10 is 90-100%, 11 past its estimated life.');
	let state = out.gauge('node_mmc_pre_eol_state',
		'The eMMC\'s reserved blocks, its pre-EOL information: 1 for its state, normal, warning (80% of them consumed) or urgent; 0 for the others.');
	let seen = 0;
	let bad = null;

	for (let c in cards(fs)) {
		let h = health(fs, c.dir);

		if (h.bad != null) {
			bad ??= h.bad;
			continue;
		}

		if (h.a == null && h.b == null && h.eol == null)
			continue;

		seen++;

		let labels = { device: c.device };

		for (let k in INFO)
			labels[k] = read_value(fs, `${c.dir}/${k}`);
		info(labels, 1);

		if (h.a != null)
			step({ device: c.device, type: 'a' }, h.a);
		if (h.b != null)
			step({ device: c.device, type: 'b' }, h.b);

		if (h.eol != null)
			for (let i, s in STATES)
				state({ device: c.device, state: s }, (h.eol == i + 1) ? 1 : 0);
	}

	if (bad != null)
		return Result.err(errors.SOURCE_INVALID, bad);

	if (!seen)
		return Result.none('no eMMC reports its health');

	return Result.ok();
};

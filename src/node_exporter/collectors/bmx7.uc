'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/bmx7.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten in ucode; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'bmx7',
	help: 'The bmx7 mesh node, its links and tunnels, from its JSON status files.',
	needs: [ 'fs' ],
};

export const DIR = '/var/run/bmx7/json';

const SCALE = { K: 1000, M: 1000000, G: 1000000000 };

// A number as bmx7 writes rates and memory ("54M", "2176K", "900"): with a K, M
// or G suffix, it is scaled; anything else is returned as it is.
export function interpret_suffix(v) {
	let m = type(v) == 'string' ? match(v, /^(-?[0-9]+(\.[0-9]+)?)([KMG])$/) : null;

	return m ? +m[1] * SCALE[m[3]] : v;
};

// The object under `key` in one of the JSON files, or an error Result.
function read(fs, file, key) {
	let path = `${DIR}/${file}`;
	let s = fs.readfile(path);

	if (s == null)
		return Result.err(errors.SOURCE_UNREADABLE, path);

	let doc;
	try {
		doc = json(s);
	} catch (e) {
		return Result.err(errors.SOURCE_INVALID, `${path}: ${e.message}`);
	}

	let data = doc?.[key];
	if (!(type(data) in [ 'object', 'array' ]))
		return Result.err(errors.SOURCE_INVALID, `${path}: no ${key}`);

	return Result.ok(data);
}

function list(v) {
	return type(v) == 'array' ? v : type(v) == 'object' ? values(v) : [];
}

export function collect(deps, out) {
	let res = read(deps.fs, 'status', 'status');
	if (!res.ok)
		return res;

	let status = res.data;

	out.gauge('bmx7_status', 'The bmx7 node.')({
		id: status.shortId,
		name: status.name,
		address: status.primaryIp,
		revision: status.revision,
	}, 1);
	out.gauge('bmx7_cpu_usage', 'CPU usage of bmx7, in percent.')(null, status.cpu);
	out.gauge('bmx7_mem_usage', 'Memory used by bmx7, in bytes.')(null, interpret_suffix(status.mem));

	res = read(deps.fs, 'links', 'links');
	if (!res.ok)
		return res;

	let rx = out.gauge('bmx7_link_rxRate', 'The receive rate of a link to a neighbour.');
	let tx = out.gauge('bmx7_link_txRate', 'The transmit rate of a link to a neighbour.');

	for (let link in list(res.data)) {
		let labels = { source: status.shortId, target: link?.shortId, name: link?.name, dev: link?.dev };
		rx(labels, interpret_suffix(link?.rxRate));
		tx(labels, interpret_suffix(link?.txRate));
	}

	res = read(deps.fs, 'parameters', 'OPTIONS');
	if (!res.ok)
		return res;

	let tun_in = out.gauge('bmx7_tunIn', 'A network this node announces with tunIn.');
	let plugin = out.gauge('bmx7_plugin', 'A plugin bmx7 has loaded.');

	for (let option in list(res.data)) {
		if (option?.name == 'tunIn') {
			for (let instance in list(option.INSTANCES))
				for (let child in list(instance?.CHILD_INSTANCES))
					// The /network of the tunnel; other child options are no network.
					if (child?.name == null || child.name == 'network')
						tun_in({ name: instance.value, network: child.value }, 1);
		} else if (option?.name == 'plugin') {
			for (let instance in list(option.INSTANCES))
				plugin({ name: instance?.value }, 1);
		}
	}

	return Result.ok();
};

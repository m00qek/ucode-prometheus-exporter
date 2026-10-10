'use strict';

import { Result, errors, services } from 'prometheus_exporter.api';

export const DIR = '/var/run/bmx7/json';

export const meta = {
	name: 'bmx7',
	title: 'bmx7 mesh',
	help: 'The bmx7 mesh node, its links and tunnels, from its JSON status files.',
	needs: [ 'fs', 'ubus' ],
	ubus: { rc: [ 'list' ] },
	paths: [ DIR ],
};

const SCALE = { K: 1000, M: 1000000, G: 1000000000 };

export function interpret_suffix(v) {
	let m = type(v) == 'string' ? match(v, /^(-?[0-9]+(\.[0-9]+)?)([KMG])$/) : null;

	return m ? +m[1] * SCALE[m[3]] : v;
};

export function ratio(v) {
	let n = (type(v) in [ 'int', 'double' ]) ? v
		: (type(v) == 'string' && match(trim(v), /^-?[0-9]+(\.[0-9]+)?$/)) ? +trim(v) : null;

	return n == null ? null : n / 100.0;
};

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
		return services.unless_disabled(deps.ubus, 'bmx7', res);

	let status = res.data;

	out.gauge('bmx7_info', 'The bmx7 node.')({
		id: status.shortId,
		name: status.name,
		address: status.primaryIp,
		revision: status.revision,
	}, 1);
	out.gauge('bmx7_cpu_usage_ratio', 'CPU usage of bmx7, from 0 to 1.')(null, ratio(status.cpu));
	out.gauge('bmx7_memory_usage_bytes', 'Memory used by bmx7, in bytes.')(null, interpret_suffix(status.mem));

	res = read(deps.fs, 'links', 'links');
	if (!res.ok)
		return res;

	let rx = out.gauge('bmx7_link_receive_rate_bits_per_second', 'The receive rate of a link to a neighbour, in bits per second.');
	let tx = out.gauge('bmx7_link_transmit_rate_bits_per_second', 'The transmit rate of a link to a neighbour, in bits per second.');

	for (let link in list(res.data)) {
		let labels = { source: status.shortId, target: link?.shortId, name: link?.name, device: link?.dev };
		rx(labels, interpret_suffix(link?.rxRate));
		tx(labels, interpret_suffix(link?.txRate));
	}

	res = read(deps.fs, 'parameters', 'OPTIONS');
	if (!res.ok)
		return res;

	let tun_in = out.gauge('bmx7_tun_in_info', 'A network this node announces with tunIn.');
	let plugin = out.gauge('bmx7_plugin_info', 'A plugin bmx7 has loaded.');

	for (let option in list(res.data)) {
		if (option?.name == 'tunIn') {
			for (let instance in list(option.INSTANCES))
				for (let child in list(instance?.CHILD_INSTANCES))
					if (child?.name == null || child.name == 'network')
						tun_in({ name: instance.value, network: child.value }, 1);
		} else if (option?.name == 'plugin') {
			for (let instance in list(option.INSTANCES))
				plugin({ name: instance?.value }, 1);
		}
	}

	return Result.ok();
};

'use strict';

import { Result, errors } from 'prometheus.exporter';

const SPACES = /\s+/;

export const meta = {
	name: 'uci_dhcp_host',
	title: 'Static DHCP hosts',
	help: 'Static DHCP leases from /etc/config/dhcp.',
	needs: [ 'uci' ],
	configs: [ 'dhcp' ],
};

export function macs(value) {
	let all = [];

	for (let v in (type(value) == 'array' ? value : [ value ]))
		if (type(v) == 'string')
			push(all, ...filter(split(trim(v), SPACES), length));

	return length(all) ? all : [ null ];
};

function scalar(v) {
	return type(v) == 'array' ? join(' ', v) : v;
}

export function collect(deps, out) {
	let dhcp = deps.uci.dhcp;

	if (!dhcp.loaded())
		return Result.err(errors.SOURCE_UNREADABLE, '/etc/config/dhcp');

	let info = out.gauge('node_openwrt_dhcp_host_info', 'A static DHCP lease from /etc/config/dhcp.');
	let seen = {};

	dhcp.foreach('host', (s) => {
		for (let mac in macs(s.mac)) {
			let labels = { name: scalar(s.name), mac, ip: scalar(s.ip) };
			let id = sprintf('%J', labels);

			if (!seen[id]) {
				seen[id] = true;
				info(labels, 1);
			}
		}
	});

	return Result.ok();
};

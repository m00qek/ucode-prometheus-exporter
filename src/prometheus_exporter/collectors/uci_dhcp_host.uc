'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/uci_dhcp_host.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The ucode exporter's uci_dhcp_host collector: node_openwrt_dhcp_host_info 1
// (its dhcp_host_info, in the namespace of OpenWrt's own metrics) for every
// static lease (`config host`) in /etc/config/dhcp, labeled with its name, MAC
// and IP. A host with several MACs, as a list or as one space-separated value,
// has a sample per MAC, where upstream dropped the mac label of a list; a host
// without a MAC, name or IP has a sample without that label.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
const SPACES = /\s+/;

export const meta = {
	name: 'uci_dhcp_host',
	title: 'Static DHCP hosts',
	help: 'Static DHCP leases from /etc/config/dhcp.',
	needs: [ 'uci' ],
	configs: [ 'dhcp' ],
};

// The MACs of a host's `mac` option: none, one, a list, or several in one value.
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

			// Two hosts alike would be the same series twice.
			if (!seen[id]) {
				seen[id] = true;
				info(labels, 1);
			}
		}
	});

	return Result.ok();
};

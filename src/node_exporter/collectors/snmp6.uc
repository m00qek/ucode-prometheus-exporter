'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/snmp6.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten in ucode; see NOTICE.

// IPv6 statistics, as upstream's snmp6 collector: each "<name> <value>" line
// of /proc/net/snmp6 is a counter snmp6_<name>{device="all"}, and of
// /proc/net/dev_snmp6/<device> the same counter for that device. Its ifIndex
// line is exported too, as upstream does.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { lines, fields } from 'node_exporter.proc';

export const meta = {
	name: 'snmp6',
	help: 'IPv6 statistics from /proc/net/snmp6 and /proc/net/dev_snmp6.',
	needs: [ 'fs' ],
};

const ALL = '/proc/net/snmp6';
const DEVICES = '/proc/net/dev_snmp6';

// False when the file cannot be read.
function parse(fs, out, path, device) {
	let l = lines(fs, path);

	if (l == null)
		return false;

	for (let line in l) {
		let x = fields(line);

		if (length(x) >= 2)
			out.counter(`snmp6_${x[0]}`, `IPv6 statistic ${x[0]}.`)({ device }, x[1]);
	}

	return true;
}

export function collect(deps, out) {
	// Where IPv6 is disabled there is no /proc/net/snmp6: nothing to collect.
	if (!parse(deps.fs, out, ALL, 'all'))
		return Result.err(errors.SOURCE_UNREADABLE, ALL);

	// A device that goes away before it is read is left out.
	for (let device in sort(deps.fs.lsdir(DEVICES) ?? []))
		parse(deps.fs, out, `${DEVICES}/${device}`, device);

	return Result.ok();
};

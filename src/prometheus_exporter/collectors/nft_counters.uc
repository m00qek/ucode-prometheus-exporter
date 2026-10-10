'use strict';

import { Result, errors } from 'prometheus_exporter.api';

export const meta = {
	name: 'nft-counters',
	title: 'nftables counters',
	help: 'Packets and bytes of the named nftables counters.',
	needs: [ 'exec' ],
	capabilities: [ 'CAP_NET_ADMIN' ],
	commands: [ 'nft' ],
};

export function collect(deps, out) {
	let res = deps.exec.run([ 'nft', '--json', 'list', 'counters' ]);

	if (!res.ok)
		return res;

	let doc;
	try {
		doc = json(res.data);
	} catch (e) {
		return Result.err(errors.SOURCE_INVALID, `nft --json list counters: ${e.message}`);
	}

	if (type(doc) != 'object' || type(doc.nftables) != 'array')
		return Result.err(errors.SOURCE_INVALID, 'nft --json list counters: no nftables array');

	let packets = out.counter('nft_counter_packets_total', 'Packets counted by the nftables counter.');
	let bytes = out.counter('nft_counter_bytes_total', 'Bytes counted by the nftables counter.');

	for (let item in doc.nftables) {
		let c = item?.counter;

		if (type(c) != 'object')
			continue;

		let labels = { family: c.family, table: c.table, name: c.name, comment: c.comment };
		packets(labels, c.packets);
		bytes(labels, c.bytes);
	}

	return Result.ok();
};

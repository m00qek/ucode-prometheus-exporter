'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as commands from 'prometheus.exporter.devkit.commands';
import * as nft_counters from 'prometheus.collectors.nft_counters';

const NFT = commands.line([ 'nft', '--json', 'list', 'counters' ]);

// banIP's counters on the caju router.
const ROUTER = fixtures.file('caju-router', '/commands/nft_json_list_counters.txt');

// Counters with and without a comment, in the counter object of
// libnftables-json(5), as nft 1.1.6 writes it.
const COMMENTED = fixtures.file('synthetic', '/commands/nft_json_list_counters.txt');

function with_nft(output, cb) {
	with_collector(nft_counters, { fs: commands.fs(output == null ? {} : { [NFT]: output }) }, cb);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.nft_counters', () => {
	it('exports the packets and bytes of every counter of the caju router', () => {
		with_nft({ out: ROUTER }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP nft_counter_packets_total Packets counted by the nftables counter.',
				'# TYPE nft_counter_packets_total counter',
				'nft_counter_packets_total{family="inet",table="banIP",name="cnt_icmpflood"} 0',
				'nft_counter_packets_total{family="inet",table="banIP",name="cnt_udpflood"} 117',
				'nft_counter_packets_total{family="inet",table="banIP",name="cnt_synflood"} 0',
				'nft_counter_packets_total{family="inet",table="banIP",name="cnt_tcpinvalid"} 0',
				'nft_counter_packets_total{family="inet",table="banIP",name="cnt_ctinvalid"} 34',
				'nft_counter_packets_total{family="inet",table="banIP",name="cnt_bcp38"} 0',
				'# HELP nft_counter_bytes_total Bytes counted by the nftables counter.',
				'# TYPE nft_counter_bytes_total counter',
				'nft_counter_bytes_total{family="inet",table="banIP",name="cnt_icmpflood"} 0',
				'nft_counter_bytes_total{family="inet",table="banIP",name="cnt_udpflood"} 39347',
				'nft_counter_bytes_total{family="inet",table="banIP",name="cnt_synflood"} 0',
				'nft_counter_bytes_total{family="inet",table="banIP",name="cnt_tcpinvalid"} 0',
				'nft_counter_bytes_total{family="inet",table="banIP",name="cnt_ctinvalid"} 1900',
				'nft_counter_bytes_total{family="inet",table="banIP",name="cnt_bcp38"} 0',
			], r.lines);
		});
	});

	it('labels a counter with its comment, when it has one', () => {
		with_nft({ out: COMMENTED }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'nft_counter_packets_total{family="inet",table="fw4",name="wan_in",comment="WAN \\"inbound\\" traffic"} 18446744073',
				'nft_counter_packets_total{family="ip6",table="stats",name="icmp6"} 12',
				'nft_counter_bytes_total{family="inet",table="fw4",name="wan_in",comment="WAN \\"inbound\\" traffic"} 25769803776123',
				'nft_counter_bytes_total{family="ip6",table="stats",name="icmp6"} 960',
			], samples(r.lines));
		});
	});

	it('exports nothing for a ruleset without counters', () => {
		with_nft({ out: '{"nftables": [{"metainfo": {"json_schema_version": 1}}]}' }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('passes on a failing nft as COMMAND_FAILED', () => {
		with_nft({ out: '', status: 1 }, (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'nft: exit status 1' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('passes on an nft that does not answer in time as COMMAND_TIMEOUT', () => {
		with_nft({ hangs: true }, (r) => {
			assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'nft: still running after 5 s, killed' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('fails with COMMAND_FAILED when nft cannot start', () => {
		with_nft(null, (r) => {
			assert.match({ error: 'COMMAND_FAILED', details: 'nft: cannot start' }, { error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_INVALID for output that is not JSON', () => {
		with_nft({ out: 'Error: syntax error\n' }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for JSON without an nftables array', () => {
		for (let out in [ '{}', '[]', 'null', '{"nftables": {}}' ])
			with_nft({ out }, (r) => assert.match('SOURCE_INVALID', r.result.error, out));
	});

	prop('exports each counter once, with its values',
		gen.array(gen.tuple(gen.alphanumeric({ min_len: 1, max_len: 10 }), gen.int(0, 1000000), gen.int(0, 1000000000)),
			{ min_len: 0, max_len: 8 }), (counters) => {
			let items = map(counters, (c, i) => ({ counter: { family: 'inet', table: 't', name: `${c[0]}${i}`, handle: i, packets: c[1], bytes: c[2] } }));

			with_nft({ out: sprintf('%J', { nftables: items }) }, (r) => {
				assert.match(true, r.result.ok);
				assert.match([
					...map(counters, (c, i) => `nft_counter_packets_total{family="inet",table="t",name="${c[0]}${i}"} ${c[1]}`),
					...map(counters, (c, i) => `nft_counter_bytes_total{family="inet",table="t",name="${c[0]}${i}"} ${c[2]}`),
				], samples(r.lines));
			});
		});
});

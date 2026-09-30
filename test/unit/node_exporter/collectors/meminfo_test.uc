'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as meminfo from 'node_exporter.collectors.meminfo';

const ROUTER = fixtures.files('caju-router', [ '/proc/meminfo' ]);
const AP = fixtures.files('caju-ap', [ '/proc/meminfo' ]);

function mem(text) {
	return { fs: { data: { '/proc/meminfo': text } } };
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.meminfo', () => {
	it('exports every field of the caju router in bytes, a gauge each', () => {
		with_collector(meminfo, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_memory_MemTotal_bytes Memory information field MemTotal_bytes.',
				'# TYPE node_memory_MemTotal_bytes gauge',
				'node_memory_MemTotal_bytes 4125917184',
			], slice(r.lines, 0, 3));
			assert.match(length(r.families) * 3, length(r.lines));
			assert.match([
				'node_memory_MemTotal_bytes 4125917184',
				'node_memory_MemFree_bytes 2666844160',
				'node_memory_MemAvailable_bytes 3446120448',
				'node_memory_Buffers_bytes 190058496',
				'node_memory_Cached_bytes 612884480',
				'node_memory_SwapCached_bytes 0',
				'node_memory_Active_bytes 703873024',
				'node_memory_Inactive_bytes 611921920',
				'node_memory_Active_anon_bytes 514908160',
				'node_memory_Inactive_anon_bytes 0',
				'node_memory_Active_file_bytes 188964864',
				'node_memory_Inactive_file_bytes 611921920',
				'node_memory_Unevictable_bytes 0',
				'node_memory_Mlocked_bytes 0',
				'node_memory_SwapTotal_bytes 0',
				'node_memory_SwapFree_bytes 0',
				'node_memory_Dirty_bytes 4096',
				'node_memory_Writeback_bytes 0',
				'node_memory_AnonPages_bytes 489238528',
				'node_memory_Mapped_bytes 159375360',
				'node_memory_Shmem_bytes 2072576',
				'node_memory_KReclaimable_bytes 50647040',
				'node_memory_Slab_bytes 87760896',
				'node_memory_SReclaimable_bytes 50647040',
				'node_memory_SUnreclaim_bytes 37113856',
				'node_memory_KernelStack_bytes 3825664',
				'node_memory_PageTables_bytes 4259840',
				'node_memory_SecPageTables_bytes 0',
				'node_memory_NFS_Unstable_bytes 0',
				'node_memory_Bounce_bytes 0',
				'node_memory_WritebackTmp_bytes 0',
				'node_memory_CommitLimit_bytes 2062958592',
				'node_memory_Committed_AS_bytes 1472188416',
				'node_memory_VmallocTotal_bytes 138535235485696',
				'node_memory_VmallocUsed_bytes 9805824',
				'node_memory_VmallocChunk_bytes 0',
				'node_memory_Percpu_bytes 540672',
				'node_memory_AnonHugePages_bytes 385875968',
				'node_memory_ShmemHugePages_bytes 0',
				'node_memory_ShmemPmdMapped_bytes 0',
				'node_memory_FileHugePages_bytes 0',
				'node_memory_FilePmdMapped_bytes 0',
				'node_memory_CmaTotal_bytes 16777216',
				'node_memory_CmaFree_bytes 15204352',
				'node_memory_HugePages_Total_bytes 0',
				'node_memory_HugePages_Free_bytes 0',
				'node_memory_HugePages_Rsvd_bytes 0',
				'node_memory_HugePages_Surp_bytes 0',
				'node_memory_Hugepagesize_bytes 2097152',
				'node_memory_Hugetlb_bytes 0',
			], samples(r.lines));
		});
	});

	it('reads the caju AP too', () => {
		with_collector(meminfo, { fs: { data: AP } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(contains([ '# TYPE node_memory_MemAvailable_bytes gauge' ]), r.lines);
		});
	});

	it("names a field's parenthesised part with an underscore and keeps unitless values as they are", () => {
		with_collector(meminfo, mem('Active(anon):   2 kB\nHugePages_Total:   7\n'), (r) => {
			assert.match([ 'node_memory_Active_anon_bytes 2048', 'node_memory_HugePages_Total_bytes 7' ], samples(r.lines));
		});
	});

	it('fails with SOURCE_UNREADABLE when /proc/meminfo cannot be read', () => {
		with_collector(meminfo, mem(null), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/meminfo' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
			assert.match([ "collector 'meminfo': SOURCE_UNREADABLE (/proc/meminfo)" ], r.logs);
		});
	});

	it('fails with SOURCE_INVALID for an empty file', () => {
		with_collector(meminfo, mem(''), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: '/proc/meminfo: no fields' },
				{ error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_INVALID for a line it cannot read, keeping the fields around it', () => {
		with_collector(meminfo, mem('MemTotal: 1 kB\nMemFree: lots kB\nCached: 3 kB\n'), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: '/proc/meminfo: "MemFree: lots kB"' },
				{ error: r.result.error, details: r.result.details });
			assert.match([ 'node_memory_MemTotal_bytes 1024', 'node_memory_Cached_bytes 3072' ], samples(r.lines));
		});
	});

	// Unique names: an index, then letters and digits, then maybe a parenthesised part.
	prop('exports every field it is given, in bytes when the kernel says kB',
		gen.array(gen.record({
			name: gen.alphanumeric({ min_len: 1, max_len: 12 }),
			sub: gen.optional(gen.alphanumeric({ min_len: 1, max_len: 6 })),
			value: gen.int(0, 1 << 50),
			kb: gen.bool(),
		}), { min_len: 1, max_len: 30 }), (fields) => {
			let text = '';
			let want = [];

			for (let i, f in fields) {
				let name = `F${i}${f.name}`;

				text += sprintf('%-16s %10d%s\n', name + (f.sub != null ? `(${f.sub})` : '') + ':', f.value, f.kb ? ' kB' : '');
				push(want, `node_memory_${name}${f.sub != null ? '_' + f.sub : ''}_bytes ${f.kb ? f.value * 1024 : f.value}`);
			}

			with_collector(meminfo, mem(text), (r) => {
				assert.match(true, r.result.ok);
				assert.match(want, samples(r.lines));
			});
		});
});

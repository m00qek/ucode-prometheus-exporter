// What make bench-qemu checks in the guest before the bench, on the installed
// exporter: that what reads data in the CPU's own byte order and word size
// reads, on this CPU, what the kernel wrote. The bench's worlds are text, the
// same on every CPU; these read the guest's own kernel. A line a check, `ok`
// or `FAILED` and what it found; exits 1 when one failed.
//
// - The auxiliary vector (proc.auxv(), which finds its layout by what fits):
//   the page size sockstat multiplies by, and the clock tick the exporter
//   collector divides by.
// - sockstat's node_sockstat_<protocol>_mem_bytes: its pages times that page
//   size, in a scrape of the installed collector. An idle guest holds no
//   socket memory, 0 pages: that the family is there at all says the page size
//   was read, as sockstat leaves it out otherwise.
// - Basic auth's hashes (crypt.uc, over the digest module's hex), against
//   known ones.
'use strict';

import { readfile, popen } from 'fs';
import { auxv, AT_PAGESZ, AT_CLKTCK } from 'prometheus.exporter.proc';
import { verify } from 'prometheus.exporter.crypt';

let failed = 0;

function check(what, ok, found) {
	printf('%s %s: %s\n', ok ? 'ok' : 'FAILED', what, found);
	if (!ok)
		failed++;
}

// The ELF header of busybox says the byte order and word size the kernel
// writes the vector in: EI_CLASS (1, 32-bit; 2, 64-bit) and EI_DATA (1,
// little-endian; 2, big-endian).
let elf = readfile('/bin/busybox', 6);
let order = (elf && substr(elf, 0, 4) == '\x7fELF')
	? sprintf('%d-bit %s-endian', ord(elf, 4) * 32, ord(elf, 5) == 2 ? 'big' : 'little')
	: 'unknown';

// The kernel's own page size, as it says it in text: a mapping's
// KernelPageSize, or, where there is no smaps (malta's kernel), procd's
// resident memory in kB over the pages statm counts of it, the same counters.
function kernel_page_size() {
	let m = match(readfile('/proc/self/smaps') ?? '', /KernelPageSize:\s+(\d+) kB/);

	if (m)
		return [ int(m[1]) * 1024, 'smaps' ];

	let kb = match(readfile('/proc/1/status') ?? '', /\nVmRSS:\s+(\d+) kB/);
	let pages = split(readfile('/proc/1/statm') ?? '', ' ')[1];

	return (kb && +pages > 0) ? [ int(kb[1]) * 1024 / +pages, "procd's VmRSS over statm" ] : [ null, 'unknown' ];
}

let kernel_page = kernel_page_size();

let vector = auxv(readfile('/proc/self/auxv'));
let page = vector?.[AT_PAGESZ], tick = vector?.[AT_CLKTCK];

check('auxv', vector != null && page != null, `${order}, AT_PAGESZ ${page}, AT_CLKTCK ${tick}`);
check('auxv page size', page != null && page == kernel_page[0], `${page}, the kernel's ${kernel_page[0]} (${kernel_page[1]})`);
// USER_HZ: 100 on every architecture OpenWrt runs on.
check('auxv clock tick', tick == 100, `${tick}`);

// sockstat as the service runs it: in a scrape of the installed collector.
let p = popen('prometheus-exporter scrape sockstat 2>/dev/null');
let text = p ? p.read('all') : null;
p?.close();

let pages = {}, bytes = {};
for (let m in match(text ?? '', /\nnode_sockstat_([A-Za-z0-9]+)_mem(_bytes)? (\d+)/g))
	(m[2] ? bytes : pages)[m[1]] = int(m[3]);

let seen = [], wrong = 0;
for (let proto, n in pages) {
	push(seen, `${proto} ${n} pages, ${bytes[proto]} bytes`);
	if (page == null || bytes[proto] != n * page)
		wrong++;
}
check('sockstat mem_bytes', length(seen) > 0 && !wrong,
	length(seen) ? join('; ', seen) : `no node_sockstat_*_mem in the scrape: ${text}`);

// Known hashes: glibc's own examples, MD5-crypt and the SHA-crypts.
for (let h in [
	[ 'Hello world!', '$1$saltstri$YMyguxXMBpd2TEZ.vS/3q1' ],
	[ 'a', '$5$rounds=1000$x$SQwVBUy5LmuITCN/Pzolg3R9CfHva3WZZYnD1O10qB5' ],
	[ 'Hello world!', '$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1' ],
])
	check('crypt', verify(h[0], h[1]), substr(h[1], 0, 3) + '...');

exit(failed ? 1 : 0);

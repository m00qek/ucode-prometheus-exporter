# Performance on Small Routers

A scrape is a ucode program run on a router's CPU, and many routers have a slow one: a MIPS core of a few hundred MIPS, interpreting bytecode. This page is about what a scrape costs there, how that was measured, and where the cost still bites.

---

## The cost of the VM

Every operation of ucode's VM costs about a microsecond on a router: a loop's turn, a call of a builtin, a property read. A regex match costs several, and a regex literal is compiled each time it is evaluated. A scrape writes thousands of samples and reads tables of thousands of lines, so what matters is what is done per sample and per line.

That is why the code looks the way it does. Regexes are module constants, and kept out of what runs per line where `index()`, `split()` on a string or `substr()` do. A sample's line is written once, when it is recorded, and labels several samples share are written once and passed around. nat_traffic takes a conntrack line apart with fixed-string splits, without a regex or a function call per line. `make bench` shows what a collector costs, and holds the budgets of `test/bench/budgets.uc`: a scaling budget, a memory budget, and generous times.

## What a scrape costs

The same scrape, the typical world (a home router with Wi-Fi: 12 links, 300 conntrack entries, 20 stations, 50 leases) with the base package and the `-full` group, on each machine, with the speed of ucode's VM on it (`calibrate:vm`'s loop turn) and of running a program:

| Machine | Typical full scrape | A loop turn | A program run |
| :--- | :--- | :--- | :--- |
| devenv (Ryzen 7 7840U) | 0.10 s | 0.32 µs | 1.7 ms |
| NanoPi R3S (4×A55, OpenWrt 25.12.5) | 0.55 s | 2.0 µs | 3.2 ms |
| YunCore AX835 (MT7981, 2×A53 at 1.3 GHz) | 0.72 s | 3.0 µs | 3.4 ms |
| QEMU malta, 24Kc at 500 MIPS (`QEMU_SHIFT=1`) | 2.0 s | 9.9 µs | 5.3 ms |
| QEMU malta, 24Kc at 250 MIPS (`QEMU_SHIFT=2`) | 4.0 s | 19.7 µs | |

A scrape runs in a process of its own, as uhttpd answers each request in a process forked from the one that loaded the exporter, so it starts with nothing a scrape before left. The benchmark does the same: each run is a process of its own, timed after loading, and its memory is how far its peak rose above what it held before the run.

## Calibration

A container limited to a share of one CPU stands in for a slower machine, when the share makes its loop turn match. On the laptop above, 0.35 of one CPU matched the R3S (2.0 µs, and 0.54 s for the scrape), 0.22 the AP (3.1 µs), and 0.07 the 500-MIPS 24Kc (10.7 µs), though not its scrape (3.4 s): a container's programs cost what the host's do under a quota, 30 ms a run there, while a router's cost what its own kernel makes them. The share depends on how loaded and how fast the host is, so it is picked in the same session as the run.

QEMU is the closer model of a MIPS router. It counts instructions (`-icount shift=N,sleep=on`, with the guest's clock on the same count), so its times are a deterministic function of the code and of N: shift 2 is exactly twice shift 1. A MIPS router's own speed is its clock times its instructions per cycle: an MT7621's 1004Kc at 880 MHz runs an interpreter at roughly 0.5 to 0.7 instructions a cycle, 450 to 600 MIPS, which is `QEMU_SHIFT=1`; a 24Kc at 600 to 750 MHz (QCA953x, QCA956x) at 300 to 450 MIPS, between shift 1 and shift 2. The A53 anchors the scale: a loop turn takes it 3.0 µs and the 1000-MIPS guest 4.9 µs, so it runs this code as a 1650-MIPS 24Kc would, three to four times an MT7621.

## Where it still bites: nat_traffic

nat_traffic reads the whole conntrack table, a line per connection, at every scrape. Its time grows with the table, linearly, as its scaling budget holds it to: 0.41 s for 20,000 entries in the devenv. A home router's table holds a few hundred entries; a busy one, or one under a flood of connections, tens of thousands.

Scaled by the loop turn, the 500-MIPS 24Kc is about thirty times slower than the devenv: 20,000 entries would take it about twelve seconds, more than Prometheus's default `scrape_timeout` of ten. Prometheus drops a scrape that answers late whole, not only nat_traffic's part.

So a scrape has a deadline, the scraper's timeout less half a second, and runs the collectors fastest first: nat_traffic, slowest, comes last, and when the time left does not fit what it took before, it is left out, and the scrape answers with the rest. And a collector that takes longer than its budget, 5 seconds by default, is quarantined for a few scrapes.

On QEMU's 500-MIPS 24Kc (`make bench-qemu`), the full scrape of the benchmark's large world, whose conntrack table holds 20,000 connections, takes 14.1 s without a deadline, nat_traffic 7.0 s of it. With Prometheus's default timeout of 10 s (`deadline:full@20000`), once the first scrape has filled the ledger, it answers in 7.0 s, nat_traffic left out and every other collector served. The first scrape after a restart, before the ledger knows how long nat_traffic takes, can still be late. See [About deadlines and circuit breakers](deadlines-and-breakers.md).

It is in the `-network` and `-full` groups. On such a router, leave it out, [disable it](../how-to/choose-collectors.md#disable-a-collector), or scrape it in a job of its own with a longer timeout and a `budget` to match; and watch `node_scrape_collector_duration_seconds{collector="nat_traffic"}`.

## A process per collector {#a-process-per-collector}

Each scrape runs its collectors in a child process, so that one that never returns, or ends its process, costs itself alone (see [About the architecture](architecture.md#a-process-of-its-own)). That has a price, which the benchmark measures as a scrape forked (`scrape:`) against the same scrape in one process (`inline:`):

| Scrape | devenv | QEMU's 500-MIPS 24Kc |
| :--- | :--- | :--- |
| typical, base collectors (16) | 24.1 ms, 6.7 ms more | 420 ms, 76 ms more (+22%) |
| typical, every collector (36) | 156 ms, 20 ms more (+15%) | 2.72 s, 271 ms more (+11%) |
| large, base collectors | 50.6 ms, 7 ms more | 904 ms, 70 ms more (+8%) |
| large, every collector | 685 ms, 61 ms more (+10%) | nat_traffic alone takes 7.3 s there |

On the router, that is about a twentieth of a second for the fork and some 7 ms a collector: the round trip between the scrape and its child, and the pages the child copies from the scrape's as it writes them (copy-on-write). Loading every collector first in a child process costs uhttpd's start as much again as loading them: 0.88 s rather than 0.45 s on the 24Kc, once per start. The progress file costs a scrape 3.6 ms there, a tenth of a percent.

So a scrape on a slow router costs a tenth to a fifth more than it would if its collectors could not stop it. That is the trade: a collector that loops, waits on a FIFO or runs out of memory then costs its own budget and nothing more, where it would hold every later scrape, or end the request with nothing answered.

## The ledger

Ordering the collectors and keeping their breakers costs a scrape a read of a small file when it starts, and a locked read and write when it ends (`make bench`'s `ledger:full`, 35 collectors, a ledger of 1.5 kB): 1.0 ms in the devenv and 21 ms on the 500-MIPS 24Kc, about 1% of a typical full scrape on both.

## Gzip

A whole scrape of the lab (every collector, about 1250 series, on x86_64) is 143,500 bytes plain and 21,640 gzipped, 6.6 times smaller. Deflating it takes about 1 ms at zlib's fastest level, which the exporter uses, and 3 ms at its default level, for 19,160 bytes. Over loopback the scrape takes as long either way (118 ms plain, 123 ms gzipped): the gain is on the wire, 85% fewer bytes per scrape, which matters on a slow or metered link and costs the router little.

## Basic auth

The handler computes the password's hash in ucode at each scrape, so the hash's rounds are what a check costs (`make bench`'s `auth:` cases, the median of a check in a process of its own):

| Machine | `$1$` | `$6$`, 1000 rounds (`hash_password`'s) | `$5$`, 2000 | `$6$`, 2000 | By the cache |
| :--- | :--- | :--- | :--- | :--- | :--- |
| devenv (Ryzen 7 7840U) | 2.5 ms | 4.1 ms | 6.5 ms | 7.8 ms | 0.09 ms |
| NanoPi R3S (4×A55) | 14 ms | 19 ms | 33 ms | 37 ms | 0.5 ms |
| QEMU malta, 24Kc at 500 MIPS | 63 ms | 135 ms | 206 ms | 259 ms | 2.4 ms |

A round of SHA-512-crypt takes the 500-MIPS 24Kc 125 µs. The 9,999,999 rounds a hash may name would take it twenty minutes, the default 5000 0.63 s. So a hash takes at most 2000 rounds, a quarter of a second there, and more is refused. Even 1000 rounds are 135 ms of each scrape on such a router, which is why the handler keeps a cache of the last header it let in: a request it lets in by the cache costs about 2% of the full check, everywhere. See [About the security model](security.md#the-cache-and-what-it-trades).

## See also

- [How to run the benchmark](../how-to/developer/benchmarks.md)
- [How to give programs more time](../how-to/exec-timeout.md)

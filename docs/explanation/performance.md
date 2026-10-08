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

The MT7621's packages are little-endian (`mipsel_24kc`); the most common small routers, ath79's, are big-endian (`mips_24kc`). `QEMU_ENDIAN=be` runs malta's big-endian image instead. On 25.12.5, at shift 1, every case of the benchmark wrote the same samples and logs in both byte orders, and took within 2% of the same time, the big-endian guest the slower by about 1% (the fastest runs of `deadline:full@20000` too, whose median depends on where the deadline stops a run): the byte order changes nothing ucode's VM does with text. What the exporter reads in the CPU's byte order, the auxiliary vector that gives sockstat its page size and the exporter collector its clock tick, the guest checks against its own kernel before the bench, in both.

## Where it still bites: nat_traffic

nat_traffic reads the whole conntrack table, a line per connection, at every scrape. Its time grows with the table, linearly, as its scaling budget holds it to: 0.41 s for 20,000 entries in the devenv. A home router's table holds a few hundred entries; a busy one, or one under a flood of connections, tens of thousands.

Scaled by the loop turn, the 500-MIPS 24Kc is about thirty times slower than the devenv: 20,000 entries would take it about twelve seconds, more than Prometheus's default `scrape_timeout` of ten. Prometheus drops a scrape that answers late whole, not only nat_traffic's part.

So a scrape has a deadline, the scraper's timeout less half a second, and runs the collectors fastest first: nat_traffic, slowest, comes last, and when the time left does not fit what it took before, it is left out, and the scrape answers with the rest. And a collector that takes longer than its budget, 5 seconds by default, is quarantined for a few scrapes.

On QEMU's 500-MIPS 24Kc (`make bench-qemu`), the full scrape of the benchmark's large world, whose conntrack table holds 20,000 connections, takes 16.6 s without a deadline, nat_traffic 7.7 s of it. With Prometheus's default timeout of 10 s (`deadline:full@20000`), once the first scrape has filled the ledger, it answers in 8.6 to 9.7 s, nat_traffic left out and every other collector served: within the timeout, by little, as a collector still running at the deadline is stopped there. The first scrape after a restart, before the ledger knows how long nat_traffic takes, can still be late. See [About deadlines and circuit breakers](deadlines-and-breakers.md).

It is in the `-network` and `-full` groups. On such a router, leave it out, [disable it](../how-to/choose-collectors.md#disable-a-collector), or scrape it in a job of its own with a longer timeout and a `budget` to match; and watch `node_scrape_collector_duration_seconds{collector="nat_traffic"}`.

## A process per collector {#a-process-per-collector}

Each scrape runs its collectors in a child process, so that one that never returns, or ends its process, costs itself alone (see [About the architecture](architecture.md#a-process-of-its-own)). That has a price, which the benchmark measures as a scrape forked (`scrape:`) against the same scrape in one process (`inline:`):

| Scrape | devenv | QEMU's 500-MIPS 24Kc |
| :--- | :--- | :--- |
| typical, base collectors (16) | 16.9 ms, 4.4 ms more | 393 ms, 62 ms more (+19%) |
| typical, every collector (36) | 104 ms, 14 ms more (+15%) | 2.72 s, 279 ms more (+11%) |
| large, base collectors | 35.9 ms, 4.8 ms more | 887 ms, 62 ms more (+8%) |
| large, every collector | 481 ms, 35 ms more (+8%) | 16.1 s, 0.87 s more (+6%) |

On the 24Kc, that is some 4 to 8 ms a collector: the round trip between the scrape and its child, and the pages the child copies from the scrape's as it writes them (copy-on-write). The progress file costs a scrape 3.6 ms there, a tenth of a percent.

So a scrape on a slow router costs a tenth to a fifth more than it would if its collectors could not stop it. That is the trade: a collector that loops, waits on a FIFO or runs out of memory then costs its own budget and nothing more, where it would hold every later scrape, or end the request with nothing answered.

## Besides the collectors {#besides-the-collectors}

A scrape is more than its collectors' runs. uhttpd forks the request's process; the scrape reads the config and the ledger, hands each collector to the child and reads its run back, owns and renders every family, and writes the ledger and the progress file. In 0.2.0 that cost far more than it had to: on the NanoPi R3S a scrape of 37 collectors took 0.79 to 0.89 s through uhttpd, while its collectors' durations added up to 0.47 s, which was 0.1.0's whole scrape.

It was work, not waiting. Traced step by step through uhttpd under procd, in a container and on QEMU's 24Kc, no step of a scrape waits on a timer: the scrape hands a collector to its child and reads its run back over a pipe, which uloop wakes it for, and its timer, which looks every 100 ms, fires only while a collector runs that long, to stop it at its limit or to see its child died. What took the time was the scrape's own work, much of it done for each collector, or each family, that needed doing once. On QEMU, a scrape of the guest's own system by the 36 collectors of the `-full` group spent 0.87 s besides its collectors':

- 248 ms on the collectors' settings: each read the main section of the config two or three times over, and each value of a `range()` option made its datatype anew, writing the English of what it takes. A scrape now reads the main section once for all its collectors, and a range is made once.
- 81 ms deciding whose each family is, which now checks each family in one pass; 42 ms rendering the scrape's own families, whose label each collector's four samples now share; and the run of each collector read back with a function call for each of its families, on both sides of the pipe.
- The rest is the containment above, the ledger, the progress file, and rendering each collector's samples, which every scrape must.

Through uhttpd, as Prometheus waits for it, a scrape of the same collectors on the same system:

| Scrape | 0.1.0 | 0.2.0 | Now |
| :--- | :--- | :--- | :--- |
| QEMU's 24Kc, the `-full` group (35, 36 collectors) | 0.87 s, 0.35 s besides them | 1.44 s, 0.87 s besides them | 1.16 s, 0.59 s besides them |
| devenv's procd container, every collector (44) | 67 ms, 15 ms besides them | 98 ms, 44 ms besides them | 82 ms, 28 ms besides them |

The benchmark measures that path too, so that it cannot grow unseen: its `handler:` cases start uhttpd with the service's handler, the collectors reading the benchmark's world, and time a scrape as wget gets it. What a typical full scrape takes besides its collectors is 0.41 of what they take in the devenv and 0.33 on QEMU, where 0.2.0 took 0.53 and 0.48; a budget holds it under 0.47.

Over HTTPS, a scrape that opens a connection of its own pays a TLS handshake too, whatever it asks for: 128 ms in the devenv's container with uclient-fetch, for a path that is not there as much as for a scrape, through the exporter's uhttpd or LuCI's. Prometheus keeps its connection open between scrapes (`http_keepalive`), and pays it once.

## Loading {#loading}

uhttpd loads the collectors when it starts, in the process every request is forked from, and holds them as long as it runs. A collector imports the collector API, which imports four modules of the core; ucode compiles a module once in a program, and keeps its source file open while the program lives. 0.2.0 compiled a program for each collector, so each had its own copy of those five modules, and six descriptors with its own: 37 collectors kept 268 open in the R3S's uhttpd, where a process may open 1024, which some 160 collectors would reach. The collectors are now compiled as one program, once each has loaded in a child process of its own (the probe, which still compiles each alone):

| Loading every collector | 0.2.0 | Now |
| :--- | :--- | :--- |
| devenv, the benchmark's 36 (`load:full`) | 34 ms; 216 descriptors, 6.1 MB | 12.5 ms; 41 descriptors, 3.9 MB |
| QEMU's 24Kc, the same | 0.93 s; 216 descriptors, 4.8 MB | 0.37 s; 41 descriptors, 3.1 MB |
| QEMU's 24Kc, probed first (`probe:full`), as uhttpd does | 1.78 s | 1.21 s |
| the service's uhttpd, devenv's procd container, 45 collectors | 315 descriptors, 7.3 MB | 95 descriptors, 4.5 MB |
| the service's uhttpd, QEMU, 36 collectors | 263 descriptors, 5.2 MB | 86 descriptors, 3.5 MB |

A request's process and the collectors' child are forked from that uhttpd, so they start smaller too. Should the collectors not load as one program, which the probe makes unlikely, each is loaded alone, as before.

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

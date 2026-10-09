# Performance on Small Routers

A scrape is a ucode program run on a router's CPU, and many routers have a slow one: a MIPS core of a few hundred MIPS, interpreting bytecode. This page is about what a scrape costs there, how that was measured, and where the cost still bites.

---

## The cost of the VM

Every operation of ucode's VM costs about a microsecond on a router: a loop's turn, a call of a builtin, a property read. A regex match costs several, and a regex literal is compiled each time it is evaluated. A scrape writes thousands of samples and reads tables of thousands of lines, so what matters is what is done per sample and per line.

That is why the code looks the way it does. Regexes are module constants, and kept out of what runs per line where `index()`, `split()` on a string or `substr()` do: on a 24Kc a match costs 20 to 60 µs, three to eight times a builtin's call. A sample's line is written once, when it is recorded, and labels several samples share are written once and passed around. nat_traffic takes a conntrack line apart with fixed-string splits, without a regex or a function call per line. `make bench` shows what a collector costs, and holds the budgets of `test/bench/budgets.uc`: a scaling budget, a memory budget, and generous times.

## What a scrape costs

The same scrape, the typical world (a home router with Wi-Fi: 12 links, 300 conntrack entries, 20 stations, 50 leases) with the base package and the `-full` group, on each machine, with the speed of ucode's VM on it (`calibrate:vm`'s loop turn) and of running a program:

| Machine | Typical full scrape | A loop turn | A program run |
| :--- | :--- | :--- | :--- |
| devenv (Ryzen 7 7840U) | 0.10 s | 0.23 µs | 0.9 ms |
| NanoPi R3S (4×A55, OpenWrt 25.12.5) | 0.55 s | 2.0 µs | 3.2 ms |
| YunCore AX835 (MT7981, 2×A53 at 1.3 GHz) | 0.72 s | 3.0 µs | 3.4 ms |
| QEMU malta, 24Kc at 500 MIPS (`QEMU_SHIFT=1`) | 2.6 s | 9.9 µs | 5.4 ms |
| QEMU malta, 24Kc at 250 MIPS (`QEMU_SHIFT=2`) | 5.3 s | 19.7 µs | |

A scrape runs in a process of its own, as uhttpd answers each request in a process forked from the one that loaded the exporter, so it starts with nothing a scrape before left. The benchmark does the same: each run is a process of its own, timed after loading, and its memory is how far its peak rose above what it held before the run.

## Calibration

A container limited to a share of one CPU stands in for a slower machine, when the share makes its loop turn match. On the laptop above, 0.35 of one CPU matched the R3S (2.0 µs, and 0.54 s for the scrape), 0.22 the AP (3.1 µs), and 0.07 the 500-MIPS 24Kc (10.7 µs), though not its scrape (3.4 s): a container's programs cost what the host's do under a quota, 30 ms a run there, while a router's cost what its own kernel makes them. The share depends on how loaded and how fast the host is, so it is picked in the same session as the run.

QEMU is the closer model of a MIPS router. It counts instructions (`-icount shift=N,sleep=on`, with the guest's clock on the same count), so its times are a deterministic function of the code and of N: shift 2 is exactly twice shift 1. A MIPS router's own speed is its clock times its instructions per cycle: an MT7621's 1004Kc at 880 MHz runs an interpreter at roughly 0.5 to 0.7 instructions a cycle, 450 to 600 MIPS, which is `QEMU_SHIFT=1`; a 24Kc at 600 to 750 MHz (QCA953x, QCA956x) at 300 to 450 MIPS, between shift 1 and shift 2. The A53 anchors the scale: a loop turn takes it 3.0 µs and the 1000-MIPS guest 4.9 µs, so it runs this code as a 1650-MIPS 24Kc would, three to four times an MT7621.

The MT7621's packages are little-endian (`mipsel_24kc`); the most common small routers, ath79's, are big-endian (`mips_24kc`). `QEMU_ENDIAN=be` runs malta's big-endian image instead. On 25.12.5, at shift 1, every case of the benchmark wrote the same samples and logs in both byte orders, and took within 2% of the same time, the big-endian guest the slower by about 1% (the fastest runs of `deadline:full@20000` too, whose median depends on where the deadline stops a run): the byte order changes nothing ucode's VM does with text. What the exporter reads in the CPU's byte order, the auxiliary vector that gives sockstat its page size and the exporter collector its clock tick, the guest checks against its own kernel before the bench, in both.

## Where it still bites: nat_traffic

nat_traffic reads the whole conntrack table, a line per connection, at every scrape. Its time grows with the table, linearly, as its scaling budget holds it to: 0.21 s for 20,000 entries in the devenv. A home router's table holds a few hundred entries; a busy one, or one under a flood of connections, tens of thousands.

The 500-MIPS 24Kc is about forty times slower than the devenv: 20,000 entries take it 8.2 s, most of Prometheus's default `scrape_timeout` of ten, and a busier table more. Prometheus drops a scrape that answers late whole, not only nat_traffic's part.

So a scrape has a deadline, the scraper's timeout less half a second, and runs the collectors fastest first: nat_traffic, slowest, comes last, and when the time left does not fit what it took before, it is left out, and the scrape answers with the rest. And a collector that takes longer than its budget, 5 seconds by default, is quarantined for a few scrapes.

On QEMU's 500-MIPS 24Kc (`make bench-qemu`), the full scrape of the benchmark's large world, whose conntrack table holds 20,000 connections, takes 17.8 s without a deadline, nat_traffic 8.9 s of it. With Prometheus's default timeout of 10 s (`deadline:full@20000`), once the first scrape has filled the ledger, it answers in 9.0 to 9.6 s, nat_traffic and dhcp_leases left out, with the exporter collector, which runs after every other, and the rest served: within the timeout, by little, as a collector still running at the deadline is stopped there. The first scrape after a restart, before the ledger knows how long nat_traffic takes, can still be late. See [About deadlines and circuit breakers](deadlines-and-breakers.md).

It is in the `-network` and `-full` groups. On such a router, leave it out, [disable it](../how-to/choose-collectors.md#disable-a-collector), or scrape it in a job of its own with a longer timeout and a `budget` to match; and watch `node_scrape_collector_duration_seconds{collector="nat_traffic"}`.

## A process per collector {#a-process-per-collector}

Each scrape runs its collectors in a child process, so that one that never returns, or ends its process, costs itself alone (see [About the architecture](architecture.md#a-process-of-its-own)). That has a price, which the benchmark measures as a scrape forked (`scrape:`) against the same scrape in one process (`inline:`):

| Scrape | devenv | QEMU's 500-MIPS 24Kc | YunCore AX835 |
| :--- | :--- | :--- | :--- |
| typical, base collectors (17) | 14.5 ms, 1.9 ms more | 359 ms, 44 ms more (+14%) | 131 ms, 9 ms more (+7%) |
| typical, every collector (37) | 114 ms, about as long | 2.51 s, 129 ms more (+5%) | 940 ms, 11 ms more (+1%) |
| large, base collectors | 34.7 ms, 1.8 ms more | | |

On the 24Kc, that is some 2.5 to 3.5 ms a collector, where it was 3 to 5 before 0.3.0: a fork, a line and a run in the file the child writes and the scrape reads, and the pages the child copies from the scrape's as it writes them (copy-on-write). The progress file costs a scrape 3.7 ms there, a tenth of a percent.

So a scrape on a slow router costs a tenth to a fifth more than it would if its collectors could not stop it. That is the trade: a collector that loops, waits on a FIFO or runs out of memory then costs its own budget and nothing more, where it would hold every later scrape, or end the request with nothing answered.

## What a sample and a collector cost {#samples-and-collectors}

What a scrape does for each sample and each collector, the benchmark measures apart: `record:` cases record 20,000 samples of one shape and write their text, `noop:` cases scrape 1 and 41 collectors that write nothing, each in the child process, and the difference is what a scrape costs a collector besides it. Budgets hold them: a sample of labels to a multiple of one of a `labels()` set, on any machine, and a collector to 0.5 ms in the devenv.

| | devenv, before | devenv, now | QEMU's 24Kc, before | QEMU's 24Kc, now |
| :--- | :--- | :--- | :--- | :--- |
| a sample, two labels of an object (`record:labels`) | 7.6 µs | 5.2 µs | 318 µs | 235 µs |
| the same, a double value (`record:double`) | 9.7 µs | 7.1 µs | 399 µs | 296 µs |
| a sample of a `labels()` set (`record:made`) | 2.1 µs | 2.2 µs | 92 µs | 96 µs |
| a family of a sample (`record:family`) | 14.4 µs | 14.3 µs | 521 µs | 504 µs |
| a collector besides it (`noop:`) | 0.140 ms | 0.133 ms | 4.98 ms | 4.34 ms |
| nat_traffic, 20,000 connections | 247 ms | 209 ms | 9.71 s | 8.16 s |
| netstat | 6.8 ms | 2.4 ms | 135 ms | 84 ms |
| cpu (46 samples) | 1.0 ms | 0.9 ms | 28.2 ms | 23.2 ms |
| meminfo (37 families) | 1.2 ms | 1.2 ms | 27.1 ms | 24.9 ms |

A collector's own times are its `collector:` cases, which read its settings too, as a scrape does not.

What changed:

- **A sample's labels.** Each must be an object, checked as it is written: its names valid, none two once sanitized, its values valid UTF-8, escaped where they need it. The recorder keeps each name's text, `",name="`, as it first writes it, and writes a sample whose names it has all kept and whose values are strings a lookup and a concatenation a label, with one match of the values together for what must be escaped or read as UTF-8; any other is written as before, by a call that checks every label. A double that reads back as ucode's 14 digits is written so before the checks for NaN and the infinities. nat_traffic and cpu make one object for every sample's labels, which the recorder keeps nothing of.
- **A closure's place in its program.** ucode makes a closure in a step for each function its program compiled before the closure's own: a closure of a module compiled after the exporter's others cost a scrape 1.4 µs in the devenv where one compiled first costs 0.3. The recorder makes fifteen for each collector and one for each family, so its module is the handler's program's first (`app.uc`), and a test holds it there. A recorder takes 5 µs to make in the devenv, where it took 14.
- **A collector's settings.** Most collectors have no section in the config, and a scrape gives such a collector its defaults straight away, without the specs a section's values are checked against: 5 µs where it took 13, in the devenv.
- **netstat's fields.** A scrape checks each of the kernel's 400 or so fields against the `fields` option, and musl takes as long to match one against node_exporter's default pattern as forty lookups. The default is checked with lookups instead, which tests hold to the pattern; any other is matched.

What is left is mostly the VM's own work. A sample of labels is a loop over its object, a lookup, a type check and two concatenations a label, and one match: nat_traffic's 20,000 connections take 0.2 s in the devenv, where prebuilt label strings, which no longer reach the recorder, took 0.18. A family is its name and its HELP text checked, its writer made, and its header written: meminfo writes a family a sample, half a millisecond each on the 24Kc. A double is written by C's `%g` and read back by `strtod()`, which the 24Kc does in software: 70 µs. What a scrape costs a collector besides it is mostly the VM's work too, 250 to 300 turns of its loop on any machine (see [In 0.3.0](#in-030)).

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

The benchmark measures that path too, so that it cannot grow unseen: its `handler:` cases start uhttpd with the service's handler, the collectors reading the benchmark's world, and time a scrape as wget gets it. By the base collectors, light ones, a typical scrape takes about as long again besides them in the devenv, 0.8 to 1.05 of what they take, where 0.2.0 took 1.6, and a budget holds it under 1.3; by every collector, it takes 0.41 to 0.48 of what they take in the devenv and 0.33 on QEMU, where 0.2.0 took 0.53 and 0.48, and a budget holds it under 0.6. A unit test holds a scrape to reading the main section as often for many collectors as for one.

Over HTTPS, a scrape that opens a connection of its own pays a TLS handshake too, whatever it asks for: 128 ms in the devenv's container with uclient-fetch, for a path that is not there as much as for a scrape, through the exporter's uhttpd or LuCI's. Prometheus keeps its connection open between scrapes (`http_keepalive`), and pays it once.

## In 0.3.0 {#in-030}

Traced step by step through uhttpd again, on the base collectors and those of an access point, what a scrape spent besides its collectors was mostly done for each collector, and the pages a process writes after a fork, which the kernel copies first. Each collector was three messages and two wakeups of the scrape: the child asked for it, the scrape worked out its settings and limit and answered, and read its run back once it was done. The child now goes through the plan itself, forked with it, and the scrape only holds the clock:

- **The child goes through the plan.** It leaves out what the deadline, a breaker or the reply's sample limit keeps out as the scrape did, and writes, in one write a collector, the line that it starts, with its limit, and the run before it, to a file the scrape reads through a descriptor of its own, at its timer's turns, while the child goes on. The pipe tells the scrape only of a collector whose limit is near, or one after a few runs worth taking while the child goes on, and of the child's end. A child stopped or dead leaves its runs, and a new one goes on after them.
- **A run's families are their names, checked all at once.** Who owns each family was a loop over every family of every run, with a lookup and two prefix checks each; it is now one `uniq()` of all the names and one `index()` of each run's, and a family at a time only when two runs write one, or one of the core's.
- **The scrape's own four samples of each collector** are written as text, without a recorder: a fifth of what a collector that writes nothing cost.
- **Once a scrape, not once a collector**: the config's collector sections are walked once for which are switched off, the ledger is parsed once and recorded with one copy of each entry, its order is a sort of text rather than a call of ours for each pair, and the exporter collector's counters record only the runs that count. A regex that ucode compiled at each call is a constant.

Besides its collectors, a scrape (`scrape:`) and a scrape through uhttpd (`handler:`), on the same machines, before (main of 2026-10-08, the collectors of 0.3.0) and now:

| | devenv | QEMU's 500-MIPS 24Kc | YunCore AX835 |
| :--- | :--- | :--- | :--- |
| through uhttpd, base collectors (`handler:base`) | 9.7 → 7.7 ms | 161 → 118 ms | |
| through uhttpd, every collector (`handler:full`) | 28.9 → 18.5 ms | 518 → 378 ms | |
| a scrape of the base collectors (`scrape:base`) | 7.4 → 3.9 ms | 130 → 96 ms | 49 → 32 ms |
| a scrape of every collector (`scrape:full`) | 22.1 → 12.4 ms | 457 → 312 ms | 171 → 104 ms |
| a collector besides it (`noop:`) | 0.152 → 0.081 ms | 4.38 → 3.52 ms | 1.50 → 0.89 ms |
| the ledger (`ledger:full`) | 1.0 → 0.8 ms | 26.4 → 21.0 ms | 9.9 → 8.2 ms |
| a family of a sample (`record:family`) | 16.4 → 14.4 µs | 506 → 488 µs | 181 → 172 µs |

A sample costs what it did, 5.6 µs for two labels of an object in the devenv, and a family six of a `labels()` set's samples: its name and its HELP text checked, an object, a closure and two arrays, and its header. A collector that writes nothing is 250 to 300 turns of the VM's loop on any machine (0.081 ms of 0.29 µs in the devenv, 0.89 ms of 3.5 µs on the A53): its settings and its limit, its recorder, its start and its run packed in the child and read back here, and its four samples. The rest of what a scrape spends besides its collectors is rendering their families, which every exporter must, and the pages the request's process and the child copy as they write them; and the less a process holds, the fewer it copies.

uhttpd holds less too, which the benchmark's `rest:` cases measure: what the process holds of its own (RssAnon) once it has compiled the handler's program and loaded a set's collectors, as the service's handler does, more than before. musl compiles a regex's count, as `[./0-9A-Za-z]{86}`, into a copy of what it counts for each, and the three hash formats of basic auth held 350 kB of it: they are checked by their lengths now. The loader, its jail's rules and its import scanner served no scrape: each module is checked in the probe's child, and the loader compiled there alone. And of the native modules a collector may need, rtnl, nl80211 and socket are loaded when a loaded collector needs them.

| What uhttpd holds at rest | before | now |
| :--- | :--- | :--- |
| devenv, base collectors (`rest:base`) | 2.06 MB | 1.48 MB |
| devenv, every collector (`rest:full`) | 2.62 MB | 2.08 MB |
| YunCore AX835, base collectors | 2.01 MB | 1.48 MB |
| QEMU's 24Kc (32-bit), base collectors | | 1.08 MB |
| the service's uhttpd with an access point's 19 collectors, devenv (RssAnon) | 2.46 MB | 1.88 MB |

What is left is code: ucode keeps about a kilobyte for each function a program compiled and each object it made, so the handler's program, some 350 functions, holds about 0.95 MB, the native modules 0.35 MB, and the collectors 20 kB each besides the 100 kB of the collector API they share.

## The collectors, in 0.3.0 {#collectors-in-030}

On the YunCore AX835, an access point of 20 collectors and 838 samples, a scrape took 0.193 s, its collectors 137 ms of it, where the Lua exporter's took 0.083 s; netclass, netstat, netdev, wifi and the exporter collector were 100 ms of the 137. What each cost was rarely its source. A turn of the VM's loop and a builtin's call cost a microsecond or so there, and these collectors did a few of each for every field or file the kernel has, whether they wrote it or not:

- **netstat** checked each of the kernel's 400 or so fields against node_exporter's default pattern, a turn and several calls each, to write 42 of them, and split each of `/proc/net/snmp6`'s 90 lines with a regex. It now looks for the fields the default takes in each section's names, an index() of each it names whole and one match of the names for the rest, which skips MPTcpExt's 70 at once; it splits a line of snmp6 on its tab, and leaves one the default does not take unread. Property tests hold both to the pattern and to proc.fields() with the protocols' regex.
- **netclass** read 14 sysfs files a link, and a file of a router's sysfs costs as much as all else it does for the link. It reads 9 to 11: flags once, not twice; the alias from the link dump, which has it; carrier_changes as the sum of the up and down counts, which is what sysfs writes of it; iflink as the ifindex where the dump has no other link; and duplex only where speed could be read. The fixtures' sysfs holds each to what reading it gives.
- **The exporter collector** read the auxiliary vector a byte at a time, a turn of a loop a byte, for the clock tick, and found `/proc/stat`'s btime with a regex that read its 2 kB of interrupt counts: it reads a word with one expression, and finds the line with an index(). vmstat checked each of 170 fields with two regexes, its default now with a call or two. netdev made an array for each statistic of each link.
- **A family of one sample** cost a writer made and called, a call of sanitize() and a match of its HELP: meminfo, netstat and vmstat write dozens. `out.batch()` records them without a writer each, with one match of every HELP, and a name valid as it is is taken after one match; a property test holds a batch to what a writer for each row records.

Each collector on the benchmark's large world (50 links, 3 radios of 3 networks and 200 stations), before (main of 2026-10-09) and now; the Cortex-A53's include the 3.5 ms its case costs a collector that writes one sample:

| Collector | devenv | QEMU's 500-MIPS 24Kc | YunCore AX835 |
| :--- | :--- | :--- | :--- |
| netstat | 2.4 → 1.3 ms | 82 → 43 ms | 29.3 → 15.2 ms |
| netclass | 12.0 → 10.0 ms | 274 → 237 ms | 108.9 → 90.4 ms |
| netdev | 3.9 → 3.2 ms | 152 → 128 ms | 50.9 → 42.5 ms |
| wifi | 10.2 → 9.4 ms | 362 → 354 ms | 126 → 124 ms |
| the exporter collector | 1.05 → 0.77 ms | 19.6 → 14.2 ms | 9.3 → 6.6 ms |
| meminfo | 0.97 → 0.79 ms | 25.0 → 22.5 ms | 9.8 → 8.7 ms |
| vmstat | 0.93 → 0.58 ms | 15.0 → 13.8 ms | 7.7 → 5.4 ms |
| a family of a sample (`record:family`) | 14.1 → 12.4 µs | 488 → 460 µs | 172 → 158 µs |
| a scrape of the base collectors, typical (`scrape:base`) | 14.4 → 12.8 ms | 355 → 337 ms | 131 → 124 ms |

The access point's own scrape, its 12 links and a few stations, takes these collectors' share of what it took less: netstat about 12 ms where it took 26.6, against the Lua exporter's 10.6; netclass and netdev together about 40 ms where they took 48, against Lua's 29.4; the exporter collector about 7 ms where it took 10.8. That is some 30 ms of the 193, a scrape of about 0.165 s. What is left is mostly what a sample and a family cost every collector, the VM's own work, and wifi's ubus call and nl80211's replies, which no change here touched.

## Loading {#loading}

uhttpd loads the collectors when it starts, in the process every request is forked from, and holds them as long as it runs. A collector imports the collector API, which imports four modules of the core; ucode compiles a module once in a program, and keeps its source file open while the program lives. 0.2.0 compiled a program for each collector, so each had its own copy of those five modules, and six descriptors with its own: 37 collectors kept 268 open in the R3S's uhttpd, where a process may open 1024, which some 160 collectors would reach. The collectors are now compiled as one program, once each has loaded in a child process of its own (the probe, which still compiles each alone):

| Loading every collector | 0.2.0 | Now |
| :--- | :--- | :--- |
| devenv, the benchmark's 36 (`load:full`) | 34 ms; 216 descriptors, 6.1 MB | 12.5 ms; 41 descriptors, 3.9 MB |
| QEMU's 24Kc, the same | 0.93 s; 216 descriptors, 4.8 MB | 0.37 s; 41 descriptors, 3.1 MB |
| QEMU's 24Kc, probed first (`probe:full`), as uhttpd does | 1.78 s | 1.21 s |
| the service's uhttpd, devenv's procd container, 45 collectors | 315 descriptors, 7.3 MB | 95 descriptors, 4.5 MB |
| the service's uhttpd, QEMU, 36 collectors | 263 descriptors, 5.2 MB | 86 descriptors, 3.5 MB |

A request's process and the collectors' child are forked from that uhttpd, so they start smaller too. Should the collectors not load as one program, which the probe makes unlikely, each is loaded alone, as before. What uhttpd holds once they are loaded is in [In 0.3.0](#in-030).

## The ledger

Ordering the collectors and keeping their breakers costs a scrape a read of a small file when it starts, and a locked read and write when it ends (`make bench`'s `ledger:full`, 37 collectors, a ledger of 1.6 kB): 0.8 ms in the devenv and 21 ms on the 500-MIPS 24Kc, about 1% of a typical full scrape on both.

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

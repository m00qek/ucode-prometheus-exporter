# Performance on Small Routers

A scrape is a ucode program, and it runs on the router's CPU. Many routers have a slow one: a MIPS core of a few hundred MIPS, interpreting bytecode. This page covers what a scrape costs there, how that was measured, and where the cost still bites.

---

## The cost of the VM

On a router, every operation of ucode's VM costs about a microsecond: a turn of a loop, a call of a builtin, a property read. A regex match costs several, and a regex literal is compiled again each time it is evaluated. A scrape writes thousands of samples and reads tables of thousands of lines, so what counts is the work done per sample and per line.

That is why the code looks the way it does:

- Regexes are module constants.
- Code that runs per line uses `index()`, `split()` on a string or `substr()` where they do the job, not a regex. On a 24Kc a match costs 20 to 60 µs, three to eight times a builtin's call.
- A sample's line is written once, when it is recorded. Labels that several samples share are written once and passed around.
- nat_traffic takes a conntrack line apart with fixed-string splits, with no regex and no function call per line.

`make bench` shows what a collector costs. It also enforces the budgets of `test/bench/budgets.uc`: a scaling budget, a memory budget, and generous times.

## What a scrape costs

The table shows the same scrape on each machine: the benchmark's typical world (a stand-in for a home router with Wi-Fi: 12 links, 300 conntrack entries, 20 stations, 50 leases), with the base package and the `-full` group. Beside it are the speed of ucode's VM on that machine (a loop turn, from `calibrate:vm`) and the cost of running a program. The devenv is the development container, here on a laptop.

| Machine | Typical full scrape | A loop turn | A program run |
| :--- | :--- | :--- | :--- |
| devenv (Ryzen 7 7840U) | 0.10 s | 0.23 µs | 0.9 ms |
| NanoPi R3S (4×A55, OpenWrt 25.12.5) | 0.55 s | 2.0 µs | 3.2 ms |
| YunCore AX835 (MT7981, 2×A53 at 1.3 GHz) | 0.72 s | 3.0 µs | 3.4 ms |
| QEMU malta, 24Kc at 500 MIPS (`QEMU_SHIFT=1`) | 2.6 s | 9.9 µs | 5.4 ms |
| QEMU malta, 24Kc at 250 MIPS (`QEMU_SHIFT=2`) | 5.3 s | 19.7 µs | |

Each scrape runs in a process of its own, because uhttpd answers each request in a process forked from the one that loaded the exporter. So a scrape starts with nothing left over from the scrape before. The benchmark does the same. Each run is a process of its own, timed after loading, and its memory is how far its peak rose above what it held before the run.

## Calibration

A container limited to a share of one CPU can stand in for a slower machine, when the share makes its loop turn match. On the laptop above:

- 0.35 of one CPU matched the R3S: 2.0 µs a turn, and 0.54 s for the scrape.
- 0.22 matched the AP, the YunCore AX835 access point (3.1 µs).
- 0.07 matched the 500-MIPS 24Kc's loop turn (10.7 µs), but not its scrape (3.4 s). Under a quota, a container's programs cost what the host's do, 30 ms a run there, while a router's cost what its own kernel makes them.

The right share depends on how loaded and how fast the host is, so it is picked in the same session as the run.

QEMU is the closer model of a MIPS router. It counts instructions (`-icount shift=N,sleep=on`, with the guest's clock on the same count), so its times are a deterministic function of the code and of N: shift 2 is exactly twice shift 1.

A MIPS router's own speed is its clock times its instructions per cycle:

- An MT7621's 1004Kc at 880 MHz runs an interpreter at roughly 0.5 to 0.7 instructions a cycle: 450 to 600 MIPS, which is `QEMU_SHIFT=1`.
- A 24Kc at 600 to 750 MHz (QCA953x, QCA956x) runs at 300 to 450 MIPS, between shift 1 and shift 2.

The A53 anchors the scale. A loop turn takes it 3.0 µs, and takes the 1000-MIPS guest 4.9 µs. So the A53 runs this code as a 1650-MIPS 24Kc would: three to four times as fast as an MT7621.

The MT7621's packages are little-endian (`mipsel_24kc`). The most common small routers, ath79's, are big-endian (`mips_24kc`), and `QEMU_ENDIAN=be` runs malta's big-endian image instead. On 25.12.5 at shift 1, every case of the benchmark wrote the same samples and logs in both byte orders, and took within 2% of the same time, the big-endian guest slower by about 1%. That holds for the fastest runs of `deadline:full@20000` too, whose median depends on where the deadline stops a run. The byte order changes nothing ucode's VM does with text. The exporter reads one thing in the CPU's byte order: the auxiliary vector, which gives sockstat its page size and the exporter collector its clock tick. Before the bench, the guest checks those against its own kernel, in both byte orders.

## Where it still bites: nat_traffic

nat_traffic reads the whole conntrack table, a line per connection, at every scrape. Its time grows linearly with the table, and its scaling budget holds it to that: 0.21 s for 20,000 entries in the devenv. A home router's table holds a few hundred entries. A busy one, or one under a flood of connections, holds tens of thousands.

The 500-MIPS 24Kc is about forty times slower than the devenv. 20,000 entries take it 8.2 s, most of Prometheus's default `scrape_timeout` of ten, and a busier table takes more. When a scrape answers late, Prometheus drops all of it, not only nat_traffic's part.

So a scrape has a deadline: the scraper's timeout less half a second. The scrape runs the collectors fastest first, so nat_traffic, the slowest, comes last. When the time left does not fit what nat_traffic took before, the scrape leaves it out and answers with the rest. And a collector that takes longer than its budget, 5 seconds by default, is quarantined for a few scrapes.

The benchmark's large world has a conntrack table of 20,000 connections. On QEMU's 500-MIPS 24Kc (`make bench-qemu`), its full scrape takes 17.8 s without a deadline, 8.9 s of it nat_traffic's. With Prometheus's default timeout of 10 s (`deadline:full@20000`), the scrape answers in 9.0 to 9.6 s once the first scrape has filled the ledger (the file where the exporter keeps how long each collector took). nat_traffic and dhcp_leases are left out, and the rest is served. That is within the timeout, by little, because a collector still running at the deadline is stopped there. The first scrape after a restart can still be late, since the ledger does not yet know how long nat_traffic takes. See [About deadlines and circuit breakers](deadlines-and-breakers.md).

Each scrape also reads the routes, of every table, to know which end of a connection is on this side of the router. It then looks up each address it has not seen yet among the routes' prefixes. It used to compare the address with each prefix in turn, a function call each, and a router's 60 or so routes made that some 50 ms of the R3S's scrape. It now keeps a set of the prefixes of each length, and looks the address up in each set: a few lookups.

The benchmark's world has routes shaped like such a router's, and one connection in eight comes from the internet. On it:

- 1,000 connections take 10.6 ms in the devenv, where they took 32.1, and 130 ms on the AX835, where they took 217.
- 20,000 take 175 ms in the devenv, where they took 375.

The world's routes are shaped after the R3S's 72. On the R3S itself, nat_traffic took 60.8 ms with the old lookup, where it had taken 6.9 before it read the routes at all. In the devenv, the new lookup of an address costs a ninth of the old one for those routes (3.8 µs against 33). That would leave some 6 ms of the 54 the routes added on the R3S.

nat_traffic is in the `-network` and `-full` groups. On a slow router with a busy table, leave it out, [disable it](../how-to/choose-collectors.md#disable-a-collector), or scrape it in a job of its own with a longer timeout and a `budget` to match. Watch `node_scrape_collector_duration_seconds{collector="nat_traffic"}`.

## A process per collector {#a-process-per-collector}

Each scrape runs its collectors in a child process, so that a collector that never returns, or ends its process, costs only itself (see [About the architecture](architecture.md#a-process-of-its-own)). That has a price. The benchmark measures it by comparing a forked scrape (`scrape:`) with the same scrape in one process (`inline:`):

| Scrape | devenv | QEMU's 500-MIPS 24Kc | YunCore AX835 |
| :--- | :--- | :--- | :--- |
| typical, base collectors (17) | 14.5 ms, 1.9 ms more | 359 ms, 44 ms more (+14%) | 131 ms, 9 ms more (+7%) |
| typical, every collector (37) | 114 ms, about as long | 2.51 s, 129 ms more (+5%) | 940 ms, 11 ms more (+1%) |
| large, base collectors | 34.7 ms, 1.8 ms more | | |

On the 24Kc, that is some 2.5 to 3.5 ms a collector, where it was 3 to 5 before 0.3.0. The price is:

- a fork;
- a line and a run in the file the child writes and the scrape reads;
- the pages the child copies from the scrape's as it writes to them (copy-on-write).

The progress file costs a scrape 3.7 ms there, a tenth of a percent.

So on a slow router a scrape costs a tenth to a fifth more than it would if its collectors could not stop it. That is the trade. In exchange, a collector that loops, waits on a FIFO or runs out of memory costs its own budget and nothing more. Without the child, it would hold every later scrape, or end the request with nothing answered.

## What a sample and a collector cost {#samples-and-collectors}

The benchmark measures apart what a scrape does for each sample and for each collector:

- `record:` cases record 20,000 samples of one shape and write their text.
- `noop:` cases scrape 1 and 41 collectors that write nothing, each in the child process. The difference is what a scrape costs per collector beyond the collector's own work: the table calls it "a collector besides it".

Budgets hold both. A sample with labels is held to a multiple of a sample of a `labels()` set, on any machine, and a collector to 0.5 ms in the devenv.

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

A collector's own times are its `collector:` cases. Those also read the collector's settings, which a scrape does not.

What changed:

- **A sample's labels.** The labels must be an object, and the recorder checks each label as it writes it: its name valid, no two names the same once sanitized, its value valid UTF-8 and escaped where needed. The recorder now keeps each name's text, `",name="`, from the first time it writes it. A sample whose names it has all kept, and whose values are strings, costs a lookup and a concatenation per label, plus one match over all the values together to find what must be escaped or read as UTF-8. Any other sample is written as before, by a call that checks every label. A double that reads back as ucode's 14 digits is written that way before the checks for NaN and the infinities. nat_traffic and cpu make one object for each sample's labels, and the recorder keeps nothing of those objects.
- **A closure's place in its program.** To make a closure, ucode takes one step for each function its program compiled before the closure's own. A closure of a module compiled after the exporter's other modules cost a scrape 1.4 µs in the devenv; one compiled first costs 0.3. The recorder makes fifteen closures for each collector and one for each family, so its module is the first of the handler's program (`app.uc`), and a test keeps it there. A recorder takes 5 µs to make in the devenv, where it took 14.
- **A collector's settings.** Most collectors have no section in the config. A scrape now gives such a collector its defaults straight away, without the specs a section's values are checked against: 5 µs where it took 13, in the devenv.
- **netstat's fields.** A scrape checks each of the kernel's 400 or so fields against the `fields` option. musl takes as long to match one field against node_exporter's default pattern as forty lookups. So the default is now checked with lookups, which tests hold to the pattern. Any other pattern is matched as before.

What is left is mostly the VM's own work:

- A sample with labels is a loop over its object (a lookup, a type check and two concatenations per label) and one match. nat_traffic's 20,000 connections take 0.2 s in the devenv. Prebuilt label strings, which no longer reach the recorder, took 0.18.
- A family is its name and HELP text checked, its writer made, and its header written. meminfo writes one family per sample, half a millisecond each on the 24Kc.
- A double is written by C's `%g` and read back by `strtod()`, which the 24Kc does in software: 70 µs.
- What a scrape costs per collector, beyond the collector's own work, is mostly the VM's work too: 250 to 300 turns of its loop on any machine (see [In 0.3.0](#in-030)).

## Besides the collectors {#besides-the-collectors}

A scrape does more than run its collectors. uhttpd forks the request's process. The scrape then reads the config and the ledger, hands each collector to the child and reads its run back, decides which collector owns each family and renders it, and writes the ledger and the progress file. In 0.2.0 that cost far more than it had to. On the NanoPi R3S, a scrape of 37 collectors took 0.79 to 0.89 s through uhttpd, while its collectors' durations added up to 0.47 s, which was 0.1.0's whole scrape.

The time went to work, not to waiting. A scrape was traced step by step through uhttpd under procd, in a container and on QEMU's 24Kc, and no step waits on a timer. The scrape hands a collector to its child and reads its run back over a pipe, and uloop wakes it for that. Its timer looks every 100 ms, and fires only while a collector runs that long: to stop the collector at its limit, or to see that its child died. The time went to the scrape's own work, much of it done for each collector or each family when it needed doing once. On QEMU, a scrape of the guest's own system by the 36 collectors of the `-full` group spent 0.87 s outside its collectors:

- 248 ms on the collectors' settings. Each collector read the config's main section two or three times over, and each value of a `range()` option built its datatype anew, including the English text that describes what it accepts. A scrape now reads the main section once for all its collectors, and builds a range once.
- 81 ms deciding which collector owns each family, which now checks each family in one pass. 42 ms rendering the scrape's own families, where the four samples of each collector now share one label. And each collector's run was read back with a function call per family, on both sides of the pipe.
- The rest is the containment above, the ledger, the progress file, and rendering each collector's samples, which every scrape must do.

The same collectors on the same system, scraped through uhttpd as Prometheus waits for it:

| Scrape | 0.1.0 | 0.2.0 | Now |
| :--- | :--- | :--- | :--- |
| QEMU's 24Kc, the `-full` group (35, 36 collectors) | 0.87 s, 0.35 s besides them | 1.44 s, 0.87 s besides them | 1.16 s, 0.59 s besides them |
| devenv's procd container, every collector (44) | 67 ms, 15 ms besides them | 98 ms, 44 ms besides them | 82 ms, 28 ms besides them |

The benchmark measures that path too, so that it cannot grow unseen. Its `handler:` cases start uhttpd with the service's handler, with the collectors reading the benchmark's world, and time a scrape as wget gets it:

- With the base collectors, which are light, a typical scrape spends about as long again outside them in the devenv: 0.8 to 1.05 of what they take, where 0.2.0 spent 1.6. A budget holds it under 1.3.
- With every collector, it spends 0.41 to 0.48 of what they take in the devenv, and 0.33 on QEMU, where 0.2.0 spent 0.53 and 0.48. A budget holds it under 0.6.

A unit test holds a scrape to reading the main section as often for many collectors as for one.

Over HTTPS, a scraper that opens a new connection also pays a TLS handshake, whatever it asks for: 128 ms in the devenv's container with uclient-fetch. A path that does not exist pays it as much as a scrape does, through the exporter's uhttpd or LuCI's. Prometheus keeps its connection open between scrapes (`http_keepalive`), so it pays the handshake once.

## In 0.3.0 {#in-030}

For 0.3.0, a scrape was traced step by step through uhttpd again, with the base collectors and with an access point's. What it spent outside its collectors was mostly work done per collector, plus the pages a process writes after a fork, which the kernel must copy first. Each collector cost three messages and two wakeups of the scrape: the child asked for the collector; the scrape worked out its settings and limit and answered; and the scrape read its run back once it was done. Now the child goes through the plan itself, forked with it, and the scrape only holds the clock:

- **The child goes through the plan.** It leaves out what the deadline, a breaker or the reply's sample limit keeps out, as the scrape did. For each collector it makes one write to a file: the previous collector's run, then a line saying this one starts, with its limit. The scrape reads that file through a descriptor of its own, at its timer's turns, while the child goes on. The pipe now tells the scrape only of a collector whose limit is near, of a few runs worth taking while the child goes on, and of the child's end. A child that is stopped or dies leaves its runs behind, and a new one goes on after them.
- **A run's families are their names, checked all at once.** Deciding who owns each family was a loop over every family of every run, with a lookup and two prefix checks each. It is now one `uniq()` of all the names and one `index()` of each run's. The scrape looks at one family at a time only when two runs write the same family, or a run writes one of the core's.
- **The scrape's own four samples of each collector** are written as text, without a recorder. That costs a fifth of what a collector that writes nothing cost.
- **Once a scrape, not once a collector.** The config's collector sections are walked once to find which are switched off. The ledger is parsed once, and recorded with one copy of each entry. Its order is a sort of text, rather than a call of ours for each pair. The exporter collector's counters record only the runs that count. And a regex that ucode compiled at each call is now a constant.

Outside its collectors, a scrape (`scrape:`) and a scrape through uhttpd (`handler:`) on the same machines, before (main of 2026-10-08, with the collectors of 0.3.0) and now:

| | devenv | QEMU's 500-MIPS 24Kc | YunCore AX835 |
| :--- | :--- | :--- | :--- |
| through uhttpd, base collectors (`handler:base`) | 9.7 → 7.7 ms | 161 → 118 ms | |
| through uhttpd, every collector (`handler:full`) | 28.9 → 18.5 ms | 518 → 378 ms | |
| a scrape of the base collectors (`scrape:base`) | 7.4 → 3.9 ms | 130 → 96 ms | 49 → 32 ms |
| a scrape of every collector (`scrape:full`) | 22.1 → 12.4 ms | 457 → 312 ms | 171 → 104 ms |
| a collector besides it (`noop:`) | 0.152 → 0.081 ms | 4.38 → 3.52 ms | 1.50 → 0.89 ms |
| the ledger (`ledger:full`) | 1.0 → 0.8 ms | 26.4 → 21.0 ms | 9.9 → 8.2 ms |
| a family of a sample (`record:family`) | 16.4 → 14.4 µs | 506 → 488 µs | 181 → 172 µs |

A sample costs what it did: 5.6 µs for two labels of an object in the devenv. A family costs as much as six samples of a `labels()` set: its name and HELP text checked, an object, a closure and two arrays, and its header. A collector that writes nothing costs 250 to 300 turns of the VM's loop on any machine (0.081 ms at 0.29 µs a turn in the devenv, 0.89 ms at 3.5 µs on the A53). That pays for its settings and its limit, its recorder, its start and its run packed in the child and read back by the scrape, and its four samples. The rest of what a scrape spends outside its collectors is:

- rendering their families, which every exporter must do;
- the pages the request's process and the child copy as they write to them. The less a process holds, the fewer pages it copies.

uhttpd holds less too. The benchmark's `rest:` cases measure what the process holds of its own (RssAnon) once it has compiled the handler's program and loaded a set's collectors, as the service's handler does, beyond what it held before:

- musl compiles a regex's count, such as `[./0-9A-Za-z]{86}`, into a copy of what it counts for each repetition. The three hash formats of basic auth held 350 kB of that. They are now checked by their lengths.
- The loader, its jail's rules and its import scanner served no scrape. Each module is now checked in the probe's child (the process that checks each collector before uhttpd loads it), and the loader is compiled there alone.
- Of the native modules a collector may need, rtnl, nl80211 and socket are loaded only when a loaded collector needs them.

| What uhttpd holds at rest | before | now |
| :--- | :--- | :--- |
| devenv, base collectors (`rest:base`) | 2.06 MB | 1.48 MB |
| devenv, every collector (`rest:full`) | 2.62 MB | 2.08 MB |
| YunCore AX835, base collectors | 2.01 MB | 1.48 MB |
| QEMU's 24Kc (32-bit), base collectors | | 1.08 MB |
| the service's uhttpd with an access point's 19 collectors, devenv (RssAnon) | 2.46 MB | 1.88 MB |

What is left is code. ucode keeps about a kilobyte for each function a program compiled and each object it made. So the handler's program, some 350 functions, holds about 0.95 MB, the native modules 0.35 MB, and the collectors 20 kB each, plus the 100 kB of the collector API they share. What uhttpd holds since then, and what is left of it, is in [What uhttpd holds at rest](#at-rest).

## The collectors, in 0.3.0 {#collectors-in-030}

On the YunCore AX835, an access point with 20 collectors and 838 samples, a scrape took 0.193 s, 137 ms of it in its collectors. The Lua exporter's took 0.083 s. netclass, netstat, netdev, wifi and the exporter collector were 100 ms of the 137. What each cost was rarely its source. A turn of the VM's loop and a builtin's call cost a microsecond or so there, and these collectors did a few of each for every field or file the kernel has, whether they wrote it or not:

- **netstat** checked each of the kernel's 400 or so fields against node_exporter's default pattern, a turn and several calls each, to write 42 of them. It also split each of `/proc/net/snmp6`'s 90 lines with a regex. It now looks for the default's fields in each section's names: an index() for each field the default names whole, and one match of the names for the rest, which skips MPTcpExt's 70 at once. It splits a line of snmp6 on its tab, and leaves unread a line the default does not take. Property tests hold both to the pattern, and to proc.fields() with the protocols' regex.
- **netclass** read 14 sysfs files a link, and on a router reading one sysfs file costs as much as all the rest the collector does for the link. It now reads 9 to 11, and the fixtures' sysfs holds each to what reading it gives:
    - flags once, not twice;
    - the alias from the link dump, which has it;
    - carrier_changes as the sum of the up and down counts, which is what sysfs writes for it;
    - iflink as the ifindex where the dump has no other link;
    - duplex only where speed could be read.
- **The exporter collector** read the auxiliary vector one byte at a time, a loop turn per byte, to find the clock tick. It found `/proc/stat`'s btime with a regex that read the file's 2 kB of interrupt counts. It now reads a word with one expression, and finds the line with an index(). vmstat checked each of 170 fields with two regexes; its default now takes a call or two. netdev made an array for each statistic of each link.
- **A family of one sample** cost a writer made and called, a call of sanitize() and a match of its HELP, and meminfo, netstat and vmstat write dozens. `out.batch()` records them without a writer each, with one match over every HELP, and takes a name that is valid as it is after one match. A property test holds a batch to what a writer for each row records.

Each collector on the benchmark's large world (50 links, 3 radios of 3 networks and 200 stations), before (main of 2026-10-09) and now. The Cortex-A53's times include the 3.5 ms its case costs a collector that writes one sample:

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

On the access point's own scrape, with its 12 links and a few stations, these collectors now take less:

- netstat about 12 ms, where it took 26.6, against the Lua exporter's 10.6;
- netclass and netdev together about 40 ms, where they took 48, against Lua's 29.4;
- the exporter collector about 7 ms, where it took 10.8.

That is some 30 ms of the 193, a scrape of about 0.165 s. What is left is mostly what a sample and a family cost every collector, the VM's own work, and wifi's ubus call and nl80211's replies, which no change here touched.

## What uhttpd holds at rest {#at-rest}

uhttpd holds what the handler's program compiled and loaded for as long as it runs, and every request's process and every collectors' child is forked from it. So what a scrape needs only now and then is loaded where it is needed, in the process that needs it, and kept there:

- **ubus, rtnl and nl80211** are the native modules collectors read with. uhttpd used to hold them all: some 150 kB with an access point's collectors. Then they were loaded in the scrape's child, the first time a collector's deps asked for one (`deps.native`). uhttpd now loads, when it starts, those its enabled collectors need, and no other (see [Native modules when uhttpd starts](#natives-at-start)).
- **Basic auth's module, crypt and ucode-mod-digest** are compiled when the handler finds uhttpd's auth file, and kept from then on; without basic auth, never. The config's datatypes take what a user and a hash may be from a module of their own, `hashes.uc`. A meta's fingerprint is its JSON, not its MD5. Together: 50 kB. If basic auth's module does not load, for whatever reason, every request is denied, as without its file.
- **The exposition parser** is compiled the first time a collector parses: unbound and textfile, in the child. 60 kB.
- **zlib** was loaded in the request's process the first time it gzipped a reply. It is now loaded when uhttpd starts, and a reply is sent plain if zlib does not load. And what the service grants its user when it starts (the ubus ACL, the groups, the capabilities, the TLS copies) moved from `privileges.uc`, which a scrape checks against, to `grant.uc`, which only `jail.uc` loads. 45 kB together.

In exchange, a scrape pays for each the first time it needs it (`make bench`'s `lazy:` cases, each a process of its own):

| Loaded where it is needed | devenv | QEMU's 500-MIPS 24Kc | YunCore AX835 |
| :--- | :--- | :--- | :--- |
| the exposition parser, compiled (`lazy:parse`) | 1.2 ms | 30.5 ms | 10.4 ms |
| zlib (`lazy:zlib`) | 0.2 ms | 1.4 ms | 1.1 ms |
| ubus (`lazy:ubus`) | 0.2 ms | 1.4 ms | 1.1 ms |
| rtnl (`lazy:rtnl`) | 0.2 ms | 2.4 ms | 1.3 ms |
| nl80211 (`lazy:nl80211`) | 0.2 ms | 1.8 ms | 1.1 ms |

An access point's scrape needs all of them but the parser: 4.6 ms more of its 0.17 s on the AX835, for 0.25 MB less held for as long as uhttpd runs. A scrape with unbound pays for the parser too; textfile's already did.

Every scrape paid that, for modules that every scrape of the same collectors needs. So the native modules now take a middle way: uhttpd loads them when it starts, and a scrape loads none of them (see [Native modules when uhttpd starts](#natives-at-start)). Basic auth's modules, the exposition parser and socket are still loaded where they are needed.

What uhttpd holds, before (main of 2026-10-09) and now:

| | before | now |
| :--- | :--- | :--- |
| devenv, the handler with the base collectors (`rest:base`) | 1.58 MB | 1.38 MB |
| devenv, with every collector (`rest:full`) | 2.23 MB | 2.02 MB |
| YunCore AX835, base collectors (`rest:base`) | 1.58 MB | 1.39 MB |
| YunCore AX835, every collector (`rest:full`) | 2.22 MB | 2.03 MB |
| QEMU's 24Kc (32-bit), base collectors (`rest:base`) | 1.08 MB | 1.02 MB |
| QEMU's 24Kc, every collector (`rest:full`) | | 1.46 MB |
| the service's uhttpd in the devenv's procd container (RssAnon): base collectors | 1.90 MB | 1.63 MB |
| the same, an access point's 19 collectors | 2.07 MB | 1.74 MB |
| the same, the base package and the `-full` group (36) | 2.54 MB | 2.26 MB |
| the service's uhttpd in QEMU's 24Kc, the base package and the `-full` group (36) | | 1.70 MB |

The `rest:` cases run in the benchmark's own process, which has loaded some native modules itself, so they show less of what a native module saves than the service does. On the access point, the service's uhttpd held 2.21 MB with 0.2.1-r4, against the Lua exporter's 0.52 MB. Less the container's 16%, that is about 1.86 MB now.

### What is left {#what-is-left}

What uhttpd holds now is mostly what ucode keeps of a program it compiled from source, and what compiling it left behind:

- **A function** costs ucode some 0.8 kB however small, a kilobyte with a few locals, more with many. That is its bytecode, plus the debug information of its locals and its lines, from which a runtime error's message is written. The handler's program has some 380 functions; the collectors 5 to 20 each.
- **An object** a module makes when it loads, such as an option's spec or a table of names, costs another 0.6 kB or so, and its strings twice: once in the program, once in the object.
- **The source text** costs a sixth of its bytes. The packages install it without comments, which halves the bytes: the service's uhttpd, base collectors, holds 1.62 MB (RssAnon) in the package-check image, where it held 1.65 MB with them.
- **Compiling** leaves about a quarter more, freed but not given back: musl's malloc keeps freed memory for the process to reuse.

Loading the same program as precompiled bytecode stripped of its debug information (`ucode -c -s`) shows how much of it is that information. The handler's program holds 1076 kB compiled from source in the devenv, and 612 kB loaded that way, and loads in a sixth of the time. With the handler installed as stripped bytecode (116 kB), the service's uhttpd holds 1.20 MB with the base collectors in the package-check image, where it holds 1.62 MB from source. The packages do not ship bytecode, because of what it costs:

- **Flash.** 25.12's ucode compiles a program together with every module it imports statically, and has no `-c module` to compile a module alone. So each program carries its own copy of the library: the base package's eleven programs, as bytecode, are 1.47 MB, where the whole package is 270 kB. And a module's stripped bytecode is no smaller than its stripped source (`breaker.uc` 1.4 kB against 1.3, `exposition/format.uc` 6.7 against 6.4), and a third bigger compressed, as JFFS2 stores it.
- **Source all the same.** Collectors are imported at run time, by `loadstring()`. They, the collector API and the loader, with all they import, are then compiled from source: 75 of the package's modules, most of them duplicated in the handler's bytecode.
- **Errors.** A runtime error in a bytecode program has no line and no file. A collector's `COLLECTOR_CRASHED` and the log give both.
- **Checks.** The loader's import scan and `collector check`'s purity tokenizer read a module's text.

## Flash {#flash}

The packages install their ucode and JavaScript without comments: the build strips them, and the sources keep no comments but the exported symbols' JSDoc. The sizes below are installed, as apk counts them, and as a JFFS2 image with LZMA, as an overlay stores it (`mkfs.jffs2`, 64 KiB blocks), with comments (0.2.1) and without:

| Package | Installed | JFFS2 |
| :--- | :--- | :--- |
| `ucode-prometheus-exporter` | 554 → 264 KiB | 250 → 119 KiB |
| `luci-app-prometheus-exporter` | 73 → 54 KiB | 34 → 24 KiB |
| `ucode-prometheus-exporter-cli` | 17 → 10 KiB | 9 → 6 KiB |
| `ucode-prometheus-exporter-devkit` | 40 → 23 KiB | |
| a collector's package | 2–16 → 1–12 KiB | |
| base, LuCI app, `-wifi`, `-hostapd_stations`, `-thermal` | 648 → 332 KiB | 294 → 148 KiB |

On QEMU's malta, the overlay's upper layer was a 1.6 MB mtdram device (26 blocks of 64 KiB), as on the YunCore AX835. apk installed that set in 452 KiB of the overlay, its database included, and now installs it in 296 KiB. Upgrading it in place took 8 and 20 KiB more. An empty overlay has room for 1,440 KiB; after the set, 988 KiB with comments and 1,092 KiB without.

Shipping bytecode instead of source would cut nothing more: see [What is left](#what-is-left).

### Native modules when uhttpd starts {#natives-at-start}

The `lazy:` costs above were paid by each scrape, in its child, for modules that do not change between scrapes: some 0.8 ms in the devenv, 4.6 ms on the AX835 and 7 ms on QEMU's 24Kc for an access point's collectors. uhttpd now loads them once, when it starts: ubus, rtnl and nl80211 where an enabled collector needs one, and zlib, whatever the collectors, while `compress` is on. Each is loaded in the probe's child first, as the collectors are. So a module whose C code crashes as it loads costs only that child, and is left to the scrapes, where a crash costs only the collector that needs it.

What that costs uhttpd and its scrapes in the devenv (`make bench`, main of 2026-10-10 against now, run back to back). The benchmark's worlds stand in for the native modules, so its scrapes show what moved, not what they no longer load:

| | before | now |
| :--- | :--- | :--- |
| the handler at rest, base collectors (`rest:base`) | 1.35 MB | 1.44 MB |
| the handler at rest, every collector (`rest:full`) | 1.96 MB | 2.04 MB |
| loading it, base collectors (`rest:base`'s time) | 41 ms | 49 ms |
| the service's uhttpd, base collectors (`handler:base`'s RSS) | 2.83 MB | 2.94 MB |
| a scrape through uhttpd, base collectors (`handler:base`) | 21.0 ms | 21.1 ms |
| a scrape of the base collectors (`scrape:base`) | 12.6 ms | 12.7 ms |

uhttpd holds some 0.1 MB more, and takes one more fork when it starts. A scrape takes as long, not counting the modules it no longer loads. Of what a scrape spends outside its collectors, a fraction of a millisecond moved from the exporter collector's run to the scrape's own work, because the scrape now writes the exporter's counters itself (see [About deadlines and circuit breakers](deadlines-and-breakers.md#quarantine-applies-to-every-scrape)).

## The ubus object's sources {#the-ubus-objects-sources}

wifi, hostapd_stations, timesync and wireguard's `peer_names` ask the service's ubus object for what the service's user may not read itself (see [About the security model](security.md#what-the-services-user-reaches-over-ubus)). When they first did, each call cost a scrape on the access point some 15 to 20 ms, where the call it replaced cost a few. There were two reasons:

- **rpcd's collection.** After every call of a ucode plugin's method, rpcd collects the plugin's garbage: a pass over everything the plugin holds. And rpcd answers one call at a time. The object's plugin held every module of the object, which its methods for LuCI need: 0.7 MB, collected in 1.5 ms in the devenv. That is some 6,300 turns of the VM's loop, so 15 to 20 ms on the AX835, paid by the next call rpcd answered, whoever made it: timesync's `rc list` after its `time_daemons`, hostapd_stations' call after wifi's. The plugin now holds only the collectors' methods, `rpc/sources.uc`: some 0.1 MB with ucode's own, collected in 0.03 ms. It compiles the rest when one of LuCI's methods is called, some 25 ms in the devenv, and lets go of it 120 s after the last.
- **A program for each call.** `wireless` asked netifd through ubus's command line, in a process of its own, so that a busy netifd would not hold rpcd. That cost a fork, a shell and `ubus` at every scrape of wifi and of hostapd_stations: 1.3 ms of a program run in the devenv and 3.4 ms on the AX835, each. Now `wireless` reads the wireless config, and the collector asks the kernel which interfaces exist and are up, as it already asked it for the rest. netifd is not asked, so a netifd busy setting a radio up no longer fails the scrape (`network.wireless status: no answer`).

The benchmark's `rpcd:` cases hold what the plugin holds, and time each of the three methods with rpcd's collection after it, on the typical world's configs, sysfs and procd (`make bench`, and `make bench-device` on the YunCore AX835):

| | devenv, before | devenv, now | AX835, before | AX835, now |
| :--- | :--- | :--- | :--- | :--- |
| what rpcd's plugin holds (`rpcd:rest`) | 0.71 MB | 0.10 MB | 0.72 MB | 0.10 MB |
| its collection, after each call | 1.5 ms | 0.03 ms | 14.4 ms | 0.28 ms |
| programs run by a call of `wireless` | 1, 1.3 ms | none | 1, 3.4 ms | none |
| `wireless`, and the collection (`rpcd:wireless`) | | 0.22 ms | | 2.0 ms |
| `time_daemons`, and the collection (`rpcd:time_daemons`) | | 0.05 ms | | 0.6 ms |
| `wireguard_peers`, and the collection (`rpcd:wireguard_peers`) | | 0.04 ms | | 0.3 ms |

On the AX835 itself, with the exporter it had installed before (main of 2026-10-19):

- a call of `wireless` through ubus's command line took some 17 ms more than one of rpcd's `rc list`;
- an `rc list` made right after `time_daemons` took up to 10 ms more than the next.

Its scrapes, as vmagent timed them: wifi took 36.7 ms, where it had taken 14.8 before the object asked for it; timesync 18.5 where 3.4; and the whole scrape 0.216 s where 0.170. On the R3S, which has no radio, wifi took 19.5 ms where 1.8, and hostapd_stations 19.1 where 2.4. The calls now cost what collecting 0.1 MB and reading two configs cost, a few milliseconds of the A53's: what the calls they replaced cost.

Budgets hold both in turns of the VM's loop, under 3,000, so that neither cost comes back: a program run is some 5,000 turns, and the collection of every module 6,300.

## wifi, ethtool and agh {#wifi-ethtool-agh}

vmagent's averages over four hours, with main of 2026-10-19 installed:

- wifi took 23 ms of the AX835's scrape, where it took 15 before it asked the service's object;
- ethtool took 97 ms of the R3S's, where it took about 60 before it wrote link modes;
- agh took 19 ms.

Each was timed apart on its device, against its own sources.

**wifi**, on the AP's 2 radios and 3 interfaces. The object's `wireless` took 2.85 ms through ubus, where netifd's status had taken 0.84. It read the wireless and network configs and sysfs at every call, and wifi and hostapd_stations each call it. Each interface cost a GET_INTERFACE of nl80211 (0.17 ms), a survey (1.0 to 1.6 ms, the channels of its phy), and a link of rtnetlink (0.5 to 0.77 ms in a new process, since rtnl converts all the link holds, its statistics and per-family settings with it). The surveys of a phy's two interfaces are the same survey.

wifi now asks nl80211 for every interface in one dump (0.3 ms), reads whether each is up from its flags in sysfs (0.08 ms), asks for a phy's survey once, and writes an interface's samples to a `labels()` set. rpcd keeps the reply of `wireless` while the two configs' files and the phys are as they were. A dump of every link from rtnetlink would have cost more than the three lookups: 4.0 ms for the AP's 12 links.

**ethtool**, on the R3S's two NICs: an stmmac of 216 statistics and an r8169 of 14. A program run under the watchdog took 5.7 ms there. ethtool alone takes 3.5; its shell and the watchdog's subshells take the rest. Six of them took 34 ms, and one batch of the six takes 17 (`run_all()`, see [About the implementation](internals.md#running-a-program)).

What is left is the VM's work: a few dozen turns for each statistic and its family of one sample, to take its line apart, make its name, check its family's name, and write the line. On the Cortex-A53, a turn costs as much as a regex reading some 30 bytes. So one regex over the listing takes half the time that taking each line apart did. The names of a device's new statistics are made together, and a batch of the families checks their names with one match. Two stmmac ports take 95 ms, where they took 105. A Wi-Fi interface is not asked its link settings, since cfg80211 has none; a port that is down still is.

**agh**. `/control/stats` takes AdGuard Home 10 to 30 ms on the R3S, because it computes its top lists from a day of statistics; `/control/status` takes 2.5 ms. Parsing the 6.5 kB of statistics took 3.2 to 6 ms; parsing only their totals, which follow the last top list, takes 0.2. Only the status gives the version, protection and whether DNS runs, and only the statistics give their totals. Asked both at once, over two connections, AdGuard Home took longer than asked one after the other (a mean of 24 to 27 ms, against 18). And a collector keeps nothing from one scrape to the next, so it cannot ask for the status less often. So agh asks for one, then the other, and parses only the totals.

Before (main of 2026-10-19) and after, on the benchmark's large world in the devenv and on the AX835 (`make bench`, `make bench-device`), and against the devices' own sources:

| | devenv | YunCore AX835 | On the device |
| :--- | :--- | :--- | :--- |
| wifi, 3 radios of 3 networks and 200 stations | 10.4 → 10.3 ms | 127 → 126 ms | AX835's: 23.7 → 18.8 ms, with the object it has installed |
| its requests of nl80211 and rtnetlink (`asked`) | 27 and 9 → 13 and 0 | | AX835's: 9 and 3 → 6 and 0 |
| the object's `wireless`, and rpcd's collection (`rpcd:wireless`) | 0.2 → 0.1 ms | 2.0 → 0.8 ms | |
| ethtool, 7 wired ports and 9 radios' interfaces | 106 → 55 ms | 615 → 452 ms | R3S's six programs: 34 → 17 ms |
| its watchdog's runs, and programs (`asked`) | 48 and 48 → 1 and 39 | | R3S's: 6 and 6 → 1 and 6 |
| ethtool in a typical full scrape (`scrape:full`) | 71 → 38 ms | 432 → 314 ms | |
| a typical full scrape (`scrape:full`) | 124 → 90 ms | 956 → 840 ms | |
| agh, a day's statistics of the router's size | 0.9 → 0.8 ms | 8.2 → 6.7 ms | R3S's parse: 3.2–6 → 0.2 ms |

Asking the worlds' netlink costs nothing, so wifi takes as long there as before. On the AX835 itself, the held reply of `wireless` saves another 1.2 ms on each of a scrape's two calls, so wifi is some 17 ms of its scrape, where it was 23. On the R3S, ethtool is some 70 ms, where it was 97: the programs' 17 ms saved, and a tenth of the VM's work. agh is some 14 to 16 ms there, where it was 19.

Budgets hold them in counts, which are the same on any machine:

- wifi to 13 requests of nl80211 and none of rtnetlink on the large world;
- ethtool to one run of the watchdog for 39 programs;
- agh to 2 connections;
- `rpcd:wireless` to no cursor of the configs on a call that follows another.

Budgets also hold wifi and agh in turns of the VM's loop, and agh to 128 kB where a run's peak is its own (24 to 52 kB parsing the totals, 216 to 260 parsing the whole statistics).

## memory_limit's floor {#memory-floor}

`memory_limit` limits each of uhttpd's processes (RLIMIT_DATA): the one that loads the handler and the collectors, each request's, and the child its collectors run in. With too little, uhttpd does not load the handler, and procd starts it again and again; or a scrape, or a collector, runs out. The least it takes is 8 MB (MEMORY_LIMIT_MIN), and the config refuses less. `make bench`'s `floor:` cases find the least limit, in whole MB, under which uhttpd loads the handler with a set's collectors and the typical world's scrape of them has every collector succeed:

| Machine | base collectors (16) | every collector (36) |
| :--- | :--- | :--- |
| devenv (x86_64) | 4 MB | 7 MB |
| QEMU's 24Kc (32-bit MIPS) | 3 MB | 5 MB |
| YunCore AX835 (Cortex-A53), by the benchmark's scrape process | 3 MB | 7 MB |

The access point's installed exporter is not the source tree's, so uhttpd there cannot run this one. The case limits the benchmark's scrape process instead, which lacks uhttpd's own data. It found the same as uhttpd does in the devenv for every collector, and 1 MB less for the base ones. So 8 MB holds on each, 32-bit and 64-bit, with room for a collector or two of another package.

A busy router's scrape takes more. The benchmark's large world, 20,000 connections and every collector, needs 29 MB in the devenv and 27 MB on the A53. `memory_limit` 0 means a quarter of the RAM, at most 64 MB, which gives it that on a router of 128 MB or more.

The default limits were sized on the benchmark's large world:

- `max_samples`, 20,000. The most one collector writes there is 3,650 (snmp6 on 50 devices), at some 0.5 kB held per sample, so a runaway collector is bounded at some 10 MB.
- `max_scrape_samples`, 200,000. The world writes 33,600, at some 0.2 kB per sample in the scrape process, so the limit comes to 40 MB, under memory_limit's cap of 64 MB. The scrape's peak there is 30 MB on 64 bits and 22 MB on a 32-bit MIPS.
- `exec_timeout`, 5 s. The programs collectors run answer in milliseconds, or in about a second for an ssh login to a radio, and a hung one still leaves the rest of Prometheus's 10 s.

## What each collector costs {#each-collector}

For each collector: what it adds to what uhttpd holds (compiled with the collector API, in the devenv, to 4 kB), and its run on the benchmark's large world (50 links, 3 radios of 3 networks and 200 stations, 2,000 DHCP leases), in each case's process:

| Collector | held at rest | devenv | QEMU's 500-MIPS 24Kc | YunCore AX835 |
| :--- | :--- | :--- | :--- | :--- |
| chrony | 48 kB | 7.2 ms | - | 33.0 ms |
| conntrack | 20 kB | 0.6 ms | 14.3 ms | 6.3 ms |
| cpu | 12 kB | 0.8 ms | 22.5 ms | 8.9 ms |
| dhcp_leases | 48 kB | 55.1 ms | 2141 ms | 680 ms |
| diskstats | 24 kB | 1.8 ms | 46.2 ms | 17.9 ms |
| dnsmasq | 16 kB | 0.7 ms | 17.3 ms | 6.6 ms |
| entropy | 12 kB | 0.4 ms | 6.9 ms | 3.5 ms |
| ethtool | 52 kB | 54.5 ms | 1387 ms | 452 ms |
| exporter | 36 kB | 0.8 ms | 14.0 ms | 6.4 ms |
| filefd | 8 kB | 0.3 ms | 6.9 ms | 3.1 ms |
| filesystem | 28 kB | 0.8 ms | 20.1 ms | 7.5 ms |
| hostapd_stations | 16 kB | 13.2 ms | 523 ms | 167 ms |
| hostapd_ubus_stations | 16 kB | 6.4 ms | 259 ms | 83.2 ms |
| hwmon | 44 kB | 5.4 ms | 124 ms | 52.1 ms |
| loadavg | 12 kB | 0.4 ms | 7.5 ms | 3.4 ms |
| meminfo | 8 kB | 0.8 ms | 22.2 ms | 8.4 ms |
| netclass | 28 kB | 9.9 ms | 235 ms | 91.2 ms |
| netdev | 20 kB | 3.3 ms | 128 ms | 44.2 ms |
| netstat | 44 kB | 1.4 ms | 43.1 ms | 16.2 ms |
| nft-counters | 8 kB | 5.0 ms | 124 ms | 44.4 ms |
| openwrt | 8 kB | 0.5 ms | 9.6 ms | 4.0 ms |
| openwrt_interfaces | 20 kB | 1.5 ms | 54.6 ms | 18.9 ms |
| qdisc | 16 kB | 3.5 ms | 56.3 ms | 22.0 ms |
| selinux | 12 kB | 0.4 ms | 7.0 ms | 3.2 ms |
| snmp6 | 8 kB | 16.7 ms | 576 ms | 212 ms |
| sockstat | 20 kB | 0.8 ms | 19.4 ms | 8.2 ms |
| softnet | 12 kB | 0.6 ms | 16.5 ms | 7.0 ms |
| textfile | 16 kB | 24.4 ms | 795 ms | 275 ms |
| thermal | 16 kB | 0.9 ms | 15.1 ms | 7.4 ms |
| time | 4 kB | 0.3 ms | 6.3 ms | 2.9 ms |
| timesync | 20 kB | 0.5 ms | 10.1 ms | 4.2 ms |
| uci_dhcp_host | 16 kB | 3.4 ms | 123 ms | 43.3 ms |
| uname | 8 kB | 0.5 ms | 7.8 ms | 3.6 ms |
| vmstat | 16 kB | 0.5 ms | 13.5 ms | 5.4 ms |
| wifi | 40 kB | 10.4 ms | 353 ms | 124 ms |
| wireguard | 16 kB | 2.3 ms | 62.8 ms | 21.8 ms |
| nat_traffic, 1,000 connections | 12 kB | 8.1 ms | 308 ms | 110 ms |
| nat_traffic, 20,000 connections | 12 kB | 142 ms | 5609 ms | 1953 ms |

The collector API they share holds 110 kB more, once. On a slow router, a collector that reads a table takes as long as its table: nat_traffic's connections, dhcp_leases' leases, ethtool's ports, textfile's files. ethtool runs `ethtool -S`, `-i` and the link settings of each port, all in one batch; QEMU's time is from before the batch (see [wifi, ethtool and agh](#wifi-ethtool-agh)). Some packages bring programs that take flash too: ethtool's `ethtool` (72 KiB on mipsel), qdisc's `tc-tiny` and `kmod-sched-core` (279 and 172 KiB). See [How to run the exporter on a small device](../how-to/small-device.md).

## Loading {#loading}

uhttpd loads the collectors when it starts, in the process every request is forked from, and holds them as long as it runs. A collector imports the collector API, which imports four modules of the core. ucode compiles a module once per program, and keeps its source file open while the program lives. 0.2.0 compiled a program for each collector, so each had its own copy of those five modules, and six open descriptors with its own file. 37 collectors kept 268 descriptors open in the R3S's uhttpd. A process may open 1024, which some 160 collectors would reach. The collectors are now compiled as one program, once each has loaded in a child process of its own (the probe, which still compiles each alone):

| Loading every collector | 0.2.0 | Now |
| :--- | :--- | :--- |
| devenv, the benchmark's 36 (`load:full`) | 34 ms; 216 descriptors, 6.1 MB | 12.5 ms; 41 descriptors, 3.9 MB |
| QEMU's 24Kc, the same | 0.93 s; 216 descriptors, 4.8 MB | 0.37 s; 41 descriptors, 3.1 MB |
| QEMU's 24Kc, probed first (`probe:full`), as uhttpd does | 1.78 s | 1.21 s |
| the service's uhttpd, devenv's procd container, 45 collectors | 315 descriptors, 7.3 MB | 95 descriptors, 4.5 MB |
| the service's uhttpd, QEMU, 36 collectors | 263 descriptors, 5.2 MB | 86 descriptors, 3.5 MB |

A request's process and the collectors' child are forked from that uhttpd, so they start smaller too. If the collectors do not load as one program, which the probe makes unlikely, each is loaded alone, as before. What uhttpd holds once they are loaded is in [In 0.3.0](#in-030).

## The ledger

Ordering the collectors and keeping their breakers costs a scrape a read of a small file when it starts, and a locked read and write when it ends. That is 0.8 ms in the devenv and 21 ms on the 500-MIPS 24Kc, about 1% of a typical full scrape on both (`make bench`'s `ledger:full`, 37 collectors, a ledger of 1.6 kB).

## Gzip

A whole scrape of the lab (every collector, about 1250 series, on x86_64) is 143,500 bytes plain and 21,640 gzipped, 6.6 times smaller. Deflating it takes about 1 ms at zlib's fastest level, which the exporter uses, and 3 ms at its default level, for 19,160 bytes. Over loopback the scrape takes as long either way (118 ms plain, 123 ms gzipped). The gain is on the wire: 85% fewer bytes per scrape, which matters on a slow or metered link and costs the router little.

## Basic auth

The handler computes the password's hash in ucode at each scrape, so a check costs what the hash's rounds cost (`make bench`'s `auth:` cases, the median of a check in a process of its own):

| Machine | `$1$` | `$6$`, 1000 rounds (`hash_password`'s) | `$5$`, 2000 | `$6$`, 2000 | By the cache |
| :--- | :--- | :--- | :--- | :--- | :--- |
| devenv (Ryzen 7 7840U) | 2.5 ms | 4.1 ms | 6.5 ms | 7.8 ms | 0.09 ms |
| NanoPi R3S (4×A55) | 14 ms | 19 ms | 33 ms | 37 ms | 0.5 ms |
| QEMU malta, 24Kc at 500 MIPS | 63 ms | 135 ms | 206 ms | 259 ms | 2.4 ms |

A round of SHA-512-crypt takes the 500-MIPS 24Kc 125 µs. The 9,999,999 rounds a hash may name would take it twenty minutes; the default 5000, 0.63 s. So a hash may have at most 2000 rounds, a quarter of a second there, and a hash with more is refused. Even 1000 rounds are 135 ms of each scrape on such a router. That is why the handler keeps a cache of the last header it let in. A request let in by the cache costs about 2% of the full check, on every machine. See [About the security model](security.md#the-cache-and-what-it-trades).

## See also

- [How to run the benchmark](../how-to/developer/benchmarks.md)
- [How to give programs more time](../how-to/exec-timeout.md)

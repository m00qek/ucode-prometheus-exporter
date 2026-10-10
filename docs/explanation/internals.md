# About the Implementation

The code carries no explanatory comments (see [How to write documentation](../how-to/developer/documentation.md#comments-in-the-code)). What a maintainer needs and cannot read off the code is here: the quirks of ucode, its modules and the kernel that the code works round, and why some code is shaped the way it is. The reasons that shape the design are in the other explanation pages.

---

## ucode

- **Numbers.** ucode converts a string with no digit before its point, `'.5'`, to NaN: the deadline prefixes a `0` before it converts the scraper's timeout header.
- **Closures.** A closure made in a loop body sees the loop variable's last value, so the guard of a collector's top level makes each trap in a function of its own.
- **Modules.** `require()` cannot load an ES module, but a program that imports one can: modules are loaded with `loadstring("import * as m from '…'; return m;")`. Each such program compiles its own copy of every module it imports, so collectors do not share `prometheus.exporter.result`: a Result is known by a mark on its prototype, never by identity, so that `Result.is()` holds whichever copy made it.
- **uloop.** It keeps the callbacks of every task it ran, and what they hold, for as long as the process lives: a forked child's task drops what it holds once it is done.
- **uloop's pipes.** A task's messages are written each in one write, its length and its JSON, and read without blocking: one longer than `PIPE_BUF` (4 kB) may reach the reader in parts, and the reader loses one whose rest is not there yet; past what a pipe holds, 64 kB, on one CPU, it always is. So the runner's messages are a few words, its runs crossing by a file, and the probe's child sends what it checked of a module, a meta as long as its options' help, as base64 in parts of 2 kB, each a message that crosses whole.
- **Strings.** Appending to a string copies it whole: the scrape's own families are written line by line and joined once.
- **musl's regex.** A count, `{86}` or `{0,63}`, compiles into a copy of what it counts for each, which uhttpd then holds for as long as it runs: lengths are counted with `length()`, never matched. And `regexec` reads its whole subject even for an anchored match: the loader looks for what precedes a module's `'use strict'` in its first kilobyte, and reads further only when that may go on.

## Native modules

ubus, rtnl, nl80211 and socket are imported by name at run time, not statically: nl80211 and socket are packages only some collectors depend on, so a static import would stop the exporter loading without them; a module that exports a `const` does not import under utest, whose generated shim does not compile; and uhttpd needs only those its enabled collectors do. `make lint` loads each by name on 25.12, so a function it lacks still shows.

When uhttpd starts, the handler loads ubus, rtnl and nl80211 where an enabled collector needs one, and zlib, so that no scrape loads them again; socket, the exposition parser and basic auth's modules are still loaded where they are needed. A native module is C, and one that crashes as it loads would take uhttpd with it: each is loaded first in the probe's child, as the collectors are, and here only once it loaded there. One that did not is logged, and left to the scrapes' children, where a crash costs the collector that needs it. A collector enabled later, without a restart, loads what it needs in the scrape's child, as before.

- **rtnl and nl80211.** `request()` fails with null before a request is sent, and with false when the kernel refuses it; a dump of nothing is null without an error.
- **error().** rtnl's, nl80211's and ubus's clear the error as they read it, so it is read once. A failed ubus call's status, `Not found`, is the text before its first `: `.
- **ubus timeouts.** ucode's ubus takes one timeout per connection, in whole seconds, set when it connects. A call under a shorter limit, the collector's budget or the deadline running down, connects again, at most once a second, as does the first call under a new, longer limit; a call never waits less than a second.
- **Sockets.** A request sends with `MSG_NOSIGNAL`, so a server gone before it is sent is an EPIPE, not a SIGPIPE that would end uhttpd. The errnos it tests, EAGAIN (11, `SO_RCVTIMEO` passed) and EACCES (13), are the same on every architecture OpenWrt builds for.

## Running a program

A collector's programs run under a watchdog written in ash builtins alone: the jail has `/bin/sh` and the declared programs but no `timeout`, `sleep` or `kill`, and ash has no job control without a terminal. The program runs in the background while a subshell reports its pid, then its exit status, into a pipe; `read -t`, the shell's only clock, counts whole seconds. When no status comes in time, the watchdog stops the program and every process under it, found by their parent in `/proc/<pid>/stat` until no more turn up (a stopped process starts no other), then kills them all and the shell itself, whose SIGKILL status marks a killed program.

## The exposition format

A double is written with ucode's 14 significant digits when they read back as the same value, else with the fewest more that do; 17 always do, as for a byte counter past 10^14. UTF-8 is validated as Go's `utf8.ValidString`, with which Prometheus reads a scrape: overlong forms, surrogates and code points past U+10FFFF are invalid.

A run's text crosses from the scrape's child as it is, after a head that is a JSON array, not an object: ucode makes and reads an array for less, and JSON would escape every quote of every label.

## Reading a collector's text

The loader's import scanner runs at every uhttpd start, on every module, so it reads only the lines that hold one of its words or open a block comment, found with `index()` and `split()`, and only those a character at a time. A string or template that runs past its line is taken to end there: the rest may then be read as code, which can only find an import that is not there, never hide one. The purity tokenizer reads a whole module a character at a time, some 50 ms for 15 kB in the devenv, so only `collector check` and the tests run it; at load, the probe's guard holds collectors to the same rule.

## What the collectors read

- **conntrack** reads the columns of `/proc/net/stat/nf_conntrack` by the names of its header line, not by position: the kernel has renamed columns (`searched` is `clashres` now), and a column it does not write leaves its statistic out.
- **cpu** and **exporter** take `/proc` times in USER_HZ, 100 on every architecture OpenWrt builds for; exporter reads the auxiliary vector first, where it says.
- **dhcp_leases** gives a dnsmasq lease the interface whose subnet holds its address, the most specific first, as dnsmasq picks its range; an odhcpd lease the interface whose device it serves, the first in netifd's dump when several share it. odhcpd lists every interface it serves, so those without leases have a 0; dnsmasq does not.
- **filesystem** takes each mount's type and flags from the host's `/proc/mounts`, which rpcd reads for it (the jail has its own mount namespace). rpcd reads a file that reports no size in one read of at most 4 KiB, ended at a whole line, so past some 60 mounts the rest are left out.
- **interrupts** splits a line of `/proc/interrupts` at its first `:`, as node_exporter does, since arm64's may have no blank after the name; a line without a count for every CPU (ERR, MIS) is left out.
- **nat_traffic** sums to 0 without conntrack accounting (`net.netfilter.nf_conntrack_acct`): the table has no `bytes=`. A connection from outside to the router itself counts as its peer's host. The kernel writes an IPv6 address in full; the labels compress it (RFC 5952), so they join with other collectors'.
- **netclass** takes `flags` from sysfs, not netlink, whose flags are `dev_get_flags()`'s, with IFF_RUNNING and IFF_LOWER_UP added. sysfs refuses (EINVAL) the carrier of a device that is not up, and the speed and duplex of one not up or whose driver cannot tell: each reads as absent, not as an error.
- **openwrt_interfaces** writes netifd's uptime, not a start timestamp, which would move a second either way from scrape to scrape and jump with every clock step. An address of a prefix assignment counts as the interface's, though netifd lists it under `ipv6-prefix-assignment`.
- **qdisc** runs `tc -s -j qdisc show`: ucode's rtnl on 25.12 does not decode a qdisc's statistics (TCA_STATS2, TCA_XSTATS).
- **selinux** reads `/proc/filesystems`, where the kernel lists selinuxfs only when SELinux is on: the jail's own sysfs has no selinuxfs, and it does not mount `/sys/fs/selinux`, which the service would otherwise wait for on kernels without SELinux, OpenWrt's.
- **softnet**: since Linux 5.14, `/proc/net/softnet_stat` has a column with the CPU's number, so with CPUs offline a row's number is not the CPU's; before 5.14 the row number is all there is.
- **textfile** opens only a regular file, or a link to one, checked with `stat()`: a FIFO nothing writes to, or a device that never ends, would never return.
- **thermal** skips a zone whose type, policy or temperature it cannot read (a sleeping sensor answers EAGAIN or ENODATA) and reports the others.
- **vmstat** on a kernel without CONFIG_VM_EVENT_COUNTERS, as on small targets, finds no event fields: its default pattern matches nothing, and it succeeds empty.

## The LuCI app's themes

The pages work round LuCI's themes. No class makes a label red in every theme, so Failed takes the theme's error colour from its CSS variables (bootstrap's, then material's and openwrt2020's), and says Failed in words anyway. Links on error alerts take the text's colour, underlined, and links in banners are buttons, since a theme's link colour may not show on them. Refused items are not `<li>`, which material colours grey on red.

## See also

- [About the architecture](architecture.md)
- [Performance on small routers](performance.md)
- [The jail](../reference/jail.md)

# About the Implementation

The code carries no explanatory comments (see [How to write documentation](../how-to/developer/documentation.md#comments-in-the-code)). This page holds what a maintainer needs and cannot read off the code: the quirks of ucode, its modules and the kernel that the code works round, and why some code is shaped the way it is. The reasons behind the design are in the other explanation pages.

---

## ucode

- **Numbers.** ucode converts a string with no digit before its point, such as `'.5'`, to NaN. So the deadline puts a `0` in front before it converts the scraper's timeout header.
- **Object keys.** An object's key ends at its first NUL byte, so `o['b\0x']` finds `o.b`. So the recorder looks a family up by its name, and then compares the name it found with the one it was given.
- **Closures.** A closure made in a loop body sees the loop variable's last value. So the guard of a collector's top level makes each trap in a function of its own.
- **Modules.** `require()` cannot load an ES module, but a program that imports one can, so modules are loaded with `loadstring("import * as m from '…'; return m;")`. Each such program compiles its own copy of every module it imports, so collectors do not share `prometheus.exporter.result`. A Result is therefore known by a mark on its prototype, never by identity, so that `Result.is()` holds whichever copy made it.
- **uloop.** It keeps the callbacks of every task it ran, and what they hold, for as long as the process lives. So a forked child's task drops what it holds once it is done.
- **uloop's pipes.** A task's messages are written each in one write, its length and its JSON, and read without blocking. A message longer than `PIPE_BUF` (4 kB) may reach the reader in parts, and the reader loses a message whose rest is not there yet. Past what a pipe holds, 64 kB, on one CPU, it always loses it. So the runner's messages are a few words, and its runs cross by a file. The probe's child sends what it checked of a module, a meta as long as its options' help, as base64 in parts of 2 kB, each a message that crosses whole.
- **Strings.** Appending to a string copies it whole. So the scrape's own families are written line by line and joined once.
- **musl's regex.** A count, such as `{86}` or `{0,63}`, compiles into a copy of what it counts for each repetition, and uhttpd then holds that for as long as it runs. So lengths are counted with `length()`, never matched. And `regexec` reads its whole subject, even for an anchored match. So the loader looks for what precedes a module's `'use strict'` in its first kilobyte, and reads further only when that may go on.

## Native modules

ubus, rtnl, nl80211 and socket are imported by name at run time, not statically, for three reasons:

- nl80211 and socket are packages that only some collectors depend on, so a static import would stop the exporter loading without them;
- a module that exports a `const` does not import under utest, whose generated shim does not compile;
- uhttpd needs only the modules its enabled collectors need.

`make lint` loads each by name on 25.12, so a function one lacks still shows.

When uhttpd starts, the handler loads ubus, rtnl and nl80211 where an enabled collector needs one, and zlib while `compress` is on, so that no scrape loads them again. The socket module, the exposition parser and basic auth's modules are still loaded where they are needed. A native module is C, and one that crashes as it loads would take uhttpd with it. So each is loaded first in the probe's child, as the collectors are, and in uhttpd only once it loaded there. One that did not is logged, and left to the scrapes' children, where a crash costs only the collector that needs it. A collector enabled later, without a restart, loads what it needs in the scrape's child, as before.

- **rtnl and nl80211.** `request()` fails with null before a request is sent, and with false when the kernel refuses it. A dump of nothing is null without an error.
- **error().** rtnl's, nl80211's and ubus's clear the error as they read it, so it is read once. A failed ubus call's status, such as `Not found`, is the text before its first `: `.
- **ubus timeouts.** ucode's ubus takes one timeout per connection, in whole seconds, set when it connects. So a call under a shorter limit, the collector's budget or the deadline running down, connects again, at most once a second. So does the first call under a new, longer limit. A call never waits less than a second.
- **fs.open().** Its mode is fopen's: `r`, `w` or `a`, with `+`, `x` and `e`. It has neither `O_NOFOLLOW` nor `O_NONBLOCK`, and `r` on a FIFO with no writer never returns. So when root reads a state file, which the service's user owns, it:
    1. calls `lstat()` first, and wants a regular file of the directory's owner with one link;
    2. opens it `r+`, read-write, which opens a FIFO at once rather than wait for a writer;
    3. calls `stat()` on `/proc/self/fd/<fd>`, the file it opened, and reads nothing unless that is the file it looked at.

    A FIFO or a link put in its place in between is so closed unread.

- **Sockets.** A request sends with `MSG_NOSIGNAL`, so a server gone before the send is an EPIPE, not a SIGPIPE that would end uhttpd. The errnos it tests, EAGAIN (11, `SO_RCVTIMEO` passed) and EACCES (13), are the same on every architecture OpenWrt builds for.

## Running a program

A collector's programs run under a watchdog written in ash builtins alone. The jail has `/bin/sh` and the declared programs, but no `timeout`, `sleep` or `kill`, and ash has no job control without a terminal. The program runs in the background, while a subshell reports its pid, then its exit status, into a pipe. `read -t`, the shell's only clock, counts whole seconds. When no status comes in time, the watchdog stops the program and every process under it, found by their parent in `/proc/<pid>/stat` until no more turn up (a stopped process starts no other). Then it kills them all, and the shell itself, whose SIGKILL status marks a killed program.

`run_all()` runs its programs in a shell function, which the watchdog runs in the background, as it runs a program. That costs a fork and an exec per program, where `run()` costs a shell, its two subshells and the program's fork. After each program's output, the function writes a line with a mark and the program's exit status, using `printf`, a builtin. The mark is the batch's own, made of the monotonic clock's nanoseconds and the channel's count, so no program's output holds it unless the program guessed it. A batch killed at its seconds ends without the marks of the program then running and of those after it.

## The exposition format

A double is written with ucode's 14 significant digits when they read back as the same value, and otherwise with the fewest more that do. 17 always do, as for a byte counter past 10^14. UTF-8 is validated as Go's `utf8.ValidString` validates it, since Prometheus reads a scrape with it: overlong forms, surrogates and code points past U+10FFFF are invalid.

`out.batch()` checks its rows' names with one match over all of them, one name to a line, when no name holds a NUL byte (a C string ends there, and so does a regex) and each is one line. Otherwise it matches each name on its own. On a router's CPU, a turn of the VM costs as much as a regex reading some 30 bytes, so one regex over all the names costs less than a match of each.

A run's text crosses from the scrape's child as it is, after a head that is a JSON array. The text is not JSON, which would escape every quote of every label. The head is an array, not an object, because ucode makes and reads an array for less.

## Reading a collector's text

The loader's import scanner runs at every uhttpd start, on every module. So it reads only the lines that hold one of its words or open a block comment, found with `index()` and `split()`, and reads only those a character at a time. A string or template that runs past its line is taken to end there. The rest may then be read as code, which can only find an import that is not there, never hide one.

The purity tokenizer reads a whole module a character at a time, some 50 ms for 15 kB in the devenv, so only `collector check` and the tests run it. At load, the probe's guard holds collectors to the same rule.

## What the collectors read

- **agh** asks for the status, then the statistics. Only the status gives the version, whether protection is on and whether DNS runs, and only the statistics give their totals. Asked at once, on the R3S, the two took AdGuard Home longer than one after the other. Of the statistics, agh parses only the totals, which follow the last top list. AdGuard Home writes the fields compact, in its struct's order, with the totals and `dns_queries` after the top lists, and a top list's entry is a name and a number. So `,"dns_queries":[` is that field's and nothing else's. A reply that does not start with `time_units`, or whose part from `dns_queries` on lacks a total, is parsed whole.
- **conntrack** reads the columns of `/proc/net/stat/nf_conntrack` by the names in its header line, not by position. The kernel has renamed columns (`searched` is `clashres` now), and a column it does not write leaves its statistic out.
- **cpu** and **exporter** take `/proc` times in USER_HZ, 100 on every architecture OpenWrt builds for. exporter reads the auxiliary vector first, where it says.
- **dhcp_leases** gives a dnsmasq lease the interface whose subnet holds its address, the most specific first, as dnsmasq picks its range. It gives an odhcpd lease the interface whose device it serves, the first in netifd's dump when several share it. odhcpd lists every interface it serves, so those without leases have a 0; dnsmasq does not.
- **ethtool** runs all its programs of a scrape in one `run_all()`. It reads `ethtool -S` with one regex over the listing, one match per line. It names a device's new statistics together, transforming their names joined one to a line, each line's name its own. On a Cortex-A53 the regex takes half the time that splitting and looking at each line took: 216 lines in 4.4 ms, where 8.4. Its statistics are a batch, a row each, of the device's label set. It asks no link settings of a Wi-Fi interface (one with a `phy80211` link in sysfs): cfg80211 gives none, and `ethtool <device>` says only whether it has a link, which no family writes. It does ask them of a port that is down, since phylib still says what the port supports and advertises.
- **filesystem** takes each mount's type and flags from the host's `/proc/mounts`, which rpcd reads for it, since the jail has its own mount namespace. rpcd reads a file that reports no size in one read of at most 4 KiB, ended at a whole line, so past some 60 mounts the rest are left out.
- **interrupts** splits a line of `/proc/interrupts` at its first `:`, as node_exporter does, since arm64's may have no blank after the name. A line without a count for every CPU (ERR, MIS) is left out.
- **nat_traffic** sums to 0 without conntrack accounting (`net.netfilter.nf_conntrack_acct`), since the table then has no `bytes=`.

    A connection's host is its end on this side of the router, which the routes say: an address of the router's own, or one on-link to an interface without a default route. The LAN host a port forward reaches comes first, then the source, then the destination. So a connection from the internet that the firewall accepts without NAT is the router's WAN address's when it is to the router (a ping, an open port), and the LAN host's when it is ICMPv6 to the host's global address. One with neither end there, as between two WAN neighbours, is `host="other"`.

    The collector reads the routes once a scrape, every table's, because rtnl dumps them all whatever table a request names: the kernel filters a dump by table only for a socket with strict checking, which ucode's rtnl does not ask for. It sorts the prefixes into a set for each length: an IPv4 one by its integer shifted to the length, an IPv6 one by the leading characters of its full form. So an address is a lookup for each length, not a comparison with each route, and the collector looks at each address once. The kernel writes an IPv6 address in full, which the sets take as it is. The labels compress it (RFC 5952), so they join with other collectors'.

- **netclass** takes `flags` from sysfs, not netlink, whose flags are `dev_get_flags()`'s, with IFF_RUNNING and IFF_LOWER_UP added. sysfs refuses (EINVAL) the carrier of a device that is not up, and the speed and duplex of one that is not up or whose driver cannot tell. Each reads as absent, not as an error.
- **openwrt_interfaces** writes netifd's uptime, not a start timestamp. A timestamp would move a second either way from scrape to scrape, and jump with every clock step. An address of a prefix assignment counts as the interface's, though netifd lists it under `ipv6-prefix-assignment`.
- **qdisc** runs `tc -s -j qdisc show`, because ucode's rtnl on 25.12 does not decode a qdisc's statistics (TCA_STATS2, TCA_XSTATS).
- **selinux** reads `/proc/filesystems`, where the kernel lists selinuxfs only when SELinux is on. The jail's own sysfs has no selinuxfs, and the jail does not mount `/sys/fs/selinux`, which the service would otherwise wait for on kernels without SELinux, such as OpenWrt's.
- **softnet**: since Linux 5.14, `/proc/net/softnet_stat` has a column with the CPU's number, so with CPUs offline a row's number is not the CPU's. Before 5.14, the row number is all there is.
- **textfile** opens only a regular file, or a link to one, checked with `stat()`. A FIFO nothing writes to, or a device that never ends, would never return.
- **thermal** skips a zone whose type, policy or temperature it cannot read (a sleeping sensor answers EAGAIN or ENODATA), and reports the others.
- **wifi** and **hostapd_stations** take the radios and their networks from the wireless config, which the service's ubus object reads (it has the keys).

    Each network's interface is named as netifd names it, as `mac80211.sh` does: its `ifname`; else the radio's prefix (the phy's name and, on a phy of several, the radio's index, or `ifname_prefix`), the mode, and the network's index among the radio's networks of that mode, an OWE transition network counting one more.

    The phy is found as wifi-scripts' `find_phy()` finds it, read-only: by the radio's `path` (`+N` the Nth of the device's phys, by their index), `macaddr` or `phy`. wifi-scripts may rename a phy as board.json names it, and by then the rename is done.

    wifi then asks nl80211 for every interface in one dump, and leaves out a network whose interface is not in it. It reads whether each interface is up from its flags in sysfs: a radio is up while one of its networks' interfaces is. A channel survey is the phy's, which nl80211 gives alike to each of its interfaces, so wifi asks for it once for each phy.

    netifd's `up` is not used here. It says whether netifd set the radio up, which is also true of a radio with no network enabled, and of one whose interfaces hostapd has not brought up. A network whose logical interface `ifdown` took down is taken as set up, as the config has it, though netifd leaves it out until it is up again. The radio's later networks of that mode are then named one past what netifd names them, so the last name is not there and is left out.

    wifi labels an interface with the SSID nl80211 says it serves (an access point's, or a client's network), and with the config's SSID or mesh ID where nl80211 says none, so the labels stay right. hostapd_stations takes the SSID from hostapd and the encryption from the config, which may then be the next network's.

- **vmstat** on a kernel without CONFIG_VM_EVENT_COUNTERS, as on small targets, finds no event fields. Its default pattern matches nothing, and it succeeds empty.

## The LuCI app's themes

The pages work round LuCI's themes:

- No class makes a label red in every theme. So Failed takes the theme's error colour from its CSS variables (bootstrap's, then material's and openwrt2020's), and says Failed in words anyway.
- A theme's link colour may not show on an error alert or a banner. So links on error alerts take the text's colour, underlined, and links in banners are buttons.
- Refused items are not `<li>`, which material colours grey on red.

## See also

- [About the architecture](architecture.md)
- [Performance on small routers](performance.md)
- [The jail](../reference/jail.md)

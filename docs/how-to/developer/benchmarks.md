# How to Run the Benchmark

The benchmark times each collector and whole scrapes on generated worlds: what a router's `/proc`, `/sys`, ubus, netlink and programs would give. Run it to see what a change costs, here, in a container limited as a slower router, on a device, or in QEMU as a MIPS router.

## In the development environment

```bash
make bench
```

It prints a table and writes `bin/bench/devenv.json`, and checks the budgets of `test/bench/budgets.uc`: scaling and memory always, times too when the container is unconstrained. CI runs the same.

A `scrape:` case runs each collector in a child process, as the service does; its `inline:` twin runs them all in the scrape's own process, so the difference is what that containment costs, which a budget holds. A `handler:` case is the scrape as Prometheus gets it: uhttpd started with the service's handler (`test/bench/handler.uc`, which has the collectors read the world), and asked by wget, so it counts the request's process, the ledger, the progress file and the deadline too; its note gives what it takes besides its collectors (`outside`, wget's own time left out), which a budget holds, and the descriptors and memory of the uhttpd process. It runs where uhttpd and its ucode plugin are and find this exporter: in the container `make bench` links the source tree into `/usr/share/ucode`, and QEMU's guest has the packages installed. `load:` and `probe:full` load the collectors as uhttpd does, `probe:` each in a child process first; their note gives the descriptors loading left open, which a budget holds too. `rest:base` and `rest:full` are what the handler's process holds once it has loaded a set, as uhttpd holds it for as long as it runs: its private memory (RssAnon) more than before it compiled the handler's program, which a budget holds. `lazy:` cases time what a process pays the first time it needs a module: the exposition parser, which a scrape loads where a collector parses, and zlib, ubus, rtnl and nl80211, which uhttpd loads when it starts and a scrape so no more. `floor:base` and `floor:full` find the least `memory_limit`, in whole MB, under which uhttpd loads the handler with the set and a typical scrape of it has every collector succeed, each of its processes limited as procd limits the service's; a budget holds it to `memory_limit`'s least, 8 MB. On a device whose installed exporter is not the source tree's, where uhttpd cannot run this one, they limit the benchmark's scrape process instead, and say so (`by scrape`). `progress:full` is a scrape's progress file. `record:` cases time the recorder alone, a sample of each shape collectors write, and `noop:1` and `noop:41` scrape collectors that write nothing: the note of `noop:41` gives what a scrape costs a collector besides it. Budgets hold both, the latter in turns of `calibrate:vm`'s loop, which holds on any machine. `rpcd:` cases run in a process of their own (`test/bench/rpcd.uc`) that holds what rpcd's plugin holds of the ubus object: `rpcd:rest` what it holds, which a budget holds, and how long collecting it takes, as rpcd does after every call; `rpcd:wireless`, `rpcd:wireguard_peers` and `rpcd:time_daemons` a call of each of the methods the collectors call at every scrape, on the world's configs, sysfs and procd, and the collection after it. Budgets in turns hold them, and timesync, wifi, agh and nat_traffic on 1,000 connections, so that a program run for each call, or rpcd collecting all of the object's modules, does not come back unseen; and `rpcd:wireless` to reading the configs no more while they and the phys are as they were. A `collector:` case's result counts what the collector asked of the world (`asked`): rtnl and nl80211 requests, the watchdog's runs and the programs in them, TCP connections; budgets hold wifi, ethtool and agh to theirs, a count the same on any machine, as a request, a run or a connection is what costs a router most. AdGuard Home's API is a stand-in on 127.0.0.1:8080 that answers the world's replies, as the router's answered. The table's note for a scrape gives the child's peak memory, to size `memory_limit` by.

The worlds have the config the package installs, every option of its main section set, as a router has it: a scrape reads each, and one that read them per collector costs what it costs there.

Narrow it to some cases, or run each more:

```bash
make bench FILTER='typical/scrape'
make bench FILTER='nat_traffic' BENCH_ARGS='-r 20'
```

`-r N` runs each case at least N times, `-t S` for at least S seconds.

## Before and after a change

Bench another revision's `src/` with this checkout's benchmark:

```bash
make bench BENCH_REV=main
make bench
```

The results are `bin/bench/devenv-main.json` and `bin/bench/devenv.json`.

## As a slower router

Limit the container to a share of one CPU:

```bash
make bench FILTER='calibrate' BENCH_CPUS=0.35 BENCH_CPUSET=0
```

Pick `BENCH_CPUS` by `calibrate:vm`'s loop turn, in the same session: the share that makes it match the router's. A container's programs still cost what the host's do, so its whole scrapes are faster than the router's; QEMU is the closer model of a MIPS router. The calibration is in [Performance on small routers](../../explanation/performance.md#calibration).

`BENCH_MEMORY=64m` limits its memory too.

## On a device

```bash
make bench-device HOST=root@router.lan
```

The sources, the benchmark and the worlds are copied to the device's `/tmp`, run there with its own ucode, beside whatever it runs, and removed afterwards; nothing is installed. The device needs `ucode`, `ucode-mod-fs`, `-ubus`, `-uci`, `-rtnl` and `-log`; its `rest:` and `floor:` cases are the benchmark's process's, as uhttpd cannot run the source tree there. The result is `bin/bench/<HOST>.json`, or `BENCH_DEVICE_LABEL=` names it.

## In QEMU, as a MIPS router

```bash
make bench-qemu
make bench-qemu QEMU_SHIFT=2
make bench-qemu QEMU_ENDIAN=be
```

OpenWrt's malta target in qemu-system-mipsel: a MIPS 24Kc, `mipsel_24kc` packages as MT7621-class routers have, with the built packages installed from the release's feed. `QEMU_ENDIAN=be` runs malta's big-endian image in qemu-system-mips instead, with the `mips_24kc` packages of ath79-class routers, the most common small ones; its result is `bin/bench/qemu-malta-be-shift<N>.json`. `QEMU_SHIFT=1` runs it at 500 MIPS, `2` at 250.

`QEMU_MEMORY=64` runs it in a guest of 64 MB. Before the bench, the guest says what the install added to its flash, each package's installed size (`size:` lines), and, while the service runs as installed, what its uhttpd holds, what the guest has left and how many collectors it serves (`service:` lines). Then it checks, on the installed exporter, what reads data in the CPU's own byte order: the auxiliary vector's page size and clock tick, sockstat's bytes against its pages, and basic auth's hashes. Each check is a `check:` line of the output, and one that fails fails the target. It downloads the release's images and packages the first time, into `bin/qemu/`, and it is slow: narrow it with `FILTER=`.

---

The worlds are generated by `test/bench/gen.uc` from a seed, with the fixtures as templates, so every machine reads the same; `make bench-worlds` writes them to `bin/bench/worlds/`. What the cases are, and what the results mean, is in [Performance on small routers](../../explanation/performance.md).

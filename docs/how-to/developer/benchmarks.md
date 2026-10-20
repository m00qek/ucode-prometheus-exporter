# How to Run the Benchmark

The benchmark times each collector, and whole scrapes, on generated worlds. A world is what a router's `/proc`, `/sys`, ubus, netlink and programs would give. Run the benchmark to see what a change costs. You can run it here, in a container limited like a slower router, on a device, or in QEMU as a MIPS router.

## In the development environment

```bash
make bench
```

It prints a table, writes `bin/bench/devenv.json`, and checks the budgets in `test/bench/budgets.uc`. It always checks the scaling and memory budgets, and also the time budgets when the container is unconstrained. CI runs the same.

The cases, by prefix. A "budget" is a limit in `test/bench/budgets.uc` that fails the run when exceeded.

- **`scrape:`** runs each collector in a child process, as the service does. Its **`inline:`** twin runs them all in the scrape's own process. The difference is what that containment costs, and a budget holds it.
- **`handler:`** is the scrape as Prometheus gets it. The benchmark starts uhttpd with the service's handler (`test/bench/handler.uc`, which makes the collectors read the world) and asks it with wget. So the case also counts the request's process, the ledger, the progress file and the deadline. Its note gives:
    - what the scrape takes besides its collectors (`outside`, leaving out wget's own time), which a budget holds
    - the descriptors and memory of the uhttpd process

    It runs where uhttpd and its ucode plugin are installed and can find this exporter. In the container, `make bench` links the source tree into `/usr/share/ucode`. QEMU's guest has the packages installed.
- **`load:`** and **`probe:full`** load the collectors as uhttpd does. `probe:` first loads each in a child process. Their note gives the descriptors that loading left open, which a budget also holds.
- **`rest:base`** and **`rest:full`** measure what the handler's process holds once it has loaded a set, as uhttpd holds it for as long as it runs. That is its private memory (RssAnon), minus what it held before it compiled the handler's program. A budget holds it.
- **`lazy:`** cases time what a process pays the first time it needs a module:
    - the exposition parser, which a scrape loads where a collector parses
    - zlib, ubus, rtnl and nl80211, which uhttpd loads when it starts, so a scrape no longer pays for them
- **`floor:base`** and **`floor:full`** find the smallest `memory_limit`, in whole MB, under which uhttpd loads the handler with the set and a typical scrape has every collector succeed. Each of the processes is limited as procd limits the service's. A budget holds the result to `memory_limit`'s minimum, 8 MB. On a device whose installed exporter is not the source tree's, uhttpd cannot run this one. There, these cases limit the benchmark's scrape process instead, and say so (`by scrape`).
- **`progress:full`** is a scrape's progress file.
- **`record:`** cases time the recorder alone, with a sample of each shape collectors write. **`noop:1`** and **`noop:41`** scrape collectors that write nothing. The note of `noop:41` gives what a scrape costs per collector, apart from the collector itself. Budgets hold both. The `noop:41` budget is in turns of `calibrate:vm`'s loop, so it holds on any machine.
- **`rpcd:`** cases run in their own process (`test/bench/rpcd.uc`), which holds what rpcd's plugin holds for the ubus object.
    - `rpcd:rest` measures what the process holds, which a budget holds, and how long collecting it takes, as rpcd collects after every call.
    - `rpcd:wireless`, `rpcd:wireguard_peers` and `rpcd:time_daemons` each time a call of a method the collectors call at every scrape, on the world's configs, sysfs and procd, plus the collection after it.

    Budgets in turns of `calibrate:vm`'s loop hold these cases, and timesync, wifi, agh and nat_traffic on 1,000 connections. So if a change runs a program for each call, or makes rpcd collect all of the object's modules, the benchmark catches it. A budget also holds `rpcd:wireless` to not reading the configs again while they and the phys are unchanged.
- **`collector:`** cases count what the collector asked of the world (`asked`): rtnl and nl80211 requests, the watchdog's runs and the programs in them, and TCP connections. Budgets hold wifi, ethtool and agh to their counts. A count is the same on any machine, and a request, a run or a connection is what costs a router most. AdGuard Home's API is a stand-in on 127.0.0.1:8080 that answers with the world's replies, as the router's API answered.

For a scrape, the table's note gives the child's peak memory, to size `memory_limit` by.

The worlds have the config the package installs, with every option of its main section set, as on a router. A scrape reads each option. So a change that made each collector read them would cost here what it costs on a router.

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

Pick `BENCH_CPUS` by `calibrate:vm`'s loop turn, in the same session: choose the share that makes the turn match the router's. A container's programs still cost what the host's do, so its whole scrapes are faster than the router's. QEMU is the closer model of a MIPS router. [Performance on small routers](../../explanation/performance.md#calibration) has the calibration.

`BENCH_MEMORY=64m` also limits the container's memory.

## On a device

```bash
make bench-device HOST=root@router.lan
```

The target copies the sources, the benchmark and the worlds to the device's `/tmp`. It runs them there with the device's own ucode, beside whatever else the device runs, and removes them afterwards. It installs nothing.

The device needs `ucode`, `ucode-mod-fs`, `-ubus`, `-uci`, `-rtnl` and `-log`. Its `rest:` and `floor:` cases measure the benchmark's process, since uhttpd cannot run the source tree there. The result is `bin/bench/<HOST>.json`, or the name `BENCH_DEVICE_LABEL=` gives.

## In QEMU, as a MIPS router

```bash
make bench-qemu
make bench-qemu QEMU_SHIFT=2
make bench-qemu QEMU_ENDIAN=be
```

This runs OpenWrt's malta target in qemu-system-mipsel: a MIPS 24Kc, with the `mipsel_24kc` packages that MT7621-class routers use. It installs the built packages, and their dependencies from the release's feed.

- `QEMU_ENDIAN=be` runs malta's big-endian image in qemu-system-mips instead, with the `mips_24kc` packages of ath79-class routers, the most common small ones. Its result is `bin/bench/qemu-malta-be-shift<N>.json`.
- `QEMU_SHIFT=1` runs the guest at 500 MIPS, and `2` at 250.
- `QEMU_MEMORY=64` runs it in a guest of 64 MB.

Before the benchmark, the guest reports:

- what the install added to its flash, and each package's installed size (`size:` lines)
- while the service runs as installed: what its uhttpd holds, what the guest has left, and how many collectors it serves (`service:` lines)

Then, on the installed exporter, it checks the code that reads data in the CPU's own byte order: the auxiliary vector's page size and clock tick, sockstat's bytes against its pages, and basic auth's hashes. Each check is a `check:` line of the output. If one fails, the target fails.

The first time, the target downloads the release's images and packages into `bin/qemu/`. It is slow: narrow it with `FILTER=`.

---

`test/bench/gen.uc` generates the worlds from a seed, with the fixtures as templates, so every machine reads the same worlds. `make bench-worlds` writes them to `bin/bench/worlds/`. [Performance on small routers](../../explanation/performance.md) explains the cases and what the results mean.

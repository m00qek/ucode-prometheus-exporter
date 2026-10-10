# How to Package a Collector

Every collector is in the base package or in a package of its own, `ucode-prometheus-exporter-<name>`. Both are declared in `openwrt/ucode-prometheus-exporter/Makefile`.

## Prerequisites

- The collector, `src/prometheus/collectors/<module>.uc`, and its unit test. See [Collector interface](../../reference/collector-interface.md).

---

## 1. Choose its package

- **The base package** only for what every device has, and only when it needs nothing the base package does not bring. Add its module to `BASE_COLLECTORS`:

    ```makefile
    BASE_COLLECTORS:=conntrack cpu ... uname vmstat <module>
    ```

- **A package of its own** for anything else. Add a `Collector` line, in the order of the module names:

    ```makefile
    $(eval $(call Collector,<module>,<name>,<what it collects>,<dependencies>))
    ```

    | Argument | Content |
    | :--- | :--- |
    | `<module>` | The module's file name, without `.uc`: `ltq_dsl`. |
    | `<name>` | `meta.name`, the package's suffix: `ltq-dsl`. |
    | `<what it collects>` | A few words, added to the package's title: `Lantiq DSL line`. No commas. |
    | `<dependencies>` | `+package` for what the collector reads with, space-separated: `+ucode-mod-nl80211` for `nl80211`, `+ucode-mod-socket` for `socket`, the package of a program it runs on any device (`+tc`, `+ethtool`). Never what it watches: installing a collector must not install and start mwan3 or chrony. A program that comes with what it watches (`chronyc`, `mmcli`) goes in `meta.optional_commands` instead, and where it is missing the collector has nothing to observe. Empty for none; `make test` checks it. |

    The macro makes a package that installs the module, depends on the base package of the same version, and reloads an enabled service when it is installed or removed.

## 2. Add it to a group

If every router or access point should have it, add its name to a group's list:

```makefile
NETWORK_GROUP:=ethtool nat_traffic netstat nft-counters qdisc snmp6 sockstat <name>
```

`FULL_GROUP` holds the other three and more. Leave out a collector of particular hardware or of an optional service.

## 3. Check

```bash
make test
make docs-gen
make lint
make package-check
```

- `test/integration/collectors_test.uc` holds every collector to one package, named after it, whose dependencies cover its needs and commands. A new program needs an entry in its `COMMAND_PACKAGES`.
- `make docs-gen` adds it to the reference: its package and groups to [Collectors](../../reference/collectors.md), its families to [Metrics](../../reference/metrics.md). If it can have nothing to observe, or declares a family no fixture makes it write, the generator says what to add to `docs/gen/notes.uc`.
- `make package-check` builds and installs every package, the new one too.
- Add the collector to `NOTICE` when it ports an upstream collector.

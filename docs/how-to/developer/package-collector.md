# How to Package a Collector

Every collector is in the base package or in its own package, `ucode-prometheus-exporter-<name>`. `openwrt/ucode-prometheus-exporter/Makefile` declares both.

## Prerequisites

- The collector, `src/prometheus/collectors/<module>.uc`, and its unit test. See [Collector interface](../../reference/collector-interface.md).

---

## 1. Choose its package

- **The base package**, only for what every device has, and only when the collector needs nothing beyond what the base package brings. Add its module to `BASE_COLLECTORS`:

    ```makefile
    BASE_COLLECTORS:=conntrack cpu ... uname vmstat <module>
    ```

- **A package of its own**, for anything else. Add a `Collector` line, in alphabetical order of the module names:

    ```makefile
    $(eval $(call Collector,<module>,<name>,<what it collects>,<dependencies>))
    ```

    | Argument | Content |
    | :--- | :--- |
    | `<module>` | The module's file name, without `.uc`: `ltq_dsl`. |
    | `<name>` | `meta.name`, the package's suffix: `ltq-dsl`. |
    | `<what it collects>` | A few words, added to the package's title: `Lantiq DSL line`. No commas. |
    | `<dependencies>` | `+package` for what the collector reads with, space-separated: `+ucode-mod-nl80211` for `nl80211`, `+ucode-mod-socket` for `socket`, the package of a program it runs on any device (`+tc`, `+ethtool`). Never what it watches: installing a collector must not install and start mwan3 or chrony. A program that comes with what it watches (`chronyc`, `mmcli`) goes in `meta.optional_commands` instead, and where it is missing the collector has nothing to observe. Empty for none; `make test` checks it. |

    The macro makes a package that installs the module and depends on the base package of the same version. The package reloads an enabled service when it is installed or removed.

## 2. Add it to a group

If every router or access point should have it, add its name to a group's list:

```makefile
NETWORK_GROUP:=ethtool nat_traffic netstat nft-counters qdisc snmp6 sockstat <name>
```

`FULL_GROUP` holds the other three groups and more. Leave out a collector for particular hardware or for an optional service.

## 3. Check

```bash
make test
make docs-gen
make lint
make package-check
```

- `test/integration/collectors_test.uc` checks that every collector is in exactly one package, named after it, whose dependencies cover the collector's needs and commands. A new program needs an entry in the test's `COMMAND_PACKAGES`.
- `make docs-gen` adds the collector to the reference: its package and groups to [Collectors](../../reference/collectors.md), its families to [Metrics](../../reference/metrics.md). If the collector can have nothing to observe, or declares a family no fixture makes it write, the generator says what to add to `docs/gen/notes.uc`.
- `make package-check` builds and installs every package, including the new one.
- Add the collector to `NOTICE` when it ports an upstream collector.

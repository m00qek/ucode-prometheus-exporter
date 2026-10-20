# How to Capture Fixtures from a Device

The tests, the benchmark's worlds and the metrics reference read what real devices answered, from `test/fixtures/<set>/`. When you write a collector for something the sets do not cover yet, capture a device's answers.

## Prerequisites

- ssh access to the device, as root, with `ucode` on it (OpenWrt 25.12 has it).
- The device runs what the collector reads.

---

## 1. Say what to read

Add the sources to `test/fixtures/SOURCES`, one per line:

| Line | Captures |
| :--- | :--- |
| `file PATH` | The file, or every file the glob matches, at its own path. |
| `ubus OBJECT METHOD [ARGS]` | The reply, as `ubus/OBJECT.METHOD.json`. |
| `link GLOB` | Where each symlink the glob matches leads, into `links.json`. |
| `uci CONFIG` | The config's sections, as `uci/CONFIG.json`, without secret options (keys, passwords). |

## 2. Capture

```bash
make fixtures HOST=root@router.lan NAME=my-router
```

Everything is read-only on the device. The target adds only files that are not in `test/fixtures/my-router/` yet, so the values the tests assert on do not change under them. `FORCE=1` replaces them all.

Capture by hand, into the same set, what `make fixtures` cannot read, and say how in comments in `SOURCES`:

- a program's output, as `commands/<program>_<arguments>.txt` (`commands/ethtool_S_lan.txt` for `ethtool -S lan`)
- an rtnetlink or nl80211 reply, as `rtnl/<CMD>.json` or `nl80211/<CMD>.<device>.json`

## 3. Redact

Before you commit, replace in every file of the set:

- MAC addresses, with locally administered ones, `02:00:00:…`
- public IP addresses, with `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` or `2001:db8::/32`
- SSIDs, hostnames, domain names, user names and keys

uci captures leave out secret options, but they keep names and addresses.

## 4. Name the set in the docs

The metrics reference runs every collector on every set, and names each set without the device's name. Add the new set to `capture_sets` in `docs/gen/notes.uc`, then run:

```bash
make docs-gen
```

---

What no captured device has is written by hand in `test/fixtures/synthetic/`. `test/fixtures/synthetic/SOURCES` gives the format each file follows.

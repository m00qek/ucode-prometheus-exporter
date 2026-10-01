# How to Capture Fixtures from a Device

The tests, the benchmark's worlds and the metrics reference read what real devices answered, from `test/fixtures/<set>/`. Capture a device's answers when you write a collector for something the sets do not have yet.

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

Everything is read-only on the device. Only files not there yet are added to `test/fixtures/my-router/`, so the values tests assert on do not change under them; `FORCE=1` replaces them all.

What `make fixtures` cannot read, capture by hand into the same set and say how in `SOURCES`' comments: a program's output as `commands/<program>_<arguments>.txt` (`commands/ethtool_S_lan.txt` for `ethtool -S lan`), an rtnetlink or nl80211 reply as `rtnl/<CMD>.json` or `nl80211/<CMD>.<device>.json`.

## 3. Redact

Before you commit, replace in every file of the set:

- MAC addresses, with locally administered ones, `02:00:00:…`;
- public IP addresses, with `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` or `2001:db8::/32`;
- SSIDs, hostnames, domain names, user names and keys.

uci captures leave out secret options, but not names and addresses.

## 4. Name the set in the docs

The metrics reference runs every collector on every set, and names each set without its device's name. Add the new set to `capture_sets` in `docs/gen/notes.uc`, then:

```bash
make docs-gen
```

---

What neither device has is written by hand in `test/fixtures/synthetic/`, each file with the format it follows in `test/fixtures/synthetic/SOURCES`.

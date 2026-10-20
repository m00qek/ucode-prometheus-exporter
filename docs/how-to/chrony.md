# How to Monitor chrony

Two collectors watch the clock when chronyd keeps it:

- **timesync**, in the base package, says whether the clock is synchronized, whichever daemon keeps it: busybox ntpd or chronyd. It writes `node_timesync_synchronized{daemon="chronyd"}`, and the daemon's stratum, offset and last update.
- **chrony**, in its own package, writes chronyd's details with chrony_exporter's names: its tracking, each source, and its server statistics where it serves time.

Use timesync to alert when the clock is not synchronized. Add chrony to see why.

## Prerequisites

- chrony is installed and running: the `chrony` (or `chrony-nts`) package, its service enabled, and its servers in `/etc/config/chrony`.
- The base package is installed.

---

## 1. Install the chrony collector

```sh
apk add ucode-prometheus-exporter-chrony
```

The service reloads with it.

## 2. Check it

```sh
service prometheus-exporter check | grep -e chrony -e timesync
wget -qO- 'http://127.0.0.1:9100/metrics?collect[]=chrony&collect[]=timesync' | grep -e '^chrony_tracking_stratum' -e '^node_timesync_synchronized'
```

```
chrony_tracking_stratum 3
node_timesync_synchronized{daemon="chronyd"} 1
```

If busybox ntpd runs too, timesync writes a series for each daemon: `daemon="ntpd"` and `daemon="chronyd"`. Only one should keep the clock. Turn the system's NTP client off, in LuCI's **System → System → Time Synchronization** or with `uci set system.ntp.enabled=0`.

---

## Server statistics

A scrape of `/metrics` never holds chronyd's server statistics, `chrony_serverstats_*`. Here is why:

- chronyd answers them only on its Unix command socket.
- `chronyc` reaches that socket only by creating a socket of its own beside it, in `/var/run/chrony`.
- Write access there would let the exporter command chronyd, which sets the clock. So the exporter's jail does not give it.

Under procd, the collector asks over chronyd's UDP command port instead, as `chronyc` falls back to. That port answers tracking and sources, but not the server statistics.

`prometheus-exporter scrape chrony` also runs in the service's jail, so it does not show them either. To see them on the device, ask chronyd:

```sh
chronyc serverstats
```

## If it fails

| `check` or the log says | Cause |
| :--- | :--- |
| `chrony has nothing to observe: chronyd is disabled` | chronyd's init script is disabled. Nothing is wrong. |
| `chrony: COMMAND_FAILED (chronyc: exit status 1)` | chronyd is enabled and does not answer: it is stopped, or does not answer on its command port. |
| `timesync has nothing to observe: neither ntpd nor chronyd runs` | No NTP daemon runs. |
| `timesync: SOURCE_UNREADABLE (chronyd is enabled and not running)` | chronyd is enabled at boot, and stopped. |

See [Collectors](../reference/collectors.md#chrony) and [Metrics](../reference/metrics.md#chrony).

# How to Monitor chrony

Two collectors watch the clock when chronyd keeps it:

- **timesync**, in the base package, says whether the clock is synchronized, whichever daemon keeps it, busybox ntpd or chronyd: `node_timesync_synchronized{daemon="chronyd"}`, its stratum, offset and last update.
- **chrony**, a package of its own, has chronyd's details, as chrony_exporter names them: its tracking, each source, and its server statistics where it serves time.

Use timesync to alert on a clock that is not synchronized; add chrony for why.

## Prerequisites

- chrony is installed and runs: `chrony` (or `chrony-nts`), its service enabled, `/etc/config/chrony` holding its servers.
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

With busybox ntpd running too, timesync writes a series for each, `daemon="ntpd"` and `daemon="chronyd"`. Only one should keep the clock: turn the system's NTP client off, in LuCI's **System → System → Time Synchronization** or with `uci set system.ntp.enabled=0`.

---

## Server statistics

chronyd's server statistics, `chrony_serverstats_*`, are never in a scrape of `/metrics`. chronyd answers them on its Unix command socket only, and `chronyc` reaches that socket only by making one of its own beside it, in `/var/run/chrony`. Writing there is commanding chronyd, which sets the clock, so the exporter's jail does not give it: under procd the collector asks over chronyd's UDP command port, as `chronyc` falls back to, which answers tracking and sources, and leaves the server statistics out.

Outside the jail they are read where chronyd serves time, an `allow` section in `/etc/config/chrony`. To see them on the device:

```sh
prometheus-exporter chrony | grep '^chrony_serverstats_'
```

## If it fails

| `check` or the log says | Cause |
| :--- | :--- |
| `chrony has nothing to observe: chronyd is disabled` | chronyd's init script is disabled. Nothing is wrong. |
| `chrony: COMMAND_FAILED (chronyc: exit status 1)` | chronyd is enabled and does not answer: it is stopped, or does not answer on its command port. |
| `timesync has nothing to observe: neither ntpd nor chronyd runs` | No NTP daemon runs. |
| `timesync: SOURCE_UNREADABLE (chronyd is enabled and not running)` | chronyd is enabled at boot, and stopped. |

See [Collectors](../reference/collectors.md#chrony) and [Metrics](../reference/metrics.md#chrony).

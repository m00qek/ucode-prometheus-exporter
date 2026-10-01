# The `prometheus-exporter` Command

`/usr/bin/prometheus-exporter` prints a scrape on standard output, as `/metrics` answers it. The base package installs it.

```
usage: prometheus-exporter [-h] [-l] [-d DIR] [COLLECTOR...]
  -h      show this help
  -l      list the installed collectors
  -d DIR  load the collectors from DIR
```

---

## Arguments

| Argument | Description |
| :--- | :--- |
| `COLLECTOR...` | The collectors to scrape, by name (`ltq-dsl`) or module (`ltq_dsl`), in that order. Without any, every enabled collector, as a scrape without `collect[]`. Each is passed as `collect[]=<name>`: see [HTTP endpoint](http.md#query-string). |
| `-l` | Print one line per installed collector, its name and its help, and exit. |
| `-d DIR` | Load the collectors from `DIR` instead of `/usr/share/ucode/prometheus_exporter/collectors`. |
| `-h` | Print the usage and exit. |

## Exit status

| Status | When |
| :--- | :--- |
| `0` | The scrape was printed, or `-l` or `-h` was given. |
| `1` | The scrape was refused: a collector that is not installed, or one that is disabled. Its message is on standard error, as `COLLECTOR_INVALID (unknown collector 'nope')`. |
| `2` | An option it does not take. The usage is on standard error. |

## Behavior

- It reads the committed configuration, as the service does: a collector disabled in `/etc/config/prometheus-exporter` is left out, and naming it is refused.
- What the exporter logs goes to standard error, whatever its level: a collector that fails, a module the loader leaves out.
- It runs as the user who runs it, outside the jail. A collector that works here and fails under the service lacks something in the jail: see [The jail](jail.md).
- It never compresses and never asks for basic auth: those are the HTTP endpoint's.
- The build info's `version` is the package's, `<version>-r<release>`, or `dev` from a source tree.

## Examples

```sh
prometheus-exporter -l
prometheus-exporter loadavg
prometheus-exporter wifi ltq-dsl
```

```
$ prometheus-exporter loadavg
# HELP node_load1 1m load average.
# TYPE node_load1 gauge
node_load1 0.72
...
ucode_prometheus_exporter_build_info{version="0.1.0-r1"} 1
```

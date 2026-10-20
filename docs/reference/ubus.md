# ubus Object

The ubus object `prometheus-exporter` belongs to the base package. rpcd serves it whether or not the service runs. It serves it from the ucode plugin `/usr/share/rpcd/ucode/prometheus-exporter.uc`, which uses `src/prometheus/exporter/rpc.uc` and its modules `rpc/describe.uc`, `rpc/validate.uc`, `rpc/sources.uc` and `rpc/plugin.uc`. rpcd loads the plugin when it starts or reloads, and the package reloads rpcd when it is installed, upgraded or removed.

rpcd keeps the methods [for the collectors](#for-the-collectors) loaded all the time, with `rpc/sources.uc` only. It compiles the other methods, with `rpc.uc` and all it imports, when one of them is called, and drops them 120 s after the last such call. The reason: after every call of a plugin's methods, rpcd collects the plugin's garbage, in a pass over everything the plugin holds, and the collectors call their methods at every scrape. See [Performance on small routers](../explanation/performance.md#the-ubus-objects-sources).

The object reads with the exporter's own modules. The only thing it writes is the hash of basic auth's password, through `set_password`. Each call reads the committed configuration and the installed collectors afresh.

```
$ ubus -v list prometheus-exporter
'prometheus-exporter' @085bb3ca
	"collectors":{}
	"validate":{"main":"Table","collectors":"Table"}
	"status":{}
	"interfaces":{}
	"hash_password":{"password":"String"}
	"password":{}
	"set_password":{"password":"String"}
	"wireless":{}
	"wireguard_peers":{}
	"time_daemons":{}
```

---

## Methods

| Method | Arguments | Reply |
| :--- | :--- | :--- |
| [`collectors`](#collectors) | none | `{ collectors: [ collector ], skipped: [ message ] }` |
| [`validate`](#validate) | `{ main?, collectors? }` | `{ ok, errors: { main: { <option>: refusal }, collectors: { <module>: { <option>: refusal } } } }` |
| [`status`](#status) | none | `{ service: { enabled, boot, running, error, auth, compress }, listen: [ url ], collectors: [ result ], jailed }` |
| [`interfaces`](#interfaces) | none | `{ interfaces: [ { name, proto } ] }` |
| [`hash_password`](#hash_password) | `{ password }` | `{ hash }` |
| [`password`](#password) | none | `{ saved }` |
| [`set_password`](#set_password) | `{ password }` | `{ saved }` |
| [`wireless`](#for-the-collectors) | none | `{ radios: { <radio>: { disabled, config: { channel, country, htmode }, interfaces: [ { ifname, config: { ssid, mesh_id, encryption } } ] } } }` |
| [`wireguard_peers`](#for-the-collectors) | none | `{ interfaces: { <interface>: { <public key>: <description> } } }` |
| [`time_daemons`](#for-the-collectors) | none | `{ running: { sysntpd, chronyd } }` |

A call with malformed arguments, or one that fails, gets the reply `{ error, message }`. See [Errors](#errors).

## `collectors`

Every installed collector, sorted by name, and the messages of the modules the loader left out (`skipped`).

| Field of a collector | Type | Content |
| :--- | :--- | :--- |
| `name` | string | Its name, as `collect[]` takes it. |
| `id` | string | Its module: the name of its section. |
| `title`, `help` | string | `meta.title` and `meta.help`. |
| `enabled` | boolean | Whether its section enables it. |
| `package` | string or null | The package that installed it, from apk's file lists; null when no package did. |
| `base` | boolean or null | Whether that package is the base package. |
| `options` | array | Its own options, in the order it declares them. For a collector that runs programs, the core's `timeout` follows them. |
| `needs`, `configs`, `commands` | array | `meta.needs`, `meta.configs`, `meta.commands`. |
| `jail` | object | What the jail gives it: `paths`, `owned`, `commands` (`{ <name>: <path or null> }`), `mounts`, `problems`, `missing`. See [The jail](jail.md). |
| `error` | string or null | The first option of its section that the exporter does not accept, as `CODE (detail)`. |

| Field of an option | Type | Content |
| :--- | :--- | :--- |
| `name` | string | The option's name. |
| `core` | boolean | `true` for the core's `timeout`, `false` for the collector's own. |
| `title` | string | Its label, as the collector declares it: `Excluded devices`. The core's `timeout` is `Program timeout`. |
| `type` | string | `bool`, `int` or `string`: the type of its default. |
| `default` | any | Its default. For `timeout`, the seconds it gets while unset. |
| `default_from` | string | `timeout` only: where the default's seconds come from, `meta.timeout` or `exec_timeout`. |
| `help` | string or null | What it does. |
| `datatype` | string or null | See [UCI configuration](uci-config.md#values). |
| `value` | any | Its value as the exporter reads it. When the exporter does not accept it, the value as uci holds it. |
| `set` | boolean | Whether its section sets it. |
| `error` | string or null | What the exporter expected, for a value it does not accept. |

## `validate`

Checks values as the exporter would read them, without saving anything. `main` holds options of the main section. `collectors` holds options of collector sections, by module. Values are given as uci holds them: as strings.

```
$ ubus call prometheus-exporter validate '{"main":{"listen_port":"0","auth_user":"p"}}'
{
	"ok": false,
	"errors": {
		"main": {
			"listen_port": {
				"code": "RANGE",
				"min": 1,
				"max": 65535,
				"value": 0,
				"message": "expected an integer from 1 to 65535, got 0"
			},
			"auth_password": {
				"code": "AUTH_NEEDS_PASSWORD",
				"message": "basic auth needs the hash of a password along with auth_user"
			},
			"auth_user": {
				"code": "AUTH_NEEDS_TLS",
				"message": "basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear"
			}
		},
		"collectors": {

		}
	}
}
```

For each value it refuses, `validate` answers a refusal. A refusal says what is wrong with the value as a code, which a client can put in its own words, as LuCI does. It also carries the exporter's English message.

| Field of a refusal | Type | Content |
| :--- | :--- | :--- |
| `code` | string | What is wrong: one of the closed set in [UCI configuration](uci-config.md#problems), such as `RANGE` or `AUTH_NEEDS_TLS`. |
| `min`, `max` | integer | The arguments of the codes that take them: `RANGE`'s bounds, `CRYPT_ROUNDS`' most rounds. |
| `value` | any | What the exporter read: an integer for `RANGE` and `UINTEGER`, a list where it got one, a string otherwise. Absent from `auth_password`'s refusal, and from the codes of options that go together. |
| `message` | string | The exporter's English message, without the option's name, as `check` and the log say it. |

A client that does not know a code shows `message`.

- Each value is checked alone. An empty value is unset, and takes the default.
- Options nobody declared, and collectors that are not installed, are ignored, as the exporter ignores them.
- Some of the main section's options go together: basic auth's user, the hash, and the `cert` and `key` that basic auth needs. They are checked as if the values given were the whole section.
- `auth_password`, the hash, is accepted among `main`'s options, though it is saved apart (see [`set_password`](#set_password)). When it is not given, a user given is checked against the saved hash. The saved hash is never answered.
- A collector section accepts `enabled`, `budget`, the collector's own options, and `timeout` for a collector that runs programs.
- No refusal holds the value of `auth_password`.

## `status`

Runs one scrape of the enabled collectors, and replies when it is done. It runs them as the service's scrapes do: in the service's own jail, with ujail, where it can; each collector in a process of its own, stopped at its budget, within `scrape_timeout`. It runs a collector the service quarantined all the same.

rpcd runs the scrape in a process of its own, `/usr/libexec/prometheus-exporter/rpc-status.uc`, and answers other calls meanwhile. Among them are the collectors' calls to objects rpcd serves: `wireguard`, this object's own, and `prometheus-exporter.filesystem`. If that process is still running after 60 s, rpcd kills it, with all it started.

One scrape runs at a time. A call made while one runs waits for it, and gets its reply. So repeated calls, such as from a page being refreshed, never run more than one scrape at once.

| Field | Type | Content |
| :--- | :--- | :--- |
| `service.enabled` | boolean or null | `option enabled` of the main section; null when that section is not valid. |
| `service.boot` | boolean | Whether the boot link `/etc/rc.d/S*prometheus-exporter` is there. |
| `service.running` | boolean or null | Whether procd runs the uhttpd instance; null when procd cannot be asked. |
| `service.error` | string or null | Why procd could not be asked. |
| `service.auth` | boolean or null | Whether basic auth is configured. |
| `service.compress` | boolean or null | `option compress`. |
| `listen` | array | The URLs the running instance listens on, as `http://*:9100/metrics`. |
| `collectors` | array | One result per installed collector, sorted by name. |
| `jailed` | boolean | Whether the scrape ran in the service's jail; `false` where ujail cannot run, as for a process that is not root's. |

| Field of a result | Type | Content |
| :--- | :--- | :--- |
| `name`, `id`, `title` | string | As in `collectors`. |
| `enabled` | boolean | Whether it ran: a disabled collector does not. |
| `success` | boolean or null | Whether it succeeded; null when it did not run. |
| `observing` | boolean or null | `false` for a collector with nothing to observe, `true` for any other that ran, null when it did not run. |
| `reason` | string or null | Why it has nothing to observe, as `dnsmasq is disabled`. |
| `duration` | number or null | Its seconds. |
| `error` | string or null | Why it failed, as `CODE (detail)`. |
| `mounts` | array | What the jail mounts for it; empty when it is disabled. |
| `service` | object or null | What the service's own scrapes found of it, from the ledger of its running instance (see [The jail](jail.md#the-ledger)); null when the ledger has nothing of it. |

| Field of `service` | Type | Content |
| :--- | :--- | :--- |
| `estimate` | number or null | Its seconds, as the ledger averages them; null before it ran. |
| `quarantined` | boolean | Whether its circuit breaker is open, or its trial is due. |
| `reason` | string or null | What tripped its breaker, as `CODE (detail)`. |
| `retry_in` | integer or null | The scrapes until its trial: 1 for the next. |
| `late` | integer or null | The scrapes since the deadline last left it out: 0 for the service's last scrape. |

## `interfaces`

The logical interfaces netifd has, in its order, as `network.interface dump` gives them: `name`, and `proto` (null when it has none). It never reads `/etc/config/network`.

```
$ ubus call prometheus-exporter interfaces
{
	"interfaces": [
		{
			"name": "lan",
			"proto": "static"
		},
		{
			"name": "loopback",
			"proto": "static"
		}
	]
}
```

## `hash_password`

A SHA-512-crypt hash of `password`, with 1000 rounds and a fresh salt of 16 characters, for `auth_password`:

```
$ ubus call prometheus-exporter hash_password '{"password":"…"}'
{
	"hash": "$6$rounds=1000$…"
}
```

The password is 1 to 256 bytes, without control characters. rpcd runs the method unjailed, and logs neither the password nor the hash.

## `password`

Whether a hash of basic auth's password is saved, in `/etc/config/prometheus-exporter-auth`: `{ "saved": true }`. It never answers the hash.

## `set_password`

Hashes `password` as `hash_password` does, and saves the hash in `/etc/config/prometheus-exporter-auth`. It then commits that config, and sends procd the config's `config.change` event, which reloads the service as `reload_config` would. It replies `{ "saved": true }`. An empty `password` removes the saved hash: `{ "saved": false }`. The reply never holds the hash.

```
$ ubus call prometheus-exporter set_password '{"password":"…"}'
{
	"saved": true
}
```

Basic auth is on while the main section's `auth_user` is set. A hash saved without a user is unused, and a user without a hash is refused. The change applies at once, apart from any change staged in uci: neither a rollback nor `uci revert` undoes it.

LuCI changes and removes the password this way, with its **Change password…** and **Remove password** buttons, apart from Save & Apply. LuCI's ACL grants this method to a login that may write, and grants nothing of `/etc/config/prometheus-exporter-auth`. See [LuCI app](luci.md#basic-auth-password).

## For the collectors

Three methods give collectors data that the service's user may not be allowed to read itself. Each asks its source as root, and answers only the part the collectors read. Each takes no arguments, and answers no key, password or command line. The service's ACL allows each method while a collector that calls it is enabled. LuCI's ACL grants none of them. See [About the security model](../explanation/security.md#what-the-services-user-reaches-over-ubus).

| Method | Asks, as root | Answers of it | For |
| :--- | :--- | :--- | :--- |
| `wireless` | uci's `wireless` config, which holds each network's `key`, and its `network` config's interfaces; sysfs's phys | Each radio's `disabled`, its config's `channel`, `country` and `htmode`, and for each of its networks the config's `ssid`, `mesh_id` and `encryption`, with the interface netifd names it (`ifname`), where netifd sets it up; `{ radios: {} }` without a wireless config | wifi, hostapd_stations |
| `wireguard_peers` | uci's `network` config, whose peer sections hold the preshared keys and whose interfaces hold the private keys | The `description` of each `wireguard_<interface>` section that has one, by interface and `public_key` | wireguard, with `peer_names` |
| `time_daemons` | procd's `service list` of `sysntpd` and of `chronyd`, which holds each instance's command line and environment | Whether an instance of each runs its daemon, `/usr/sbin/ntpd` and `/usr/sbin/chronyd` | timesync |

```
$ ubus call prometheus-exporter wireless
{ "radios": { "radio0": { "disabled": false, "config": { "channel": "36", "country": "DE", "htmode": "HE80" }, "interfaces": [ { "ifname": "phy0-ap0", "config": { "ssid": "example", "encryption": "sae" } } ] } } }
```

`wireless` and `wireguard_peers` read uci's committed configs in rpcd's own process, and ask no daemon. `wireless` also reads sysfs.

`wireless` names each network's interface as netifd does, by `mac80211.sh`'s rules. The name is the network's `ifname`. Without one, it is built from:

- the radio's `ifname_prefix`, or else the phy's name, with the radio's index on a phy of several radios (`phy0.1-`);
- the network's mode;
- the network's index among the radio's networks of that mode (`phy0-ap1`).

The phy is the radio's as wifi-scripts find it: by its `path` (`+N` for the Nth of the device's phys), by its `macaddr`, or by its `phy`.

A network that netifd does not set up has no `ifname`. That is a network:

- of a disabled radio, or of a radio without a phy;
- whose logical interfaces are all disabled or `auto '0'`;
- that is an MLO network.

The collectors learn whether each interface is there from nl80211, and whether it is up from sysfs.

rpcd keeps the last reply of `wireless`. It gives the same reply again while the phys and the two configs' files (their inode, size and times) are unchanged. A scrape calls `wireless` twice, for wifi and for hostapd_stations, and the configs rarely change.

`time_daemons` asks procd over a connection of its own, without waiting on it, so rpcd answers other calls meanwhile. A procd that does not answer costs the call 3 s, and never blocks rpcd.

A source that cannot be asked is answered `{ error, message }`, such as `{ "error": "UBUS_CALL_FAILED", "message": "service list sysntpd: Request timed out" }`. The collector then fails with `SOURCE_INVALID`.

## Errors

| `error` | `message` | When |
| :--- | :--- | :--- |
| `ARGS_INVALID` | `main and collectors must be objects`, `collectors.<module> must be an object` | `validate` was given something else. |
| `ARGS_INVALID` | `password: expected a password`, `password: expected a password of at most 256 bytes`, `password: expected a password without control characters` | `hash_password` or `set_password` was given a password it does not take. |
| `FILE_UNWRITABLE` | `FILE_UNWRITABLE (cannot write /etc/config/prometheus-exporter-auth: ...)` | `set_password` could not save the hash. |
| `STATUS_FAILED` | `cannot run /usr/libexec/prometheus-exporter/rpc-status.uc`, `... printed no reply` | `status` could not run its scrape, or the scrape printed no reply (or was killed at 60 s). |
| A [code](error-codes.md) | `CODE (detail)` | `interfaces` could not ask netifd; `hash_password` or `set_password` had no random bytes. |

ubus itself refuses arguments of the wrong type, such as a string for `main`, with `Invalid argument`.

## `prometheus-exporter.filesystem`

The filesystem collector has its own object. The base package has none: the collector's package serves it from the rpcd plugin `/usr/share/rpcd/ucode/prometheus-exporter-filesystem.uc`.

Its one method, `mounts`, takes no arguments. It answers `{ device, mount, fstype, ro, size, free, avail, files, ffree }` for each mount of the host's `/proc/mounts` in which statvfs() finds blocks:

- the device, mount point and filesystem type of its line;
- whether its options have `ro`;
- its sizes, in bytes and in inodes.

statvfs() comes from luci-base's `luci.core`. Without it, or without `/proc/mounts`, `mounts` answers `{ error }`.

This is all the collector asks. It cannot read the mounts from the jail, whose own mounts are not the host's, and it does not use rpcd's `file read`, which reads any file as root (see [About the security model](../explanation/security.md#not-root)). Where rpcd has not loaded the plugin, the collector fails, and says so.

```
$ ubus call prometheus-exporter.filesystem mounts
{ "result": [ { "device": "tmpfs", "mount": "/tmp", "fstype": "tmpfs", "ro": false, "size": 122658816, "free": 122286080, "avail": 122286080, "files": 29946, "ffree": 29890 }, ... ] }
```

Like getMountPoints, it runs statvfs() on every mount, including a network mount that hangs, in rpcd's process.

ucode's fs module has no `statvfs()` on 25.12, so the plugin uses luci-base's `luci.core`. It requires `luci.core` when `mounts` is called, not when rpcd loads the plugin. So a luci-base without it fails the call, and leaves rpcd and its other objects working.

## Access

Over HTTP, through uhttpd-mod-ubus, a session needs the methods in its ACL. The LuCI app's ACL, `luci-app-prometheus-exporter`, grants `collectors`, `interfaces`, `password`, `status` and `validate` to read, and `set_password` to write. See [LuCI app](luci.md#acl).

## See also

- [How to troubleshoot](../how-to/troubleshoot.md)
- [Service commands](service-commands.md#check): `check`, which shows the same on the command line.

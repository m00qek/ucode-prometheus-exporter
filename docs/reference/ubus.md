# ubus Object

The ubus object `prometheus-exporter` belongs to the base package. rpcd serves it, from the ucode plugin `/usr/share/rpcd/ucode/prometheus-exporter.uc`, over `src/prometheus/exporter/rpc.uc` and its modules `rpc/describe.uc` and `rpc/validate.uc`, whether or not the service runs. rpcd loads it when it starts or reloads; the package reloads rpcd when it is installed, upgraded or removed.

The object reads with the exporter's own modules, and writes nothing but the hash of basic auth's password, through `set_password`. Each call reads the committed configuration and the installed collectors afresh.

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

A call with malformed arguments, and one that fails, is answered `{ error, message }`. See [Errors](#errors).

## `collectors`

Every installed collector, in the order of their names, and the messages of the modules the loader left out (`skipped`).

| Field of a collector | Type | Content |
| :--- | :--- | :--- |
| `name` | string | Its name, as `collect[]` takes it. |
| `id` | string | Its module: the name of its section. |
| `title`, `help` | string | `meta.title` and `meta.help`. |
| `enabled` | boolean | Whether its section enables it. |
| `package` | string or null | The package that installed it, from apk's file lists; null when none did. |
| `base` | boolean or null | Whether that is the base package. |
| `options` | array | Its own options, in the order it declares them, then, for a collector that runs programs, the core's `timeout`. |
| `needs`, `configs`, `commands` | array | `meta.needs`, `meta.configs`, `meta.commands`. |
| `jail` | object | What the jail gives it: `paths`, `owned`, `commands` (`{ <name>: <path or null> }`), `mounts`, `problems`, `missing`. See [The jail](jail.md). |
| `error` | string or null | The first option of its section the exporter does not take, as `CODE (detail)`. |

| Field of an option | Type | Content |
| :--- | :--- | :--- |
| `name` | string | The option's name. |
| `core` | boolean | `true` for the core's `timeout`, `false` for the collector's own. |
| `title` | string | Its label, as the collector declares it: `Excluded devices`. The core's `timeout` is `Program timeout`. |
| `type` | string | `bool`, `int` or `string`: the type of its default. |
| `default` | any | Its default. For `timeout`, the seconds it gets while unset. |
| `default_from` | string | `timeout` only: `meta.timeout` or `exec_timeout`, whose seconds the default is. |
| `help` | string or null | What it does. |
| `datatype` | string or null | See [UCI configuration](uci-config.md#values). |
| `value` | any | Its value as the exporter reads it; as uci holds it when the exporter does not take it. |
| `set` | boolean | Whether its section sets it. |
| `error` | string or null | What the exporter expected of a value it does not take. |

## `validate`

Checks values as the exporter would read them, without saving anything. `main` holds options of the main section and `collectors` options of collector sections, by module: values as uci holds them, as strings.

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

Each value it refuses is answered as a refusal: what is wrong with it, by a code a client can say in its own words, as LuCI does, and the exporter's English of it.

| Field of a refusal | Type | Content |
| :--- | :--- | :--- |
| `code` | string | What is wrong: one of the closed set in [UCI configuration](uci-config.md#problems), as `RANGE` or `AUTH_NEEDS_TLS`. |
| `min`, `max` | integer | The arguments of the codes that take them: `RANGE`'s bounds, `CRYPT_ROUNDS`' most rounds. |
| `value` | any | What the exporter read: an integer for `RANGE` and `UINTEGER`, a list where it got one, a string otherwise. Absent from `auth_password`'s, and from the codes of options that go together. |
| `message` | string | The exporter's English of it, without the option's name, as `check` and the log say it. |

A client that does not know a code shows `message`.

- Each value is checked alone. An empty value is unset, and takes the default.
- Options nobody declared, and collectors that are not installed, are ignored, as the exporter ignores them.
- The main section's options that go together, basic auth's user and the hash and the `cert` and `key` it needs, are checked as if the values given were the whole section. `auth_password`, the hash, is taken among `main`'s though it is saved apart (see [`set_password`](#set_password)): without it, a user given is checked with the saved hash, which is never answered.
- A collector section takes `enabled`, `timeout` for a collector that runs programs, `budget`, and the collector's own options.
- No refusal holds the value of `auth_password`.

## `status`

Runs one scrape of the enabled collectors and replies when it is done: in the service's own jail, with ujail, where it can, as the service's scrapes run them (each collector in a process of its own, stopped at its budget, within `scrape_timeout`). rpcd runs it in a process of its own, `/usr/libexec/prometheus-exporter/rpc-status.uc`, and answers other calls meanwhile, the collectors' calls to objects rpcd serves (`wireguard`, `luci`) among them; it kills that process, with all it started, if it is still running after 60 s. It runs a collector the service quarantined all the same.

| Field | Type | Content |
| :--- | :--- | :--- |
| `service.enabled` | boolean or null | `option enabled` of the main section; null when that section is not valid. |
| `service.boot` | boolean | Whether the boot link `/etc/rc.d/S*prometheus-exporter` is there. |
| `service.running` | boolean or null | Whether procd runs the uhttpd instance; null when procd cannot be asked. |
| `service.error` | string or null | Why procd could not be asked. |
| `service.auth` | boolean or null | Whether basic auth is configured. |
| `service.compress` | boolean or null | `option compress`. |
| `listen` | array | The URLs the running instance listens on, as `http://*:9100/metrics`. |
| `collectors` | array | One result per installed collector, in the order of their names. |
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

The logical interfaces netifd has, in its order, as `network.interface dump` gives them: `name` and `proto` (null when it has none). It never reads `/etc/config/network`.

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

A SHA-512-crypt hash of `password`, of 1000 rounds and a fresh salt of 16 characters, for `auth_password`:

```
$ ubus call prometheus-exporter hash_password '{"password":"…"}'
{
	"hash": "$6$rounds=1000$…"
}
```

The password is 1 to 256 bytes, without control characters. rpcd runs the method, unjailed, and logs neither the password nor the hash.

## `password`

Whether a hash of basic auth's password is saved, in `/etc/config/prometheus-exporter-auth`: `{ "saved": true }`. Never the hash.

## `set_password`

Hashes `password` as `hash_password` does, saves the hash in `/etc/config/prometheus-exporter-auth`, commits it, and sends procd the `config.change` event of that config, which reloads the service as `reload_config` would: `{ "saved": true }`. An empty `password` removes the saved hash: `{ "saved": false }`. The reply never holds the hash.

```
$ ubus call prometheus-exporter set_password '{"password":"…"}'
{
	"saved": true
}
```

Basic auth is on while the main section's `auth_user` is set: a hash saved without one is unused, and a user without one is refused. The change applies at once, apart from any change staged in uci: it is not undone by a rollback, nor by `uci revert`.

This is how LuCI changes and removes the password, with its **Change password…** and **Remove password**, apart from Save & Apply: LuCI's ACL grants it to a login that may write, and nothing of `/etc/config/prometheus-exporter-auth`. See [LuCI app](luci.md#basic-auth-password).

## Errors

| `error` | `message` | When |
| :--- | :--- | :--- |
| `ARGS_INVALID` | `main and collectors must be objects`, `collectors.<module> must be an object` | `validate` was given something else. |
| `ARGS_INVALID` | `password: expected a password`, `password: expected a password of at most 256 bytes`, `password: expected a password without control characters` | `hash_password` or `set_password` was given a password it does not take. |
| `FILE_UNWRITABLE` | `FILE_UNWRITABLE (cannot write /etc/config/prometheus-exporter-auth: ...)` | `set_password` could not save the hash. |
| `STATUS_FAILED` | `cannot run /usr/libexec/prometheus-exporter/rpc-status.uc`, `... printed no reply` | `status` could not run its scrape, or the scrape printed no reply (or was killed at 60 s). |
| A [code](error-codes.md) | `CODE (detail)` | `interfaces` could not ask netifd; `hash_password` or `set_password` had no random bytes. |

ubus itself refuses arguments of the wrong type, as a string for `main`, with `Invalid argument`.

## `prometheus-exporter.filesystem`

The filesystem collector's own object, which its package serves from the rpcd plugin `/usr/share/rpcd/ucode/prometheus-exporter-filesystem.uc`: the base package has none. Its one method, `mounts`, takes no arguments, and answers what luci's `getMountPoints` does, with each mount's inodes besides: of each mount of `/proc/mounts` that statvfs() finds blocks in, `{ device, mount, size, free, avail, files, ffree }`, sizes in bytes. statvfs() is luci-base's, of `luci.core`; without it, or without `/proc/mounts`, it answers `{ error }`. The collector asks it from the jail, whose own mounts are not the host's; where rpcd has not loaded it, the collector asks `getMountPoints`, and writes the sizes alone.

```
$ ubus call prometheus-exporter.filesystem mounts
{ "result": [ { "device": "tmpfs", "mount": "/tmp", "size": 122658816, "free": 122286080, "avail": 122286080, "files": 29946, "ffree": 29890 }, ... ] }
```

As getMountPoints does, it statvfs()es every mount, a network mount that hangs included, in rpcd's process.

ucode's fs module has no `statvfs()` on 25.12, so the plugin takes luci-base's `luci.core`, and requires it when `mounts` is called, not when rpcd loads the plugin: a luci-base without it fails the call and leaves rpcd and its other objects as they are.

## Access

Over HTTP, through uhttpd-mod-ubus, a session needs the methods in its ACL. The LuCI app's ACL, `luci-app-prometheus-exporter`, grants `collectors`, `interfaces`, `password`, `status` and `validate` to read, and `set_password` to write. See [LuCI app](luci.md#acl).

## See also

- [How to troubleshoot](../how-to/troubleshoot.md)
- [Service commands](service-commands.md#check): `check`, which shows the same on the command line.

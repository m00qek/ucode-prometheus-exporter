# About the Security Model

The exporter runs as root, on a router, and answers requests from the network. It reads much of what the router knows: its interfaces and addresses, its clients and leases, its configuration. This page is about what keeps that from becoming more than a read, and the trade-offs taken along the way.

---

## A jail built from declarations

uhttpd, and the exporter in it, runs in procd's jail. The jail holds the exporter's own code and libraries, procfs, sysfs and the log, and then what the installed and enabled collectors declare: the configs they read, the programs they run, the files and directories they read, and the ubus socket while one of them needs ubus. Nothing else of `/etc/config` is there, and nothing outside it is writable but the exporter's small state directory.

The jail is computed, not written by hand. Each collector's `meta` says what it needs, the init script asks `jail.uc` what that adds up to, and procd mounts that. A collector the device does not install, or that its configuration disables, adds nothing. This is what makes the jail tight: it is exactly as wide as the collectors in use, and it stays right as packages come and go, without anyone keeping a list.

Some declarations are refused outright: a path that is not absolute or not plain, and directories that hold what every service has, `/etc/config`, `/run`, `/tmp`, `/usr/lib` and the like. A collector cannot ask for a socket in `/run`, because the jail would then hold every service's sockets. ujail cannot mount a socket by itself, so a collector names the socket's directory, which must be its service's alone, as Unbound's `/var/lib/unbound` is.

A directory the exporter owns, textfile's, is held tighter: the service makes it as root and mounts it, so it must be under `/var`, `/tmp` or `/etc/prometheus-exporter`, and a value elsewhere is refused before anything is made. An allowlist, not the list of shared directories above: whoever may write the exporter's configuration, as a LuCI login allowed this app alone, cannot have the service make directories in, or mount, the rest of the filesystem.

The ubus socket matters most of these. The jail runs as root, and ubusd lets root call every object, so with the socket the exporter could ask rpcd, netifd or any service for anything they answer. The jail limits what the exporter can see, not what it can do over ubus; so it has the socket only while a collector that needs ubus is enabled, and a router whose enabled collectors read files and netlink alone runs it without ubus.

The jail is a boundary for the exporter's own mistakes as much as for an attacker's: a collector that parses something wrong cannot write anywhere, and one whose program hangs is killed with everything it started.

Read-only is not the same as harmless, so some files stay out of the jail whoever reads around them. `/etc/config/network` holds WireGuard's private keys: the wireguard collector does not declare it, and names peers by their descriptions only with `peer_names`, asking rpcd's `uci` object for the interface's peer sections alone and letting go of all but each one's public key and description. That keeps the keys out of the jail's files, where a mistake in reading a path could reach them; it is not a wall against an exporter that runs code it should not, which, as root with ubus, which the wireguard collector needs, could ask rpcd for the whole config. The ubus object's `interfaces`, by contrast, asks netifd, so that a LuCI user allowed the exporter's object alone gets interface names without the file.

## Buggy, not hostile {#buggy-not-hostile}

Collectors come from packages: the exporter's own, and others that anyone may write. Most of what can go wrong with one is a bug: a loop whose condition never turns false, a read of a FIFO that nothing writes to, a table that grows past what anyone expected, a family named as another collector's, an allocation that never stops. The exporter is built so that one such collector costs itself and nothing else: it runs in a process of its own, stopped at its budget, limited in samples and memory, kept to its own families, and quarantined when it keeps failing. The [collector contract](../reference/collector-contract.md) lists every rule and what breaking it costs.

What the exporter does not do is contain a hostile collector, and cannot. A collector is code a root package installed, and it runs in the exporter's own process, as root, before any jail the exporter could set up for it: its module is loaded where the handler is, it can call whatever ucode and the modules it imports can, and it could undo any limit set from inside that process. Containing hostile code takes a boundary it cannot reach from where it runs, a separate user, a sandbox of the kernel's around each collector, and that is a different design with a different cost. Here the boundary is installing the package: a collector package is code you choose to run as root, as any other package is.

So the guards are written against mistakes. They hold a collector to what it declared and to what a scrape can afford, they make its failure visible (a reply that says so, a log line, a counter, a quarantine), and they keep the rest of the scrape on time. They do not try to outwit code that means to escape them.

## What collectors get

Inside the jail, a collector gets less than the jail holds. It receives capabilities, not modules: the fs functions that read and none that write; uci handles on the configs it named, read-only, of the committed configuration only, so a change staged in uci but not committed is never read; programs only from its own list, run without a shell's interpretation of their arguments, and killed with their children when its seconds are spent. See [About the architecture](architecture.md#only-one-module-touches-the-system).

And a collector imports one module, the collector API, so it has no way to the system but those capabilities: a collector that imports `fs`, or calls `require('fs')`, is refused before it is loaded. This is a rule against mistakes, as the others are. An author used to ucode scripts imports `fs` without a second thought; ported from elsewhere, a collector reaches for the module it knew. The loader reads the module's text for its imports and those calls, which is what such a collector has; code written to get round it, reaching `require` some other way, would, and would be hostile. The tests hold our collectors to what they declare in the same spirit: they run each in the filesystem its jail gives it, so a read of a path it did not declare fails the test, rather than passing there and finding nothing in the service.

## Basic auth, over TLS only

Basic auth sends the password with every request, encoded but not encrypted. Over HTTP anyone on the path reads it. So the exporter takes basic auth over HTTPS only: `auth_user` and `auth_password` without `cert` and `key` are an invalid configuration, refused wherever it is checked, start, reload, `check`, the ubus object's `validate` and LuCI alike. A configuration that asks for a login is never served without TLS, rather than served with a warning.

`auth_password` holds a crypt hash, never the password: the configuration, its backups and LuCI's forms never hold the secret. The ubus object makes the hash, so the password is not on a command line, where `ps` would show it. Neither the password nor the hash is logged, and no reply of the ubus object holds the hash.

The hash is kept apart, too, in `/etc/config/prometheus-exporter-auth`, mode 0600, and not in the exporter's config. LuCI's ACL for the app grants reading the exporter's config, which a login that may only look at the settings needs; were the hash there, that login could read it through rpcd's `uci` object, and guess the password offline at a hash's pace. So the app's ACL grants nothing of the hash's config: LuCI asks the ubus object's `password` whether one is saved, and hands a new password to `set_password`, which saves the hash as root. The jail does not mount that config either: the handler reads uhttpd's file, which must hold the hash.

### Why the handler checks the password itself

uhttpd has basic auth of its own: a config file of `prefix:user:hash` lines, `-c`, with a realm, `-r`. The init script writes that file, and uhttpd reads it. But OpenWrt 25.12's uhttpd applies it to files and CGI only, not to a handler's prefix: a request to `/metrics` would reach the handler without a login. uhttpd fixed this in August 2026 (commit 3aa7e1c), after every 25.12 release so far.

So the handler reads the same file when it starts, and checks every request against it before it scrapes, computing the hash in ucode as musl's crypt would. On a uhttpd that does check, the request is checked twice; on one that does not, it is checked once, which is what matters. A file that is there but wrong denies every request rather than letting them through, and so does a file that is not there while the configuration sets `auth_user`: should the file go and procd start uhttpd again as it was, with no file for the jail to mount, the handler reads the exporter's configuration, which the jail has, and fails closed rather than serve without the login it asks for.

### The cache, and what it trades

Computing a hash costs real time on a router's CPU: 135 ms for `hash_password`'s 1000 rounds of SHA-512-crypt on a 500-MIPS MIPS core, at every scrape. And uhttpd's process per request keeps nothing in memory. So, after a request is let in, the handler writes to its state directory the SHA-256 of that request's exact `Authorization` header, bound to the user and the hash; a later request with the same header is let in on that digest, compared in constant time. Any other header pays the full check, and a wrong one stays out, leaving the entry as it was. A changed user or password lets nothing in by the old entry, and a restart forgets it.

The digest reveals no more than what is already on the device. It sits beside the hash, as closed: root's alone, in a directory of mode 0700 on tmpfs, never on flash nor in a backup. Finding a header that gives it is guessing the password, as with the hash, only cheaper per guess: one SHA-256 against a thousand rounds and more. That matters only to whoever can read the file, which is root on the router, who can also read the password itself from the next scrape, since uhttpd ends the TLS. A long random password, as a scraper's should be, is out of reach either way.

### Why the rounds are capped

A `$5$` or `$6$` hash may name up to 9,999,999 rounds. A hash of that many would take a 500-MIPS router twenty minutes per scrape, and anyone who can set the configuration could make the exporter burn its CPU. So a hash may have at most 2000 rounds, a quarter of a second there, and a hash that names none, which means 5000, is refused like any invalid value. See [Performance on small routers](performance.md#basic-auth).

## Defaults that face inward

The exporter listens on loopback until told otherwise: a fresh install exposes nothing. `listen_interface` takes a logical interface, so it follows that interface's addresses; `*`, every address, is a choice to make deliberately, since it includes the WAN's.

Once it listens on the LAN, the port is meant for the scrapers alone, and the firewall is what keeps it so ([How to listen on the LAN](../how-to/listen-on-lan.md#keep-it-to-the-scrapers)). Every request is a scrape, or a check of a password, and either costs the router CPU; a client that reaches the port without credentials still makes the handler check the ones it sends. uhttpd runs 3 requests at once and keeps at most 10 connections, so such a client delays the scrapes, and no more: requests past those wait their turn, and the connections bound how many can wait. See [HTTP endpoint](../reference/http.md#connections).

## Trade-offs

- **The jail is not a sandbox against a hostile collector.** It narrows what the installed collectors can reach; it does not vet them. A collector package is code you choose to run as root: see [Buggy, not hostile](#buggy-not-hostile).
- **The same jail everywhere it can be had.** `check`, the ubus object's `status` and `prometheus-exporter scrape` run the collectors in the service's own jail, with ujail, so what they find is what Prometheus gets. Where ujail cannot run (not root, or a kernel or container that refuses it a namespace) they run outside it, as root, and say so; the guards are the same. `prometheus-exporter collector check` runs a module not installed yet, outside the jail. chronyd's server statistics are read only where they run outside it: reaching them means writing to chronyd's command directory, which the jail does not give.
- **rpcd runs the ubus object unjailed.** It reads the committed configuration and writes nothing but the hash, through `set_password`; `hash_password` and `set_password` alone handle a secret, and log neither it nor the hash. The LuCI app's ACL grants the reading methods, and `set_password` only to a login that may write.
- **A password saved through LuCI applies at once.** `set_password` commits the hash and has procd reload the service when Save hashes it, before Save & Apply applies the rest; LuCI cannot stage a change to a config it may not read. A user set in the same Save turns basic auth on when it is applied.

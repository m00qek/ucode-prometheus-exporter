# Explanation

Discussion of why the exporter is the way it is: to read away from the router, when you want to understand rather than do. The table says which reader each page is mostly for: [who these docs are for](../index.md#who-these-docs-are-for).

| Page | For | About |
| :--- | :--- | :--- |
| [About the exporter](about.md) | Everyone | The two feed exporters before it, why a rewrite, and credits. |
| [About the architecture](architecture.md) | Everyone | uhttpd's process per request, the library, the loader, capabilities, the state, and why the ubus object lives in rpcd. |
| [About the security model](security.md) | Operators | The jail built from declarations, basic auth over TLS only, the handler's own check, and the cache's trade-off. |
| [About nothing to observe](nothing-to-observe.md) | Operators, collector authors | Why a device without radios is not a failure, and how a collector tells. |
| [About deadlines and circuit breakers](deadlines-and-breakers.md) | Operators, collector authors | How a scrape answers before the scraper gives up, why collectors run fastest first, and why one that hangs or keeps failing is set aside for a while. |
| [What happens when a collector breaks](when-a-collector-breaks.md) | Operators | A hung ubus daemon, a stuck program, a huge conntrack table on a slow router, a label that is not UTF-8: what Prometheus gets from this exporter and from the Lua one, measured. |
| [About metric names](metric-names.md) | Operators, collector authors | node_exporter's names, the conventions, modern names only, and the build info. |
| [Performance on small routers](performance.md) | Operators, maintainers | The cost of ucode's VM, the measurements, gzip, basic auth, and nat_traffic on weak MIPS. |
| [About the implementation](internals.md) | Maintainers | The quirks of ucode, its modules and the kernel the code works round, and why some code is shaped as it is: for maintainers. |
| [About versions](versions.md) | Operators, collector authors | What major, minor and patch promise, and how packages follow. |
| [About versioned documentation](versioned-docs.md) | Maintainers | Why the docs are published per minor, and how they are fixed. |

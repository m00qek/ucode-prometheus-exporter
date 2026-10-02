# Explanation

Discussion of why the exporter is the way it is: to read away from the router, when you want to understand rather than do.

| Page | About |
| :--- | :--- |
| [About the exporter](about.md) | The two feed exporters before it, why a rewrite, and credits. |
| [About the architecture](architecture.md) | uhttpd's process per request, the library, the loader, capabilities, the state, and why the ubus object lives in rpcd. |
| [About the security model](security.md) | The jail built from declarations, basic auth over TLS only, the handler's own check, and the cache's trade-off. |
| [About nothing to observe](nothing-to-observe.md) | Why a device without radios is not a failure, and how a collector tells. |
| [About deadlines and circuit breakers](deadlines-and-breakers.md) | How a scrape answers before the scraper gives up, why collectors run fastest first, and why one that hangs or keeps failing is set aside for a while. |
| [About metric names](metric-names.md) | node_exporter's names, the conventions, modern names only, and the build info. |
| [Performance on small routers](performance.md) | The cost of ucode's VM, the measurements, gzip, basic auth, and nat_traffic on weak MIPS. |
| [About versions](versions.md) | What major, minor and patch promise, and how packages follow. |
| [About versioned documentation](versioned-docs.md) | Why the docs are published per minor, and how they are fixed. |

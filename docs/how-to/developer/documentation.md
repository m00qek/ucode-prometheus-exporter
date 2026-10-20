# How to Write Documentation

The documentation is built with MkDocs Material, inside Docker. You need Docker and `make`.

---

## Preview while you write

```bash
make docs-serve
```

Open `http://localhost:8000`. The page reloads when you save a file under `docs/` or change `mkdocs.yml`. If port 8000 is taken, choose another: `make docs-serve DOCS_PORT=8001`.

## Build the site

```bash
make docs
```

The site goes to `bin/site/`, and `make -C docs clean` removes it. The build runs `mkdocs build --strict`, so a broken link or any other warning fails it. On pushes and pull requests to `main` that touch the docs, CI runs the same strict build. It also runs a second one with the versioned config, `mkdocs.mike.yml` (`make docs-mike` locally).

Merging to `main` publishes nothing: the docs go online with the next release. To correct the docs already online, see [How to fix the docs of the released version](fix-released-docs.md). [Documentation publishing](../../reference/docs-publishing.md) says what publishes when.

## Where a page goes

Pick the folder by what the reader is doing, following [Diátaxis](https://diataxis.fr/):

| Folder | The reader is... | Example |
| :--- | :--- | :--- |
| `tutorials/` | learning by doing, guided step by step | Monitor a router with Prometheus |
| `how-to/` | working toward a goal they already have | Serve HTTPS with basic auth |
| `reference/` | looking up a fact | Every option of the configuration |
| `explanation/` | trying to understand why | Nothing to observe |

Keep one type per page, and link to pages of the other types instead of mixing them. Add every new page to `nav` in `mkdocs.yml` and to the `index.md` of its folder. Link between pages with relative paths, never with the site's URL, so each published version links to itself.

The reasoning a reader needs lives in the explanation pages. When a change rests on a new reason, write the reason there, in the same change.

## Comments in the code

The code under `src/`, `files/` and `luci/` carries no explanatory comments: its explanation is here, in the docs. A reason that shapes the design goes in the explanation page it belongs to; a quirk of ucode, of a module or of the kernel that the code works round, or why a piece of code is shaped as it is, goes in [About the implementation](../../explanation/internals.md). Tests may keep their comments: they do not ship.

An exported symbol of a module has a JSDoc block for the language server, which shows it on hover, and nothing more: a one-line summary, its types, and a line on each parameter and on what a function returns.

```js
/**
 * The scrapes left before the trial, seen from scrape `m`; null for a closed breaker.
 *
 * @param {?LedgerEntry} entry the collector's entry; null for none.
 * @param {int} m the scrape's number.
 * @returns {?int} the scrapes.
 */
export function left(entry, m) {

/**
 * The scrapes after which the deadline leaving a collector out is old news.
 *
 * @type {int}
 */
export const RECENT = 10;
```

The tags are `@module`, `@typedef` (record types too, where the type is defined), `@template`, `@param {T} name description`, `@returns {T} description` and, on an exported constant, `@type {T}`; and `{@link}` in a summary. Each description is one line: what the value is, not why. A function or a constant that is not exported has no comment.

The package build strips every comment that is left, JSDoc too, from the ucode and JavaScript files it installs, and keeps a newline for each line it empties, so a device gets no comments and the line of an error on it is the line here. To check that a change to comments changed nothing else:

```bash
make same-code REV=main
```

## Generated pages

Six reference pages are written from the code by `make docs-gen`, and never by hand:

| Page | From |
| :--- | :--- |
| `docs/reference/collectors.md` | Each collector's `meta`, the package Makefile, and the code's reasons for nothing to observe. |
| `docs/reference/metrics.md` | What each collector writes when it runs on the fixture sets of `test/fixtures/`. |
| `docs/reference/uci-config.md` | `config.uc`'s option specs, and `config/types.uc`'s datatypes. |
| `docs/reference/error-codes.md` | `errors.uc`, and where each code is raised; its sections are the notes'. |
| `docs/reference/command.md` | The command's usage, `cli.uc`'s `USAGE`, which docopt parses its arguments by. |
| `docs/reference/migration.md` | `docs/gen/migration.md`, its text, with the tables of the feed exporters' packages and families and this exporter's for each: from `docs/gen/feed-exporters.json`, what `make feed-inventory` read of their sources, `docs/gen/migration.uc`, the mapping, and what the collectors write, as for `metrics.md`. |

`docs/gen/notes.uc` holds what the code does not say:

- when each collector has nothing to observe
- what a computed jail path is
- the patterns that fold a driver's statistics into one row
- the families no fixture shows
- the meaning of each error code, and the section of the page it is in
- what each command of the command line does
- a name for each fixture set

The generator checks the notes against the code. If the code contradicts an entry, the generator refuses and writes nothing.

1. Change the code, or the notes.
2. Regenerate:

    ```bash
    make docs-gen
    ```

3. If it refuses, its message says which note to change:
    - A new collector that can have nothing to observe needs an entry in `nothing_to_observe`.
    - A family the collector declares, but that no fixture makes it write, needs a fixture or an entry in `unharvested`.
    - A new fixture set needs a name in `capture_sets`, which keeps the device's own name out of the docs.
4. Commit the pages with the change. `make lint` fails while a page differs from what `make docs-gen` would write.

## Keep it true

Reference pages describe the code as it is. When you change one of these, update its page in the same change:

| Code | Reference page |
| :--- | :--- |
| A collector, `config.uc` and `config/`, `errors.uc`, the package Makefile, `test/fixtures/` | The generated pages: `make docs-gen`. |
| `files/etc/init.d/prometheus-exporter`, `check.uc`, `status.uc` | [Service commands](../../reference/service-commands.md) |
| `cli.uc`, `files/usr/bin/prometheus-exporter` | [The `prometheus-exporter` command](../../reference/command.md), generated from `cli.uc`'s usage and `docs/gen/notes.uc`: `make docs-gen` |
| `runner.uc`, `probe.uc`, `jailed.uc`, `conform.uc`, the guards of `scrape.uc`, `ownership.uc`, `progress.uc`, `exposition.uc`, `loader.uc` | [Collector contract](../../reference/collector-contract.md) |
| `http.uc`, `app.uc`, `auth.uc`, `query.uc`, `scrape.uc` | [HTTP endpoint](../../reference/http.md) |
| `rpc.uc` and `rpc/`, the rpcd plugin | [ubus object](../../reference/ubus.md) |
| `luci/` | [LuCI app](../../reference/luci.md), [How to use the LuCI app](../luci.md) |
| `jail.uc`, `state.uc`, the init script's mounts | [The jail](../../reference/jail.md) |
| `loader.uc`, `deps.uc` and `deps/`, `result.uc`, `services.uc`, `exposition.uc`'s recorder | [Collector interface](../../reference/collector-interface.md) |
| A log line | [Log messages](../../reference/log-messages.md) |
| `files/`, the package Makefile | [Files and packages](../../reference/files.md) |
| The root `Makefile`, `docs/Makefile` | [Make targets](../../reference/make-targets.md) |
| `docs/Makefile`, `devenv/scripts/docs-*.sh`, `.github/workflows/docs.yml`, `mkdocs.mike.yml`, `docs/overrides/`, `devenv/gh-pages/`, `devenv/services/docs/` | [Documentation publishing](../../reference/docs-publishing.md) |
| `migrate.uc` | [How to move from the feed's exporters](../migrate-from-feed.md), and [Migrate from prometheus-node-exporter-lua/-ucode](../../reference/migration.md#configuration): its text is `docs/gen/migration.md` |
| A collector's families, or the feed's exporters (`make feed-inventory`) | [Migrate from prometheus-node-exporter-lua/-ucode](../../reference/migration.md): `make docs-gen` refuses a family of the feed's that `docs/gen/migration.uc` does not map, and a mapping to a family no collector writes |
| `monitoring/`: a rule, a threshold, a panel | [How to monitor a router with the bundled dashboards and alerts](../dashboards-and-alerts.md), and its screenshots: `make monitoring-lab` |
| A renamed metric | [Renamed metrics](../../metrics.md) |

## Steps in LuCI and over SSH

An operator step that LuCI can do gets two content tabs, LuCI first, with exactly these labels:

````markdown
=== "Browser (LuCI)"

    On **Services → Prometheus exporter**, tab **General**, untick **Compress**, and press **Save & Apply**.

=== "Terminal (SSH)"

    ```sh
    uci set prometheus-exporter.main.compress=0
    uci commit prometheus-exporter
    service prometheus-exporter reload
    ```
````

Picking a tab picks it on every page (`content.tabs.link`). Name menus, tabs, fields and buttons by the app's English source strings, in `luci/`. A step LuCI cannot do, such as adding the feed's signing key, stays SSH only.

## Examples

- Use generic names (router, ap) and documentation addresses: `192.0.2.0/24`, `198.51.100.0/24` and `203.0.113.0/24` for IPv4, `2001:db8::/32` for IPv6. Never paste a real device's name, MAC address, SSID, key or public address.
- Output captured from the lab is the exception: paste it as it is. Its addresses are docker's, and disposable.
- Use Mermaid in a fenced block with the `mermaid` language, only where a picture explains more than a paragraph.

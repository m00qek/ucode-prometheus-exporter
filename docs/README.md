# docs/

Source for the ucode-prometheus-exporter documentation site.

Built with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/). Structured using the [Diátaxis framework](https://diataxis.fr/): tutorials, how-to guides, reference, and explanation.

## Build and preview

All of these run inside Docker, so no local Python installation is required.

```bash
make -C docs serve       # Live preview at http://localhost:8000 (DOCS_PORT=<n> to change)
make -C docs build       # Build static site to bin/site/ (mkdocs build --strict)
make -C docs build-mike  # Same, with the versioned config mkdocs.mike.yml
make -C docs test        # Test the publishing scripts
make docs-gen            # Write the generated reference pages (from the repository root)
```

## Generated pages

`make docs-gen` writes `reference/collectors.md`, `reference/metrics.md`, `reference/uci-config.md`, `reference/error-codes.md`, `reference/command.md` and `reference/migration.md` from the code. It also reads `gen/notes.uc` for what the code does not say, and `gen/migration.md`, `gen/migration.uc` and `gen/feed-exporters.json` (`make feed-inventory`) for the migration page. Never edit these pages by hand: `make lint` fails while one is out of date. See [how-to/developer/documentation.md](how-to/developer/documentation.md).

## Publishing

mike publishes the site per minor release (`/X.Y/`, `/latest/`), from release tags and `docs/X.Y` branches, never from `main`. [reference/docs-publishing.md](reference/docs-publishing.md) describes the machinery, and the how-to guides in `how-to/developer/` cover releasing and fixing the docs.

## Structure

```
docs/
├── tutorials/     # Learning-oriented: monitor a router, write a first collector
├── how-to/        # Goal-oriented: install, configure, monitor, troubleshoot; developer tasks
├── reference/     # Information-oriented: collectors, metrics, UCI, ubus, HTTP, jail, logs, errors
├── explanation/   # Understanding-oriented: why a rewrite, architecture, security, performance
├── gen/           # The generator's hand-written notes (not published)
├── metrics.md     # Renamed metrics, from the feed's exporters (in Reference)
└── overrides/     # Theme override for the versioned site (outdated-version banner)
```

For contribution guidelines, see [how-to/developer/documentation.md](how-to/developer/documentation.md).

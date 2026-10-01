# How to Run the Tests

Everything runs in Docker, on OpenWrt's own images, on the release in `OPENWRT_VERSION` (25.12.5 by default). You need Docker and `make`.

## Unit and integration tests

```bash
make test
```

`make unit` and `make integration` run one suite. To narrow a run:

```bash
make unit MODULES=test/unit/prometheus_exporter/collectors/wifi_test.uc
make test FILTER='collectors.wifi' VERBOSE=1
make watch
```

`watch` runs the tests again whenever a file under `src/`, `test/`, `files/`, `devenv/scripts/` or `docs/gen/` changes. To run them on the API floor, the first 25.12 release, as CI does too: `make test OPENWRT_VERSION=25.12.0`.

## Lint

```bash
make lint
```

It loads every module on the release's ucode, so a function that ucode lacks fails here and not on a router. It also fails when the translation template or a generated reference page is out of date: run `make pot` or `make docs-gen`, and commit the result.

## The packages

```bash
make package-check
```

Builds the apks with the SDK, installs them offline in an OpenWrt image, scrapes a real uhttpd and calls the ubus object in a real rpcd, with the base package alone and then with the LuCI app.

## The service under procd

```bash
make e2e
```

Boots OpenWrt in a privileged container, without network, and checks the service in its jail as packages come and go and its configuration changes. It needs Docker to allow privileged containers.

## The LuCI app

```bash
make browser
make browser FILTER='settings'
```

Runs the Playwright tests of `test/browser/` against LuCI with the built packages. Screenshots, and on a failure the error context and LuCI's log, are in `bin/browser/`.

## The documentation tooling

```bash
make docs-test
make docs
```

`docs-test` runs the publishing scripts' tests; `docs` builds the site, strictly. See [How to write documentation](documentation.md).

---

CI runs `lint`, `test` and `package-check` on 25.12.0 and 25.12.5, `e2e` on both, `bench`, and `browser`; and the docs workflow builds the site. Every target is in [Make targets](../../reference/make-targets.md).

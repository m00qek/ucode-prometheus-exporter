# How to Run the Tests

Everything runs in Docker, on OpenWrt's own images of the release in `OPENWRT_VERSION` (25.12.5 by default). You need Docker and `make`.

## Unit and integration tests

```bash
make test
```

The tests of the template collector package, `devkit/template/test/`, run with the unit tests, on the tree's devkit. `make unit` and `make integration` each run one suite. To narrow a run:

```bash
make unit MODULES=test/unit/prometheus/collectors/wifi_test.uc
make test FILTER='collectors.wifi' VERBOSE=1
make watch
```

A full run first checks the comment stripper that the package build runs. It runs the stripper's own tests, `test/strip/`, and strips every ucode and JavaScript file the packages install. Each ucode file must compile to the same stripped bytecode as its source, which proves the stripper removed comments and nothing else. A narrowed run skips this check.

`watch` runs the tests again whenever a file under `src/`, `test/`, `files/`, `devenv/scripts/`, `docs/gen/` or `devkit/` changes. To run them on the API floor, the first 25.12 release, as CI also does: `make test OPENWRT_VERSION=25.12.0`.

## Lint

```bash
make lint
```

It loads every module on the release's ucode, so a call to a function that ucode lacks fails here, not on a router. It also fails when the translation template or a generated reference page is out of date. Run `make pot` or `make docs-gen`, and commit the result.

## The packages

```bash
make package-check
```

This builds the apks with the SDK and installs them offline in an OpenWrt image. It scrapes a real uhttpd and calls the ubus object in a real rpcd, first with the base package alone, then with the LuCI app. It checks that each installed ucode file, which the build stripped of comments, compiles to the same code as its source. Then it installs the devkit and runs the template collector's tests on it, as a collector package's own CI would.

## The service under procd

```bash
make e2e
```

This boots OpenWrt in a privileged container, without network. It checks the service in its jail while packages are installed and removed and the configuration changes. It needs Docker to allow privileged containers.

## The LuCI app

```bash
make browser
make browser FILTER='settings'
```

This runs the Playwright tests of `test/browser/` against LuCI with the built packages. It also compares the app's JavaScript as LuCI serves it, stripped of comments, with its sources, token by token. Screenshots go to `bin/browser/`, and on a failure so do the error context and LuCI's log.

## The documentation tooling

```bash
make docs-test
make docs
```

`docs-test` runs the publishing scripts' tests. `docs` builds the site, strictly. See [How to write documentation](documentation.md).

---

CI runs `lint`, `test`, `package-check` and `e2e` on 25.12.0 and 25.12.5, and `bench` and `browser` once. The docs workflow builds the site. [Make targets](../../reference/make-targets.md) lists every target.

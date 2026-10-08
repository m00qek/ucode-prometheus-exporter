OPENWRT_ARCH    ?= x86_64
# The ucode API floor is 25.12.0's; every 25.12 release so far ships the same ucode.
OPENWRT_VERSION ?= 25.12.5
# Keyed by the image's inputs, so worktrees with different Dockerfiles don't overwrite each other's image.
IMAGE_TAG       := $(OPENWRT_ARCH)-$(OPENWRT_VERSION)-$(shell cat devenv/services/openwrt/Dockerfile | sha256sum | cut -c1-12)
export OPENWRT_ARCH OPENWRT_VERSION IMAGE_TAG

COMPOSE     := docker compose -f devenv/docker-compose.yaml
RUN          = $(COMPOSE) --progress quiet run --rm $(if $(CI),-T) openwrt
IMAGE_STAMP := devenv/.built-$(IMAGE_TAG)
TEST_ARGS    = $(if $(FILTER),-f '$(FILTER)') $(if $(VERBOSE),-v) $(MODULES)

.PHONY: test unit integration watch lint shell image fixtures package pkgcheck-image package-check e2e lab lab-down browser pot bench bench-src bench-worlds bench-device bench-qemu docs docs-mike docs-test docs-serve docs-gen feed-makefile

test:        $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/test.sh all $(TEST_ARGS)
unit:        $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/test.sh unit $(TEST_ARGS)
integration: $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/test.sh integration $(TEST_ARGS)
watch:       $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/test.sh watch $(TEST_ARGS)
lint:        $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/lint.sh && I18N_IMAGE=$(I18N_IMAGE) devenv/scripts/pot.sh check
shell:       $(IMAGE_STAMP) ; @$(RUN) sh

image:
	$(COMPOSE) build --pull openwrt
	@touch $(IMAGE_STAMP)

$(IMAGE_STAMP): devenv/services/openwrt/Dockerfile
	$(COMPOSE) build openwrt
	@touch $@

# Reads the sources in test/fixtures/SOURCES from a device over ssh into
# test/fixtures/$(NAME)/: make fixtures HOST=caju-router NAME=caju-router
fixtures:
	@devenv/scripts/fixtures.sh '$(HOST)' '$(NAME)'

PKG_FIELD       = $(shell sed -n 's/^PKG_$(1):=//p' openwrt/ucode-prometheus-exporter/Makefile)
PKG_FULLVERSION := $(call PKG_FIELD,VERSION)-r$(call PKG_FIELD,RELEASE)
SDK_IMAGE       := ghcr.io/openwrt/sdk:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)
PKG_DIR         := /builder/package/ucode-prometheus-exporter

# fakeroot's faked closes every descriptor up to the open-file limit when it starts;
# where the daemon's limit is unbounded (about a billion) each start takes minutes.
package:
	@mkdir -p bin && chmod a+rwx bin
	docker run --rm --ulimit nofile=1024:524288 \
		-v $(CURDIR)/openwrt/ucode-prometheus-exporter/Makefile:$(PKG_DIR)/Makefile:ro \
		-v $(CURDIR)/src:$(PKG_DIR)/src:ro \
		-v $(CURDIR)/files:$(PKG_DIR)/files:ro \
		-v $(CURDIR)/luci:$(PKG_DIR)/luci:ro \
		-v $(CURDIR)/LICENSE:$(PKG_DIR)/LICENSE:ro \
		-v $(CURDIR)/NOTICE:$(PKG_DIR)/NOTICE:ro \
		-v $(CURDIR)/bin:/artifacts \
		$(SDK_IMAGE) sh -c 'make defconfig >/dev/null && \
			make package/ucode-prometheus-exporter/compile $(if $(VERBOSE),V=s) && \
			find bin \( -name "ucode-prometheus-exporter*-$(PKG_FULLVERSION).apk" \
				-o -name "luci-app-prometheus-exporter-$(PKG_FULLVERSION).apk" \) -exec cp {} /artifacts/ \;'

# Keyed by its inputs, the Dockerfile and the packages it installs, as IMAGE_TAG is.
# What collectors watch, which their packages do not depend on (a monitoring
# package must not change what the router does): the images install them, so
# the checks still read them.
WATCHED         := mwan3 modemmanager chrony ubnt-manager rpcd-mod-wireguard
INPUTS_OF       = $(shell { cat $(1); devenv/scripts/package-info.sh feed-depends; devenv/scripts/package-info.sh app-depends; echo $(WATCHED); } | sha256sum | cut -c1-12)
PKGCHECK_IMAGE := ucode-prometheus-exporter-pkgcheck:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)-$(call INPUTS_OF,devenv/services/pkgcheck/Dockerfile)

pkgcheck-image:
	docker build -q -t $(PKGCHECK_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg FEED_DEPENDS="$$(devenv/scripts/package-info.sh feed-depends) $$(devenv/scripts/package-info.sh app-depends) $(WATCHED) quickjs unbound-daemon" \
		devenv/services/pkgcheck >/dev/null

# No network: the image carries the dependencies.
package-check: package pkgcheck-image
	docker run --rm $(if $(CI),,-t) --network none -e PKG_FULLVERSION=$(PKG_FULLVERSION) \
		-e BASE_COLLECTORS="$$(devenv/scripts/package-info.sh base-collectors)" \
		-v $(CURDIR)/bin:/artifacts:ro \
		-v $(CURDIR):/exporter:ro \
		$(PKGCHECK_IMAGE) /exporter/devenv/scripts/package-check.sh

# Containers are named per checkout, so worktrees run them side by side.
CHECKOUT      := $(shell echo '$(CURDIR)' | sha256sum | cut -c1-8)
E2E_CONTAINER := ucode-prometheus-exporter-e2e-$(OPENWRT_ARCH)-$(OPENWRT_VERSION)-$(CHECKOUT)

# The packages on a booted OpenWrt: procd as PID 1, with ubusd and netifd,
# and ujail, which needs the container privileged. No network either.
e2e: package pkgcheck-image
	@docker rm -f $(E2E_CONTAINER) >/dev/null 2>&1 || true
	@docker run -d --privileged --network none --name $(E2E_CONTAINER) \
		-v $(CURDIR)/bin:/artifacts:ro -v $(CURDIR):/exporter:ro $(PKGCHECK_IMAGE) /sbin/init >/dev/null
	@docker exec $(if $(CI),,-t) -e PKG_FULLVERSION=$(PKG_FULLVERSION) \
		-e BASE_COLLECTORS="$$(devenv/scripts/package-info.sh base-collectors)" \
		$(E2E_CONTAINER) /exporter/devenv/scripts/e2e.sh; \
		status=$$?; docker rm -f $(E2E_CONTAINER) >/dev/null; exit $$status

# The built packages, every collector and LuCI on OpenWrt under procd, left
# running in a privileged container, with LuCI and /metrics published on the
# host; make lab-down removes it. See devenv/scripts/lab.sh.
LAB_NAME         ?= ucode-prometheus-exporter-lab
LAB_ADDRESS      ?= 127.0.0.1
LAB_LUCI_PORT    ?= 8080
LAB_METRICS_PORT ?= 9100
LAB_IMAGE        := ucode-prometheus-exporter-lab:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)-$(call INPUTS_OF,devenv/services/luci/Dockerfile)

lab: package
	docker build -q -t $(LAB_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg FEED_DEPENDS="$$(devenv/scripts/package-info.sh feed-depends) $$(devenv/scripts/package-info.sh app-depends) $(WATCHED) unbound-daemon" \
		devenv/services/luci >/dev/null
	@LAB_NAME=$(LAB_NAME) LAB_IMAGE=$(LAB_IMAGE) LAB_ADDRESS=$(LAB_ADDRESS) LAB_LUCI_PORT=$(LAB_LUCI_PORT) \
		LAB_METRICS_PORT=$(LAB_METRICS_PORT) PKG_FULLVERSION=$(PKG_FULLVERSION) devenv/scripts/lab.sh up

lab-down:
	@LAB_NAME=$(LAB_NAME) devenv/scripts/lab.sh down

# ---- benchmark -----------------------------------------------------------------
# test/bench/ on OpenWrt in the pkgcheck image: each collector and whole scrapes
# on generated worlds, results in bin/bench/$(BENCH_LABEL).json. It checks the
# scaling budgets, and unconstrained the time budgets too (test/bench/budgets.uc).
# BENCH_CPUS, BENCH_CPUSET and BENCH_MEMORY are docker's --cpus, --cpuset-cpus
# and --memory: a slower router. BENCH_ARGS go to bench.uc (-r 1: one run each).
# BENCH_REV benches the exporter of another revision (src/ only) with this
# bench: BENCH_REV=main for a before and after.
# --cpus is a CFS quota per 100 ms period: a run shorter than the quota runs
# at full speed when it starts a period, and waits out the rest of one when
# it does not, which makes short cases bimodal. The same share of a 20 ms
# period (--cpu-period, --cpu-quota) is as fast on average, and steadier;
# docker takes no quota under 1 ms, so BENCH_CPUS goes down to 0.05.
BENCH_LIMITS = $(strip $(if $(BENCH_CPUS),--cpu-period 20000 --cpu-quota $(shell awk 'BEGIN { print int($(BENCH_CPUS) * 20000) }')) \
	$(if $(BENCH_CPUSET),--cpuset-cpus $(BENCH_CPUSET)) \
	$(if $(BENCH_MEMORY),--memory $(BENCH_MEMORY) --memory-swap $(BENCH_MEMORY)))
BENCH_LABEL ?= devenv$(if $(BENCH_REV),-$(BENCH_REV))$(if $(BENCH_CPUS),-cpus$(BENCH_CPUS))$(if $(BENCH_CPUSET),-cpuset$(BENCH_CPUSET))$(if $(BENCH_MEMORY),-mem$(BENCH_MEMORY))
BENCH_SRC    = $(if $(BENCH_REV),bin/bench/rev-$(BENCH_REV),.)
export BENCH_SRC

bench-src:
	@$(if $(BENCH_REV),rm -rf $(BENCH_SRC) && mkdir -p $(BENCH_SRC) && git archive '$(BENCH_REV)' src | tar -x -C $(BENCH_SRC))

bench: pkgcheck-image bench-src
	@mkdir -p bin/bench && chmod a+rwx bin bin/bench
	@docker run --rm --network none $(BENCH_LIMITS) -e BENCH_LINK_EXPORTER=1 -v $(CURDIR):/exporter:ro -v $(CURDIR)/bin:/artifacts \
		$(if $(BENCH_REV),-v $(CURDIR)/$(BENCH_SRC)/src:/exporter/src:ro) \
		$(PKGCHECK_IMAGE) /exporter/devenv/scripts/bench.sh run /tmp/bench-worlds /artifacts/bench/$(BENCH_LABEL).json \
		$(BENCH_LABEL) -c $(if $(BENCH_LIMITS)$(BENCH_REV),,-a) $(if $(FILTER),-f '$(FILTER)') $(BENCH_ARGS)

# The worlds in bin/bench/worlds, for bench-device and bench-qemu.
bench-worlds: pkgcheck-image
	@mkdir -p bin/bench && chmod a+rwx bin bin/bench && rm -rf bin/bench/worlds
	@docker run --rm --network none -u $$(id -u):$$(id -g) -v $(CURDIR):/exporter:ro -v $(CURDIR)/bin:/artifacts \
		$(PKGCHECK_IMAGE) /exporter/devenv/scripts/bench.sh gen /artifacts/bench/worlds

# The benchmark on a device over ssh, from /tmp, removed afterwards; nothing
# is installed: make bench-device HOST=router [BENCH_DEVICE_LABEL=router] [BENCH_REV=]
BENCH_DEVICE_LABEL ?= $(HOST)$(if $(BENCH_REV),-$(BENCH_REV))

# The benchmark on OpenWrt's malta target in QEMU, from the qemu image: the
# built packages installed with their dependencies from the release's feed,
# one 24Kc CPU at 1000/2^QEMU_SHIFT MIPS of guest time, QEMU_MEMORY MB. Little-
# endian, QEMU_ENDIAN=le (malta/le, mipsel_24kc, as MT7621-class routers), or
# big-endian, be (malta/be, mips_24kc, as ath79-class ones); see
# devenv/scripts/bench-qemu.sh.
QEMU_IMAGE  := ucode-prometheus-exporter-qemu:$(shell sha256sum devenv/services/qemu/Dockerfile | cut -c1-12)
QEMU_ENDIAN ?= le
QEMU_SHIFT  ?= 1
QEMU_MEMORY ?= 128

# ucode-docopt, which the base package depends on, is in its author's feed and
# not in the release's the guest installs from: fetched here, from the pkgcheck
# image's feed (pinned there), and installed beside the built packages.
bench-qemu: package bench-worlds pkgcheck-image
	@docker run --rm --network host -u $$(id -u):$$(id -g) -v $(CURDIR)/bin:/artifacts $(PKGCHECK_IMAGE) \
		sh -c 'rm -f /artifacts/ucode-docopt-*.apk && apk fetch -q -o /artifacts ucode-docopt'
	docker build -q -t $(QEMU_IMAGE) devenv/services/qemu >/dev/null
	@docker run --rm -v $(CURDIR):/exporter:ro -v $(CURDIR)/bin:/artifacts \
		-e OPENWRT_VERSION -e PKG_FULLVERSION=$(PKG_FULLVERSION) -e QEMU_ENDIAN=$(QEMU_ENDIAN) \
		-e QEMU_SHIFT=$(QEMU_SHIFT) -e QEMU_MEMORY=$(QEMU_MEMORY) \
		-e BENCH_LABEL='$(or $(BENCH_QEMU_LABEL),qemu-malta$(if $(filter-out le,$(QEMU_ENDIAN)),-$(QEMU_ENDIAN))-shift$(QEMU_SHIFT))' -e BENCH_ARGS='$(if $(FILTER),-f $(FILTER)) $(BENCH_ARGS)' \
		$(QEMU_IMAGE) /exporter/devenv/scripts/bench-qemu.sh

bench-device: bench-worlds bench-src
	@devenv/scripts/bench-device.sh '$(HOST)' '$(BENCH_DEVICE_LABEL)' -c $(if $(FILTER),-f '$(FILTER)') $(BENCH_ARGS)

# ---- luci-app-prometheus-exporter --------------------------------------------
LUCI_IMAGE    := ucode-prometheus-exporter-luci:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)-$(call INPUTS_OF,devenv/services/luci/Dockerfile)
BROWSER_IMAGE := ucode-prometheus-exporter-browser:$(shell sed -n 's/.*"@playwright\/test": "\(.*\)".*/\1/p' devenv/services/browser/package.json)
# The collector packages the browser tests install besides the base package: options of
# each type, a regex option (diskstats'), configs read, a name with '-'.
BROWSER_COLLECTORS := dhcp_leases diskstats ltq-dsl textfile unbound wifi wireguard

# The LuCI pages against the built packages and a stand-in for procd; see devenv/scripts/browser.sh.
browser: package
	docker build -q -t $(LUCI_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg FEED_DEPENDS="$$(devenv/scripts/package-info.sh feed-depends) $$(devenv/scripts/package-info.sh app-depends) $(WATCHED)" \
		devenv/services/luci >/dev/null
	docker build -q -t $(BROWSER_IMAGE) devenv/services/browser >/dev/null
	@LUCI_IMAGE=$(LUCI_IMAGE) BROWSER_IMAGE=$(BROWSER_IMAGE) PKG_FULLVERSION=$(PKG_FULLVERSION) \
		BROWSER_COLLECTORS='$(BROWSER_COLLECTORS)' FILTER='$(FILTER)' devenv/scripts/browser.sh

# The translation template, from the LuCI sources; make lint checks it is up to date.
I18N_IMAGE := ucode-prometheus-exporter-i18n:$(shell sha256sum devenv/services/i18n/Dockerfile | cut -c1-12)
pot: ; @I18N_IMAGE=$(I18N_IMAGE) devenv/scripts/pot.sh

# ---- release -----------------------------------------------------------------
# The ucode-prometheus-exporter Makefile for the packages.ucode.dev feed, built
# from the v$(VERSION) release tarball: it downloads the tarball unless
# TARBALL=<path> or HASH=<sha256> is given. Writes to OUT, or to standard output.
feed-makefile:
	@sh devenv/scripts/gen-feed-makefile.sh \
		$(if $(TARBALL),--tarball '$(TARBALL)') \
		$(if $(HASH),--hash '$(HASH)') \
		$(if $(OUT),-o '$(OUT)') \
		'$(VERSION)'

# ---- documentation -----------------------------------------------------------
# The site, with MkDocs Material in Docker; see docs/README.md.
docs:       ; @$(MAKE) -C docs build
docs-mike:  ; @$(MAKE) -C docs build-mike
docs-test:  ; @$(MAKE) -C docs test
docs-serve: ; @$(MAKE) -C docs serve

# The reference pages the code holds as data (docs/reference/collectors.md,
# metrics.md, uci-config.md, error-codes.md, command.md), from the code, the fixtures and
# docs/gen/notes.uc; make lint fails while one is out of date. Only
# docs/reference is writable, and the files stay the invoking user's.
docs-gen: $(IMAGE_STAMP)
	@$(COMPOSE) --progress quiet run --rm $(if $(CI),-T) --user $$(id -u):$$(id -g) \
		-v $(CURDIR)/docs/reference:/exporter/docs/reference openwrt \
		ucode -L /exporter/src -L /exporter/devenv/scripts devenv/scripts/docs-gen.uc

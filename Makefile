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

.PHONY: test unit integration watch lint shell image fixtures package pkgcheck-image package-check e2e lab lab-down browser pot

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

PKGCHECK_IMAGE := ucode-prometheus-exporter-pkgcheck:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)

pkgcheck-image:
	docker build -q -t $(PKGCHECK_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg FEED_DEPENDS="$$(devenv/scripts/package-info.sh feed-depends) $$(devenv/scripts/package-info.sh app-depends) quickjs unbound-daemon" \
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
LAB_IMAGE        := ucode-prometheus-exporter-lab:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)

lab: package
	docker build -q -t $(LAB_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg FEED_DEPENDS="$$(devenv/scripts/package-info.sh feed-depends) $$(devenv/scripts/package-info.sh app-depends) unbound-daemon" \
		devenv/services/luci >/dev/null
	@LAB_NAME=$(LAB_NAME) LAB_IMAGE=$(LAB_IMAGE) LAB_ADDRESS=$(LAB_ADDRESS) LAB_LUCI_PORT=$(LAB_LUCI_PORT) \
		LAB_METRICS_PORT=$(LAB_METRICS_PORT) PKG_FULLVERSION=$(PKG_FULLVERSION) devenv/scripts/lab.sh up

lab-down:
	@LAB_NAME=$(LAB_NAME) devenv/scripts/lab.sh down

# ---- luci-app-prometheus-exporter --------------------------------------------
LUCI_IMAGE    := ucode-prometheus-exporter-luci:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)
BROWSER_IMAGE := ucode-prometheus-exporter-browser:$(shell sed -n 's/.*"@playwright\/test": "\(.*\)".*/\1/p' devenv/services/browser/package.json)
# The collector packages the browser tests install besides the base package: options of
# each type, configs read, a name with '-'.
BROWSER_COLLECTORS := dhcp_leases ltq-dsl textfile unbound wifi wireguard

# The LuCI pages against the built packages and a stand-in for procd; see devenv/scripts/browser.sh.
browser: package
	docker build -q -t $(LUCI_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg FEED_DEPENDS="$$(devenv/scripts/package-info.sh feed-depends) $$(devenv/scripts/package-info.sh app-depends)" \
		devenv/services/luci >/dev/null
	docker build -q -t $(BROWSER_IMAGE) devenv/services/browser >/dev/null
	@LUCI_IMAGE=$(LUCI_IMAGE) BROWSER_IMAGE=$(BROWSER_IMAGE) PKG_FULLVERSION=$(PKG_FULLVERSION) \
		BROWSER_COLLECTORS='$(BROWSER_COLLECTORS)' FILTER='$(FILTER)' devenv/scripts/browser.sh

# The translation template, from the LuCI sources; make lint checks it is up to date.
I18N_IMAGE := ucode-prometheus-exporter-i18n:$(shell sha256sum devenv/services/i18n/Dockerfile | cut -c1-12)
pot: ; @I18N_IMAGE=$(I18N_IMAGE) devenv/scripts/pot.sh

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

.PHONY: test unit integration watch lint shell image fixtures package package-check browser pot

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

PKG_FIELD       = $(shell sed -n 's/^PKG_$(1):=//p' openwrt/prometheus-node-exporter-ucode/Makefile)
PKG_FULLVERSION := $(call PKG_FIELD,VERSION)-r$(call PKG_FIELD,RELEASE)
SDK_IMAGE       := ghcr.io/openwrt/sdk:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)
PKG_DIR         := /builder/package/prometheus-node-exporter-ucode

# fakeroot's faked closes every descriptor up to the open-file limit when it starts;
# where the daemon's limit is unbounded (about a billion) each start takes minutes.
package:
	@mkdir -p bin && chmod a+rwx bin
	docker run --rm --ulimit nofile=1024:524288 \
		-v $(CURDIR)/openwrt/prometheus-node-exporter-ucode/Makefile:$(PKG_DIR)/Makefile:ro \
		-v $(CURDIR)/src:$(PKG_DIR)/src:ro \
		-v $(CURDIR)/files:$(PKG_DIR)/files:ro \
		-v $(CURDIR)/luci:$(PKG_DIR)/luci:ro \
		-v $(CURDIR)/LICENSE:$(PKG_DIR)/LICENSE:ro \
		-v $(CURDIR)/NOTICE:$(PKG_DIR)/NOTICE:ro \
		-v $(CURDIR)/bin:/artifacts \
		$(SDK_IMAGE) sh -c 'make defconfig >/dev/null && \
			make package/prometheus-node-exporter-ucode/compile $(if $(VERBOSE),V=s) && \
			find bin \( -name "prometheus-node-exporter-ucode*-$(PKG_FULLVERSION).apk" \
				-o -name "luci-app-prometheus-node-exporter-ucode-$(PKG_FULLVERSION).apk" \) -exec cp {} /artifacts/ \;'

PKGCHECK_IMAGE := prometheus-node-exporter-ucode-pkgcheck:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)

# No network: the image carries the dependencies.
package-check: package
	docker build -q -t $(PKGCHECK_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg FEED_DEPENDS="$$(devenv/scripts/package-info.sh feed-depends) $$(devenv/scripts/package-info.sh app-depends) quickjs" \
		devenv/services/pkgcheck >/dev/null
	docker run --rm $(if $(CI),,-t) --network none -e PKG_FULLVERSION=$(PKG_FULLVERSION) \
		-e BASE_COLLECTORS="$$(devenv/scripts/package-info.sh base-collectors)" \
		-v $(CURDIR)/bin:/artifacts:ro \
		-v $(CURDIR):/exporter:ro \
		$(PKGCHECK_IMAGE) /exporter/devenv/scripts/package-check.sh

# ---- luci-app-prometheus-node-exporter-ucode ----------------------------------
LUCI_IMAGE    := prometheus-node-exporter-ucode-luci:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)
BROWSER_IMAGE := prometheus-node-exporter-ucode-browser:$(shell sed -n 's/.*"@playwright\/test": "\(.*\)".*/\1/p' devenv/services/browser/package.json)
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
I18N_IMAGE := prometheus-node-exporter-ucode-i18n:$(shell sha256sum devenv/services/i18n/Dockerfile | cut -c1-12)
pot: ; @I18N_IMAGE=$(I18N_IMAGE) devenv/scripts/pot.sh

# make failure-demo: the pkgcheck image, with the feed's Lua exporter fetched
# into /opt/lua, every collector package of it that installs here, with what
# they depend on. Fetched, not installed: this exporter's packages refuse it
# beside them, so a container installs one or the other
# (devenv/scripts/failure-demo/run.sh).
ARG BASE
FROM ${BASE}

ARG LUA_PACKAGES
RUN mkdir -p /opt/lua && apk fetch -R -o /opt/lua $LUA_PACKAGES >/dev/null

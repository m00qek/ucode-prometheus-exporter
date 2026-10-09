#!/bin/sh
# make monitoring-check: the alerting rules of monitoring/, with the tools of
# the servers that load them, in their official images, without the network:
# - every metric and label they name is in docs/reference/metrics.md
#   (monitoring-refs.py, in the docs' mkdocs image, which has Python and YAML);
# - promtool checks the rules and runs their tests, and vmalert loads them
#   and vmalert-tool runs the same tests, as VictoriaMetrics would.
# usage: monitoring-check.sh
set -eu
cd "$(dirname "$0")/../.."

: "${PROMETHEUS_IMAGE:?run through make monitoring-check}" "${VMALERT_IMAGE:?}" "${VMALERT_TOOL_IMAGE:?}" \
	"${PYTHON_IMAGE:?}"

status=0
run() { docker run --rm --network none -u "$(id -u):$(id -g)" -v "$PWD:/exporter:ro" -w /exporter "$@"; }
step() { printf '%s\n' "$*"; }

rules=$(ls monitoring/prometheus/*.rules.yml)
tests=$(ls monitoring/prometheus/tests/*.test.yml)

step "metrics and labels against docs/reference/metrics.md"
run --entrypoint python3 "$PYTHON_IMAGE" -I devenv/scripts/monitoring-refs.py || status=1

# The check must still catch what it is for: a family the reference does not
# have, and a label its family does not.
bad=$(mktemp -d)
printf 'groups:\n  - name: x\n    rules:\n      - alert: X\n        expr: node_load_1 > 1\n' >"$bad/a.rules.yml"
printf 'groups:\n  - name: x\n    rules:\n      - alert: X\n        expr: node_load1{device="x"} > 1\n' >"$bad/b.rules.yml"
for f in a b; do
	docker run --rm --network none -u "$(id -u):$(id -g)" -v "$PWD:/exporter:ro" -v "$bad:/bad:ro" -w /exporter \
		--entrypoint python3 "$PYTHON_IMAGE" -I devenv/scripts/monitoring-refs.py "/bad/$f.rules.yml" >/dev/null 2>&1 &&
		{ echo "monitoring-refs.py let through $(sed -n 's/.*expr: //p' "$bad/$f.rules.yml")" >&2; status=1; }
done
rm -rf "$bad"

step "promtool check rules"
# shellcheck disable=SC2086 # one argument per file
run --entrypoint /bin/promtool "$PROMETHEUS_IMAGE" check rules $rules || status=1

step "promtool test rules"
# shellcheck disable=SC2086
run --entrypoint /bin/promtool "$PROMETHEUS_IMAGE" test rules $tests || status=1

step "vmalert -dryRun"
rule_args=
for f in $rules; do rule_args="$rule_args -rule=$f"; done
# shellcheck disable=SC2086
run "$VMALERT_IMAGE" -dryRun $rule_args -loggerLevel=ERROR || status=1

step "vmalert-tool unittest"
test_args=
for f in $tests; do test_args="$test_args -files=$f"; done
# shellcheck disable=SC2086
run "$VMALERT_TOOL_IMAGE" unittest -disableAlertgroupLabel $test_args || status=1

exit $status

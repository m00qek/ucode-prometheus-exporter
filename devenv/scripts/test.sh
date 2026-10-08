#!/bin/sh
# Runs inside the openwrt container.
# usage: test.sh {unit|integration|all|watch} [-f FILTER] [-v] [-t SECONDS] [PATH...]
# -t stops a run that takes longer, 300 seconds by default; the whole suite
# takes under a minute.
set -e
cd "$(dirname "$0")/../.."

suites() {
	case "$1" in
	unit) roots=test/unit ;;
	integration) roots=test/integration ;;
	# The docs generator's tests (test/docs/gen) run with the rest.
	*) roots="test/unit test/integration test/docs" ;;
	esac
	find $roots -name '*_test.uc' -exec dirname {} \; | sort -u
}

# Stops utest, $1, when it has run for $limit seconds, and says which test
# file it was in. utest stops a test file at 60 seconds, but not a run of
# many files that each take that long. It runs each file in a worker of
# its own session, `ucode ... bootstrap.uc '{"file": ...}'`; it runs in one
# of its own here too, and each session's group is signalled whole. A
# worker's children keep its arguments.
watchdog() {
	trap 'kill "$nap" 2>/dev/null; exit 0' TERM
	sleep "$limit" &
	nap=$!
	wait "$nap"
	workers=
	files=
	for cmdline in /proc/[0-9]*/cmdline; do
		file=$(tr '\0' ' ' <"$cmdline" 2>/dev/null | sed -n 's/^ucode .*bootstrap\.uc .*"file": *"\([^"]*\)".*/\1/p')
		[ -n "$file" ] || continue
		pid=${cmdline#/proc/}
		workers="$workers ${pid%/cmdline}"
		files="$files$file
"
	done
	if [ -n "$files" ]; then
		printf '%s' "$files" | sort -u | sed "s|^|test.sh: stopped after ${limit}s, in |" >&2
	else
		echo "test.sh: stopped after ${limit}s, between test files" >&2
	fi
	for pid in "$1" $workers; do kill -TERM -"$pid" 2>/dev/null || true; done
	sleep 10
	for pid in "$1" $workers; do kill -KILL -"$pid" 2>/dev/null || true; done
}

run() {
	kind=$1
	shift
	[ $# -gt 0 ] || set -- $(suites "$kind")
	setsid utest -c test/utest.config.uc -r "$reporter" ${filter:+-f "$filter"} "$@" &
	pid=$!
	watchdog "$pid" &
	dog=$!
	status=0
	wait "$pid" || status=$?
	kill "$dog" 2>/dev/null || true
	return "$status"
}

cmd=${1:-all}
[ $# -gt 0 ] && shift
reporter=compact
filter=
limit=300
while getopts f:vt: opt; do
	case $opt in
	f) filter=$OPTARG ;;
	v) reporter=detailed ;;
	t) limit=$OPTARG ;;
	*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))

case $cmd in
unit | integration | all) run "$cmd" "$@" ;;
watch)
	trap 'exit 130' INT TERM
	while :; do
		run all "$@" || true
		inotifywait -qq -r -e close_write,create,delete,move src test files devenv/scripts docs/gen
	done
	;;
*)
	echo "usage: $0 {unit|integration|all|watch} [-f FILTER] [-v] [-t SECONDS] [PATH...]" >&2
	exit 2
	;;
esac

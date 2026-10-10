#!/bin/sh
# Prints the docker run arguments that mask the host's watchdogs in a privileged
# container: /dev/null bound over each /dev/watchdog*. procd, as PID 1, opens
# /dev/watchdog and feeds it; a privileged container sees the host's, and when
# it stops the timer runs on with nothing feeding it, and resets the machine.
for w in /dev/watchdog*; do
	[ -e "$w" ] && printf -- '--mount type=bind,src=/dev/null,dst=%s ' "$w"
done
exit 0

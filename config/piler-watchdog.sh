#!/bin/sh
#
# Watchdog for the piler daemon. piler forks and manages its own pidfile and
# has no foreground mode, so supervisord can't run it directly. This keeps an
# eye on the pidfile: restart the daemon if it dies, and if it stays down after
# a few attempts terminate supervisord (pid 1) so the whole container is
# restarted clean by the orchestrator - the same escalation exit-on-fatal does
# for the programs supervisord can supervise itself.
#
set -u

PIDFILE="/var/piler/run/piler.pid"
MAX_FAILURES=3
INTERVAL=10

fails=0
while true; do
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        fails=0
    else
        fails=$((fails + 1))
        if [ "$fails" -ge "$MAX_FAILURES" ]; then
            echo "piler-watchdog: piler still down after $((fails - 1)) restart attempts, terminating supervisord to force a container restart" >&2
            kill -TERM 1
            exit 1
        fi
        echo "piler-watchdog: piler is down, restarting (attempt ${fails})" >&2
        /etc/init.d/rc.piler start || true
    fi
    sleep "$INTERVAL"
done

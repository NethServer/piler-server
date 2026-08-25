#!/bin/sh
#
# Runs piler in the foreground for supervisord. piler writes its pidfile even
# without -d, so rc.piler reload keeps working.
#
set -u

PIDFILE="/var/piler/run/piler.pid"

# piler refuses to start if the pidfile exists; a SIGKILL leaves one behind.
mkdir -p "$(dirname "$PIDFILE")"
rm -f "$PIDFILE"

exec /usr/sbin/piler

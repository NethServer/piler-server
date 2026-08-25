#!/bin/sh
#
# Runs piler in the foreground for supervisord. piler writes its pidfile even
# without -d, so rc.piler reload keeps working.
#
set -u

PIDFILE="/var/piler/run/piler.pid"
DRAIN="${PILER_STOP_DRAIN:-1}"
DRAIN_TIMEOUT="${PILER_STOP_DRAIN_TIMEOUT:-300}"
DRAIN_INTERVAL="${PILER_STOP_DRAIN_INTERVAL:-2}"

WORKDIR="$(/usr/sbin/pilerconf -q workdir 2>/dev/null | cut -f2 -d=)"
[ -n "$WORKDIR" ] || WORKDIR="/var/piler/tmp"

spool_count() {
   find "$WORKDIR" -type f 2>/dev/null | wc -l
}

# piler-smtp stops first (lower supervisord priority), so nothing refills the
# spool while we wait for the archiver to empty it.
drain_and_stop() {
   if [ "$DRAIN" = "1" ]; then
      elapsed=0
      while [ "$(spool_count)" -gt 0 ] && [ "$elapsed" -lt "$DRAIN_TIMEOUT" ]; do
         kill -0 "$piler_pid" 2>/dev/null || break
         echo "piler-run: draining spool, $(spool_count) file(s) left"
         sleep "$DRAIN_INTERVAL"
         elapsed=$((elapsed + DRAIN_INTERVAL))
      done

      left="$(spool_count)"
      if [ "$left" -eq 0 ]; then
         echo "piler-run: spool drained"
      else
         echo "piler-run: giving up with ${left} file(s) left after ${elapsed}s"
      fi
   fi

   kill "$piler_pid" 2>/dev/null

   waited=0
   while kill -0 "$piler_pid" 2>/dev/null && [ "$waited" -lt 15 ]; do
      sleep 1
      waited=$((waited + 1))
   done
   kill -9 "$piler_pid" 2>/dev/null

   exit 0
}

# piler refuses to start if the pidfile exists; a SIGKILL leaves one behind.
mkdir -p "$(dirname "$PIDFILE")"
rm -f "$PIDFILE"

/usr/sbin/piler &
piler_pid=$!

trap drain_and_stop TERM INT

wait "$piler_pid"
exit $?

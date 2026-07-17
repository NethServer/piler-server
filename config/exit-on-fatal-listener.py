#!/usr/bin/env python3
"""Supervisor event listener: exit the whole container on a FATAL process.

supervisord's own default behaviour is to give up retrying a crash-looping
program (after startretries/startsecs are exhausted) and leave it dead while
supervisord itself, and therefore the container, keeps running. That hides
the failure from whatever is supervising the container (systemd, podman
"restart:", ...), which is worse than a clean restart.

This listener subscribes to PROCESS_STATE_FATAL events and, when one fires,
kills supervisord's own pid so the container exits and the outer supervisor
(systemd unit, podman/compose restart policy) restarts it from scratch.

Protocol: https://supervisord.org/events.html#event-listeners-and-event-notifications
"""
import os
import signal
import sys


def write_stdout(msg: str) -> None:
    sys.stdout.write(msg)
    sys.stdout.flush()


def main() -> None:
    while True:
        write_stdout("READY\n")

        line = sys.stdin.readline()
        headers = dict(field.split(":") for field in line.split())
        length = int(headers["len"])
        payload = sys.stdin.read(length)

        write_stdout("RESULT 2\nOK")

        if headers.get("eventname") == "PROCESS_STATE_FATAL":
            sys.stderr.write(f"exiting: a supervised process is FATAL ({payload})\n")
            sys.stderr.flush()
            os.kill(1, signal.SIGTERM)


if __name__ == "__main__":
    main()

#!/usr/bin/env bash

# Give the engine and its descendants their own process group. The manager's
# input belongs to the watcher, not the engine.
set -m
exec "$@" </dev/null &
engine=$!

# EOF also arrives when the manager is killed and cannot close the port itself.
(
    while IFS= read -r; do :; done
    kill -KILL -- "-$engine" 2>/dev/null
) &
watcher=$!

cleanup() {
    kill "$watcher" 2>/dev/null
    kill -KILL -- "-$engine" 2>/dev/null
    wait "$watcher" 2>/dev/null
}

trap 'cleanup; exit 1' HUP INT TERM
wait "$engine" 2>/dev/null
status=$?
cleanup
exit "$status"

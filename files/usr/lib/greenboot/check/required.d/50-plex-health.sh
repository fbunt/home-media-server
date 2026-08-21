#!/usr/bin/env bash
# greenboot required check: Plex must answer once it's supposed to be running.
#
# Semantics:
#   - The plex Quadlet is baked into the image, so plex.service always exists
#     (as a generated unit; note `systemctl is-enabled` reports "generated"
#     with exit 0, so it is NOT a useful "did the operator opt in" signal).
#   - Poll http://localhost:32400/identity for up to MAX_WAIT_SECS; exit 0 on
#     the first success. /identity answers even on an unclaimed server, so
#     this works before Plex is configured.
#   - If time runs out while plex.service is still "activating" (e.g. the
#     very first boot is pulling the container image, which can take far
#     longer than any sane health window), exit 0: a slow pull is not a bad
#     deployment, and failing here would put a fresh install into a greenboot
#     rollback loop.
#   - Otherwise exit 1 (required-check failure -> greenboot rollback handling).
set -uo pipefail

UNIT="plex.service"
URL="http://localhost:32400/identity"
MAX_WAIT_SECS=180
SLEEP_SECS=5

if ! systemctl cat "${UNIT}" >/dev/null 2>&1; then
    echo "50-plex-health: ${UNIT} does not exist, skipping (nothing to check)"
    exit 0
fi

echo "50-plex-health: waiting for ${URL} to respond (up to ${MAX_WAIT_SECS}s)"

elapsed=0
while [ "${elapsed}" -lt "${MAX_WAIT_SECS}" ]; do
    if curl --fail --silent --max-time 5 "${URL}" >/dev/null 2>&1; then
        echo "50-plex-health: Plex responded on ${URL}"
        exit 0
    fi
    sleep "${SLEEP_SECS}"
    elapsed=$((elapsed + SLEEP_SECS))
done

state="$(systemctl is-active "${UNIT}" 2>/dev/null || true)"
if [ "${state}" = "activating" ]; then
    echo "50-plex-health: ${UNIT} still activating after ${MAX_WAIT_SECS}s (likely first image pull); not failing the boot"
    exit 0
fi

echo "50-plex-health: Plex did not respond on ${URL} within ${MAX_WAIT_SECS}s (unit state: ${state})" >&2
exit 1

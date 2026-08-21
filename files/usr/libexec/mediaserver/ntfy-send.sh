#!/usr/bin/env bash
# ntfy-send.sh <title> <body>
#
# Small helper that posts a notification to an ntfy topic on behalf of
# other media-server scripts/units. Configuration lives on the host at
# /etc/mediaserver/ntfy.env (see ntfy.env.example for the committed
# template) and is never baked into the image.
#
# By design this NEVER breaks the caller: if the env file is missing, or
# required variables aren't set, or curl fails, we print a note and exit 0
# so a notification hiccup can never fail a boot check or a backup job.
set -uo pipefail

ENV_FILE="/etc/mediaserver/ntfy.env"
TITLE="${1:-}"
BODY="${2:-}"

if [ ! -f "${ENV_FILE}" ]; then
    echo "ntfy-send: ${ENV_FILE} not found, skipping notification" >&2
    exit 0
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

if [ -z "${NTFY_SERVER:-}" ] || [ -z "${NTFY_TOPIC:-}" ]; then
    echo "ntfy-send: NTFY_SERVER/NTFY_TOPIC not set in ${ENV_FILE}, skipping" >&2
    exit 0
fi

if ! curl --fail --silent --show-error --max-time 10 \
        -H "Title: ${TITLE}" \
        -d "${BODY}" \
        "${NTFY_SERVER%/}/${NTFY_TOPIC}" >/dev/null 2>&1; then
    echo "ntfy-send: failed to POST notification to ${NTFY_SERVER%/}/${NTFY_TOPIC}" >&2
fi

exit 0

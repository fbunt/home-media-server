#!/usr/bin/env bash
# Sends the "booted, updated and healthy" ntfy notification once greenboot
# has confirmed the boot is healthy. Includes the current bootc deployment
# image digest when available, so notifications double as a lightweight
# "which build is running" log.
set -uo pipefail

NTFY_SEND="/usr/libexec/mediaserver/ntfy-send.sh"
TITLE="media-server: booted, updated and healthy"

DEPLOYMENT_INFO="(bootc status unavailable)"
if command -v bootc >/dev/null 2>&1; then
    STATUS_JSON="$(bootc status --format json 2>/dev/null || true)"
    if [ -n "${STATUS_JSON}" ]; then
        if command -v jq >/dev/null 2>&1; then
            DIGEST="$(printf '%s' "${STATUS_JSON}" | jq -r '.status.booted.image.image.image // "unknown"' 2>/dev/null || echo "unknown")"
            DEPLOYMENT_INFO="booted image: ${DIGEST}"
        else
            # No jq available: fall back to the raw status output so we
            # still get useful info in the notification body.
            DEPLOYMENT_INFO="bootc status (raw, jq unavailable): ${STATUS_JSON}"
        fi
    fi
fi

BODY="${DEPLOYMENT_INFO}"

"${NTFY_SEND}" "${TITLE}" "${BODY}"

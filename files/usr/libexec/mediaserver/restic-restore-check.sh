#!/bin/bash
# restic-restore-check.sh - verify the restic backup is actually restorable.
#
# This does NOT modify the live /var/srv or /etc/mediaserver data. It lists
# available snapshots, then performs a dry-run restore of the latest snapshot
# to a scratch directory (/var/tmp/restic-restore-test) so an operator can
# eyeball that a real restore would succeed and see what would land.
#
# Used by the README's backup-verification procedure. Run manually, e.g.:
#   sudo /usr/libexec/mediaserver/restic-restore-check.sh
#
# Configuration is read from /etc/mediaserver/restic.env, same as
# restic-backup.sh.

set -euo pipefail

ENV_FILE="/etc/mediaserver/restic.env"
RESTIC_IMAGE="docker.io/restic/restic:latest"
RESTORE_TEST_DIR="/var/tmp/restic-restore-test"

log() {
    printf '%s %s\n' "$(date -Iseconds)" "$*" >&2
}

if [[ ! -f "${ENV_FILE}" ]]; then
    log "ERROR: ${ENV_FILE} not found. Copy files/etc/mediaserver/restic.env.example to ${ENV_FILE} and fill in real values."
    exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

for var in RESTIC_REPOSITORY B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD; do
    if [[ -z "${!var:-}" || "${!var:-}" == CHANGE_ME* ]]; then
        log "ERROR: ${var} is not set (or still a placeholder) in ${ENV_FILE}."
        exit 1
    fi
done

mkdir -p "${RESTORE_TEST_DIR}"

podman_restic() {
    podman run --rm --pull=newer \
        --security-opt label=disable \
        --env-file "${ENV_FILE}" \
        -v "${RESTORE_TEST_DIR}:${RESTORE_TEST_DIR}:rw" \
        "${RESTIC_IMAGE}" "$@"
}

log "Listing snapshots in ${RESTIC_REPOSITORY}..."
podman_restic snapshots

log "Dry-run restoring latest snapshot to ${RESTORE_TEST_DIR} (no files will actually be written)..."
podman_restic restore latest --target "${RESTORE_TEST_DIR}" --dry-run --verify

log "Restore check complete. Nothing was written to disk (--dry-run)."
log "To perform a REAL test restore, re-run 'restic restore latest --target ${RESTORE_TEST_DIR}' without --dry-run,"
log "then inspect ${RESTORE_TEST_DIR} and remove it when done: rm -rf ${RESTORE_TEST_DIR}"

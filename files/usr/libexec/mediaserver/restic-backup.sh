#!/bin/bash
# restic-backup.sh - back up irreplaceable config/state to Backblaze B2 via restic.
#
# Scope: ONLY /var/srv (app config/state: plex, tdarr, uptime-kuma, scrutiny) and
# /etc/mediaserver (our own env files / config). This script NEVER touches
# /var/mnt/media (the NFS media share) -- that content is not backed up here,
# it is expected to be replaceable/re-acquirable and backing it up to B2 would
# be both expensive and pointless for a home media library.
#
# restic is not part of the ucore base image, so we run it via podman using
# the upstream restic/restic container image instead of layering it into the
# Containerfile. The backup targets are bind-mounted read-only. We deliberately
# do NOT add :Z/:z SELinux relabeling to these mounts: relabeling read-write
# app data directories that are actively used by other running containers
# (Plex, Tdarr, etc.) could flip their SELinux labels away from what those
# containers expect, breaking them. Instead we mount plain "ro" and pass
# --security-opt label=disable on the restic container itself, which disables
# SELinux separation for just this short-lived, read-only backup container.
#
# Configuration lives in /etc/mediaserver/restic.env (see
# files/etc/mediaserver/restic.env.example in the repo for the template).

set -euo pipefail

ENV_FILE="/etc/mediaserver/restic.env"
CACHE_DIR="/var/srv/.restic-cache"
RESTIC_IMAGE="docker.io/restic/restic:latest"
BACKUP_PATHS=(/var/srv /etc/mediaserver)
HOSTNAME_TAG="$(hostname -s 2>/dev/null || echo media-server)"

log() {
    printf '%s %s\n' "$(date -Iseconds)" "$*" >&2
}

if [[ ! -f "${ENV_FILE}" ]]; then
    log "ERROR: ${ENV_FILE} not found. Copy files/etc/mediaserver/restic.env.example to ${ENV_FILE}, fill in real values, and re-run."
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

mkdir -p "${CACHE_DIR}"

# Send a Healthchecks.io ping if configured. Never fails the script.
ping_healthchecks() {
    local suffix="${1:-}"
    if [[ -n "${HEALTHCHECKS_URL:-}" && "${HEALTHCHECKS_URL}" != CHANGE_ME* ]]; then
        curl -fsS -m 10 --retry 3 "${HEALTHCHECKS_URL}${suffix}" >/dev/null 2>&1 || true
    fi
}

on_error() {
    local exit_code=$?
    log "ERROR: restic backup failed (exit ${exit_code})."
    ping_healthchecks "/fail"
    exit "${exit_code}"
}
trap on_error ERR

podman_restic() {
    podman run --rm --pull=newer \
        --security-opt label=disable \
        --env-file "${ENV_FILE}" \
        -v /var/srv:/var/srv:ro \
        -v /etc/mediaserver:/etc/mediaserver:ro \
        -v "${CACHE_DIR}:/root/.cache/restic:rw" \
        "${RESTIC_IMAGE}" "$@"
}

log "Ensuring restic repository exists (init is a no-op if already initialized)..."
podman_restic snapshots >/dev/null 2>&1 || podman_restic init

log "Starting restic backup of: ${BACKUP_PATHS[*]}"
podman_restic backup \
    --one-file-system \
    --tag mediaserver \
    --tag "host:${HOSTNAME_TAG}" \
    --exclude '/var/srv/tdarr/cache' \
    --exclude '/var/srv/plex/**/Cache' \
    --exclude '/var/srv/plex/**/Codecs' \
    --exclude '/var/srv/plex/**/Crash Reports' \
    --exclude '/var/srv/plex/**/Transcode*' \
    --exclude '/var/srv/plex/**/transcode*' \
    "${BACKUP_PATHS[@]}"

log "Pruning old snapshots (keep 7 daily, 4 weekly, 6 monthly)..."
podman_restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune

log "Backup complete."
ping_healthchecks

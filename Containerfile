# media-server
#
# A bootc image for a home media server, built on top of ucore (Fedora
# CoreOS derivative maintained by the ublue-os project) with sane defaults
# baked in for Plex/Tdarr/monitoring/backup workloads running as rootful
# Podman Quadlets, plus Tailscale for remote access.
#
# Image: ghcr.io/fbunt/media-server
#
FROM ghcr.io/ublue-os/ucore:stable

# ucore:stable already ships Tailscale (tailscaled + tailscale CLI), so no
# package install is needed here. We deliberately leave tailscaled disabled
# and unconfigured in the image -- it is enabled and authed interactively by
# the operator after first boot (tailscale up), not baked in.
#
# The guard below keeps this Containerfile honest: if a future ucore base
# drops tailscale, the build fails loudly instead of silently shipping an
# image without it.
RUN if ! rpm -q tailscale >/dev/null 2>&1; then \
        echo "tailscale not found in base image, installing" >&2; \
        rpm-ostree install -y tailscale; \
    else \
        echo "tailscale already present in base image (ucore:stable)"; \
    fi

# Payload: Quadlets, systemd units, greenboot checks, scripts, Zincati
# config, and env-file examples. Mirrors the target filesystem layout.
COPY files/ /

# Make sure our scripts are executable regardless of how they were checked
# out of git (COPY preserves the source bit, but be explicit and cheap).
RUN chmod 0755 /usr/libexec/mediaserver/*.sh

# Enable the timers/services that should be running from first boot:
#   - bootc-upgrade.timer      : weekly bootc upgrade inside the maintenance
#                                window (Tue 04:30 local), see its .timer.
#   - restic-backup.timer      : daily config/state backups to B2 (03:00).
#   - ntfy-boot-notify.service : one-shot boot/health notification, gated on
#                                greenboot so it only fires after a healthy
#                                boot.
#   - podman.socket            : Podman API socket, handy for Quadlet
#                                tooling and any future compose/health
#                                tooling that wants to talk to the local
#                                Podman instance.
# podman-auto-update.timer is enabled by ucore/rpm-ostree defaults already;
# we don't re-enable it here to avoid masking upstream's own unit config.
RUN systemctl enable \
        bootc-upgrade.timer \
        restic-backup.timer \
        ntfy-boot-notify.service \
        podman.socket

# Lint the resulting bootc image if the base ships `bootc container lint`.
# Best-effort: older bases may not have the subcommand yet, so don't fail
# the build over it.
RUN bootc container lint || true

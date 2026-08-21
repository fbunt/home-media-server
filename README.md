# media-server

A [bootc](https://containers.github.io/bootc/) image for my home media server: Plex, Tdarr (+ QSV transcode node), Uptime Kuma, and Scrutiny, running as rootful Podman Quadlets on top of `ghcr.io/ublue-os/ucore:stable` (Fedora CoreOS derivative). Media lives on a NAS over NFS; app config/state is local and gets backed up off-box with restic.

## Hardware

- Dell OptiPlex 7080 SFF, i7-10700, Intel UHD 630 (QSV via `/dev/dri`), 16GB RAM.
- Media storage: UGREEN DXP2800 NAS over NFS (**not yet acquired** — the mount currently points at a placeholder `nas.local:/volume1/media`).

## Base image and update strategy

Built `FROM ghcr.io/ublue-os/ucore:stable`. Tailscale ships with ucore already; it's left disabled/unconfigured in the image and is enabled interactively post-install (`tailscale up`), never baked in with a key.

Everything updates inside one **Tuesday 04:00–06:00 local** maintenance window:

| Mechanism | Schedule | Role |
|---|---|---|
| `podman-auto-update.timer` | Tue 04:00 local | Pulls fresh `:latest`/`:registry`-tagged container images for all Quadlets (`AutoUpdate=registry` label on each) |
| `bootc-upgrade.timer` → `bootc-upgrade.service` | Tue 04:30 local (10 min jitter) | `bootc upgrade --quiet`, pulls/stages the next `ghcr.io/fbunt/media-server` build |
| Zincati (`files/etc/zincati/config.d/55-updates-strategy.toml`) | `periodic` strategy, window Tue 04:00, 120 min, `time_zone = "localtime"` | See caveat below |

**Zincati caveat:** Zincati manages updates against *Fedora CoreOS's* own update graph (Cincinnati). Once the host is rebased onto a custom bootc image (`ghcr.io/fbunt/media-server`), it's no longer tracking the FCOS stream it was designed for, so Zincati effectively goes inert — it has nothing matching to check against. The config in this repo is kept anyway (harmless, keeps the window declaration in one canonical place, and matters if this ever reverts to a stock FCOS stream), but **`bootc-upgrade.timer` is the thing actually driving OS updates** post-rebase. Don't rely on Zincati logs to tell you the host is updating; check `bootc status` or the ntfy boot notification instead.

The GitHub Actions build (`.github/workflows/build.yml`) also runs Tuesday 08:00 UTC (ahead of local Tuesday 04:00 for US/EU timezones) so a fresh image is sitting in the registry before the window opens, plus on every push to `main`.

## Repo layout

| Path | Purpose |
|---|---|
| `Containerfile` | Builds the image: guards for tailscale, `COPY files/ /`, chmods scripts, enables timers/services, `bootc container lint` |
| `butane/media-server.bu` | Ignition source: SSH key, hostname, `/var/srv/*` + `/etc/mediaserver` dirs, NFS mount unit, `podman-auto-update.timer` schedule override, firstboot autorebase |
| `butane/README.md` | How to compile `.bu` → `.ign` |
| `files/usr/share/containers/systemd/*.container` | Quadlets: `plex`, `tdarr`, `tdarr-node`, `uptime-kuma`, `scrutiny` |
| `files/usr/lib/systemd/system/` | `bootc-upgrade.{service,timer}`, `restic-backup.{service,timer}`, `ntfy-boot-notify.service` |
| `files/usr/libexec/mediaserver/` | `ntfy-send.sh`, `ntfy-boot-notify.sh`, `restic-backup.sh`, `restic-restore-check.sh` |
| `files/usr/lib/greenboot/check/required.d/50-plex-health.sh` | greenboot required check: polls Plex `/identity`, tolerant of first-boot image pulls |
| `files/etc/zincati/config.d/55-updates-strategy.toml` | Zincati periodic window (see caveat above) |
| `files/etc/mediaserver/*.env.example` | Committed templates for env files that live for real at `/etc/mediaserver/*.env` on the host only |
| `.github/workflows/build.yml` | Builds and pushes `ghcr.io/fbunt/media-server` on push to `main` + weekly + manual dispatch |

## Install

### 1. Compile Butane → Ignition

Edit `butane/media-server.bu` first:

- Replace the placeholder `ssh_authorized_keys` entry (`ssh-ed25519 AAAA...REPLACE_ME fred@somewhere`) with your real public key.

Then compile:

```
cd butane
butane --pretty --strict media-server.bu -o media-server.ign
```

`*.ign` files are gitignored — a compiled Ignition config embeds whatever secrets/keys you substituted in, so it must never be committed.

### 2. Provision via CoreOS installer / ucore flow

Boot the Fedora CoreOS (or ucore) installer against the OptiPlex and feed it `media-server.ign` as the Ignition config, following the standard `coreos-installer install --ignition-file media-server.ign ...` flow (or the ucore ISO's equivalent prompt for an Ignition/Butane config). This gets the box to a stock ucore boot with our storage layout, NFS mount unit, and firstboot autorebase unit already in place.

### 3. Firstboot autorebase

`ucore-autorebase.service` (defined in the Butane config) fires once on first boot, runs:

```
rpm-ostree rebase ostree-unverified-registry:ghcr.io/fbunt/media-server:latest
```

touches `/etc/ucore-autorebase-done` so it never re-fires, and reboots. After that reboot the host is running the actual `media-server` image with all the Quadlets, timers, and greenboot check in place.

Note this is an *unverified*-registry rebase (no image signature checking). If you set up cosign/sigstore signing for the image later, switch to `ostree-image-signed:docker://...` — the commented line for that is already next to it in `media-server.bu`.

### 4. Post-install checklist

Once booted into the real image:

```
# 1. Create real env files from the committed examples (never commit these).
#    The examples ship baked into the image at /etc/mediaserver/*.env.example
#    (from files/etc/mediaserver/ in this repo), so no repo checkout is
#    needed on the box itself.
for f in ntfy plex restic scrutiny-notify; do
    sudo cp /etc/mediaserver/${f}.env.example /etc/mediaserver/${f}.env
done
sudo chmod 600 /etc/mediaserver/*.env
sudo $EDITOR /etc/mediaserver/plex.env             # PLEX_CLAIM=... (get fresh from https://plex.tv/claim, 4 min TTL)
sudo $EDITOR /etc/mediaserver/ntfy.env              # NTFY_SERVER / NTFY_TOPIC
sudo $EDITOR /etc/mediaserver/restic.env            # RESTIC_REPOSITORY / B2 creds / RESTIC_PASSWORD / HEALTHCHECKS_URL
sudo $EDITOR /etc/mediaserver/scrutiny-notify.env   # SCRUTINY_WEB_NOTIFY_URLS

# 2. Tailscale
sudo tailscale up

# 3. NFS SELinux boolean (persistent) -- required since the media mount is
#    never :Z-relabeled
sudo setsebool -P virt_use_nfs on

# 4. Point the NFS mount at the real NAS export once the DXP2800 is racked
#    and its export path is known (edit the unit, not fstab):
sudo systemctl edit --full var-mnt-media.mount   # change What= from nas.local:/volume1/media
sudo systemctl daemon-reload
sudo systemctl restart var-mnt-media.mount

# 5. Initialize the restic repository (backup service also self-inits on
#    first run, but doing it explicitly up front confirms creds work)
sudo podman run --rm --security-opt label=disable \
    --env-file /etc/mediaserver/restic.env \
    docker.io/restic/restic:latest init
```

Also check `AddDevice=` lines in `files/usr/share/containers/systemd/scrutiny.container` (`/dev/sda`, `/dev/sdb`, `/dev/nvme0` are placeholders) against real `lsblk` output on this specific box, and adjust/redeploy if they don't match.

## Rollback

Two independent rollback layers:

- **bootc / rpm-ostree rollback** (OS image level): `sudo bootc rollback` (or `rpm-ostree rollback` — same underlying ostree deployment mechanism on this base) switches the *next* boot back to the previously-booted deployment, then `sudo systemctl reboot`. Use `bootc status` first to see current vs. rollback deployment digests/tags.
- **Pinning a deployment**: `sudo ostree admin pin 0` (or the relevant deployment index from `rpm-ostree status`) keeps a known-good deployment from being garbage-collected by future upgrades — useful before a risky manual rebase, or to keep a known-good build around longer than the default retention.
- **greenboot auto-rollback**: `50-plex-health.sh` is a *required* greenboot check. If `plex.service` never answers `http://localhost:32400/identity` within 180s after boot, the check fails, greenboot marks the boot unhealthy, and on a subsequent boot greenboot's own rollback logic triggers an automatic `rpm-ostree rollback` + reboot back to the prior deployment — no manual intervention needed for that failure mode. Two escape hatches keep a fresh install out of a rollback loop: if `plex.service` doesn't exist the check skips, and if it is still `activating` when time runs out (first boot pulling the Plex image can take a while) the check passes rather than failing the boot over a slow pull.

The two layers compose: greenboot handles the "new image boots but is broken" case automatically; the manual `bootc rollback` / pinning commands are for everything else (bad config change, wanting to go back further than one deployment, etc).

## Backups

**Scope — what is backed up:** `/var/srv/{plex,tdarr,uptime-kuma,scrutiny}` (app config/state) and `/etc/mediaserver` (our own env files), via `restic-backup.service`/`.timer` (daily, 03:00, 15 min jitter) to Backblaze B2. Plex cache/transcode/crash-report subdirectories and the Tdarr cache dir are excluded (large, regenerable, not worth the B2 storage/egress).

**Scope — what is explicitly NOT backed up:** `/var/mnt/media` (the NFS media library) is never touched by `restic-backup.sh`. It's treated as replaceable/re-acquirable bulk storage; backing a media library up to B2 would be both expensive and pointless here.

**Init the repo** (idempotent — the backup script does this automatically too):

```
sudo podman run --rm --security-opt label=disable \
    --env-file /etc/mediaserver/restic.env \
    docker.io/restic/restic:latest init
```

**Manual backup:**

```
sudo systemctl start restic-backup.service
sudo journalctl -u restic-backup.service -f
```

**Restore procedure:**

1. Verify first, without touching live data — `restic-restore-check.sh` lists snapshots and does a `--dry-run --verify` restore of `latest` to a scratch dir:
   ```
   sudo /usr/libexec/mediaserver/restic-restore-check.sh
   ```
2. For a real restore, run restic directly (same container/env pattern the scripts use), e.g. to restore the latest snapshot of Plex's config only, to a scratch location for inspection before swapping it in:
   ```
   sudo podman run --rm --security-opt label=disable \
       --env-file /etc/mediaserver/restic.env \
       -v /var/tmp/restic-restore:/var/tmp/restic-restore:rw \
       docker.io/restic/restic:latest \
       restore latest --target /var/tmp/restic-restore --include /var/srv/plex
   ```
   Stop the affected container (`sudo systemctl stop plex.service`), copy the restored files into place under `/var/srv/plex`, then restart it.

**Monitoring:** `restic-backup.sh` pings a healthchecks.io URL (`HEALTHCHECKS_URL` in `restic.env`) — a plain ping on success, `${HEALTHCHECKS_URL}/fail` on any error via a trap. Wire that check's URL into a healthchecks.io check configured with a grace period comfortably longer than 24h (the backup schedule) so a missed run pages you before the next window's ntfy boot notification is the only signal.

## Notifications

- **ntfy topic setup:** create a topic (e.g. on `https://ntfy.sh` or your own instance), put its server/topic in `/etc/mediaserver/ntfy.env` (`NTFY_SERVER`, `NTFY_TOPIC`). `ntfy-send.sh` is the single POST helper every other script/unit calls; it's silent-exit-0 if the env file is missing or curl fails, so a notification outage never breaks a boot check or a backup.
- **Boot notification:** `ntfy-boot-notify.service` runs once boot is confirmed healthy (`After=`/`Requires=greenboot-healthcheck.service`, so it only fires after all `required.d` checks — including `50-plex-health.sh` — pass). Body includes the currently booted image digest (`bootc status --format json`, via `jq` if present) so notifications double as a lightweight build log.
- **Uptime Kuma:** no env-file wiring for this one — configure its built-in ntfy notification in-app (Settings → Notifications → add ntfy, point at the same server/topic) and enable it on whatever monitors you set up.
- **Scrutiny:** `SCRUTINY_WEB_NOTIFY_URLS` in `/etc/mediaserver/scrutiny-notify.env`, a shoutrrr-format URL, e.g. `ntfy://ntfy.sh/CHANGE_ME_TOPIC`. Loaded via `EnvironmentFile=-` (leading `-` = optional, Scrutiny still starts if the file is absent).

## Secrets policy

Every secret-shaped value committed to this repo is a placeholder: `CHANGE_ME*` in `files/etc/mediaserver/*.env.example`, and the `ssh-ed25519 AAAA...REPLACE_ME` string in `butane/media-server.bu`. Real values live in exactly two places, neither of them in git:

- `/etc/mediaserver/*.env` on the host (copied from the `.env.example` templates, then edited) — matched by `.gitignore`'s `*.env` (with `!*.env.example` carving the templates back in).
- Compiled `*.ign` Ignition configs, which can embed the real SSH key substituted into `media-server.bu` — also gitignored.

If you ever see a real key, token, or password in a diff against this repo, that's a bug — stop and fix it before pushing.

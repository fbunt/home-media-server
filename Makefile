# Build an install USB image for the media server.
#
# `make iso` produces build/media-server-install.iso: the stock Fedora CoreOS
# live ISO with our Ignition config embedded and an install destination set,
# so booting a stick written from it AUTOMATICALLY WIPES $(DEST_DEVICE) on
# the target machine, installs CoreOS, and reboots into the firstboot
# autorebase flow (ghcr.io/fbunt/media-server). No network needed at the
# console beyond pulling the image post-install.
#
# Everything runs in podman containers (butane, coreos-installer), so the
# only local requirement is podman. Outputs land in build/ (gitignored --
# the .ign embeds your real SSH key).
#
#   make ign                          # compile Butane -> Ignition
#   make iso                          # ign + download FCOS live ISO + embed
#   make iso DEST_DEVICE=/dev/nvme0n1 # override the disk to be wiped
#   make clean

BUTANE_IMAGE    := quay.io/coreos/butane:release
INSTALLER_IMAGE := quay.io/coreos/coreos-installer:release
STREAM          := stable
DEST_DEVICE     := /dev/sda

BU       := butane/media-server.bu
IGN      := build/media-server.ign
# Fixed-name symlink to the downloaded (version-stamped) live ISO. Must not
# itself match the fedora-coreos-* glob used to find the download.
FCOS_ISO := build/fcos-live.iso
ISO      := build/media-server-install.iso

.PHONY: ign iso clean

ign: $(IGN)

iso: $(ISO)

$(IGN): $(BU)
	@if grep -q REPLACE_ME $(BU); then \
	    echo "ERROR: $(BU) still contains the REPLACE_ME SSH key placeholder."; \
	    echo "Put your real public key in it first, or you will be locked out"; \
	    echo "of the installed machine."; \
	    exit 1; \
	fi
	mkdir -p build
	podman run --rm -i $(BUTANE_IMAGE) --strict --pretty < $(BU) > $@

$(FCOS_ISO):
	mkdir -p build
	podman run --rm -v $(CURDIR)/build:/data:Z -w /data $(INSTALLER_IMAGE) \
	    download -s $(STREAM) -p metal -f iso
	cd build && ln -sf $$(ls -t fedora-coreos-*-live*.iso | head -1) $(notdir $(FCOS_ISO))

$(ISO): $(IGN) $(FCOS_ISO)
	rm -f $@
	podman run --rm -v $(CURDIR)/build:/data:Z -w /data $(INSTALLER_IMAGE) \
	    iso customize \
	    --dest-device $(DEST_DEVICE) \
	    --dest-ignition $(notdir $(IGN)) \
	    -o $(notdir $(ISO)) \
	    $(notdir $(FCOS_ISO))
	@echo
	@echo "Wrote $@"
	@echo "Write it to a USB stick, e.g.:"
	@echo "  sudo dd if=$@ of=/dev/sdX bs=4M status=progress oflag=sync"
	@echo "Booting the target from it will WIPE $(DEST_DEVICE) and install."

clean:
	rm -rf build

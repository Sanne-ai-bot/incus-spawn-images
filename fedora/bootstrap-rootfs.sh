#!/bin/bash
set -euo pipefail

# Bootstrap the base image's root filesystem: the packages in base-packages.txt
# plus any given, installed with dnf --installroot, then configured by
# configure-base.sh in a chroot. build.sh (container) and build-vm-scratch.sh
# (VM) both start from it, so their roots differ only by what each adds.
#
# Usage: bootstrap-rootfs.sh <release> <rootfs> [extra-package...]
# Runs as root in a Fedora container of that release.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE="${1:?Usage: $0 <release> <rootfs> [extra-package...]}"
ROOTFS="${2:?Usage: $0 <release> <rootfs> [extra-package...]}"
shift 2

echo "Bootstrapping rootfs..."
mapfile -t PACKAGES < <(grep -Ev '^[[:space:]]*(#|$)' "${SCRIPT_DIR}/base-packages.txt")
dnf --use-host-config \
    --installroot="${ROOTFS}" \
    --releasever="${RELEASE}" \
    --setopt=install_weak_deps=False \
    --setopt=keepcache=False \
    --setopt=tsflags=nodocs \
    --exclude='kernel*' \
    -y install \
    "${PACKAGES[@]}" "$@"

# Remove bloat packages that ship in the base but aren't needed
echo "Removing unnecessary packages..."
dnf --use-host-config --installroot="${ROOTFS}" -y remove \
    glibc-all-langpacks geolite2-city geolite2-country 2>/dev/null || true

# Run shared base configuration inside the rootfs
echo "Configuring base system..."
cp "${SCRIPT_DIR}/configure-base.sh" "${ROOTFS}/tmp/configure-base.sh"
chroot "${ROOTFS}" bash /tmp/configure-base.sh
rm -f "${ROOTFS}/tmp/configure-base.sh"

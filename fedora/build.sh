#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=$(uname -m)
RELEASE=44
ROOTFS=/tmp/rootfs
OUTPUT=${OUTPUT_DIR:-/output}

echo "=== Building Fedora ${RELEASE} container image for ${ARCH} ==="

# ============================================================
# Phase 1: Build container rootfs
# ============================================================

# Bootstrap a complete systemd-based Fedora rootfs
bash "${SCRIPT_DIR}/bootstrap-rootfs.sh" "${RELEASE}" "${ROOTFS}"

# ============================================================
# Phase 2: Package container image
# ============================================================

echo ""
echo "=== Packaging container image ==="

# Clean all caches to minimize image size
echo "Cleaning caches..."
dnf --use-host-config --installroot="${ROOTFS}" clean all
rm -rf "${ROOTFS}/var/cache/libdnf5" "${ROOTFS}/tmp"/* "${ROOTFS}/var/tmp"/*
rm -rf "${ROOTFS}/var/log"/*

# The bootstrap's systemd scriptlets wrote a machine-id, which every container
# made from the image would share (Sanne/incus-spawn#1305). Empty, so systemd
# generates one at each instance's first start. Not "uninitialized": in a
# container's writable root that boot is a first boot, whose full preset-all
# disables systemd-networkd, its sockets and the network watchdog timer.
: > "${ROOTFS}/etc/machine-id"

# Create Incus metadata.yaml
echo "Creating metadata..."
CREATION_DATE=$(date +%s)
cat > /tmp/metadata.yaml << EOF
architecture: ${ARCH}
creation_date: ${CREATION_DATE}
properties:
  description: Fedora ${RELEASE} base for incus-spawn
  os: Fedora
  release: "${RELEASE}"
  variant: incus-spawn-base
EOF

# Incus expects container rootfs under a rootfs/ subdirectory
echo "Preparing rootfs layout..."
mkdir -p /tmp/image-root/rootfs
cp /tmp/metadata.yaml /tmp/image-root/
cp -a "${ROOTFS}/." /tmp/image-root/rootfs/

# Package as unified tarball (metadata.yaml + rootfs/ tree)
echo "Packaging image..."
mkdir -p "${OUTPUT}"
TARBALL="${OUTPUT}/fedora-${RELEASE}-${ARCH}.tar.xz"
tar --xattrs -cJf "${TARBALL}" -C /tmp/image-root .

# Compute and save SHA256
sha256sum "${TARBALL}" | awk '{print $1}' > "${TARBALL}.sha256"
echo "SHA256: $(cat "${TARBALL}.sha256")"
echo "Container output: ${TARBALL}"

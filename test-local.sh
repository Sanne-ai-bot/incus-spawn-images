#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
CONFIG_DIR="${HOME}/.config/incus-spawn/images"
OVERRIDE_FILE="${CONFIG_DIR}/minimal.yaml"
ARCH=$(uname -m)
case "${ARCH}" in
  arm64) ARCH=aarch64 ;;
  amd64) ARCH=x86_64 ;;
esac
TAG="local-$(date +%Y%m%d-%H%M%S)"
# The Fedora release fedora/build.sh and fedora/build-vm-scratch.sh build.
RELEASE=45

echo "=== Building container image locally ==="
mkdir -p "${OUTPUT_DIR}"
podman run --rm --privileged \
  -v "${SCRIPT_DIR}:/build:ro" \
  -v "${OUTPUT_DIR}:/output" \
  -e OUTPUT_DIR=/output \
  "fedora:${RELEASE}" bash /build/fedora/build.sh

TARBALL="${OUTPUT_DIR}/fedora-${RELEASE}-${ARCH}.tar.xz"
if [ ! -f "${TARBALL}" ]; then
  echo "Error: expected container tarball not found: ${TARBALL}"
  exit 1
fi

echo ""
echo "=== Booting the container image ==="
"${SCRIPT_DIR}/tests/test-container-boot.sh" "${TARBALL}"

echo ""
echo "=== Building VM image ==="
# The image built from scratch, as CI builds it (build-vm-scratch.yml): the kernel
# first, then the disk around it, published under the -vm-direct name a release uses.
"${SCRIPT_DIR}/fedora/build-vm-kernel.sh" "${SCRIPT_DIR}/build/vm-kernel" "${ARCH}"
podman run --rm --privileged \
  -v "${SCRIPT_DIR}:/build:ro" \
  -v "${OUTPUT_DIR}:/output" \
  "fedora:${RELEASE}" bash -c 'dnf -y -q install gdisk mtools e2fsprogs qemu-img xz kmod >/dev/null &&
                     bash /build/fedora/build-vm-scratch.sh /output /build/build/vm-kernel/vmlinuz'

SCRATCH_TARBALL="${OUTPUT_DIR}/fedora-${RELEASE}-${ARCH}-vm-scratch.tar.xz"
VM_TARBALL="${OUTPUT_DIR}/fedora-${RELEASE}-${ARCH}-vm-direct.tar.xz"
if [ ! -f "${SCRATCH_TARBALL}" ]; then
  echo "Error: expected VM tarball not found: ${SCRATCH_TARBALL}"
  exit 1
fi
mv -f "${SCRATCH_TARBALL}" "${VM_TARBALL}"

echo ""
echo "=== Configuring isx to use local images ==="
mkdir -p "${CONFIG_DIR}"
cat > "${OVERRIDE_FILE}" << EOF
name: tpl-minimal
description: Base OS only (local build)
image: fedora-${RELEASE}-base
image_url: file://${TARBALL}
image_tag: ${TAG}
vm_image_url: file://${VM_TARBALL}
EOF

echo "Wrote ${OVERRIDE_FILE}"
echo "Tag: ${TAG}"
echo ""
echo "Next steps:"
echo "  isx build tpl-minimal              # container build (imports local image)"
echo "  isx build tpl-minimal --type vm    # VM build (imports local VM image)"
echo "  isx build tpl-dev                   # rebuild derived templates"
echo ""
echo "To revert: ./revert-local.sh"

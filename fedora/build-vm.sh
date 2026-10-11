#!/bin/bash
set -euo pipefail

# Build a prebaked Fedora VM image for incus-spawn.
#
# Downloads the stock Incus Fedora VM image (which already has the
# incus-agent, bootloader, and kernel set up), converts to raw, mounts
# via losetup, installs packages and applies configuration, then
# repackages as an Incus VM tarball.
#
# Usage: ./build-vm.sh <output-dir>
#
# Dependencies: qemu-utils (qemu-img), jq, curl
# Must run as root (for losetup + mount).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:?Usage: $0 <output-dir>}"
ARCH=$(uname -m)
RELEASE=44
IMAGE_SERVER="https://images.linuxcontainers.org"

# --- Dependency check ---
MISSING=()
for cmd in qemu-img jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: missing required tools: ${MISSING[*]}"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root (need losetup + mount)"
  exit 1
fi

# Map uname arch to simplestreams arch
case "${ARCH}" in
  x86_64)  SS_ARCH=amd64 ;;
  aarch64) SS_ARCH=arm64 ;;
  *)
    echo "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

# --- Find the latest stock Incus Fedora VM image ---
echo "=== Building Fedora ${RELEASE} VM image (${ARCH}) ==="
echo "Querying image server for latest Fedora ${RELEASE} VM image..."

PRODUCT="fedora:${RELEASE}:${SS_ARCH}:default"
DISK_PATH=$(curl -sfL "${IMAGE_SERVER}/streams/v1/images.json" \
  | jq -r ".products[\"${PRODUCT}\"].versions | to_entries | sort_by(.key) | last | .value.items[\"disk.qcow2\"].path")

if [ -z "${DISK_PATH}" ] || [ "${DISK_PATH}" = "null" ]; then
  echo "Error: could not find VM disk image for ${PRODUCT}"
  exit 1
fi

DISK_URL="${IMAGE_SERVER}/${DISK_PATH}"
echo "Found: ${DISK_URL}"

# --- Download ---
STAGING=$(mktemp -d /tmp/vm-image-XXXXXX)
MOUNTPOINT=$(mktemp -d /tmp/vm-mount-XXXXXX)
LOOP_DEV=""

cleanup() {
  set +e
  umount "${MOUNTPOINT}/dev/pts" 2>/dev/null
  umount "${MOUNTPOINT}/dev" 2>/dev/null
  umount "${MOUNTPOINT}/proc" 2>/dev/null
  umount "${MOUNTPOINT}/sys" 2>/dev/null
  umount "${MOUNTPOINT}/run" 2>/dev/null
  umount "${MOUNTPOINT}" 2>/dev/null
  if [ -n "${LOOP_DEV}" ]; then
    losetup -d "${LOOP_DEV}" 2>/dev/null
  fi
  rm -rf "${STAGING}" "${MOUNTPOINT}"
}
trap cleanup EXIT

echo "Downloading stock VM disk..."
curl -fL --progress-bar -o "${STAGING}/disk.qcow2" "${DISK_URL}"

echo "Expanding disk to 10G..."
qemu-img resize "${STAGING}/disk.qcow2" 10G

# --- Convert to raw and mount via losetup ---
echo "Converting to raw image..."
qemu-img convert -f qcow2 -O raw "${STAGING}/disk.qcow2" "${STAGING}/disk.raw"
rm -f "${STAGING}/disk.qcow2"

echo "Mounting disk image..."
LOOP_DEV=$(losetup --find --show --partscan "${STAGING}/disk.raw")

# Find the root partition (the largest one, typically partition 2)
ROOT_DEV=$(lsblk -ln -o PATH,SIZE "${LOOP_DEV}" | tail -n +2 | sort -k2 -h | tail -1 | awk '{print $1}')

echo "Loop device: ${LOOP_DEV}"
echo "Root partition: ${ROOT_DEV}"

# Grow the partition and filesystem
growpart "${LOOP_DEV}" 2 || true
e2fsck -fy "${ROOT_DEV}" 2>/dev/null || true
resize2fs "${ROOT_DEV}" 2>/dev/null || xfs_growfs "${ROOT_DEV}" 2>/dev/null || true

mount "${ROOT_DEV}" "${MOUNTPOINT}"

# Point the root that kernel-install gives later kernels at the root filesystem,
# not at the loop device the stock image was built on (Sanne/incus-spawn#1217).
# Done before any chroot step, so a kernel a package pulls in gets a bootable entry.
# -p reads the superblock rather than blkid's cache, which may describe whatever
# was on a reused loop device before.
ROOT_UUID=$(blkid -p -s UUID -o value "${ROOT_DEV}")
bash "${SCRIPT_DIR}/kernel-cmdline.sh" "${MOUNTPOINT}/etc/kernel/cmdline" "${ROOT_UUID}"

# Removing a kernel removes its boot entry even when the machine that installed
# it had another machine-id, as the image's own kernel always did
# (Sanne/incus-spawn#1217). Also before any chroot step.
install -D -m 0755 -t "${MOUNTPOINT}/etc/kernel/install.d" "${SCRIPT_DIR}"/kernel-install/*.install

# --- Install packages via chroot ---
echo "Installing packages..."

# Bind-mount host resources for chroot
mount --bind /dev "${MOUNTPOINT}/dev"
mount --bind /dev/pts "${MOUNTPOINT}/dev/pts"
mount -t proc proc "${MOUNTPOINT}/proc"
mount -t sysfs sysfs "${MOUNTPOINT}/sys"
mount -t tmpfs tmpfs "${MOUNTPOINT}/run"

# Provide DNS for the chroot. The image's /etc/resolv.conf is typically
# a symlink to /run/systemd/resolve/stub-resolv.conf — remove it first
# so we create a real file instead of writing through the symlink.
rm -f "${MOUNTPOINT}/etc/resolv.conf"
echo "nameserver 8.8.8.8" > "${MOUNTPOINT}/etc/resolv.conf"

PACKAGES="systemd-networkd dnf5 glibc-langpack-en bash-completion git curl which procps-ng findutils iproute iputils cloud-utils-growpart e2fsprogs xfsprogs"

chroot "${MOUNTPOINT}" /bin/bash -c "dnf -y install ${PACKAGES}"
chroot "${MOUNTPOINT}" /bin/bash -c "dnf -y remove glibc-all-langpacks geolite2-city geolite2-country 2>/dev/null; true"

# --- Apply base configuration ---
echo "Applying base configuration..."
cp "${SCRIPT_DIR}/configure-base.sh" "${MOUNTPOINT}/tmp/configure-base.sh"
chroot "${MOUNTPOINT}" /bin/bash /tmp/configure-base.sh
rm -f "${MOUNTPOINT}/tmp/configure-base.sh"

# The image's own kernel boots with the options in /etc/kernel/cmdline too, as
# every later kernel does (Sanne/incus-spawn#1238). After the chroot steps, so it
# copies the file as it ships.
bash "${SCRIPT_DIR}/boot-entries.sh" "${MOUNTPOINT}"

# Fail loudly if SELinux is not pinned off (see configure-base.sh, Sanne/incus-spawn#842).
if ! grep -qx 'SELINUX=disabled' "${MOUNTPOINT}/etc/selinux/config"; then
  echo "Error: /etc/selinux/config in the image does not set SELINUX=disabled"
  exit 1
fi

# Fail loudly if a chroot step undid that, or left the build host's loop device
# anywhere the guest's boot reads it. Every kernel's options come from
# /etc/kernel/cmdline, so it must exist, name the root and set a log level, and
# every boot entry must boot with exactly what it says.
CMDLINE="${MOUNTPOINT}/etc/kernel/cmdline"
if [ ! -s "${CMDLINE}" ]; then
  echo "Error: the image has no /etc/kernel/cmdline"
  exit 1
fi
if ! grep -Eq "(^|[[:space:]])root=UUID=${ROOT_UUID}([[:space:]]|$)" "${CMDLINE}"; then
  echo "Error: /etc/kernel/cmdline in the image does not set root=UUID=${ROOT_UUID}"
  exit 1
fi
if ! grep -Eq '(^|[[:space:]])(loglevel=|quiet([[:space:]]|$)|debug([[:space:]]|$))' "${CMDLINE}"; then
  echo "Error: /etc/kernel/cmdline in the image sets no kernel log level"
  exit 1
fi
read -r -d '' -a WANT_OPTIONS < "${CMDLINE}" || true
ENTRIES=("${MOUNTPOINT}"/boot/loader/entries/*.conf)
if [ ! -e "${ENTRIES[0]}" ]; then
  echo "Error: the image has no boot entries in /boot/loader/entries"
  exit 1
fi
for entry in "${ENTRIES[@]}"; do
  # BLS joins every options line of an entry
  read -r -a GOT_OPTIONS <<< "$(sed -n 's/^options[[:space:]]*//p' "${entry}" | tr '\n' ' ')"
  if [ "${GOT_OPTIONS[*]}" != "${WANT_OPTIONS[*]}" ]; then
    echo "Error: ${entry#"${MOUNTPOINT}"} boots with '${GOT_OPTIONS[*]}', not /etc/kernel/cmdline's '${WANT_OPTIONS[*]}'"
    exit 1
  fi
done
for plugin in "${SCRIPT_DIR}"/kernel-install/*.install; do
  if [ ! -x "${MOUNTPOINT}/etc/kernel/install.d/${plugin##*/}" ]; then
    echo "Error: the image lacks the kernel-install plugin /etc/kernel/install.d/${plugin##*/}"
    exit 1
  fi
done
LOOP_REFS=$(cd "${MOUNTPOINT}" && grep -rlsE '/dev/loop[0-9]' \
  etc/kernel/cmdline etc/default/grub etc/fstab boot/loader/entries boot/grub2/grubenv || true)
if [ -n "${LOOP_REFS}" ]; then
  echo "Error: the image's boot configuration names a loop device in:"
  echo "${LOOP_REFS}"
  exit 1
fi
echo "Kernel command line: $(cat "${MOUNTPOINT}/etc/kernel/cmdline" 2>/dev/null || echo '(none)')"

# --- Unmount ---
echo "Unmounting..."
umount "${MOUNTPOINT}/dev/pts"
umount "${MOUNTPOINT}/dev"
umount "${MOUNTPOINT}/proc"
umount "${MOUNTPOINT}/sys"
umount "${MOUNTPOINT}/run"
umount "${MOUNTPOINT}"
losetup -d "${LOOP_DEV}"
LOOP_DEV=""

# --- Repackage as Incus VM tarball ---
echo "Compressing disk image..."
qemu-img convert -f raw -O qcow2 -c "${STAGING}/disk.raw" "${STAGING}/rootfs.img"
rm -f "${STAGING}/disk.raw"

echo "Packaging VM image..."
CREATION_DATE=$(date +%s)
cat > "${STAGING}/metadata.yaml" << EOF
architecture: ${ARCH}
creation_date: ${CREATION_DATE}
properties:
  description: Fedora ${RELEASE} VM base for incus-spawn
  os: Fedora
  release: "${RELEASE}"
  variant: incus-spawn-base-vm
EOF

mkdir -p "${OUTPUT}"
VM_TARBALL="${OUTPUT}/fedora-${RELEASE}-${ARCH}-vm.tar.xz"
tar -cJf "${VM_TARBALL}" -C "${STAGING}" metadata.yaml rootfs.img

sha256sum "${VM_TARBALL}" | awk '{print $1}' > "${VM_TARBALL}.sha256"
echo "SHA256: $(cat "${VM_TARBALL}.sha256")"
echo "VM output: ${VM_TARBALL}"

#!/bin/bash
set -euo pipefail

# Build the Fedora VM image for incus-spawn from scratch, around a kernel of our
# own (Sanne/incus-spawn#1255, Sanne/incus-spawn-images#12).
#
# The disk is a GPT with two partitions:
#   1  ESP (EF00, 64 MiB): one file, the kernel, at EFI/BOOT/BOOTX64.EFI
#      (BOOTAA64.EFI). OVMF/AAVMF start it by the removable-media path, with no
#      NVRAM entry, no boot loader and no initrd; its command line is built in.
#   2  root (8300, named isx-root, the PARTLABEL that command line names): ext4,
#      bootstrapped by bootstrap-rootfs.sh, as the container image's root is,
#      with the VM's own packages added, and overlaid with vm-root/ (the incus-agent units, DHCP on the first NIC,
#      fstab, the dnf kernel exclusion). No kernel packages, dracut, GRUB, shim,
#      /boot/loader or module files: /usr/lib/modules/<release>/ holds only the
#      kernel's index of built-in drivers, with depmod's output, so that
#      modprobe of one succeeds (Incus runs VMs only once
#      `modprobe vhost_vsock` does).
# The kernel is built by build-vm-kernel.sh and boots only on virtio-blk: it has
# no virtio-scsi, which is Incus's default root bus.
#
# Nothing here needs a loop device or a mount: mkfs.ext4 -d writes the root into
# the disk at the partition's offset, and mtools write the ESP, so it runs in a
# container (podman --privileged, for the chroot) and on GitHub runners.
#
# Usage: build-vm-scratch.sh <output-dir> <vmlinuz>
# Beside <vmlinuz>, build-kernel.sh vm leaves modules.builtin,
# modules.builtin.modinfo and kernelrelease; all three are required.
# Output: <output-dir>/fedora-44-<arch>-vm-scratch.tar.xz (+ .sha256), an Incus
# unified tarball (metadata.yaml + rootfs.img, qcow2).
#
# Run as root in fedora:44, with: gdisk mtools e2fsprogs qemu-img xz kmod

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:?Usage: $0 <output-dir> <vmlinuz>}"
KERNEL="${2:?Usage: $0 <output-dir> <vmlinuz>}"
ARCH=$(uname -m)
RELEASE=44
# The kernel's built-in root=PARTLABEL= (incus-spawn appliance/kernel/vm-<arch>.config).
ROOT_PARTLABEL=isx-root
DISK_SIZE=10G
ESP_MIB=64
# Beyond base-packages.txt, as in the stock VM image: the tools isx's VM build
# grows the root with (it installs them first when one is missing), and a system
# bus and pam_systemd, without which systemd-logind fails and loginctl and
# systemctl --user (isx itself, run in a VM, lingers its proxy) do not work.
VM_PACKAGES=(cloud-utils-growpart e2fsprogs xfsprogs dbus-broker systemd-pam)

case "${ARCH}" in
  x86_64)  LOADER=BOOTX64.EFI ;;
  aarch64) LOADER=BOOTAA64.EFI ;;
  *) echo "Error: unsupported architecture: ${ARCH}"; exit 1 ;;
esac

[ -f "${KERNEL}" ] || { echo "Error: kernel not found: ${KERNEL}"; exit 1; }
KERNEL_DIR="$(dirname "${KERNEL}")"
for f in modules.builtin modules.builtin.modinfo kernelrelease; do
  [ -f "${KERNEL_DIR}/${f}" ] || { echo "Error: ${f} not found beside the kernel (build-kernel.sh vm writes it)"; exit 1; }
done
KERNEL_RELEASE=$(cat "${KERNEL_DIR}/kernelrelease")
[[ "${KERNEL_RELEASE}" =~ ^[A-Za-z0-9._+-]+$ ]] || { echo "Error: unexpected kernelrelease: ${KERNEL_RELEASE}"; exit 1; }
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root (dnf --installroot and chroot)"
  exit 1
fi
MISSING=()
for cmd in dnf sgdisk mformat mmd mcopy mdir mkfs.ext4 debugfs qemu-img xz depmod modprobe; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: missing required tools: ${MISSING[*]} (gdisk mtools e2fsprogs qemu-img xz kmod)"
  exit 1
fi

STAGING=$(mktemp -d /tmp/vm-scratch-XXXXXX)
trap 'rm -rf "${STAGING}"' EXIT
ROOTFS="${STAGING}/rootfs"

echo "=== Building Fedora ${RELEASE} VM image from scratch (${ARCH}) ==="

# ---- Root filesystem ----

bash "${SCRIPT_DIR}/bootstrap-rootfs.sh" "${RELEASE}" "${ROOTFS}" "${VM_PACKAGES[@]}"

echo "Adding the VM's own files..."
cp -R --no-preserve=ownership "${SCRIPT_DIR}/vm-root/." "${ROOTFS}/"
# The bootstrap's systemd scriptlets wrote a machine-id, which every VM made
# from the image would share. An empty file, never committed, makes systemd take
# each boot's ID from the VM's SMBIOS UUID (the kernel has DMI for it), which
# Incus makes anew for every copy and keeps across restarts: so a copy of a VM
# that has booted gets its own too (Sanne/incus-spawn#1483). Not
# "uninitialized": that makes a boot a first boot, and Fedora's full preset-all
# then disables systemd-networkd and the network watchdog (#1305).
: > "${ROOTFS}/etc/machine-id"
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/systemd-machine-id-commit.service"

echo "Indexing the kernel's built-in drivers (${KERNEL_RELEASE})..."
MODDIR="${ROOTFS}/usr/lib/modules/${KERNEL_RELEASE}"
mkdir -p "${MODDIR}"
cp "${KERNEL_DIR}/modules.builtin" "${KERNEL_DIR}/modules.builtin.modinfo" "${MODDIR}/"
# depmod reads <base>/lib/modules, which is the root's /lib -> usr/lib link.
# It warns that there is no modules.order: there are no modules to order.
if ! DEPMOD_LOG=$(depmod -b "${ROOTFS}" "${KERNEL_RELEASE}" 2>&1); then
  echo "${DEPMOD_LOG}"
  echo "Error: depmod failed"
  exit 1
fi
grep -v 'could not open modules.order' <<<"${DEPMOD_LOG}" || true

# ---- Checks: fail loudly rather than ship an image that boots the wrong way ----

fail() { echo "Error: $*"; exit 1; }

FORBIDDEN=$(rpm --root="${ROOTFS}" -qa --qf '%{NAME}\n' \
  | grep -E '^(kernel|kernel-core|kernel-modules.*|kernel-uki-virt.*|kernel-debug|kernel-debug-(core|modules.*|uki-virt)|dracut.*|grub2.*|shim.*|systemd-boot.*)$' || true)
[ -z "${FORBIDDEN}" ] || fail "the image has boot packages it must not have: ${FORBIDDEN//$'\n'/ }"
[ "$(ls -A "${ROOTFS}/usr/lib/modules")" = "${KERNEL_RELEASE}" ] \
  || fail "/usr/lib/modules holds more than ${KERNEL_RELEASE}: $(ls -A "${ROOTFS}/usr/lib/modules" | tr '\n' ' ')"
MODULE_FILES=$(find "${ROOTFS}/usr/lib/modules" \( -name '*.ko' -o -name '*.ko.*' -o -type d ! -path "${MODDIR}" ! -path "${ROOTFS}/usr/lib/modules" \) -print)
[ -z "${MODULE_FILES}" ] || fail "the image has module files or directories: ${MODULE_FILES//$'\n'/ }"
# What Incus asks before it runs VMs, answered from the image's own index.
modprobe -d "${ROOTFS}" -S "${KERNEL_RELEASE}" -n vhost_vsock \
  || fail "modprobe in the image does not find the built-in vhost_vsock"
[ -z "$(ls -A "${ROOTFS}/boot" 2>/dev/null)" ] || fail "the image has /boot content"
grep -q '[[:space:]]/boot/efi[[:space:]]' "${ROOTFS}/etc/fstab" && fail "/etc/fstab mounts /boot/efi"
grep -Eq "^PARTLABEL=${ROOT_PARTLABEL}[[:space:]]+/[[:space:]]" "${ROOTFS}/etc/fstab" \
  || fail "/etc/fstab does not mount PARTLABEL=${ROOT_PARTLABEL} on /"
grep -qx 'SELINUX=disabled' "${ROOTFS}/etc/selinux/config" \
  || fail "/etc/selinux/config does not set SELINUX=disabled (see configure-base.sh)"
for f in usr/lib/systemd/system/incus-agent.service usr/lib/udev/rules.d/99-incus-agent.rules; do
  [ -f "${ROOTFS}/${f}" ] || fail "the image lacks /${f}"
done
[ -f "${ROOTFS}/etc/machine-id" ] && [ ! -s "${ROOTFS}/etc/machine-id" ] || fail "the image's /etc/machine-id is not an empty file"
[ "$(readlink "${ROOTFS}/etc/systemd/system/systemd-machine-id-commit.service")" = /dev/null ] \
  || fail "the image does not mask systemd-machine-id-commit, so a VM's first ID would stick to its copies"
[ -x "${ROOTFS}/usr/lib/systemd/incus-agent-setup" ] || fail "the image lacks an executable /usr/lib/systemd/incus-agent-setup"
# dnf in the guest reads the drop-in, as the --installroot dnf below does: it
# refuses the kernel and still resolves what only looks like one.
if dnf --installroot="${ROOTFS}" -q install --assumeno kernel-core > "${STAGING}/dnf.log" 2>&1 \
    || ! grep -q 'matches only excluded packages' "${STAGING}/dnf.log"; then
  cat "${STAGING}/dnf.log"
  fail "dnf in the image does not refuse kernel-core"
fi
dnf --installroot="${ROOTFS}" -q install --assumeno kernel-headers > "${STAGING}/dnf.log" 2>&1 || true
grep -q 'Operation aborted' "${STAGING}/dnf.log" || { cat "${STAGING}/dnf.log"; fail "dnf in the image cannot resolve kernel-headers"; }

echo "Cleaning caches..."
dnf --use-host-config --installroot="${ROOTFS}" clean all
rm -rf "${ROOTFS}/var/cache/libdnf5" "${ROOTFS}/tmp"/* "${ROOTFS}/var/tmp"/* "${ROOTFS}/var/log"/*

# ---- Disk ----

echo "Assembling the disk..."
DISK="${STAGING}/disk.raw"
truncate -s "${DISK_SIZE}" "${DISK}"
# Not -q: sgdisk 1.0.10 then reports success and leaves names unset.
sgdisk -n "1:2048:+${ESP_MIB}M" -t 1:EF00 -c 1:ESP \
       -n 2:0:0 -t 2:8300 -c "2:${ROOT_PARTLABEL}" "${DISK}" >/dev/null
# Start and end sector of a partition, in 512-byte sectors (truncate's file has them).
sectors() { sgdisk -i "$1" "${DISK}" | sed -n 's/^\(First\|Last\) sector: \([0-9]*\).*/\2/p' | tr '\n' ' '; }
read -r ESP_START ESP_END <<<"$(sectors 1)"
read -r ROOT_START ROOT_END <<<"$(sectors 2)"
sgdisk -i 2 "${DISK}" | grep -q "^Partition name: '${ROOT_PARTLABEL}'" \
  || fail "could not name the root partition ${ROOT_PARTLABEL}"

ESP="${DISK}@@$((ESP_START * 512))"
# FAT32, as the UEFI specification asks of a system partition.
mformat -i "${ESP}" -F -T $((ESP_END - ESP_START + 1)) -h 64 -s 32 -v ESP ::
mmd -i "${ESP}" ::/EFI ::/EFI/BOOT
mcopy -i "${ESP}" "${KERNEL}" "::/EFI/BOOT/${LOADER}"

# The label is the stock image's; nothing here mounts by it.
mkfs.ext4 -q -F -L rootfs -d "${ROOTFS}" -E "offset=$((ROOT_START * 512))" \
  "${DISK}" "$(( (ROOT_END - ROOT_START + 1) / 2 ))k"

# The boot test rewrites the ESP and the partition name on the copy it boots,
# so what this disk carries in those places is checked here, read back.
mcopy -i "${ESP}" "::/EFI/BOOT/${LOADER}" "${STAGING}/loader"
[ "$(sha256sum < "${KERNEL}")" = "$(sha256sum < "${STAGING}/loader")" ] || fail "the ESP's EFI/BOOT/${LOADER} is not the kernel"
ESP_FILES=$(mdir -i "${ESP}" -/ -b ::/ | tr '\n' ' ')
[ "${ESP_FILES}" = "::/EFI/ ::/EFI/BOOT/ ::/EFI/BOOT/${LOADER} " ] \
  || fail "the ESP holds more than EFI/BOOT/${LOADER}: ${ESP_FILES}"
[ "$(debugfs -R "cat /etc/fstab" "${DISK}?offset=$((ROOT_START * 512))" 2>/dev/null)" = "$(cat "${SCRIPT_DIR}/vm-root/etc/fstab")" ] \
  || fail "the root filesystem on the disk does not carry vm-root/etc/fstab"

# ---- Package as an Incus VM tarball ----

echo "Compressing disk image..."
qemu-img convert -f raw -O qcow2 -c "${DISK}" "${STAGING}/rootfs.img"
rm -f "${DISK}"

cat > "${STAGING}/metadata.yaml" << EOF
architecture: ${ARCH}
creation_date: $(date +%s)
properties:
  description: Fedora ${RELEASE} VM base for incus-spawn, own kernel
  os: Fedora
  release: "${RELEASE}"
  variant: incus-spawn-base-vm
EOF

mkdir -p "${OUTPUT}"
VM_TARBALL="${OUTPUT}/fedora-${RELEASE}-${ARCH}-vm-scratch.tar.xz"
tar -cJf "${VM_TARBALL}" -C "${STAGING}" metadata.yaml rootfs.img
sha256sum "${VM_TARBALL}" | awk '{print $1}' > "${VM_TARBALL}.sha256"
echo "SHA256: $(cat "${VM_TARBALL}.sha256")"
echo "VM output: ${VM_TARBALL}"

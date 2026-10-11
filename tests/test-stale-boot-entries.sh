#!/bin/bash
# Removes the VM image's own kernel the way an instance does, with Fedora's real
# kernel-install and the plugins build-vm.sh installs, and checks its boot entry
# goes with it (Sanne/incus-spawn#1217).
#
# The image's entry is named by the machine-id of the build; an instance has
# another one. Runs in a fedora:44 container: needs podman or docker, no root and
# no loop device.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)}"
[ -n "${ENGINE}" ] || { echo "Error: needs podman or docker" >&2; exit 1; }

"${ENGINE}" run --rm -i -v "${ROOT}/fedora:/src:ro" registry.fedoraproject.org/fedora:44 bash -s <<'EOF'
set -euo pipefail
dnf -q -y --setopt=install_weak_deps=False install systemd systemd-udev grub2-common \
    > /tmp/dnf.log 2>&1 || { cat /tmp/dnf.log >&2; exit 1; }

BUILD_ID=a58a1f0c2e6b4d7f9a0b1c2d3e4f5061   # the machine that built the image
INSTANCE_ID=5a49c1d2e3f405162738495a6b7c8d9e # the instance
STOCK=7.2.9-200.fc44.x86_64
NEWER=7.2.10-200.fc44.x86_64
ENTRIES=/boot/loader/entries
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

entry() {
    printf 'title Fedora Linux (%s) 44\nversion %s\nlinux /vmlinuz-%s\ninitrd /initramfs-%s.img\noptions root=UUID=ce628afb-bfaa-47dd-8d27-275b47264e4a ro\n' "$1" "$1" "$1" "$1"
}

# The image: its kernel's entry carries the build's machine-id. The plugins go
# where build-vm.sh puts them.
mkdir -p "${ENTRIES}" /etc/kernel/install.d
for k in "${STOCK}" "${NEWER}"; do : > "/boot/vmlinuz-${k}"; done
entry "${STOCK}" > "${ENTRIES}/${BUILD_ID}-${STOCK}.conf"
for plugin in /src/kernel-install/*.install; do
    [ ! -e "${plugin}" ] || cp "${plugin}" /etc/kernel/install.d/
done

# The instance: a machine-id of its own, and a newer kernel installed under it.
echo "${INSTANCE_ID}" > /etc/machine-id
entry "${NEWER}" > "${ENTRIES}/${INSTANCE_ID}-${NEWER}.conf"
entry "${NEWER}" > "${ENTRIES}/${INSTANCE_ID}-${NEWER}~debug.conf"
# A kernel whose version merely ends in the stock one's is another kernel.
entry "custom-${STOCK}" > "${ENTRIES}/${INSTANCE_ID}-custom-${STOCK}.conf"

kernel-install remove "${STOCK}"
[ ! -e "/boot/vmlinuz-${STOCK}" ] || fail "kernel-install did not remove /boot/vmlinuz-${STOCK}"
[ ! -e "${ENTRIES}/${BUILD_ID}-${STOCK}.conf" ] \
    || fail "the image's entry for ${STOCK} survived its kernel, so GRUB may boot a missing vmlinuz"
[ -e "${ENTRIES}/${INSTANCE_ID}-${NEWER}.conf" ] || fail "the entry for ${NEWER} went too"
[ -e "${ENTRIES}/${INSTANCE_ID}-${NEWER}~debug.conf" ] || fail "the debug entry for ${NEWER} went too"
[ -e "${ENTRIES}/${INSTANCE_ID}-custom-${STOCK}.conf" ] || fail "the entry for custom-${STOCK} went too"
rm "${ENTRIES}/${INSTANCE_ID}-custom-${STOCK}.conf"

# Removing the instance's own kernel takes its debug copy as well.
kernel-install remove "${NEWER}"
remaining=$(ls -A "${ENTRIES}")
[ -z "${remaining}" ] || fail "entries left after removing every kernel: ${remaining}"

if [ "${failures}" -gt 0 ]; then
    echo "${failures} check(s) failed" >&2
    exit 1
fi
echo "All stale boot entry checks passed"
EOF

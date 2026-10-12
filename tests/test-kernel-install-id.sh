#!/bin/bash
# Installs a newer kernel the way a VM template's build does, with Fedora's real
# kernel-install, in an instance whose machine-id is not the image build's, and
# checks its boot entry is named like the image's own (Sanne/incus-spawn#1217).
#
# GRUB's blscfg orders entries by their file names, and kernel-install names them
# <machine-id>-<version>.conf. Every instance gets a machine-id of its own, so a
# kernel installed in a template sorted before or after the image's own entry by
# the luck of two random ids, and a branch often booted the old kernel. With every
# entry under one id, the newest version sorts first and boots.
#
# Runs in a fedora:44 container: needs podman or docker, no root and no loop device.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)}"
[ -n "${ENGINE}" ] || { echo "Error: needs podman or docker" >&2; exit 1; }

"${ENGINE}" run --rm -i -v "${ROOT}/fedora:/src:ro" registry.fedoraproject.org/fedora:44 bash -s <<'EOF'
set -euo pipefail
dnf -q -y --setopt=install_weak_deps=False install systemd systemd-udev grub2-common \
    > /tmp/dnf.log 2>&1 || { cat /tmp/dnf.log >&2; exit 1; }

BUILD_ID=a58a1f0c2e6b4d7f9a0b1c2d3e4f5061   # the machine that built the image
INSTANCE_ID=5a49c1d2e3f405162738495a6b7c8d9e # a template's build instance, sorting first
STOCK=7.2.9-200.fc44.x86_64
NEWER=7.2.9-201.fc44.x86_64
ENTRIES=/boot/loader/entries
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# The image as build-vm.sh leaves it: its kernel's entry under the build's
# machine-id, a machine-info with something of its own in it, the plugins, and
# kernel-install-id.sh run on the root.
mkdir -p "${ENTRIES}" /etc/kernel/install.d
printf 'title Fedora Linux (%s) 44\nversion %s\nlinux /vmlinuz-%s\noptions root=UUID=ce628afb-bfaa-47dd-8d27-275b47264e4a ro\n' \
    "${STOCK}" "${STOCK}" "${STOCK}" > "${ENTRIES}/${BUILD_ID}-${STOCK}.conf"
: > "/boot/vmlinuz-${STOCK}"
printf 'PRETTY_HOSTNAME="kept"' > /etc/machine-info   # no newline at the end
cp /src/kernel-install/*.install /etc/kernel/install.d/
bash /src/kernel-install-id.sh /
grep -qx "KERNEL_INSTALL_MACHINE_ID=${BUILD_ID}" /etc/machine-info \
    || fail "/etc/machine-info does not name the image's entry id: $(cat /etc/machine-info)"
grep -qx 'PRETTY_HOSTNAME="kept"' /etc/machine-info || fail "the rest of /etc/machine-info was lost"
bash /src/kernel-install-id.sh /
[ "$(grep -c KERNEL_INSTALL_MACHINE_ID /etc/machine-info)" = 1 ] || fail "a second run added a second line"

# A template's build instance: a machine-id of its own, and a newer kernel.
echo "${INSTANCE_ID}" > /etc/machine-id
mkdir -p "/usr/lib/modules/${NEWER}"
: > "/usr/lib/modules/${NEWER}/vmlinuz"
kernel-install add "${NEWER}" "/usr/lib/modules/${NEWER}/vmlinuz" > /tmp/ki.log 2>&1 || { cat /tmp/ki.log >&2; exit 1; }
[ -e "${ENTRIES}/${BUILD_ID}-${NEWER}.conf" ] \
    || fail "the new kernel's entry is not under the image's id: $(ls "${ENTRIES}")"
# GRUB's blscfg orders entries by id, then version, newest first, and boots the
# first; with one id that is the newest version. A stand-in for GRUB's own order,
# which only a boot can show (on real Incus, in the PR).
first=$(ls "${ENTRIES}" | sort -rV | head -n 1)
[ "${first}" = "${BUILD_ID}-${NEWER}.conf" ] || fail "the default entry would be ${first}, not the new kernel's"

# Removing the old kernel removes its entry, under the same id: by Fedora's own
# 20-grub.install, so without the plugin that removes entries under any id.
rm /etc/kernel/install.d/21-isx-stale-entries.install
kernel-install remove "${STOCK}" > /tmp/ki.log 2>&1 || { cat /tmp/ki.log >&2; exit 1; }
[ ! -e "${ENTRIES}/${BUILD_ID}-${STOCK}.conf" ] || fail "the old kernel's entry survived it"

if [ "${failures}" -gt 0 ]; then
    echo "${failures} check(s) failed" >&2
    exit 1
fi
echo "All kernel-install id checks passed"
EOF

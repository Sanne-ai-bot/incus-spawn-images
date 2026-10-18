#!/bin/bash
# Boots the container image build.sh made under podman with systemd as PID 1 and
# checks that it reaches `running`, not `degraded` (#30). Then adds a system bus, as
# templates that need logind do (incus-spawn's podman tool installs dbus-broker and
# systemd-pam), and checks that logind starts once there is one.
#
# Usage: test-container-boot.sh <fedora-44-<arch>.tar.xz>
# Needs podman (rootful or rootless) and network for the dnf step.
#
# podman is not Incus: its containers get no console unless given a tty, so it
# cannot reproduce console-getty failing on the console Incus provides; that unit is
# checked to be masked instead. CAP_SYS_ADMIN is added because an Incus container
# has it in its user namespace and systemd-oomd fails to start without it.
set -euo pipefail

TARBALL="${1:?Usage: $0 <container image tarball>}"
WORK="$(mktemp -d)"
NAME="isx-boot-test-$$"
as_owner() { if [ "$(id -u)" = 0 ]; then "$@"; else podman unshare "$@"; fi; }
cleanup() {
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    as_owner rm -rf "$WORK"
}
trap cleanup EXIT

as_owner tar --xattrs -xJf "$TARBALL" -C "$WORK" ./rootfs

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
in_box() { podman exec "$NAME" "$@"; }

# Boots the rootfs and checks that it reaches `running`; $1 says which image it is.
boot_running() {
    podman run -d --name "$NAME" --systemd=always --cap-add=SYS_ADMIN \
        --rootfs "$WORK/rootfs" /usr/sbin/init >/dev/null
    # Until PID 1 is up, systemctl answers nothing or `offline`; then wait once for
    # the boot to settle.
    local state= i
    for i in $(seq 30); do
        state=$(in_box systemctl is-system-running 2>/dev/null) || true
        [ -n "$state" ] && [ "$state" != offline ] && break
        sleep 1
    done
    if [ -z "$state" ] || [ "$state" = offline ]; then
        fail "$1: systemd did not answer within 30s"
        return
    fi
    state=$(in_box timeout 120 systemctl is-system-running --wait 2>/dev/null) || true
    if [ "$state" = running ]; then
        echo "ok: $1 boots to running"
    else
        fail "$1 boots to '$state', not running; failed units:"
        in_box systemctl --failed --no-legend >&2 || true
    fi
}

boot_running "the base image"
if [ "$(in_box systemctl is-enabled console-getty.service 2>/dev/null)" = masked ]; then
    echo "ok: console-getty is masked"
else
    fail "console-getty.service is not masked"
fi
# Skipped by its condition, not failed (which the boot check alone would also catch).
# An empty ConditionTimestamp would mean logind was never even pulled in.
if [ "$(in_box systemctl show -P ConditionResult systemd-logind.service)" = no ] \
    && [ -n "$(in_box systemctl show -P ConditionTimestamp systemd-logind.service)" ]; then
    echo "ok: systemd-logind is skipped without a system bus"
else
    fail "systemd-logind is not skipped by its condition without a system bus"
fi

# A template that wants logind brings the bus and pam_systemd itself.
in_box dnf -y -q --setopt=install_weak_deps=False install dbus-broker systemd-pam \
    > "$WORK/dnf.log" 2>&1 || { cat "$WORK/dnf.log" >&2; exit 1; }
podman rm -f "$NAME" >/dev/null
boot_running "the image with a system bus"
if in_box systemctl is-active --quiet systemd-logind.service; then
    echo "ok: systemd-logind runs once there is a system bus"
else
    fail "systemd-logind does not run with a system bus"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi

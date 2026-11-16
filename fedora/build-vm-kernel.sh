#!/bin/bash
set -euo pipefail

# Build the kernel of the from-scratch VM image (build-vm-scratch.sh).
#
# The kernel's config has one home, incus-spawn's appliance/kernel: this fetches
# that directory at the pinned incus-spawn commit and runs
# `build-kernel.sh vm`, which builds a vanilla kernel.org kernel, checksummed,
# with no modules and its command line built in (Sanne/incus-spawn#1255). The
# same checkout carries appliance/test-vm-kernel.sh, the boot test CI gates the
# image with.
#
# Usage: build-vm-kernel.sh <output-dir> [arch]
# Output: <output-dir>/vmlinuz with its modules.builtin, modules.builtin.modinfo
# and kernelrelease (build-vm-scratch.sh installs the index of built-in
# drivers), and the checkout in <output-dir>/incus-spawn.
#
# Requirements: git, and build-kernel.sh's: build-essential flex bison bc
# libelf-dev libssl-dev (Fedora: gcc make flex bison bc elfutils-libelf-devel
# openssl-devel).

# A commit on incus-spawn's main, never a tag. A change to the fragments reaches
# this image only through a bump here, which incus-spawn's upstream watch proposes
# (upstream/manifest.yaml, item isx-ref): the newest commit on main that changed
# the kernel's script, its fragments or the boot test.
ISX_REPO=https://github.com/Sanne/incus-spawn.git
ISX_REF=07c20e488230ee2e3b52c5d0723553432de3faee

OUTPUT="${1:?Usage: $0 <output-dir> [arch]}"
ARCH="${2:-$(uname -m)}"
mkdir -p "${OUTPUT}"
OUTPUT="$(cd "${OUTPUT}" && pwd)"
SRC="${OUTPUT}/incus-spawn"

rm -rf "${SRC}"
git init -q "${SRC}"
git -C "${SRC}" fetch -q --depth 1 "${ISX_REPO}" "${ISX_REF}"
git -C "${SRC}" -c advice.detachedHead=false checkout -q FETCH_HEAD

"${SRC}/appliance/kernel/build-kernel.sh" vm "${OUTPUT}" "${ARCH}"

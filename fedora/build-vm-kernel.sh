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

# An immutable commit on incus-spawn's main, not a release tag, so a kernel fix
# reaches this image without waiting for an isx release (#1355). A change to the
# kernel or its boot test reaches the image only through a bump here, which
# update-isx-ref.yml proposes daily: fedora/update-isx-ref.sh moves ISX_REF to
# the newest main commit that changed ISX_INPUTS.
ISX_REPO=https://github.com/Sanne/incus-spawn.git
ISX_REF=2b08cfde4dda4017110da199bc111e3cdb6ebb15
# Everything this build reads from that checkout, and all it checks out:
# build-kernel.sh and the fragments it builds from, and the boot test
# build-vm-scratch.yml runs. A file outside these is missing, so a new input
# fails the build until it is listed here, where update-isx-ref.sh sees its
# changes too; the rest of appliance/kernel/ is the appliance's tooling.
ISX_INPUTS="appliance/kernel/build-kernel.sh appliance/kernel/*.config appliance/test-vm-kernel.sh"

OUTPUT="${1:?Usage: $0 <output-dir> [arch]}"
ARCH="${2:-$(uname -m)}"
mkdir -p "${OUTPUT}"
OUTPUT="$(cd "${OUTPUT}" && pwd)"
SRC="${OUTPUT}/incus-spawn"

rm -rf "${SRC}"
git init -q "${SRC}"
# The patterns go to git unexpanded: ISX_INPUTS is a list of paths and globs.
set -f
# shellcheck disable=SC2086
git -C "${SRC}" sparse-checkout set --no-cone $(printf '/%s\n' ${ISX_INPUTS})
set +f
git -C "${SRC}" fetch -q --depth 1 "${ISX_REPO}" "${ISX_REF}"
git -C "${SRC}" -c advice.detachedHead=false checkout -q FETCH_HEAD

"${SRC}/appliance/kernel/build-kernel.sh" vm "${OUTPUT}" "${ARCH}"

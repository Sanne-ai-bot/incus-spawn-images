#!/bin/bash
set -euo pipefail

# Move build-vm-kernel.sh's ISX_REF to the newest commit on incus-spawn's main
# that changed ISX_INPUTS, when the inputs at ISX_REF differ from main's
# (Sanne/incus-spawn#1355). A kernel bump merged there reaches the VM image
# through this, without an isx release. update-isx-ref.yml runs it daily and
# proposes the result as a PR; nothing merges by itself.
#
# Usage:  fedora/update-isx-ref.sh
#
# Prints nothing when the pin is current. Otherwise rewrites ISX_REF and prints
# "<old> <new>", then the incus-spawn commits between them that changed the
# inputs, one "<sha> <subject>" per line. The new ref is an immutable commit
# that is on main; a current ISX_REF that is not on main fails, rather than be
# moved past.
#
# Requirements: git.

FILE="$(cd "$(dirname "$0")" && pwd)/build-vm-kernel.sh"
value() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$FILE"; }
ISX_REPO="$(value ISX_REPO)"
ISX_REF="$(value ISX_REF)"
ISX_INPUTS="$(value ISX_INPUTS)"
[ -n "$ISX_REPO" ] && [ -n "$ISX_REF" ] && [ -n "$ISX_INPUTS" ] \
    || { echo "ERROR: ISX_REPO, ISX_REF or ISX_INPUTS not found in $FILE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# History and trees only: no file contents are needed to compare them.
git clone -q --bare --filter=blob:none --single-branch --branch main "$ISX_REPO" "$WORK/isx.git"
G() { git -C "$WORK/isx.git" "$@"; }

G merge-base --is-ancestor "$ISX_REF" main 2> /dev/null \
    || { echo "ERROR: ISX_REF $ISX_REF is not a commit on incus-spawn's main" >&2; exit 1; }

# ISX_INPUTS is a list of paths and globs, for git's pathspecs to match.
set -f
# shellcheck disable=SC2086
G diff-tree -r --quiet "$ISX_REF" main -- $ISX_INPUTS && exit 0
# shellcheck disable=SC2086
new="$(G log -1 --format=%H main -- $ISX_INPUTS)"

sed -i.bak "s/^ISX_REF=.*\$/ISX_REF=$new/" "$FILE"
rm -f "$FILE.bak"
[ "$(value ISX_REF)" = "$new" ] || { echo "ERROR: failed to rewrite ISX_REF in $FILE" >&2; exit 1; }
echo "$ISX_REF $new"
# shellcheck disable=SC2086
G log --format='%H %s' "$ISX_REF..$new" -- $ISX_INPUTS

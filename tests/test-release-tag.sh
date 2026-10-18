#!/bin/bash
# Runs .github/scripts/release-tag.sh, which build-fedora.yml's release job uses to
# name its tag, against lists of existing tags. Needs nothing but bash.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.github/scripts/release-tag.sh"
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# run <existing tags, one per line> [requested tag]: the tag for a release on 2026-10-12
run() { printf '%s' "$1" | bash "$SCRIPT" 44 20261012 ${2:+"$2"} 2>&1; }

# expect <name> <existing tags> <expected tag> [requested tag]
expect() {
    local got
    if ! got="$(run "$2" ${4:+"$4"})"; then
        fail "$1: exited non-zero: $got"
        return
    fi
    [ "$got" = "$3" ] || fail "$1: got '$got', want '$3'"
}

# refuse <name> <existing tags> <requested tag>
refuse() {
    local got
    if got="$(run "$2" "$3")"; then
        fail "$1: published under '$got', an existing tag"
    elif [[ "$got" != *"already exists"* ]]; then
        fail "$1: failed for another reason: $got"
    fi
}

expect "first of the day" "fedora-44-20261011
" fedora-44-20261012
expect "no tags yet" "" fedora-44-20261012
# Sanne/incus-spawn-images#24: a second run on 2026-10-12 re-uploaded every asset
# of fedora-44-20261012, which incus-spawn had already pinned.
expect "second of the day" "fedora-44-20261011
fedora-44-20261012
" fedora-44-20261012-2
expect "third of the day" "fedora-44-20261012
fedora-44-20261012-2
" fedora-44-20261012-3
expect "last tag without a newline" "fedora-44-20261012" fedora-44-20261012-2
expect "requested, new" "fedora-44-20261012
" fedora-44-v7 fedora-44-v7
refuse "requested, existing" "fedora-44-v7
" fedora-44-v7
refuse "requested, today's" "fedora-44-20261012
" fedora-44-20261012
refuse "requested, last without a newline" "fedora-44-20261011
fedora-44-v7" fedora-44-v7

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)" >&2
    exit 1
fi
echo "All release tag checks passed."

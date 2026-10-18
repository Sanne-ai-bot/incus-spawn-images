#!/bin/bash
# Prints the tag a release is published under, never one that already exists: a
# published tag is immutable, since incus-spawn pins the checksums of its assets.
#
# Usage: release-tag.sh <release> <YYYYMMDD> [requested tag] < existing tag names
#
# A requested tag is used as given, or refused if it exists. Otherwise the tag is
# fedora-<release>-<YYYYMMDD>, and a later release on the same day gets -2, -3 and
# so on: isx takes the first release the GitHub API lists as the newest, and on a
# tie in commit date the API lists the later release, the higher id, first (as
# every tie in this repository's list shows; GitHub does not document it).
set -euo pipefail

release="$1" date="$2" requested="${3:-}"
declare -A existing=()
while IFS= read -r tag || [ -n "$tag" ]; do
    [ -n "$tag" ] && existing["$tag"]=1
done

if [ -n "$requested" ]; then
    if [ -n "${existing[$requested]:-}" ]; then
        echo "Tag $requested already exists; a release never replaces a published tag's assets." >&2
        exit 1
    fi
    echo "$requested"
    exit 0
fi

tag="fedora-$release-$date"
n=2
while [ -n "${existing[$tag]:-}" ]; do
    tag="fedora-$release-$date-$n"
    n=$((n + 1))
done
echo "$tag"

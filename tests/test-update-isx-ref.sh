#!/bin/bash
# Runs fedora/update-isx-ref.sh, fedora/build-vm-kernel.sh's checkout and update-isx-ref.yml's PR
# step against a fixture incus-spawn repository, offline (Sanne/incus-spawn#1355). Checks that the
# ref moves to the newest main commit that changed ISX_INPUTS, and only when their content
# differs; that a ref not on main fails; that the build checks out ISX_INPUTS and nothing else;
# and that the PR step keeps one PR, refreshed, and skips a declined ref. Needs bash, git, jq and
# mikefarah yq.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The fixture incus-spawn: main with commits that do and do not touch ISX_INPUTS, and a side branch.
ISX="$WORK/incus-spawn"
mkdir -p "$ISX/appliance/kernel"
G() { git -C "$ISX" -c user.name=t -c user.email=t@t "$@"; }
commit() { G add -A && G commit -qm "$1" && G rev-parse HEAD; }
G init -q -b main && G config uploadpack.allowFilter true
# A stand-in build-kernel.sh that lists what the checkout holds, where the real one would build.
printf '#!/bin/bash\ncd "$(dirname "$0")/../.." && find . -path ./.git -prune -o -type f -print | sort > "$2/checked-out"\n' \
    > "$ISX/appliance/kernel/build-kernel.sh"
chmod +x "$ISX/appliance/kernel/build-kernel.sh"
echo "# boot test" > "$ISX/appliance/test-vm-kernel.sh"
echo "# not an input" > "$ISX/appliance/build.sh"
echo "# not an input" > "$ISX/README.md"
echo "# the appliance's tooling" > "$ISX/appliance/kernel/update-kernel-pin.sh"
C1=$(commit "base")
echo "change" >> "$ISX/README.md"; C2=$(commit "docs")
echo "CONFIG_X=y" > "$ISX/appliance/kernel/vm.config"; C3=$(commit "kernel fragment")
echo "# faster" >> "$ISX/appliance/test-vm-kernel.sh"; C4=$(commit "boot test")
echo "change" >> "$ISX/appliance/build.sh"; C5=$(commit "appliance only")
echo "change" >> "$ISX/appliance/kernel/update-kernel-pin.sh"; C6=$(commit "appliance tooling (#99)")
G checkout -q -b side "$C1"
echo "side" >> "$ISX/appliance/kernel/vm.config"; SIDE=$(commit "not on main")
G checkout -q main

# install <ref>: a copy of fedora/ pinned to <ref> of the fixture
install() {
    local dir; dir="$(mktemp -d "$WORK/images.XXXX")"
    mkdir -p "$dir/fedora"
    cp "$ROOT/fedora/update-isx-ref.sh" "$dir/fedora/"
    sed -e "s#^ISX_REPO=.*#ISX_REPO=file://$ISX#" -e "s/^ISX_REF=.*/ISX_REF=$1/" \
        "$ROOT/fedora/build-vm-kernel.sh" > "$dir/fedora/build-vm-kernel.sh"
    chmod +x "$dir/fedora/build-vm-kernel.sh"
    echo "$dir"
}
ref() { sed -n 's/^ISX_REF=//p' "$1/fedora/build-vm-kernel.sh"; }

d=$(install "$C1")
out=$("$d/fedora/update-isx-ref.sh")
[ "$(ref "$d")" = "$C4" ] || fail "from C1: ISX_REF is $(ref "$d"), not C4, the newest change to ISX_INPUTS"
[ "$(echo "$out" | head -1)" = "$C1 $C4" ] || fail "from C1: printed '$(echo "$out" | head -1)'"
[ "$(echo "$out" | tail -n +2 | cut -d' ' -f1 | tr '\n' ' ')" = "$C4 $C3 " ] || fail "from C1: the changes listed are not C4 and C3: $out"

d=$(install "$C4"); [ -z "$("$d/fedora/update-isx-ref.sh")" ] && [ "$(ref "$d")" = "$C4" ] || fail "at C4: a current ref moved"
d=$(install "$C5"); [ -z "$("$d/fedora/update-isx-ref.sh")" ] && [ "$(ref "$d")" = "$C5" ] || fail "at C5: a later ref with the same inputs moved back"
d=$(install "$C4"); [ -z "$("$d/fedora/update-isx-ref.sh")" ] || fail "at C4: a change to appliance/kernel/ that the build does not read moved the ref"
d=$(install "$SIDE")
if "$d/fedora/update-isx-ref.sh" > /dev/null 2>&1; then fail "a ref not on main was accepted"; fi
[ "$(ref "$d")" = "$SIDE" ] || fail "a ref not on main was rewritten"

# The build checks out ISX_INPUTS at ISX_REF, and nothing else.
d=$(install "$C4")
"$d/fedora/build-vm-kernel.sh" "$d/out" x86_64 > /dev/null
expected="./appliance/kernel/build-kernel.sh
./appliance/kernel/vm.config
./appliance/test-vm-kernel.sh"
[ "$(cat "$d/out/checked-out")" = "$expected" ] || fail "the build checked out: $(cat "$d/out/checked-out")"

# update-isx-ref.yml's PR step, with gh faked: it applies each --jq filter to fixture JSON.
STEP="Open or refresh the bump PR" yq -r '.jobs.bump.steps[] | select(.name == strenv(STEP)) | .run' \
    "$ROOT/.github/workflows/update-isx-ref.yml" > "$WORK/step.sh"
[ -s "$WORK/step.sh" ] || fail "no PR step in update-isx-ref.yml"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/bash
echo "gh $(printf '%s' "$*" | tr '\n' ' ')" >> "$CALLS"
if [ "$1 $2" = "pr view" ]; then printf 'Body\n\n<!-- update-isx-ref.yml: x -->\n'; exit 0; fi
if [ "$1 $2" = "pr list" ]; then
    state=""; filter=""
    while [ $# -gt 0 ]; do case "$1" in --state) state=$2; shift ;; --jq) filter=$2; shift ;; esac; shift; done
    jq -r "$filter" "$FIXTURES/$state.json"
fi
EOF
chmod +x "$WORK/bin/gh"

# A PR from this repository's own branch, with the fields the step filters on
ours() { printf '{"headRepositoryOwner": {"login": "Sanne"}, "isCrossRepository": false, %s}' "$1"; }
fork() { printf '{"headRepositoryOwner": {"login": "someone"}, "isCrossRepository": true, %s}' "$1"; }

# pr <name> <main's ref> <new ref or ""> <open.json> <closed.json> [<ref on bot/isx-ref> [<its author>]]
pr() {
    local dir="$WORK/pr-$1"
    mkdir -p "$dir/fixtures" "$dir/src/fedora"
    printf '%s' "$4" > "$dir/fixtures/open.json"
    printf '%s' "$5" > "$dir/fixtures/closed.json"
    printf 'ISX_REF=%s\n' "$2" > "$dir/src/fedora/build-vm-kernel.sh"
    (
        cd "$dir/src"
        H() { git -c user.name=t -c user.email=t@t "$@"; }
        H init -q -b main && H add -A && H commit -qm init
        git init -q --bare "$dir/remote.git" && git remote add origin "$dir/remote.git" && git push -q origin main
        if [ -n "${6:-}" ]; then
            H switch -q -c bot/isx-ref && printf 'ISX_REF=%s\n' "$6" > fedora/build-vm-kernel.sh
            git -c user.name=x -c user.email="${7:-github-actions[bot]@users.noreply.github.com}" commit -q --allow-empty -am "pin $6"
            git push -q origin bot/isx-ref && H switch -q main
        fi
        [ -n "$3" ] && printf 'ISX_REF=%s\n' "$3" > fedora/build-vm-kernel.sh
        { [ -n "$3" ] && echo "$2 $3" && echo "$3 Change the \`kernel\` (#123) for @someone"; } > "$dir/isx-ref" || true
        PATH="$WORK/bin:$PATH" CALLS="$dir/calls" FIXTURES="$dir/fixtures" RUNNER_TEMP="$dir" GH_TOKEN=x \
            OLD="$2" NEW="$3" bash -eo pipefail "$WORK/step.sh" > "$dir/out" 2>&1
        echo $? > "$dir/exit"
    ) || true
    touch "$dir/calls"
}
ok() { [ "$(cat "$WORK/pr-$1/exit")" = 0 ] || { cat "$WORK/pr-$1/out" >&2; fail "$1: the step failed"; }; }
calls() { grep -c -- "$2" "$WORK/pr-$1/calls" || true; }
pushed() { git -C "$WORK/pr-$1/remote.git" rev-parse -q --verify refs/heads/bot/isx-ref || true; }

pr new "$C1" "$C4" '[]' '[]'; ok new
[ -n "$(pushed new)" ] || fail "new: bot/isx-ref was not pushed"
[ "$(calls new "pr create .*--title Build the VM kernel from incus-spawn ${C4:0:12} .*commit/$C4) \`Change the kernel (#123) for @someone\`.*<!-- update-isx-ref.yml: $C4 -->")" = 1 ] \
    || fail "new: no PR naming $C4 and its change, quoted: $(cat "$WORK/pr-new/calls")"
pr same "$C1" "$C4" "[$(ours '"number": 5')]" '[]' "$C4"; ok same
[ "$(calls same 'pr \(create\|edit\)')" = 0 ] || fail "same: the open PR was changed"
pr newer "$C1" "$C4" "[$(ours '"number": 5')]" '[]' "$C3"; ok newer
[ "$(calls newer "pr edit 5 --title Build the VM kernel from incus-spawn ${C4:0:12}")" = 1 ] || fail "newer: #5 was not refreshed"
# Someone pushed to the branch: the job stops, visibly, rather than force-push their commit away.
pr hand-pushed "$C1" "$C4" "[$(ours '"number": 5')]" '[]' "$C3" sanne@example.invalid
[ "$(cat "$WORK/pr-hand-pushed/exit")" != 0 ] && grep -q "did not make" "$WORK/pr-hand-pushed/out" \
    || fail "hand-pushed: the job did not stop"
[ "$(git -C "$WORK/pr-hand-pushed/remote.git" log -1 --format=%ae bot/isx-ref)" = sanne@example.invalid ] || fail "hand-pushed: the commit was pushed over"
pr declined "$C1" "$C4" '[]' "[$(ours "\"body\": \"<!-- update-isx-ref.yml: $C4 -->\", \"mergedAt\": null")]"; ok declined
[ "$(calls declined 'pr create')" = 0 ] && [ -z "$(pushed declined)" ] || fail "declined: a declined ref was proposed again"
# A fork's branch of the same name is neither the open bump nor a declined one.
pr fork "$C1" "$C4" "[$(fork '"number": 6')]" "[$(fork "\"body\": \"<!-- update-isx-ref.yml: $C4 -->\", \"mergedAt\": null")]"; ok fork
[ "$(calls fork 'pr create')" = 1 ] && [ "$(calls fork 'pr \(edit\|close\) 6')" = 0 ] || fail "fork: a fork's PR was taken for the bump"
pr caught-up "$C4" "" "[$(ours '"number": 5')]" '[]' "$C4"; ok caught-up
[ "$(calls caught-up 'pr close 5 --delete-branch')" = 1 ] || fail "caught-up: the stale #5 was not closed"
calls caught-up 'pr edit 5 --body' | grep -q 1 && ! grep 'pr edit 5 --body' "$WORK/pr-caught-up/calls" | grep -q 'update-isx-ref.yml:' \
    || fail "caught-up: the stale #5 kept its marker, so it would read as declined"

echo "update-isx-ref: all cases pass"

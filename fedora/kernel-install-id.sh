#!/bin/bash
# Name every later kernel's boot entry with the id the VM image's own entry has.
#
# kernel-install names a kernel's BLS entry <machine-id>-<version>.conf, and GRUB
# (blscfg) orders entries by that id before their version: the first one boots.
# The image's own kernel has the id of the machine that built the image, and every
# instance gets a machine-id of its own, so a kernel a template's build installed
# sorted before or after the image's by the luck of two random ids, and a branch
# of the template often booted the old kernel (Sanne/incus-spawn#1217).
#
# kernel-install takes the id from KERNEL_INSTALL_MACHINE_ID in /etc/machine-info
# when it is set, and Fedora's 20-grub.install names and removes entries by it.
# Setting it to the image's entry id gives every kernel, in every instance, the
# same id, so the newest version sorts first, and removing a kernel finds its
# entry. The machine-id itself stays each instance's own.
#
# Usage: kernel-install-id.sh <image-root>
# The image must have entries, all under one id; anything else is an error.
set -euo pipefail

ROOT="${1:?Usage: $0 <image-root>}"
INFO="${ROOT%/}/etc/machine-info"

IDS=()
for entry in "${ROOT%/}"/boot/loader/entries/*.conf; do
  [ -e "${entry}" ] || continue
  name="${entry##*/}"
  [[ "${name}" =~ ^([0-9a-f]{32})- ]] || continue
  [[ " ${IDS[*]} " == *" ${BASH_REMATCH[1]} "* ]] || IDS+=("${BASH_REMATCH[1]}")
done
[ ${#IDS[@]} -eq 1 ] || { echo "Error: expected the image's boot entries under one machine-id, found ${#IDS[@]}: ${IDS[*]}" >&2; exit 1; }

# A symlink would be replaced by a copy below, cutting off whatever it pointed at.
[ ! -L "${INFO}" ] || { echo "Error: ${INFO} is a symlink" >&2; exit 1; }
[ -e "${INFO}" ] || install -m 0644 /dev/null "${INFO}"
sed -i '/^KERNEL_INSTALL_MACHINE_ID=/d' "${INFO}"
# A last line without its newline would swallow the key.
[ ! -s "${INFO}" ] || [ -z "$(tail -c 1 "${INFO}")" ] || echo >> "${INFO}"
echo "KERNEL_INSTALL_MACHINE_ID=${IDS[0]}" >> "${INFO}"

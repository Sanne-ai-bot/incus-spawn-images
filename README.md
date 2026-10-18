# incus-spawn-images

Custom Fedora base images for [incus-spawn](https://github.com/Sanne/incus-spawn).

These images are pre-baked with the static setup that `incus-spawn` would
otherwise perform at template build time. Baking it in once means clean builds
no longer depend on the linuxcontainers.org image server and skip the repeated
per-build provisioning, so spinning up a fresh container is faster and more
reproducible.

Each release carries three images, for both architectures:
- **Container image** (`.tar.xz`): rootfs tarball for Incus containers
- **VM image** (`-vm-direct.tar.xz`): the [VM image built from scratch](#the-vm-image-built-from-scratch)
  around a kernel of our own, listed only in `SHA256SUMS.v2`
- **Legacy VM image** (`-vm.tar.xz`): bootable disk image for Incus VMs, based on
  the stock Incus Fedora image, for isx releases that read only `SHA256SUMS`

`SHA256SUMS` lists the container and legacy VM images and nothing else, exactly as
before `-vm-direct` existed: isx releases before the `SHA256SUMS.v2` reader
([Sanne/incus-spawn#1255](https://github.com/Sanne/incus-spawn/issues/1255)) take
any name containing `-vm` in it for the VM image, so one more line would overwrite
a checksum they use. `SHA256SUMS.v2` lists all six, in the same format.

## What's baked in

The image is a Fedora 44 systemd rootfs bootstrapped directly with
`dnf --installroot` (see [`fedora/build.sh`](fedora/build.sh)).

**Packages.** Installed with weak dependencies off (`install_weak_deps=False`)
and without docs (`tsflags=nodocs`) to keep the image small. The list is
[`fedora/base-packages.txt`](fedora/base-packages.txt), shared with the VM
image built from scratch:

- Core: `systemd`, `systemd-udevd`, `sudo`, `bash`, `coreutils`, `util-linux`, `passwd`, `dnf5`
- Networking: `systemd-networkd`, `iproute`, `iputils`
- Locale: `glibc-langpack-en`
- Dev/agent basics: `git`, `curl`, `which`, `procps-ng`, `findutils`, `bash-completion`

The kernel (`kernel*`) is **excluded** from the container image — containers
share the host kernel. Bloat that the base pulls in anyway
(`glibc-all-langpacks`, `geolite2-city`, `geolite2-country`) is removed after
install, and `/usr/share/doc`, `man`, `info`, `licenses`, and `groff` are
stripped.

**`agentuser` (UID 1000).** Created with passwordless sudo, added to the
`systemd-journal` group (so it can read logs), given a `~/inbox` directory, and
a `.bashrc` that sets the terminal window title to `isx:<hostname>` and sources
bash-completion.

**Networking.** `systemd-networkd` is enabled for static IP assignment
(configured per-branch by `incus-spawn`). A connectivity watchdog
(`isx-network-watchdog.timer`) monitors the expected IP/gateway every 30s and
restarts `systemd-networkd` on mismatch (recovers from host sleep/wake). It looks
for the address on any link, since a VM's NIC is `enp5s0`, not `eth0`, and uses
only tools the container image ships (it has no `awk`).
`tests/test-network-watchdog.sh` runs it against stubbed `ip`/`ping` with
nothing else on `PATH`.
`nsswitch.conf` has the mDNS `resolve` entry stripped so `.local` names go to
`incus-spawn`'s gateway dnsmasq instead of multicast DNS. `/etc/resolv.conf` is
removed; `incus-spawn`'s `BuildCommand` writes the real one at container start.

`systemd-udev` is installed (as a systemd dependency and for `udevadm`). A
`/etc/tmpfiles.d/static-nodes-permissions.conf` override prevents `fchmod`
failures on `/dev/net/tun` and `/dev/fuse` during rpm `%triggerin` scriptlets
(host-injected device nodes can't have their permissions changed inside the
user namespace).

**Trimmed systemd units.** ~20 services/timers/sockets that are useless or
harmful in a container are masked — `systemd-homed` (+ firstboot), the
`systemd-pcrlock-*` and `systemd-tpm2-clear` TPM units, time sync
(`timesyncd`, `time-wait-sync`), `systemd-boot-*` and `systemd-sysupdate*`,
`systemd-firstboot`, `unbound-anchor.timer`, `fstrim.timer`,
`selinux-autorelabel-mark`, and `dnf-makecache.timer`, which would refresh
package metadata in the background through the isx proxy in boxes that may
never run dnf.

The container image also masks `console-getty` (nobody can log in on a
container's console) and skips `systemd-logind` until a template installs a
system bus, as incus-spawn's `podman` tool does; `fedora/build.sh` says why.
`tests/test-container-boot.sh` boots the image under podman and checks it
reaches `running`, with and without a bus; the container build job runs it.

**SELinux is pinned off in practice.** These images ship without an SELinux
policy, so nothing is labelled. `configure-base.sh` writes `/etc/selinux/config`
with `SELINUX=disabled` so a policy arriving later as a transitive dependency —
`perl` pulls in `selinux-policy-targeted` — cannot flip a VM to enforcing, where
the `incus-agent` is denied `listen` on its vsock socket and the VM is unreachable
(relabelling does not help). Caveat: without `selinux=0` on the kernel command
line SELinux stays enabled in the kernel with no policy loaded, which Fedora calls
the unsafe way to disable it (see its config template and
`selinux-check-proper-disable.service`). See
[Sanne/incus-spawn#842](https://github.com/Sanne/incus-spawn/issues/842).

**Container packaging.** Incus unified tarball: `metadata.yaml` plus the rootfs
under a `rootfs/` subdirectory, compressed as `.tar.xz`, with a companion
`.sha256`.

**VM packaging.** The VM image starts from the stock Incus Fedora VM image
(which already has the kernel, bootloader, and `incus-agent` set up). The
qcow2 disk is converted to raw, mounted via `losetup`, and customized in a
chroot with the same packages and configuration as the container image (see
[`fedora/build-vm.sh`](fedora/build-vm.sh)). The modified disk is converted
back to a compressed qcow2 and packaged as an Incus unified tarball
(`metadata.yaml` + `rootfs.img`).

**The VM kernel command line names the root by UUID.** The stock image ships
`/etc/kernel/cmdline` with the loop device it was built on
(`root=/dev/loop0p2`). Its own kernel boots anyway, because its boot entry
uses `$kernelopts`, but `kernel-install` writes the entry for every kernel
installed later from that file, so a guest whose `dnf upgrade` brought a new
kernel waited forever for the loop device on its next boot.
[`fedora/kernel-cmdline.sh`](fedora/kernel-cmdline.sh) rewrites the root to
`root=UUID=<root filesystem>` before any package is installed, keeping the
other options, and the build fails if a later step undid it or left a loop
device anywhere in the image's boot configuration. See
[Sanne/incus-spawn#1217](https://github.com/Sanne/incus-spawn/issues/1217).

**The VM kernel boots with `loglevel=5`, and `/etc/kernel/cmdline` decides it
for every kernel.** The stock image writes the kernel's informational messages
to `console=tty1 console=ttyS0`, about 125 KB per boot through an emulated
serial port and framebuffer before userspace starts. `kernel-cmdline.sh` adds
`loglevel=5` unless the line sets a level already. The console then shows only
messages more severe than notices: warnings (`WARN_ON` backtraces included),
errors and panics, about 300 bytes on a normal boot. systemd's per-unit status
lines are not kernel messages and still print, the ones isx quotes when an
`incus-agent` fails to start included. `quiet` would also drop the kernel's
warnings (it caps the console at `loglevel=4`) and turn systemd's status lines
off until a unit fails or stalls. SELinux avc denials are notices and no longer
reach the console; the image pins SELinux off. The stock kernel's boot entry
reads `$kernelopts`, filled in from a fallback in the EFI partition's
`grub.cfg`, so [`fedora/boot-entries.sh`](fedora/boot-entries.sh) writes the
contents of `/etc/kernel/cmdline` into it, and every other entry, after the
package installs, as `kernel-install` does for every later kernel. The build
fails unless every boot
entry boots with exactly what that file says, and it names the root by UUID and
sets a log level. See
[Sanne/incus-spawn#1238](https://github.com/Sanne/incus-spawn/issues/1238).

**Removing a kernel removes its boot entry in every instance.** Fedora's
`20-grub.install` names a kernel's boot entry `<machine-id>-<version>.conf` and,
when the kernel goes, removes only the entry under the running machine's id. The
image's own kernel has the entry of the machine that built the image, and every
instance has a machine-id of its own, so a template whose `dnf upgrade`s pushed
that kernel past `installonly_limit` kept an entry for a `vmlinuz` that no longer
exists. GRUB boots whichever entry sorts first, so whether the guest then failed
with ``file `/boot/vmlinuz-...' not found`` was down to its machine-id. The build
installs the kernel-install plugin
[`fedora/kernel-install/21-isx-stale-entries.install`](fedora/kernel-install/21-isx-stale-entries.install)
in `/etc/kernel/install.d`; it removes every entry for the version being
removed, whatever machine-id named it.
[`tests/test-stale-boot-entries.sh`](tests/test-stale-boot-entries.sh) runs
Fedora's own `kernel-install` against it in a container. See
[Sanne/incus-spawn#1217](https://github.com/Sanne/incus-spawn/issues/1217).

**A kernel a template installs is the one that boots.** GRUB's `blscfg` orders
entries by that same machine-id before their version, and boots the first. A
kernel a template's build installed was filed under the build instance's id, so
whether its branches booted it or the image's older kernel was down to two
random ids. The build runs
[`fedora/kernel-install-id.sh`](fedora/kernel-install-id.sh), which writes
`KERNEL_INSTALL_MACHINE_ID=<the image's entry id>` into `/etc/machine-info`.
`kernel-install`, and Fedora's `20-grub.install` with it, then names every later
entry by that id, in every instance, so the newest version sorts first; each
instance keeps its own machine-id.
[`tests/test-kernel-install-id.sh`](tests/test-kernel-install-id.sh) checks it
with Fedora's `kernel-install` in a container. The VM image built from scratch
has no boot entries: its kernel is the ESP's only file, and dnf in it refuses
kernel packages, so a template cannot change its kernel at all.

## The VM image built from scratch

[`fedora/build-vm-scratch.sh`](fedora/build-vm-scratch.sh) builds the VM image
without the stock Incus image, around a kernel of our own
([Sanne/incus-spawn#1255](https://github.com/Sanne/incus-spawn/issues/1255),
[#12](https://github.com/Sanne/incus-spawn-images/issues/12)). It boots with no
boot loader, no initrd and no modules: on one host, 2.4 s to `basic.target`
against 6.0 s for the image built from the stock one.

**Disk.** A GPT with two partitions, written without loop devices or mounts
(`sgdisk`, mtools, `mkfs.ext4 -d`), so the build runs in a container:

1. The EFI system partition, holding one file: the kernel, as
   `EFI/BOOT/BOOTX64.EFI` (`BOOTAA64.EFI`). The firmware starts it by the
   removable-media path, with no NVRAM entry, and its command line is built in.
   Linux never mounts this partition.
2. The root, ext4, with the GPT partition name `isx-root`, which the kernel's
   command line names (`root=PARTLABEL=isx-root`): the kernel finds it with no
   initrd and no udev. `/etc/fstab` remounts it read-write and has no
   `/boot/efi` line.

**Root.** `dnf --installroot` with the container image's packages plus the
VM's own (`cloud-utils-growpart`, `e2fsprogs` and `xfsprogs` for isx's root
expansion, `dbus-broker` and `systemd-pam` for logind and `systemctl --user`),
configured by the same `configure-base.sh`, then overlaid with
[`fedora/vm-root/`](fedora/vm-root): the incus-agent's unit, udev rule and setup
script as the stock Incus images have them, DHCP on the first NIC, the fstab
and the dnf drop-in below. No kernel packages, dracut, GRUB, shim, `/boot` or
module files, and `/etc/machine-id` is empty with
`systemd-machine-id-commit` masked, so each VM takes its ID from its SMBIOS
UUID at every boot, which Incus makes anew for every copy
(Sanne/incus-spawn#1483); the build fails otherwise. `/usr/lib/modules/<release>/` holds
only the kernel's index of its built-in drivers (`modules.builtin`, from
`build-kernel.sh vm`) and what `depmod` makes of it, so `modprobe` of a
built-in driver succeeds: Incus runs VMs only once `modprobe vhost_vsock`
does, which a nested Incus in a `--kvm` branch needs.

**The kernel is the image's.** It is built by
[`fedora/build-vm-kernel.sh`](fedora/build-vm-kernel.sh) from incus-spawn's
`appliance/kernel` (`build-kernel.sh vm`) at a pinned commit, so its config has
one home; a fragment change reaches this image through a bump of that pin. It
has no modules and no virtio-scsi, so the root disk must be on virtio-blk
(`io.bus=virtio-blk`); isx sets that from step 4 of
[Sanne/incus-spawn#1255](https://github.com/Sanne/incus-spawn/issues/1255) on,
and until then it is set by hand. Kernel updates arrive with an image rebuild.

**dnf will not install a kernel.**
`/etc/dnf/libdnf5.conf.d/isx-kernel.conf` excludes `kernel`, `kernel-core`,
`kernel-modules`, `kernel-modules-core`, `kernel-modules-extra`,
`kernel-uki-virt` and the rest of the packages that carry a kernel or its
modules, the debug flavour's included: a Fedora kernel package would put a kernel in `/boot` that
nothing boots, plus about 100 MB of modules nothing loads. dnf answers
`dnf install kernel-core` with "matches only excluded packages". Exact
names, not `kernel*`: `kernel-headers` (needed by `glibc-devel`) and `kernel-devel` stay
installable. To lift it for one command, `dnf --setopt=excludepkgs= install
...`; for good, delete the file. Neither makes the box boot that kernel.

**Kernel development** happens in a nested VM inside a `--kvm` branch
(virtme-ng, or QEMU with `-kernel`), never by replacing the box's own kernel.

**Built locally**, as root in a Fedora 44 container:

```bash
fedora/build-vm-kernel.sh build/vm-kernel        # needs the kernel build tools
mkdir -p output && sudo podman run --rm --privileged \
  -v "$(pwd):/build:ro" -v "$(pwd)/output:/output" fedora:44 \
  bash -c 'dnf -y -q install gdisk mtools e2fsprogs qemu-img xz kmod &&
           bash /build/fedora/build-vm-scratch.sh /output /build/build/vm-kernel/vmlinuz'
tar xJf output/fedora-44-$(uname -m)-vm-scratch.tar.xz -C output rootfs.img
build/vm-kernel/incus-spawn/appliance/test-vm-kernel.sh build/vm-kernel/vmlinuz output/rootfs.img
```

The last command is the boot test CI gates the image with; it needs QEMU, OVMF
(AAVMF), `sgdisk`, mtools and `debugfs`. The output is
`output/fedora-44-<arch>-vm-scratch.tar.xz` (+ `.sha256`). To try it in Incus
by hand, put the root on virtio-blk and Secure Boot off:

```bash
incus image import output/fedora-44-x86_64-vm-scratch.tar.xz --alias isx-scratch
incus launch isx-scratch t1 --vm -c security.secureboot=false -d root,io.bus=virtio-blk
```

## Building locally

**Container image** — requires a container runtime with `--privileged`
(for chroot and `dnf --installroot`):

```bash
mkdir -p output && podman run --rm --privileged \
  -v "$(pwd):/build:ro" \
  -v "$(pwd)/output:/output" \
  -e OUTPUT_DIR=/output \
  fedora:44 bash /build/fedora/build.sh
```

**VM image** — runs directly on the host (needs root for `losetup` + `mount`):

```bash
sudo fedora/build-vm.sh output
```

Requires `qemu-img`, `jq`, `curl`, `growpart`, and `e2fsprogs`/`xfsprogs`.

Output files:
- `output/fedora-44-<arch>.tar.xz` — container image (+ `.sha256`)
- `output/fedora-44-<arch>-vm.tar.xz` — VM image (+ `.sha256`)

## CI

[`.github/workflows/build-fedora.yml`](.github/workflows/build-fedora.yml)
builds both `x86_64` (on a regular instance) and `aarch64` (on an arm instance).
The container image is built in podman; the VM image is built directly on the
runner via `losetup` + chroot.

Triggers:

- **Push** to `main` touching `fedora/**` or the workflow — builds artifacts
  only (no release).
- **Scheduled** (1st, 11th, 21st, 03:17 UTC) — rebuilds for security updates and
  publishes a release tagged `fedora-44-<YYYYMMDD>`.
- **Manual dispatch** — optionally pass a `version` tag (e.g. `fedora-44-v2`)
  and publishes a release.

Releases attach the container, VM and legacy VM tarballs for both architectures,
plus `SHA256SUMS` (container and legacy VM only) and `SHA256SUMS.v2` (all six).
The release job checks every line of `SHA256SUMS.v2` against the file published
under its name (`sha256sum -c`), and that `SHA256SUMS` names no `-vm-direct`
asset, before it publishes anything.

[`.github/workflows/build-vm-scratch.yml`](.github/workflows/build-vm-scratch.yml)
builds the VM image from scratch with its kernel, for both architectures, on
every pull request touching `fedora/**`, and boots it with
incus-spawn's `appliance/test-vm-kernel.sh` (x86_64 under KVM, aarch64 under
TCG) until it reaches `basic.target`. `build-fedora.yml` calls it as a reusable
workflow, so a release ships its tarballs as `-vm-direct.tar.xz` only when that
boot test passed; a failed one fails the whole release.

[`.github/workflows/test.yml`](.github/workflows/test.yml) (`Test`) runs on
every pull request and push to `main`. It runs `tests/test-network-watchdog.sh`,
which checks the network watchdog against stubbed tools and against the
runner's real `ip`. It needs no root and builds no image.

## Testing locally with incus-spawn

The quickest way to build and test local images:

```bash
./test-local.sh              # builds both images, configures isx to use them
isx build tpl-minimal        # imports the local container tarball
isx build tpl-minimal --type vm  # imports the local VM image
isx build tpl-dev             # rebuild derived templates
./revert-local.sh            # reverts isx to the built-in base image
```

`test-local.sh` runs the podman build and boots the container image with
`tests/test-container-boot.sh`, then writes a `tpl-minimal` override
pointing at the local tarballs via `file://` URLs. Each run generates a unique
tag so `isx` re-imports automatically. `revert-local.sh` deletes the override.

### Manual setup

If you prefer to set things up by hand, or want a standalone test template that
doesn't override `tpl-minimal`, create a YAML file in
`~/.config/incus-spawn/images/`:

```yaml
# ~/.config/incus-spawn/images/test-base.yaml
name: tpl-test-base
description: Local base image test
image: fedora-44-test
image_url: file:///path/to/incus-spawn-images/output/fedora-44-{arch}.tar.xz
vm_image_url: file:///path/to/incus-spawn-images/output/fedora-44-{arch}-vm.tar.xz
image_tag: local-test
```

No `image_sha256` / `vm_image_sha256` — omitting them skips the hash check,
which is what you want during iterative testing. Bump `image_tag` each time you
rebuild the tarballs so `isx` detects the change and re-imports.

To override `tpl-minimal` directly (so derived templates like `tpl-dev` build
on top of your local image), use `name: tpl-minimal` instead. When done, delete
the override to revert:

```bash
rm ~/.config/incus-spawn/images/minimal.yaml
# or: rm ~/.config/incus-spawn/images/test-base.yaml
```

## Releasing a new version

To publish a new base image release:

1. **Trigger the workflow** — either via the GitHub UI (Actions → Build Fedora
   Base Image → Run workflow) or the CLI:

   ```bash
   # Auto-generated date tag (fedora-44-YYYYMMDD):
   gh workflow run build-fedora.yml

   # Explicit tag:
   gh workflow run build-fedora.yml --field version=fedora-44-v7
   ```

2. **Wait for CI** — the workflow builds both `x86_64` and `aarch64` images and
   creates a GitHub release with the tarballs, `SHA256SUMS` and `SHA256SUMS.v2`.

3. **Update `incus-spawn`** — the release notifies `incus-spawn`, whose
   `update-base-image.yml` opens a PR bumping `common/src/main/resources/images/minimal.yaml`
   (tag and checksums; the VM image's are `-vm-direct`'s from `SHA256SUMS.v2`).
   Check every checksum in it against the release before merging:

   ```bash
   gh release download <tag> -R Sanne/incus-spawn-images -p SHA256SUMS.v2 -O -
   ```

4. **Rebuild and test `isx`** — `mvn package && ./install.sh`, then
   `isx build tpl-minimal` and `isx build tpl-minimal --type vm` to verify both
   image types import and boot correctly.

Scheduled builds (1st, 11th, 21st, 03:17 UTC) automatically create a release for
security updates. Pushes to `main` touching `fedora/**` build artifacts but
don't release — use manual dispatch to publish those changes.

## Using with incus-spawn

The built-in `tpl-minimal` template in `incus-spawn` already points at this
repository's releases. On each `isx build tpl-minimal`, the tool checks whether
the installed base image matches the expected tag and re-downloads if needed.

### Managing base image versions

`isx update-base` checks for new releases and lets you choose how to track them:

```bash
isx update-base              # interactive — list releases, choose track-latest or pin
isx update-base --latest     # always track the newest built-in version
isx update-base --list       # list available releases without changing anything
isx update-base fedora-44-v3 # pin to a specific release tag
```

**Track latest** (default): no user override is written — `isx` uses whatever
tag is baked into the current binary. Updating `isx` automatically picks up
newer base images.

**Pinned**: writes a user override to `~/.config/incus-spawn/images/minimal.yaml`
with `pinned: true`. The pinned version is used until you explicitly change it.
If a newer version becomes available in a later `isx` release, the build will
print a warning:

```
Warning: base image is pinned to fedora-44-v3, but fedora-44-20260619 is available.
Run 'isx update-base --latest' to update.
```

### Pointing at a release manually

To reference a specific release directly in a template definition:

```yaml
image: fedora-44-base
image_url: https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/fedora-44-{arch}.tar.xz
vm_image_url: https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/fedora-44-{arch}-vm.tar.xz
image_sha256:
  x86_64: <sha256>
  aarch64: <sha256>
vm_image_sha256:
  x86_64: <sha256>
  aarch64: <sha256>
```

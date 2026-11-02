# incus-spawn-images

Custom Fedora base images for [incus-spawn](https://github.com/Sanne/incus-spawn).

These images are pre-baked with the static setup that `incus-spawn` would
otherwise perform at template build time. Baking it in once means clean builds
no longer depend on the linuxcontainers.org image server and skip the repeated
per-build provisioning, so spinning up a fresh container is faster and more
reproducible.

Each release carries two images, for both architectures:
- **Container image** (`.tar.xz`): rootfs tarball for Incus containers
- **VM image** (`-vm-direct.tar.xz`): the [VM image built from scratch](#the-vm-image-built-from-scratch)
  around a kernel of our own

`SHA256SUMS.v2` lists all four, one `<sha256>  <file>` per line, and is the
release's only manifest. Releases up to Fedora 44 also carried `SHA256SUMS` and a
legacy VM image (`-vm.tar.xz`, built from the stock Incus Fedora image) for isx
releases before the `SHA256SUMS.v2` reader
([Sanne/incus-spawn#1255](https://github.com/Sanne/incus-spawn/issues/1255)).
Both were dropped with the move to Fedora 45
([Sanne/incus-spawn#1862](https://github.com/Sanne/incus-spawn/issues/1862)):
isx up to v0.3.11 reads `SHA256SUMS` by arch alone, and would take a Fedora 45
release's checksums for its own Fedora 44 downloads.

Release tags and asset names carry the Fedora release (`fedora-45-<date>`,
`fedora-45-<arch>.tar.xz`). An isx release downloads the asset names its built-in
`tpl-minimal` names, so isx releases from before the move to Fedora 45 find no
asset they can use in a `fedora-45-*` release and stay on their built-in Fedora
44 release ([Sanne/incus-spawn#1862](https://github.com/Sanne/incus-spawn/issues/1862)).

## What's baked in

The image is a Fedora 45 systemd rootfs bootstrapped directly with
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

## The VM image built from scratch

[`fedora/build-vm-scratch.sh`](fedora/build-vm-scratch.sh) builds the VM image
without the stock Incus image, around a kernel of our own
([Sanne/incus-spawn#1255](https://github.com/Sanne/incus-spawn/issues/1255),
[#12](https://github.com/Sanne/incus-spawn-images/issues/12)). It boots with no
boot loader, no initrd and no modules: on one host, 2.4 s to `basic.target`
against 6.0 s for the legacy image built from the stock one. It has no boot
entries: its kernel is the ESP's only file, and dnf in it refuses kernel
packages, so a template cannot change its kernel at all.

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

**Built locally**, as root in a Fedora 45 container:

```bash
fedora/build-vm-kernel.sh build/vm-kernel        # needs the kernel build tools
mkdir -p output && sudo podman run --rm --privileged \
  -v "$(pwd):/build:ro" -v "$(pwd)/output:/output" fedora:45 \
  bash -c 'dnf -y -q install gdisk mtools e2fsprogs qemu-img xz kmod &&
           bash /build/fedora/build-vm-scratch.sh /output /build/build/vm-kernel/vmlinuz'
tar xJf output/fedora-45-$(uname -m)-vm-scratch.tar.xz -C output rootfs.img
build/vm-kernel/incus-spawn/appliance/test-vm-kernel.sh build/vm-kernel/vmlinuz output/rootfs.img
```

The last command is the boot test CI gates the image with; it needs QEMU, OVMF
(AAVMF), `sgdisk`, mtools and `debugfs`. The output is
`output/fedora-45-<arch>-vm-scratch.tar.xz` (+ `.sha256`). To try it in Incus
by hand, put the root on virtio-blk and Secure Boot off:

```bash
incus image import output/fedora-45-x86_64-vm-scratch.tar.xz --alias isx-scratch
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
  fedora:45 bash /build/fedora/build.sh
```

**VM image**: see [the VM image built from scratch](#the-vm-image-built-from-scratch).

Output files:
- `output/fedora-45-<arch>.tar.xz` — container image (+ `.sha256`)
- `output/fedora-45-<arch>-vm-scratch.tar.xz` — VM image (+ `.sha256`), released as `-vm-direct.tar.xz`

## CI

[`.github/workflows/build-fedora.yml`](.github/workflows/build-fedora.yml)
builds both `x86_64` (on a regular instance) and `aarch64` (on an arm instance).
The container image is built in podman; the VM image is built by
`build-vm-scratch.yml`, below.

Triggers:

- **Push** to `main` touching `fedora/**` or the workflow — builds artifacts
  only (no release).
- **Scheduled** (1st, 11th, 21st, 03:17 UTC) — rebuilds for security updates and
  publishes a release tagged `fedora-45-<YYYYMMDD>`.
- **Manual dispatch** — optionally pass a `version` tag (e.g. `fedora-45-v1`)
  and publishes a release.

A release never replaces the assets of a tag that already exists: incus-spawn
pins their checksums. A later release on the same day, or a re-run, is tagged
`fedora-45-<YYYYMMDD>-2`, `-3` and so on, and a requested `version` that exists
fails the release ([`release-tag.sh`](.github/scripts/release-tag.sh)).
A run that fails after creating its tag, in "Create release", leaves the tag
behind, and possibly a draft release (assets are uploaded before it is
published): delete both by hand before running that `version` again, or it
fails as already existing. Never delete a published release, which isx may
already have pinned: release under a new `version` instead.

Releases attach the container and VM tarballs for both architectures, plus
`SHA256SUMS.v2` (all four). The release job checks every line of it against the
file published under its name (`sha256sum -c`), and that there is no
`SHA256SUMS`, before it publishes anything.

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
runner's real `ip`, and `tests/test-release-tag.sh`. It needs no root and builds
no image.

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
`tests/test-container-boot.sh`, builds the VM image from scratch (its kernel
first, which takes a while), then writes a `tpl-minimal` override
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
image: fedora-45-test
image_url: file:///path/to/incus-spawn-images/output/fedora-45-{arch}.tar.xz
vm_image_url: file:///path/to/incus-spawn-images/output/fedora-45-{arch}-vm-direct.tar.xz
image_tag: local-test
```

The VM file is the `-vm-scratch.tar.xz` build output under its release name,
`-vm-direct.tar.xz`, which isx keys the VM image's alias on (`test-local.sh`
renames it).

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
   # Auto-generated date tag (fedora-45-YYYYMMDD, then -2, -3 on the same day):
   gh workflow run build-fedora.yml

   # Explicit tag:
   gh workflow run build-fedora.yml --field version=fedora-45-v1
   ```

2. **Wait for CI** — the workflow builds both `x86_64` and `aarch64` images and
   creates a GitHub release with the tarballs and `SHA256SUMS.v2`.

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
isx update-base fedora-45-v1 # pin to a specific release tag
```

**Track latest** (default): no user override is written — `isx` uses whatever
tag is baked into the current binary. Updating `isx` automatically picks up
newer base images.

**Pinned**: writes a user override to `~/.config/incus-spawn/images/minimal.yaml`
with `pinned: true`. The pinned version is used until you explicitly change it.
If a newer version becomes available in a later `isx` release, the build will
print a warning:

```
Warning: base image is pinned to fedora-45-v1, but fedora-45-20261111 is available.
Run 'isx update-base --latest' to update.
```

### Pointing at a release manually

To reference a specific release directly in a template definition:

```yaml
image: fedora-45-base
image_url: https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/fedora-45-{arch}.tar.xz
vm_image_url: https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/fedora-45-{arch}-vm-direct.tar.xz
image_sha256:
  x86_64: <sha256>
  aarch64: <sha256>
vm_image_sha256:
  x86_64: <sha256>
  aarch64: <sha256>
```

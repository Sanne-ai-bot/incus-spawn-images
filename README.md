# incus-spawn-images

Custom Fedora base images for [incus-spawn](https://github.com/Sanne/incus-spawn).

These images are pre-baked with the static setup that `incus-spawn` would
otherwise perform at template build time. Baking it in once means clean builds
no longer depend on the linuxcontainers.org image server and skip the repeated
per-build provisioning, so spinning up a fresh container is faster and more
reproducible.

The build produces **two image formats** from a single rootfs:
- **Container image** (`.tar.xz`): rootfs tarball for Incus containers
- **VM image** (`-vm.tar.xz`): bootable disk image for Incus VMs, based on the stock Incus Fedora image

## What's baked in

The image is a Fedora 44 systemd rootfs bootstrapped directly with
`dnf --installroot` (see [`fedora/build.sh`](fedora/build.sh)).

**Packages.** Installed with weak dependencies off (`install_weak_deps=False`)
and without docs (`tsflags=nodocs`) to keep the image small:

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

Releases attach container and VM tarballs for both architectures, plus a
combined `SHA256SUMS`.

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

`test-local.sh` runs the podman build, then writes a `tpl-minimal` override
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
   creates a GitHub release with the tarballs and `SHA256SUMS`.

3. **Update `incus-spawn`** — edit
   `src/main/resources/images/minimal.yaml` in the `incus-spawn` repo:

   ```yaml
   image_tag: fedora-44-YYYYMMDD          # the new release tag
   image_sha256:
     x86_64: <sha256-from-SHA256SUMS>
     aarch64: <sha256-from-SHA256SUMS>
   vm_image_sha256:
     x86_64: <sha256-from-SHA256SUMS>
     aarch64: <sha256-from-SHA256SUMS>
   ```

   Get the checksums from the release's `SHA256SUMS` file:

   ```bash
   curl -sL https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/SHA256SUMS
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

# seed

our initial building ground

The seed is the minimal Fedora bootc base image that the other image based
variants build on, see
[atomic/tracker#144](https://forge.fedoraproject.org/atomic/tracker/issues/144).
It contains a kernel, systemd, podman, the SELinux policy, bootc and dnf, and
by design no bootloader: the base does not have to be installable on its own.

This is a prototype of building it **without rpm-ostree**: no treefiles and
no `rpm-ostree compose`, just `dnf --installroot` plus a short list of
explicit build steps in the [Containerfile](Containerfile).

## Building and testing

```bash
just build        # podman build --security-opt=label=disable -t localhost/seed .
just test         # test-rootfs + test-derive + test-boot
```

- `test-rootfs` checks the image layout from inside a container
  ([tests/rootfs.sh](tests/rootfs.sh)).
- `test-derive` builds an image `FROM` the seed that upgrades its kernel (or
  reinstalls it, if the repos have nothing newer). The result must have
  exactly one kernel and a fresh initramfs
  ([tests/Containerfile.derive](tests/Containerfile.derive)).
- `test-boot` boots the seed with `bcvk ephemeral`, which uses QEMU direct
  kernel boot with the root on virtiofs, so no bootloader is needed
  ([tests/booted.sh](tests/booted.sh)). Note that this path skips
  ostree-prepare-root and composefs; only an installed system exercises those.

The build also runs `bootc container lint --fatal-warnings`.

`BUILDER_IMAGE` (default `quay.io/fedora/fedora:rawhide`) selects the Fedora
release: the repos and releasever are taken from it.

## How it's built

1. **builder**: `dnf --installroot=/target --use-host-config install` of
   [packages.txt](packages.txt), without weak dependencies. In the same layer,
   the state that scriptlets leave behind is cleaned up or moved (`/run`,
   logs, caches, the SELinux module store, the rpmdb journal mode), and the
   static files from [rootfs/](rootfs) are added.
2. **rootfs**: the installed tree becomes a container, and the remaining steps
   run *inside it* as ordinary `RUN`s, the same way any derived image is
   built: apply bootc's reference layout, generate the initramfs via
   `kernel-install`, apply systemd presets, and lint.
3. The result is flattened into a single layer (`FROM scratch` + `COPY`).

Unlike the rpm-ostree build, this needs no nested containers, `--cap-add=all`
or `/dev/fuse`. It still needs `--security-opt=label=disable`: once the target's
SELinux policy is installed, `%sysusers` scriptlets try to label files in the
installroot, which the default `container_t` confinement denies.

## What rpm-ostree did, and what the seed does instead

| rpm-ostree compose and base-images | seed |
| --- | --- |
| treefile manifests | [packages.txt](packages.txt) and the Containerfile |
| `/sysroot`, `/ostree` link, composefs and read-only `/sysroot` in `prepare-root.conf`, dracut `ostree`/`bootc` modules | the same, taken from bootc's own reference content in `/usr/share/doc/bootc/baseimage` where possible |
| `/home`, `/root`, `/srv`, `/mnt`, `/media` links to `/var` and `/run`; `provision.conf` rewritten and `home.conf` removed, since tmpfiles doesn't follow those links | same, plus [seed-toplevel.conf](rootfs/usr/lib/tmpfiles.d/seed-toplevel.conf) |
| runs dracut, `05-rpmostree.install` handles `layout=ostree` in derived builds | [05-bootc-initramfs.install](rootfs/usr/lib/kernel/install.d/05-bootc-initramfs.install), which mirrors `rpm-ostree kernel-install` (depmod and dracut into `/usr/lib/modules`, then skip the other plugins; no UKIs), used for the seed itself too |
| `/var` content converted to tmpfiles.d automatically ("autovar") | [seed-var.conf](rootfs/usr/lib/tmpfiles.d/seed-var.conf), checked by the linter |
| SELinux module store moved to `/etc/selinux` | same, done in the builder |
| rpmdb moved to `/usr/share/rpm`, normalized to a rollback journal | rpm's native `/usr/lib/sysimage/rpm`, same normalization |
| passwd/group split into `/usr/lib` via nss-altfiles | plain `/etc/passwd` from sysusers.d, no nss-altfiles (see [#87](https://forge.fedoraproject.org/atomic/tracker/issues/87)) |
| `remove-from-packages` for systemd-firstboot | [drop-in](rootfs/usr/lib/systemd/system/systemd-firstboot.service.d/50-seed-noninteractive.conf) that runs it without prompts, so credentials still work and a systemd update in a derived image can't bring the prompts back |
| `/usr/lib/sysimage/rpm-ostree-base-db` ([#82](https://forge.fedoraproject.org/atomic/tracker/issues/82)) | not needed |

Compared to the current `minimal` image (243 packages, 779 MB), the seed has
211 packages (not counting `gpg-pubkey` entries) and 678 MB. It drops the
bootloader stack (bootupd, grub2, shim), mkfs tools, nss-altfiles, tpm2-tools,
microcode_ctl, systemd-resolved and fedora-repos-archive. Beyond the packages
the tracker issue lists, it has `systemd-pam`, `dbus` and `kmscon` (Fedora's
presets use kmscon for the VT login), which upstream `minimal` also includes
explicitly, and `dnf5`, because derived images need a package manager.

## Found along the way

These came up while building the prototype and probably deserve issues of their
own:

- **Kernel updates in derived images from `minimal` are broken today.**
  `minimal` doesn't ship rpm-ostree but keeps `layout=ostree`, which nothing
  handles. A derived `dnf upgrade kernel` leaves the new
  `/usr/lib/modules/$kver` without an initramfs, keeps the old one in a stale
  directory (failing the `kernel` lint), and fills `/boot`. The
  kernel-install plugin here fixes that, and it belongs in bootc, which already
  ships the `layout=ostree` configuration.
- `/root` is a dangling link during container builds of `minimal`, so tools
  that write to `$HOME` in a `RUN` fail. The seed creates the `/var` targets in
  the image.
- bootc's reference base image content is installed as `%doc`, so a
  `tsflags=nodocs` build (which is the default in the `fedora` container
  image) silently loses it. A subpackage that installs it at its real paths
  would make it owned by rpm and visible to derived images. Also, its dracut
  configuration is under `/usr/lib/dracut.conf.d`, which dracut does not read
  (it reads `/usr/lib/dracut/dracut.conf.d` and `/etc/dracut.conf.d`), so
  copying it verbatim produces an initramfs without the `ostree` and `bootc`
  modules.
- kernel-core's `%posttrans` runs `kernel-install add ... || exit 0`, so a
  failing dracut in a derived build goes unnoticed and the image ships
  without an initramfs (the `%preun` of the old kernel already removed it).
  It also copies `symvers` into `/boot`.
- systemd-tmpfiles doesn't follow the `/root` and `/home` links. Rewriting
  systemd's `provision.conf` (as base-images does, and the seed copies) is
  undone whenever a derived image updates systemd.
- bootc can already convert `/var` content into tmpfiles.d entries
  (`bootc_tmpfiles::var_to_tmpfiles`), but doesn't expose that on the CLI.
  If it did, `seed-var.conf` could be generated.
- `bcvk ephemeral run --execute` hangs until its timeout when the command
  fails instead of returning the failure; `tests/booted.sh` works around it.
- bootupd fails on systems installed from an image without an
  `org.opencontainers.image.version` label: bootc writes a null version into
  `/sysroot/.bootc-aleph.json`, which bootupd can't parse
  (`bootloader-update.service` fails, as does `bootupctl status`); this is
  [coreos/bootupd#1166](https://github.com/coreos/bootupd/issues/1166). The
  seed sets the label (`VERSION` build argument, `dev` by default).

## Not done yet

- A derived, installable image with a bootloader. grub2 already ships
  `/usr/lib/efi` content for bootupd, but shim still only installs to
  `/boot/efi`.
- Rechunking (e.g. with chunkah), reproducibility (`SOURCE_DATE_EPOCH`),
  multi-arch, and Konflux pipelines.
- UID/GID stability across builds now that users come from sysusers.d
  instead of a fixed passwd file.
- The initramfs lacks the `tpm2-tss` dracut module that `minimal` adds, since
  the seed doesn't ship tpm2-tools; derived images that unlock LUKS with a
  TPM need to add both.

## Related work

[cverna/bootc-base-imagectl-dnf5](https://github.com/cverna/bootc-base-imagectl-dnf5)
also replaces rpm-ostree with dnf5, but keeps the base-images treefile
manifests and reimplements their semantics in Python. That is the path for
moving the existing manifests over unchanged. The seed instead drops the
treefile format and expresses the image as a Containerfile.

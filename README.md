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

## The goal: compatible output

The seed changes how the image is built, not what it contains. For the same
package set, its output must be bit-for-bit compatible with what the current
rpm-ostree based build produces
([fedora/bootc/base-images](https://gitlab.com/fedora/bootc/base-images),
`bootc-base-imagectl build-rootfs`): the same paths, file types, modes,
ownership, link targets, contents, extended attributes and timestamps, except
for what differs between two builds of the reference itself (see below).
Existing systems update from those images and derived images build `FROM`
them, so any difference can break them, however reasonable it looks on its
own. A change to the content belongs in the current images first.
[AGENTS.md](AGENTS.md) states the same rule for agents.

The seed doesn't meet this yet; [Compatibility with the current
images](#compatibility-with-the-current-images) lists what `just compare`
finds.

## Building and testing

```bash
just build        # podman build --security-opt=label=disable -t localhost/seed .
just test         # test-rootfs + test-derive + test-boot
just grub         # localhost/seed-grub: the seed plus bootupd, grub2 and shim
just test-grub    # bootc install it to a disk and boot it from there
just hummingbird  # localhost/seed-hummingbird: built from Hummingbird's packages
just compare      # diff against rpm-ostree's minimal image, same packages
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

`compare` builds the reference, the minimal image built the current way
([tests/compat/Containerfile](tests/compat/Containerfile), which needs nested
containers like base-images does), then the seed and its grub variant from
the reference's packages at the same versions (the seed's own
[packages.txt](packages.txt) is a subset of them). It then reports every path
whose type, mode, ownership, link target, content, file capabilities or
user.* extended attributes differ, with the owning packages, and how many
mtimes differ ([tests/compat/compare.py](tests/compat/compare.py)). SELinux
labels, hardlinks and the image configuration aren't compared. It fails if
the package versions differ, and otherwise reports rather than fails while
the seed's output still differs. `COMPARE_RELEASE` selects the Fedora release
(default `rawhide`). `test-unit` tests the comparison itself.

`BUILDER_IMAGE` (default `quay.io/fedora/fedora:rawhide`) selects the Fedora
release: the repos and releasever are taken from it. `PODMAN_BUILD_ARGS`
passes extra arguments to all the podman builds, see the [Justfile](Justfile).
Set `IMAGE` to run the recipes against another image, e.g.
`IMAGE=localhost/seed-hummingbird just test`.

### The grub variant

[grub/Containerfile](grub/Containerfile) is an ordinary derived image that
makes the seed installable: bootupd with grub2 and shim, plus the mkfs tools
`bootc install to-disk` needs. shim and grub2 already ship their EFI binaries
in `/usr/lib/efi`, which bootupd reads directly, so unlike with rpm-ostree
nothing needs to move content out of `/boot`.

`test-grub` installs it with `bcvk libvirt run` (UEFI with Secure Boot) and
checks the booted system over SSH ([tests/installed.sh](tests/installed.sh)):
composefs root, read-only `/sysroot`, SELinux enforcing, Secure Boot, a
successful `bootloader-update.service`, and no failed units. bcvk drives the
install over SSH from inside the image under test, so the test image
([tests/Containerfile.installed](tests/Containerfile.installed)) adds
openssh-server, openssh-clients and NetworkManager, none of which the seed
has. Like Fedora's images, the seed doesn't set a default root filesystem, so
the test passes `--filesystem xfs`.

### Hummingbird

`just hummingbird` builds the seed from
[Project Hummingbird](https://hummingbird-project.io)'s packages (Fedora
packages rebuilt as `*.hum1`), using Hummingbird's own builder image,
`quay.io/hummingbird-ci/hummingbird-builder`, which provides its repo and
signing key. Hummingbird doesn't carry everything the seed needs, so like
Hummingbird's own images it falls back to Fedora 44, through Hummingbird's
rebuild of `fedora-repos`, which pins release 44. Hummingbird's repo has
`priority=10`, so its packages win wherever both have one. Of the seed's 208
packages, 199 come from Hummingbird; the kernel, kmscon and kmscon's
dependencies come from Fedora, as do the bootloader packages, xfsprogs (with
its dependency inih) and os-prober in the grub variant. It is `Hummingbird OS`
(`hummingbird-release`), and derived builds get the same repos
(`hummingbird-repos` and `fedora-repos`). All tests, including `test-grub`,
pass with `IMAGE=localhost/seed-hummingbird`.

The main difference is the preset policy. Fedora 44 ships its presets in
`fedora-release-common`, which conflicts with `hummingbird-release`.
Hummingbird only has systemd's own presets, which have no catch-all, so every
other installed unit would be enabled (automatic bootc updates,
`podman-auto-update`, `systemd-homed-firstboot`, which then hangs the first
boot on a prompt, ...). The seed therefore carries fallbacks for what it
relies on in its own presets: a catch-all `disable *`, the system and session
bus, ostree-remount and authselect-apply-changes. What remains different is
distribution policy: Hummingbird gets systemd's own choices (e.g. getty rather
than kmscon for the VT login, timesyncd, systemd-boot-update), and not
Fedora's (e.g. systemd-oomd, fstrim.timer, rpmdb-rebuild, the FIPS crypto
policy overlay, selinux-autorelabel-mark).

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

Several of these are differences under the goal above; see the next section.

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
the tracker issue lists, it has `systemd-pam`, `dbus` and `kmscon` (rawhide's
presets use kmscon for the VT login, Fedora 44's still getty), which upstream
`minimal` also includes explicitly, and `dnf5`, because derived images need a
package manager.

## Compatibility with the current images

Two builds of the reference itself, from the same packages, differ in
`/usr/share/rpm/rpmdb.sqlite` and its copy in
`/usr/lib/sysimage/rpm-ostree-base-db` (they record install times),
`/usr/lib/bootupd/updates/EFI.json` (a timestamp) and java's `cacerts`, and
in the mtimes of what was created at build time. These are the exceptions in
the goal. Beyond them, `just compare` finds the following on Fedora 44 and
rawhide:

- **Users and groups.** The reference injects fixed passwd and group entries
  (the manifest's `passwd` and `group` files) into `/usr/lib/passwd` and
  `/usr/lib/group` for nss-altfiles, keeps only a few groups (wheel,
  systemd-journal, tss, kvm, adm) in `/etc/group`, and adds dracut's
  `59-altfiles.conf` so the initramfs has them too. The seed lets sysusers
  allocate everything into `/etc`, and leaves `passwd-`, `shadow-` and so on,
  and `.pwd.lock`, behind. On an existing system whose `/etc/passwd` was
  changed locally (e.g. by adding a user), the 3-way merge keeps the local
  file, so every system user that only the new image's `/etc/passwd` has
  would be missing; UIDs and GIDs differ too.
- **authselect.** authselect-libs' scriptlet creates the altfiles vendor
  profiles in `/usr/share/authselect/vendor` only when `/run/ostree-booted`
  exists, which rpm-ostree's install provides and the seed's doesn't;
  `/etc/authselect/nsswitch.conf` differs accordingly.
- **rpmdb.** The reference has it in `/usr/share/rpm`, with
  `/usr/lib/sysimage/rpm` linking there, `%_dbpath` set in
  `macros.rpm-ostree`, and `/usr/lib/sysimage/rpm-ostree-base-db`. The seed
  uses rpm's native location, and adds `gpg-pubkey` entries and dnf5's state
  in `/usr/lib/sysimage/libdnf5`.
- **`/var`.** The reference's `/var` only has `lib/rpm-state`, `tmp` and the
  `run` link; rpm-ostree turns the rest into tmpfiles.d entries
  (`rpm-ostree-autovar.conf`, per-package files in
  `/usr/lib/rpm-ostree/tmpfiles.d`, `rpm-ostree-0-integration*.conf`). The
  seed ships `/var`'s directories plus `seed-var.conf`.
- **Modes.** System directories such as `/usr/bin`, `/usr/lib` and `/boot` are
  0755 in the reference and 0555 (as packaged) in the seed, `/etc/machine-id`
  is 0644 rather than 0444, and the initramfs 0644 rather than 0600.
- **Configuration files** with the same purpose but other names or contents:
  dracut (`20-bootc-base`, `22-bootc-generic`, `49-bootc-tpm2-tss` versus
  bootc's `10-bootc-base` and `30-seed`; the initramfs differs too),
  kernel-install (`install.conf` rewritten plus `00-bootc-kernel-layout.conf`,
  versus `00-bootc-layout.conf` and the seed's plugin), dnf
  (`20-ostree-installonlypkgs.conf` and `20-ostree-protect_running_kernel.conf`
  versus `20-seed-kernel.conf`), presets (`85-bootc`,
  `85-bootc-bootloader-update` versus `85-seed`, `85-seed-grub`, `90-seed`,
  `99-seed-disable`), tmpfiles (`bootc-base-rpmstate`,
  `konflux-buildinfo-contentsets` versus `seed-*`), `prepare-root.conf`
  (`enabled = yes` versus bootc's `enabled = true`), and
  `/etc/crypto-policies/config` (the packaged, commented file versus a bare
  `DEFAULT`).
- **Removed content.** The reference drops `systemd-firstboot.service` from
  `sysinit.target.wants`, and grub2-tools' systemd units and
  `/etc/grub.d/{08_fallback_counting,10_reset_boot_success,12_menu_auto_hide}`;
  the seed keeps them (systemd-firstboot with a drop-in, grub's timer
  disabled).
- **SELinux.** Both keep the module store in `/etc/selinux`, but the compiled
  policy and the store's files differ, and the reference has an empty
  `/etc/selinux/final`.
- **Smaller differences.** The reference has an empty
  `/usr/lib/ostree-boot/efi` and `/usr/lib/opt`, and drops packaged paths
  that the seed keeps: `/afs`, `/usr/lib/debug/*`, `/usr/local/sbin`. The seed
  has a regular file at `/dev/null`, written by a scriptlet in the
  installroot, which has no device nodes: a bug.

Not in that list, because `just compare` doesn't cover them:

- **Timestamps.** In the reference, files under `/usr` have mtime 0 (from
  rpm-ostree's ostree checkout), but most of `/etc` keeps build-time mtimes;
  the published `quay.io/fedora/fedora-bootc:44` has mtime 0 in `/etc` as
  well, after rechunking. The seed keeps rpm's mtimes; rechunking it the same
  way is the likely answer.
- **Image configuration.** The published images' labels differ by
  repository: `quay.io/fedora/fedora-bootc:44` has
  `org.opencontainers.image.version` `44.<date>.0`, `ostree.*` and
  `rpmostree.inputhash` labels, while
  `quay.io/bootc-devel/fedora-bootc-rawhide-minimal` has `46`,
  `bootc.diskimage-builder` and source and revision labels. The seed has
  `dev`.
- **SELinux labels and hardlinks**, and the layers of the published,
  rechunked images.

## Getting there

Two ways, which can be combined:

1. **Keep rpm-ostree's postprocessing for now**, as
   [base-images-experimental](#inputs-and-prior-work) did: install with
   `dnf --installroot` (the container- and dnf-native part), run
   `rpm-ostree compose postprocess` in the builder, and rechunk the result
   (`bootc-base-imagectl rechunk`). That reuses rpm-ostree's own handling of
   e.g. the rpmdb location and `/var`, but not what happens at install time
   (the fixed passwd and group entries, the scriptlet environment), which
   would still need doing. Each rpm-ostree step can then be replaced by an
   explicit one, with `just compare` showing that the replacement changes
   nothing. The cost is what the seed avoids today: nested containers and
   `--cap-add=all`. Not tried yet, so which differences it removes needs
   measuring.
2. **Close each gap in the seed itself**: the fixed passwd and group files
   with nss-altfiles, `/run/ostree-booted` and device nodes in `/dev` during
   the install (base-images-experimental's `dnf-installroot` sets up both),
   rpm-ostree's rpmdb location and `/var` conversion, the same file names,
   and timestamp normalization when rechunking.

Either way, the package lists should come from the base-images manifests
rather than a second list here, so that the package sets stay the same;
cverna/bootc-base-imagectl-dnf5 already reads them.

## Not done yet

- Compatible output, see above.
- Rechunking (e.g. with chunkah or `bootc-base-imagectl rechunk`),
  reproducibility (`SOURCE_DATE_EPOCH`), multi-arch, and Konflux pipelines.
- The seed's own package set lacks `tpm2-tools`, so its initramfs lacks the
  `tpm2-tss` dracut module that `minimal` adds; derived images that unlock
  LUKS with a TPM need to add both.

## Inputs and prior work

Inputs:

- [atomic/tracker#144](https://forge.fedoraproject.org/atomic/tracker/issues/144),
  the epic for the seed: the minimal package set, a base that doesn't have
  to boot, testing policy, Konflux pipelines and documentation.
- [atomic/tracker#137](https://forge.fedoraproject.org/atomic/tracker/issues/137),
  CoreOS and Atomic unification, which the seed is part of; see also
  [coreos/fedora-coreos-tracker#2214](https://github.com/coreos/fedora-coreos-tracker/issues/2214),
  [base-images#84](https://gitlab.com/fedora/bootc/base-images/-/work_items/84)
  and the [unification call notes](https://nimbinatus.fedorapeople.org/#unification).
- [fedora/bootc/base-images](https://gitlab.com/fedora/bootc/base-images),
  the current rpm-ostree based build and the compatibility target. Its
  `bootc-base-imagectl` and manifests (also in the fedora-bootc images, under
  `/usr/share/doc/bootc-base-imagectl/manifests`) build the reference for
  `just compare`. See also the
  [minimal image philosophy](https://docs.fedoraproject.org/en-US/bootc/base-images/#_minimal_image_philosophy)
  and [building from scratch](https://docs.fedoraproject.org/en-US/bootc/building-from-scratch/).
- bootc's reference base image content (`/usr/share/doc/bootc/baseimage`)
  and its [image requirements](https://bootc.dev/bootc/bootc-images.html#standard-image-content).
- [atomic/tracker#82](https://forge.fedoraproject.org/atomic/tracker/issues/82)
  (`rpm-ostree-base-db`) and
  [#87](https://forge.fedoraproject.org/atomic/tracker/issues/87)
  (nss-altfiles and sysusers).
- [bcvk](https://github.com/bootc-dev/bcvk), for the boot and install tests.

Prior work:

- [base-images-experimental](https://gitlab.com/fedora/bootc/base-images-experimental)
  (Colin Walters, 2024; archived in January 2025 in favour of
  [fedora/bootc/tracker#32](https://gitlab.com/fedora/bootc/tracker/-/work_items/32),
  "Supportable customizable base images"). Its build rationale asks for the
  same as the seed: container-native, dnf-native, no new file formats,
  hackable. It installs with `dnf --installroot`, using the builder's repos,
  through a `dnf-installroot` wrapper that gives scriptlets `/proc`, a tmpfs
  `/dev` with device nodes bound from the host, tmpfs `/run` and `/tmp`, and
  `/run/ostree-booted`. Package lists are `.spec` files whose `BuildRequires`
  go to `dnf builddep`, for comments and architecture and distribution
  conditionals. "imagedirs" add `rootfs/` content, `.post` scripts (run with
  bwrap), an `inherit` link for variants (full inherits minimal), and fixed
  `passwd` and `group` files for stable UIDs and GIDs. It then still runs
  `rpm-ostree compose postprocess`, with its own settings (e.g. `rpmdb: host`,
  `boot-location: modules`), and commits and encapsulates the result into a
  chunked image, picked up with `FROM oci-archive:`, so its output follows
  rpm-ostree's conventions. Compared to the seed, that addresses the
  scriptlets' environment in the installroot, stable IDs, chunked layers,
  conditionals in package lists and, through rpm-ostree, much of the current
  images' layout; at the price of nested containers and `--cap-add=all`. Its
  move of the EFI binaries into `/usr/lib/ostree-boot` is obsolete, since
  bootupd reads `/usr/lib/efi`.
- [cverna/bootc-base-imagectl-dnf5](https://github.com/cverna/bootc-base-imagectl-dnf5)
  also replaces rpm-ostree with dnf5, but keeps the base-images treefile
  manifests and reimplements their semantics in Python, which keeps the
  package sets those of the current images.
- Hummingbird's own bootable images
  ([bootc-os, now os-minimal](https://gitlab.com/redhat/hummingbird/containers/-/tree/main/images/os-minimal))
  are also built with `dnf --installroot` and no rpm-ostree, from lockfiles.
  They keep the SELinux module store in `/usr/lib/selinux` rather than
  `/etc`, to avoid the 3-way merge of the policy files on updates. See also
  the [Hummingbird SIG](https://fedoraproject.org/wiki/Hummingbird) and
  [its container definitions](https://gitlab.com/redhat/hummingbird/containers).
- rpm-ostree's postprocessing is, in effect, the specification of the
  current output, e.g. the SELinux store equivalency
  ([coreos/rpm-ostree#5616](https://github.com/coreos/rpm-ostree/issues/5616))
  and the rpmdb normalization
  ([rpm#2219](https://github.com/rpm-software-management/rpm/issues/2219)).

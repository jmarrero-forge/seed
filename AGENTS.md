# Instructions for agents working on the seed

## The goal: compatible output

The seed replaces how Fedora's bootc base images are built (rpm-ostree
treefiles and `rpm-ostree compose`), not what they contain. For the same
package set, its output must be bit-for-bit compatible with the images the
current rpm-ostree based build produces (`bootc-base-imagectl build-rootfs`,
as used by fedora/bootc/base-images): the same paths, file types, modes,
ownership, link targets, contents, extended attributes and timestamps. The
only exceptions are files that differ between two builds of the reference
itself, such as recorded build times; the README lists them.

Existing systems update from those images to ours, and derived images build
`FROM` them. Any difference, however reasonable it looks on its own, can break
them: e.g. a user moving from `/usr/lib/passwd` to `/etc/passwd`, a UID or
GID that is allocated differently, a relocated rpmdb, or a unit that is
enabled differently.

So:

- Treat every difference from the reference as a bug. The README's
  "Compatibility with the current images" lists the known ones; a difference
  may only stay on purpose if it is recorded there, with the reason and what
  happens to existing systems and derived images.
- Don't "improve" the image in passing. A change to the output is a change
  for the current images too; propose it there, or record it as a deviation.
- When you change the build, run `just compare` before and after, and say in
  the commit message what changed in the output, if anything. Keep the
  README's list of differences up to date with what it reports. It doesn't
  check everything yet (not SELinux labels, hardlinks, timestamps or the
  image configuration); don't take its silence on those as compatibility.

## Building and testing

`just --list` shows the recipes. `just build` and `just test` must pass before
committing; for changes that touch booting, the bootloader or installation,
`just grub` and `just test-grub` as well. The README describes what each
test covers.

The seed's own build needs `--security-opt=label=disable`, which `just build`
and `just hummingbird` pass. Don't relabel host paths you mount into builds
(no `:z` on system directories).

## Conventions

- Keep build logic in the Containerfiles as explicit, commented steps;
  comments say why a step exists and where the proper fix belongs if it is a
  workaround (with a link to the upstream issue).
- Static content goes in `rootfs/`, at the path it has in the image.
- Tests assert specific values, not just that a command succeeded. Don't
  swallow errors (`|| true`, `2>/dev/null`) without a stated reason.
- Commit subjects are `component: Summary` in the imperative; the body
  starts with why the change is made.

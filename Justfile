# Development entry point for the seed image; run `just --list`.

image := env("IMAGE", "localhost/seed")
# Controls the package versions (repos and releasever) of the seed.
builder_image := env("BUILDER_IMAGE", "quay.io/fedora/fedora:rawhide")
# Extra arguments for all the `podman build`s. E.g. when the repos serve a
# certificate only the host trusts, mount the host's CA bundle (label=disable
# lets the build read it without relabeling it; it is read-only, so build
# steps that update ca-certificates would fail):
#   PODMAN_BUILD_ARGS="--security-opt=label=disable -v /etc/pki/ca-trust/extracted:/etc/pki/ca-trust/extracted:ro"
podman_build_args := env("PODMAN_BUILD_ARGS", "")
# Hummingbird's own builder image; it ships the Hummingbird repo and keys.
hummingbird_builder_image := env("HUMMINGBIRD_BUILDER_IMAGE", "quay.io/hummingbird-ci/hummingbird-builder:latest")
# Generous upper bound for booting and running tests/booted.sh; a healthy
# boot takes seconds, but bcvk hangs instead of failing when the command does.
boot_timeout := "300"
# Passed as the ssh.authorized_keys.root credential in test-boot; only the
# comment is checked, so the key itself doesn't need to be valid.
boot_test_key_comment := "seed-boot-test"
boot_test_key := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderNotARealKeyForSeedTests " + boot_test_key_comment
# libvirt domain used (and removed again) by test-grub; named after the image,
# so that runs for different images don't collide.
grub_test_vm := file_name(image) + "-grub-test"

# Build the seed image
build:
    podman build --security-opt=label=disable {{podman_build_args}} \
        --build-arg=BUILDER_IMAGE={{builder_image}} -t {{image}} .

# Build the seed from Hummingbird's packages, falling back to Fedora 44 for
# the ones Hummingbird doesn't carry (e.g. the kernel), like Hummingbird's own
# images. Hummingbird's fedora-repos rebuild pins release 44, and its own repo
# has priority=10, so its packages win wherever both have one.
# Test with e.g. `IMAGE=localhost/seed-hummingbird just test`.
hummingbird:
    podman build --security-opt=label=disable {{podman_build_args}} \
        --build-arg=BUILDER_IMAGE={{hummingbird_builder_image}} \
        --build-arg=BUILDER_PACKAGES=fedora-repos \
        --build-arg="EXTRA_PACKAGES=hummingbird-release fedora-repos" \
        -t {{image}}-hummingbird .

# Build an installable variant of the seed, with bootupd, grub2 and shim
grub:
    podman build {{podman_build_args}} --build-arg=SEED={{image}} -t {{image}}-grub grub

# Install the grub variant to a disk and boot it (UEFI with Secure Boot)
test-grub:
    #!/usr/bin/bash
    set -euo pipefail
    podman build {{podman_build_args}} -f tests/Containerfile.installed \
        --build-arg=BASE={{image}}-grub \
        -t {{image}}-grub-test tests
    trap 'bcvk libvirt rm --force {{grub_test_vm}}' EXIT
    # Like Fedora's images, the seed has no default root filesystem type.
    bcvk libvirt run --name {{grub_test_vm}} --filesystem xfs --firmware uefi-secure \
        --detach --ssh-wait {{image}}-grub-test
    bcvk libvirt ssh {{grub_test_vm}} /usr/libexec/seed-tests/installed.sh

# Run all tests against an already built image
test: test-rootfs test-derive test-boot

# Check the root filesystem from inside a container
test-rootfs:
    podman run --rm -v {{justfile_directory()}}/tests:/tests:ro,z {{image}} /tests/rootfs.sh

# Check that a derived build can update the kernel
test-derive:
    podman build {{podman_build_args}} -f tests/Containerfile.derive --build-arg=SEED={{image}} \
        -t {{image}}-derive-test tests

# Boot the seed; no bootloader needed, as bcvk boots the kernel directly
test-boot:
    #!/usr/bin/bash
    set -euo pipefail
    key_b64=$(printf '%s\n' "{{boot_test_key}}" | base64 -w0)
    # Force first-boot semantics (bcvk boots are otherwise not "first"), so
    # that systemd-firstboot runs and would block if it prompted.
    rc=0
    out=$(timeout {{boot_timeout}} bcvk ephemeral run --rm \
        --karg systemd.condition_first_boot=true \
        --karg "systemd.set_credential_binary=ssh.authorized_keys.root:${key_b64}" \
        --bind {{justfile_directory()}}/tests:tests \
        --execute "/usr/bin/bash /run/virtiofs-mnt-tests/booted.sh {{boot_test_key_comment}}" \
        {{image}}) || rc=$?
    echo "${out}"
    test "${rc}" -eq 0 || { echo "bcvk exited with ${rc}" >&2; exit 1; }
    grep -qx 'SEED-BOOTED: PASS' <<< "${out}"

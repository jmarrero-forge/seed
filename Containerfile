# The seed: a minimal Fedora bootc base image, composed with plain dnf
# (no rpm-ostree, no treefiles).
#
# The builder stage only installs packages into an empty root. Everything
# after that runs *inside* that root as ordinary container build steps, i.e.
# the same way any derived image is built.
#
# Build with:
#   podman build --security-opt=label=disable -t localhost/seed .
# label=disable is needed because, once the target's SELinux policy is
# installed, %sysusers scriptlets try to label files in the installroot,
# which the default container_t confinement denies.

# Controls the package versions: the repos and releasever come from this image.
ARG BUILDER_IMAGE=quay.io/fedora/fedora:rawhide

FROM ${BUILDER_IMAGE} AS builder
RUN dnf -y install sqlite
COPY packages.txt /src/
COPY rootfs/ /src/rootfs/
# Don't leak the umask or setuid/setgid bits of the build context's checkout
# into the image; same as fedora/bootc/base-images.
RUN chmod -R a=rX,u+w /src
RUN --mount=type=cache,rw,id=seed-dnf-cache,target=/target/var/cache/libdnf5 <<EORUN
set -xeuo pipefail
# --use-host-config takes the repos from the builder, but also its dnf and rpm
# configuration, which is tuned for a small application container. Undo the
# parts that would change the seed's content: the builder installs only
# en_US translations and no docs (bootc's reference content is docs).
rm /etc/rpm/macros.image-language-conf
# Scriptlets detect image mode systems via /ostree (e.g. alternatives keeps
# its state in /etc instead of /var); make them behave as in derived builds.
mkdir -p /target
ln -s sysroot/ostree /target/ostree
# The kernel's %posttrans would run kernel-install before our configuration
# is in place; the initramfs is generated in the next stage instead.
# best/skip_if_unavailable: fail rather than silently compose something else.
KERNEL_INSTALL_BYPASS=1 dnf -y --installroot=/target --use-host-config \
    --setopt=tsflags= --setopt=install_weak_deps=False \
    --setopt=best=True --setopt=skip_if_unavailable=False \
    --setopt=keepcache=True \
    install $(grep -Ev '^\s*(#|$)' /src/packages.txt)

# Now fix up the state the transaction left behind. This stays in the same
# layer as the install so that moves are plain renames.
cd /target
# Runtime-only state.
find run tmp -mindepth 1 -delete
# /var is only applied at initial install, so drop build-time state from it;
# directories that remain are declared in seed-var.conf for later upgrades.
rm -r var/cache/ldconfig/aux-cache var/lib/dnf var/lib/rpm-state/kernel
find var/log -type f -print -delete
# authselect re-applies its configuration at boot.
rm var/lib/authselect/checksum
# The SELinux module store must track the policy shipped in the image, so
# move it out of /var into /etc, like rpm-ostree does; seed-var.conf links
# /var/lib/selinux back to it.
mv var/lib/selinux/targeted/active etc/selinux/targeted/
rm -r var/lib/selinux
echo 'store-root=/etc/selinux' >> etc/selinux/semanage.conf
# Label lookups through the compatibility symlink resolve like /etc/selinux;
# https://github.com/coreos/rpm-ostree/issues/5616
echo '/var/lib/selinux /etc/selinux' >> etc/selinux/targeted/contexts/files/file_contexts.subs
# rpm leaves the database in WAL mode, which can't be opened on the read-only
# /usr of a booted system without its sidecar files. Switch to a rollback
# journal, which also checkpoints and drops the sidecars; same as rpm-ostree,
# see https://github.com/rpm-software-management/rpm/issues/2219
sqlite3 usr/lib/sysimage/rpm/rpmdb.sqlite 'PRAGMA journal_mode=DELETE;'
test ! -e usr/lib/sysimage/rpm/rpmdb.sqlite-wal

# Add the seed's own files. Without --preserve, cp leaves the modes of
# existing directories (e.g. /usr/lib is 0555) as the packages set them.
cp -r /src/rootfs/. /target/
EORUN

FROM scratch AS rootfs
COPY --from=builder /target/ /
RUN <<EORUN
set -xeuo pipefail
# bootc's reference content for base images, see
# /usr/share/doc/bootc/baseimage: /sysroot, /ostree -> sysroot/ostree (created
# in the builder already), composefs for ostree, and the dracut modules bootc
# needs. bootc ships the latter under /usr/lib/dracut.conf.d, which dracut
# does not read, so install it into /usr/lib/dracut/dracut.conf.d instead.
ref=/usr/share/doc/bootc/baseimage
mkdir /sysroot
install -m 0644 -D "$ref/base/usr/lib/ostree/prepare-root.conf" /usr/lib/ostree/prepare-root.conf
install -m 0644 "$ref/dracut/usr/lib/dracut.conf.d/10-bootc-base.conf" /usr/lib/dracut/dracut.conf.d/
# Like the base-images, also keep /sysroot read-only at runtime.
printf '[sysroot]\nreadonly = true\n' >> /usr/lib/ostree/prepare-root.conf

# The root filesystem is read-only at runtime, so point the toplevel writable
# directories at /var and /run; seed-toplevel.conf creates the targets.
for d in home srv mnt; do rmdir "/$d"; ln -s "var/$d" "/$d"; done
rmdir /root && ln -s var/roothome /root
rmdir /media && ln -s run/media /media
# Also create the /var targets in the image itself, so that e.g. $HOME=/root
# works in derived container builds (and for dracut, which copies /root).
systemd-tmpfiles --create --prefix=/var /usr/lib/tmpfiles.d/seed-toplevel.conf
# systemd-tmpfiles doesn't follow those symlinks, so home.conf and
# provision.conf fail on every boot, which also breaks provisioning root's SSH
# keys via the ssh.authorized_keys.root credential. Point provision.conf at
# the real path and drop home.conf, like the base-images; seed-toplevel.conf
# already creates /var/roothome.
sed -i -e 's, /root, /var/roothome,' -e '/^d- \/var\/roothome /d' /usr/lib/tmpfiles.d/provision.conf
rm /usr/lib/tmpfiles.d/home.conf
EORUN
RUN <<EORUN
set -xeuo pipefail
# Exercise the same kernel-install path a derived image takes when it
# installs or updates the kernel.
kdirs=(/usr/lib/modules/*)
test "${#kdirs[@]}" -eq 1
kver=$(basename "${kdirs[0]}")
kernel-install add "$kver" "/usr/lib/modules/$kver/vmlinuz"
test -f "/usr/lib/modules/$kver/initramfs.img"
# The kernel's %posttrans copies symvers into /boot even with
# KERNEL_INSTALL_BYPASS; anything else there would be a bug.
rm "/boot/symvers-$kver.xz"
test -z "$(ls -A /boot)"
EORUN
RUN <<EORUN
set -xeuo pipefail
# Make the presets canonical: scriptlets ran while the preset files
# themselves were still being installed.
rm -rf /etc/systemd/system/* /etc/systemd/user/*
systemctl preset-all
systemctl --global preset-all
# Per-machine identity is generated on first boot.
truncate -s 0 /etc/machine-id
# The %post scriptlet fails to write this from the builder (ENOSYS).
systemd-hwdb update
bootc container lint --fatal-warnings --no-truncate
EORUN

FROM scratch
COPY --from=rootfs / /
# bootc records this at install time, and bootupd can't handle systems
# installed from an image without it: it fails to parse the null version in
# /sysroot/.bootc-aleph.json (https://github.com/coreos/bootupd/issues/1166).
ARG VERSION=dev
LABEL org.opencontainers.image.version=${VERSION}
LABEL containers.bootc=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

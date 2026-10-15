#!/usr/bin/bash
# Checks for the seed's root filesystem; runs inside the image:
#   podman run --rm -v ./tests:/tests:ro,z localhost/seed /tests/rootfs.sh
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

if rpm -q rpm-ostree; then fail "rpm-ostree is installed"; fi

# Exactly one kernel, its initramfs next to it, and nothing in /boot.
kdirs=(/usr/lib/modules/*)
test "${#kdirs[@]}" -eq 1 || fail "expected one kernel, got: ${kdirs[*]}"
initramfs="${kdirs[0]}/initramfs.img"
test -s "$initramfs" || fail "no initramfs in ${kdirs[0]}"
modules=$(lsinitrd -m "$initramfs")
for m in ostree bootc; do
    grep -qx "$m" <<< "$modules" || fail "dracut module $m not in the initramfs"
done
test -z "$(ls -A /boot)" || fail "/boot is not empty"

for link in home:var/home root:var/roothome srv:var/srv mnt:var/mnt \
    media:run/media ostree:sysroot/ostree; do
    name="/${link%%:*}" target="${link#*:}"
    test "$(readlink "$name")" = "$target" || fail "$name should link to $target"
done
test -d /sysroot || fail "/sysroot is missing"
test -d /var/roothome || fail "/var/roothome is missing, \$HOME breaks in builds"
# Our overlay must not change the modes packages set on shared directories.
modes=$(rpm -q --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' filesystem)
for d in /usr /usr/lib /usr/share; do
    want=$(awk -v d="$d" '$2 == d { print $1 }' <<< "$modes")
    test "$(stat -c %A "$d")" = "$want" || fail "$d is $(stat -c %A "$d"), filesystem has $want"
done

test -e /etc/machine-id || fail "/etc/machine-id is missing"
test ! -s /etc/machine-id || fail "/etc/machine-id is not empty"
# The seed's own presets apply even without the distribution's (e.g. on
# Hummingbird): what it relies on is enabled, everything else disabled.
for want in enabled:dbus.socket enabled:dbus-broker.service \
    enabled:ostree-remount.service enabled:authselect-apply-changes.service \
    enabled:autovt@tty1.service disabled:dnf-makecache.timer \
    disabled:bootc-fetch-apply-updates.timer disabled:podman-auto-update.timer \
    disabled:systemd-homed-firstboot.service; do
    state="${want%%:*}" unit="${want#*:}"
    test "$(systemctl is-enabled "$unit")" = "$state" || fail "$unit is not $state"
done
test "$(systemctl --global is-enabled dbus.socket)" = enabled || fail "no session bus"

# The rpmdb must be readable on a read-only /usr: rollback journal (sqlite
# header bytes 18-19 are 1, not 2 for WAL) and no sidecar files.
rpmdb=/usr/lib/sysimage/rpm/rpmdb.sqlite
test "$(od -An -tu1 -j18 -N2 "$rpmdb" | tr -s ' ')" = " 1 1" || fail "rpmdb is in WAL mode"
test ! -e "$rpmdb-shm" -a ! -e "$rpmdb-wal" || fail "rpmdb has sqlite sidecar files"

# State that must track the image lives in /etc, not /var.
test -d /etc/selinux/targeted/active/modules || fail "SELinux store not in /etc"
test ! -e /var/lib/selinux -a ! -L /var/lib/selinux || fail "/var/lib/selinux should only be created at boot"
test -e "/etc/alternatives-admindir/libnssckbi.so.$(uname -m)" || fail "alternatives state not in /etc"
test ! -e /var/lib/alternatives || fail "alternatives state in /var"

# Updating the kernel replaces it rather than installing alongside.
dnfconf=$(dnf5 --dump-main-config)
grep -qx 'installonlypkgs = ' <<< "$dnfconf" || fail "kernel is an installonly package"
grep -qx 'protect_running_kernel = 0' <<< "$dnfconf" || fail "dnf protects the build host's kernel"

echo "PASS: rootfs"

#!/usr/bin/bash
# Checks on the grub variant after `bootc install` and a boot from disk, run
# over SSH by `just test-grub`. Unlike `bcvk ephemeral`, this boots through
# shim, grub and ostree-prepare-root with composefs.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
# The SecureBoot EFI variable is 4 bytes of attributes followed by the value.
SECUREBOOT_VAR=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
# Upper bound for the boot to settle; a job stuck e.g. on a console prompt
# would otherwise block `is-system-running --wait` forever.
BOOT_WAIT_SECONDS=300

if ! state=$(timeout "$BOOT_WAIT_SECONDS" systemctl is-system-running --wait); then
    systemctl --failed --no-legend --plain >&2
    systemctl list-jobs --no-legend >&2
    journalctl -b -p err --no-pager -o cat >&2
    fail "system is ${state:-not settled after ${BOOT_WAIT_SECONDS}s}"
fi
test -e /run/ostree-booted || fail "not booted via ostree"
test "$(findmnt -no SOURCE /)" = composefs || fail "/ is not composefs"
findmnt -O ro /sysroot > /dev/null || fail "/sysroot is writable"
test "$(cat /sys/fs/selinux/enforce)" = 1 || fail "SELinux is not enforcing"
test "$(od -An -tu1 -j4 -N1 "$SECUREBOOT_VAR" | tr -d ' ')" = 1 || fail "not booted with Secure Boot"
# Fails e.g. on images without a version label, coreos/bootupd#1166.
test "$(systemctl is-active bootloader-update.service)" = active || fail "bootloader-update.service did not run"
bootupctl status
bootc status
rpm -q bootc kernel

echo "PASS: installed"

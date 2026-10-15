#!/usr/bin/bash
# Checks on a booted seed, run inside a `bcvk ephemeral` VM (see `just test-boot`).
# Takes the comment of the SSH key passed as the ssh.authorized_keys.root
# credential.
#
# The result is reported on the last line rather than via the exit code,
# because bcvk currently waits until its timeout when an --execute command
# fails instead of returning the failure.
set -euo pipefail
trap 'echo "SEED-BOOTED: FAIL at line $LINENO"; exit 0' ERR

key_comment="$1"
# How long to wait for the rest of the boot to settle.
JOB_WAIT_SECONDS=60

# This script runs as part of the boot transaction, so `systemctl
# is-system-running --wait` would deadlock. Instead, wait until the only jobs
# left are the targets waiting on this script's own units.
for _ in $(seq "$JOB_WAIT_SECONDS"); do
    pending=$(systemctl list-jobs --no-legend | awk '$2 !~ /^(bootc-execute.*\.service|multi-user\.target|graphical\.target)$/')
    test -z "${pending}" && break
    sleep 1
done
echo "${pending}"
test -z "${pending}"

failed=$(systemctl --failed --no-legend --plain)
echo "${failed}"
test -z "${failed}"
# The rpmdb is readable on the read-only /usr.
rpm -q bootc kernel
# systemd-firstboot ran non-interactively instead of blocking on the console.
test "$(systemctl is-active systemd-firstboot.service)" = active
test -s /etc/machine-id
# tmpfiles.d created what the image doesn't ship, including root's SSH key
# from the credential (provision.conf).
test -d /run/media
test "$(readlink /var/lib/selinux)" = ../../etc/selinux
grep -q " ${key_comment}\$" /root/.ssh/authorized_keys

echo "SEED-BOOTED: PASS"

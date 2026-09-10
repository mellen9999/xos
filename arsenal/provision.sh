#!/bin/sh
# provision.sh -- lay the arsenal onto an xos stick's p3.
#
# run AFTER `build.sh usb /dev/sdX` (flash) and `build.sh addstate /dev/sdX`
# (encrypted p3). this opens p3, mounts it, and copies in the layout: xexec,
# the arsenal, and optional wordlists/docs. idempotent -- re-run to update.
#
# needs root (cryptsetup + mount). points:
#   $1              the p3 partition, e.g. /dev/sdb3
#   XOS_ARSENAL     built tools dir      (default ~/.local/share/xos-arsenal)
#   XOS_WORDLISTS   optional staging dir -> ~/wordlists
#   XOS_DOCS        optional staging dir -> ~/docs
set -eu
. "$(cd "$(dirname "$0")" && pwd)/provision-lib.sh"
DEV="${1:-}"
SELF="$(cd "$(dirname "$0")" && pwd)"
ARSENAL="${XOS_ARSENAL:-$HOME/.local/share/xos-arsenal}"
MAP=xosprov
MNT=/run/xosprov

[ -n "$DEV" ] || { echo "usage: provision.sh /dev/sdX3   (the p3 partition)" >&2; exit 1; }
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
[ -b "$DEV" ] || { echo "not a block device: $DEV" >&2; exit 1; }
cryptsetup isLuks "$DEV" || { echo "$DEV is not LUKS -- is that p3?" >&2; exit 1; }

echo "provisioning arsenal onto $DEV"
cryptsetup open "$DEV" "$MAP"
cleanup() { umount "$MNT" 2>/dev/null || true; cryptsetup close "$MAP" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
mkdir -p "$MNT"; mount "/dev/mapper/$MAP" "$MNT"

populate "$MNT"   # defined below; the testable half
cleanup; trap - EXIT INT TERM
echo "done."

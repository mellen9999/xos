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
#   XOS_WORDLISTS   optional staging dir -> ~/wordlists (populate via
#                   arsenal/build-wordlists.sh)
#   XOS_DOCS        optional staging dir -> ~/docs (populate via
#                   arsenal/build-docs.sh)
set -eu
. "$(cd "$(dirname "$0")" && pwd)/provision-lib.sh"
DEV="${1:-}"
SELF="$(cd "$(dirname "$0")" && pwd)"
ARSENAL="${XOS_ARSENAL:-$HOME/.local/share/xos-arsenal}"
# per-run names: two provisions at once (two sticks, two terminals) must not
# share a device-mapper name or a mountpoint.
MAP=xosprov.$$
MNT=/run/xosprov.$$

[ -n "$DEV" ] || { echo "usage: provision.sh /dev/sdX3   (the p3 partition)" >&2; exit 1; }
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
[ -b "$DEV" ] || { echo "not a block device: $DEV" >&2; exit 1; }
cryptsetup isLuks "$DEV" || { echo "$DEV is not LUKS -- is that p3?" >&2; exit 1; }
# identity guard: addstate luksFormats p3 with label XOS-STATE (build.sh:4040).
# isLuks alone would happily open a typo'd device -- your own encrypted home,
# another stick -- and populate() would then overwrite it. require the label, so
# only an xos state volume is ever opened. fail-safe: a missing/unreadable label
# reads as empty and refuses; it can never wrongly ALLOW. XOS_PROVISION_ANYLUKS=1
# is the loud escape hatch for a legitimate p3 made before the label existed.
_lbl=$(cryptsetup luksDump "$DEV" 2>/dev/null | awk '/^Label:/{print $2; exit}')
if [ "$_lbl" != XOS-STATE ]; then
	if [ "${XOS_PROVISION_ANYLUKS:-}" = 1 ]; then
		echo "warning: $DEV label is '${_lbl:-none}', not XOS-STATE -- overriding on XOS_PROVISION_ANYLUKS=1" >&2
	else
		echo "$DEV is LUKS but not an xos p3 (label '${_lbl:-none}', want XOS-STATE) -- refusing to overwrite." >&2
		echo "if this really is your p3 (made before the label), re-run with XOS_PROVISION_ANYLUKS=1" >&2
		exit 1
	fi
fi

echo "provisioning arsenal onto $DEV"
cryptsetup open "$DEV" "$MAP"
cleanup() { umount "$MNT" 2>/dev/null || true; cryptsetup close "$MAP" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
mkdir -p "$MNT"; mount "/dev/mapper/$MAP" "$MNT"

populate "$MNT"   # defined below; the testable half
cleanup; trap - EXIT INT TERM
echo "done."

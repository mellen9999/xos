#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# self-healing pre-commit wall: the hook lives in githooks/, but core.hooksPath
# is per-clone local config a fresh `git clone` never receives -- so the wall
# that blocks committing keys and build artifacts would be silently absent for
# everyone but the author. arm it on every run; idempotent, and cheap.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  [ "$(git config --get core.hooksPath 2>/dev/null)" = githooks ] \
    || git config core.hooksPath githooks 2>/dev/null || true
fi

# pinned tarballs are immutable and digest-checked, so they are shared across
# every checkout and worktree instead of re-downloaded into each one. src/ then
# holds only EXTRACTED trees, which make writes into and so must stay per-tree:
# four sessions build at once. XOS_CACHE=src restores the old single-dir layout.
XOS_CACHE="${XOS_CACHE:-$HOME/.cache/xos/tarballs}"

KVER="${KVER:-6.18.49}"
BBVER="${BBVER:-1.38.0}"
IIVER="${IIVER:-2.0}"
BSSLVER="${BSSLVER:-0.6}"
ABDVER="${ABDVER:-0.6}"
# p3 needs cryptsetup, and cryptsetup needs four libraries. that takes this repo
# from four pinned upstreams to nine, which is the largest single increase in
# trust surface it has ever taken -- recorded in SOURCES.md rather than waved
# through. the kernel crypto backend (AF_ALG) is what avoids a fifth: no
# openssl, no gcrypt, no nettle.
CSVER="${CSVER:-2.8.7}"
LVMVER="${LVMVER:-2.03.42}"
POPTVER="${POPTVER:-1.19}"
JSONCVER="${JSONCVER:-0.19-20260627}"
UTLVER="${UTLVER:-2.42.2}"
# phase 4, remote access: wireguard userland + dropbear ssh. wireguard is in the
# kernel; wg only configures it. dropbear is the one listening service xos runs,
# and only ever on the wireguard interface.
WGTVER="${WGTVER:-1.0.20260223}"
DBVER="${DBVER:-2026.94}"
# maintainer key fingerprints for the six upstreams whose signed releases we
# match (see SOURCES.md for how these were established -- each cross-checked
# against at least two independent channels). the committed pubkeys in sigs/
# are convenience copies; a swapped pubkey cannot satisfy these pins.
DB_FPR=F7347EF2EE2E07A267628CA944931494F29C6773    # Matt Johnston (dropbear)
LVM_FPR=D501A478440AE2FD130A1BE8B9112431E509039F   # Marian Csontos (lvm2)
LNX_FPR=647F28654894E3BD457199BE38DBBDC86092693E   # Greg Kroah-Hartman (linux stable)
CS_FPR=2A2918243FDE46648D0686F9D9B0577BD93E98FC    # Milan Broz (cryptsetup)
UTL_FPR=B0C64D14301CC6EFAEDF60E4E4B71D5EEC39C284   # Karel Zak (util-linux)
BB_FPR=C9E9416F76E610DBD09D040F47B70C55ACC9965B    # Denys Vlasenko (busybox)
# popt has no signature; this sha512 is part of the fetch url (see fetch()).
POPT_SHA512=5d1b6a15337e4cd5991817c1957f97fc4ed98659870017c08f26f754e34add31d639d55ee77ca31f29bb631c0b53368c1893bd96cf76422d257f7997a11f6466
# one cflags line for every first-party and upstream userland build. the
# -ffile-prefix-map used to live only in cryptsetup_(), where a __FILE__ in an
# assert string had already leaked the absolute build path into the image; a
# fix applied at the one place a bug was seen is a fix waiting to be needed at
# the next. set once, inherited everywhere, so no consumer can drift.
XCF="-fPIE -Os -isystem $PWD/sysroot/include -ffile-prefix-map=$PWD=xos"
# the binaries that are not busybox applets. this used to be written out at
# every site that needed it, so adding one meant editing each and forgetting
# any of them failed confusingly. one list, read everywhere.
EXTRA_BINS="ii tlstunnel learn abduco cryptsetup wg dropbear dbclient dropbearkey"
# plaintext private keys live ONLY here, only while unlocked. /dev/shm is
# tmpfs, so nothing lands on disk. the path is scoped to THIS tree: /dev/shm is
# shared across every checkout and worktree a user has open, so a bare per-uid
# path let one tree's unlock silently satisfy another tree's.
RAMKEYS="/dev/shm/xos-keys-$(id -u)-$(printf %s "$PWD" | sha256sum | cut -c1-12)"
JOBS="$(nproc)"
# reproducibility needs the same modes and the same collation on every host:
# `cp` into root/ inherits the tree's modes (git creates files as 0666&~umask,
# and mksquashfs -all-root normalises owners, never modes), and every `sort`
# feeding a build input collates by locale. pin both; toolchain() fingerprints
# the umask so a mismatch here downgrades G13 to "unverified" instead of
# failing on an innocent cause.
umask 022
export LC_ALL=C
# 8 MiB. self-imposed -- the ESP is 64 MiB and the stick is whatever size you
# flashed. it is a budget, not a limit: every addition has to argue for itself
# against a number that does not move quietly. G1 measures xos.img; G19
# measures the whole bootable system (UKI + image) and is the binding one.
IMAGE_MAX=8388608
SALT=56524c000000000000000000000000000000000000000000000000000000000a
SBGUID=11111111-2222-3333-4444-555555555555
# the verity superblock carries a UUID that veritysetup randomises per format.
# it sits outside the hash tree so it changes no security property -- it just
# made every build produce different bytes, which is the property that lets
# anyone check the artifact against this source.
VUUID=00000000-0000-4000-8000-00000076726c
# fixed GPT identifiers so the stick is byte-deterministic AND so ONE signed
# cmdline (which names the root by PARTUUID, never by /dev/sdX) boots the same
# image whether it is p2 on a real usb stick or the whole disk under qemu.
GPT_DISK=56524c00-0000-4000-8000-000000000000
# the GPT type GUID for a LUKS partition. this used to be written as the gdisk
# shortcode 8309, which sfdisk does not accept -- it answered "Failed to add #3
# partition: Invalid argument" and addstate had therefore never once produced a
# p3 on any stick. sfdisk takes a GUID or its own alias, never gdisk's codes.
PT_LUKS=CA7D7CCB-63ED-4C53-861C-1742536059CC
PU_ESP=56524c00-0000-4001-8000-000000000001
PU_ROOT=56524c00-0000-4002-8000-000000000002
PU_STATE=56524c00-0000-4003-8000-000000000003
STICK_ESP_MIB=64
# the layout is FIXED, never derived from this build's image size. p2 used to be
# sized to xos.img exactly, so p3's start sector moved every time the image did,
# and `usb` wrote a two-partition GPT over the whole front of the device -- an
# update forgot p3 entirely even though it never touched one of its bytes. p2 is
# IMAGE_MAX now: the budget G1/G19 already enforce, spent as real sectors. p1 and
# p2 therefore occupy the same sectors in every version there will ever be, and
# p3 begins at a constant sector that a flash stops exactly short of.
ESP_START_S=2048                                 # 1 MiB, in 512-byte sectors
ROOT_START_S=$(( (1 + STICK_ESP_MIB) * 2048 ))   # 65 MiB
ROOT_SIZE_S=$(( IMAGE_MAX / 512 ))               # 8 MiB, whatever the image weighs
# 1 MiB of slack past p2 holds stick.img's own backup GPT, and doubles as the
# line a flash never writes past: p3 starts exactly where stick.img ends.
STATE_START_S=$(( ROOT_START_S + ROOT_SIZE_S + 2048 ))
# fixed build clock: the same commit must yield the same image, so the
# artifact can be checked against its source instead of trusted. this is also
# xos.epoch, the security floor init refuses to boot before -- so it is a
# PINNED LITERAL, never `date +%s`, and gets bumped + repinned periodically
# (G30 fails the build once it goes stale). 2026-09-06 00:00:00 UTC.
export SOURCE_DATE_EPOCH=1788652800
# busybox renders its banner timestamp in LOCAL time, so without a pinned TZ
# the same source builds differently in a different timezone.
export TZ=UTC
export KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" 2>/dev/null)"
export KBUILD_BUILD_USER=xos
export KBUILD_BUILD_HOST=xos

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

# grep -q exits the moment it matches, SIGPIPEs whatever is feeding it, and
# under `set -o pipefail` that reads as failure -- so a SUCCESSFUL match looks
# like a failed command. this trap bit five separate checks in this script.
# always pipe into `has` instead of `grep -q`.
has() { local n; n=$(grep -c -- "$1" || true); [ "${n:-0}" -gt 0 ]; }
# nothing on $1 may be mounted. lsblk failing is a refusal, not a pass.
# ────────────────────────────────────────────────────────────────────────────
# helpers -- shell traps, disk guards, and the one place each lives
# ────────────────────────────────────────────────────────────────────────────
unmounted() {
  local m
  m=$(lsblk -nro MOUNTPOINTS "$1" 2>/dev/null) \
    || { echo "FAIL: lsblk could not report mountpoints for $1 -- refusing to guess" >&2; return 1; }
  if printf '%s\n' "$m" | has .; then
    echo "FAIL: $1 (or a partition of it) is mounted -- unmount first" >&2; return 1; fi
}

# usb() and addstate() are the only code here that writes to a raw block device,
# and they used to carry these guards as near-identical copies -- a guard fixed
# in one and not the other is how a wrong disk gets wiped. one implementation,
# both callers, and G39 fails the build if either stops calling it.
disk_model() { # $1 device -> the model string, whitespace-squeezed
  cat "/sys/block/$(basename "$1")/device/model" 2>/dev/null | tr -s ' ' | sed 's/ *$//'
}

guard_removable() { # $1 device -- a whole, removable, unmounted disk or nothing
  local n; n=$(basename "$1")
  [ -e "/sys/block/$n" ] || { echo "FAIL: $1 is not a whole disk (partitions not allowed)" >&2; return 1; }
  [ "$(cat "/sys/block/$n/removable" 2>/dev/null)" = 1 ] \
    || { echo "FAIL: $1 is not removable -- refusing to touch a fixed disk" >&2; return 1; }
  unmounted "$1" || return 1
}

# confirmation the operator cannot bypass by hammering 'y': type the model back.
# the mount check runs AGAIN after it, because the prompt (and, in usb(), a full
# gate run before it) takes long enough for an automounter to grab the stick.
confirm_model() { # $1 device
  local model answer
  model=$(disk_model "$1")
  read -rp "  to confirm, type the disk model exactly ('${model:-unknown}'): " answer
  [ "$answer" = "${model:-unknown}" ] || { echo "FAIL: confirmation did not match -- aborted" >&2; return 1; }
  unmounted "$1" || return 1
}

# tail_parts -- the sfdisk entries for partitions 3.. on a disk, split by whether
# they begin at or past the BYTES a flash is about to write. "keep" entries lose
# nothing but their GPT record, so usb() saves them across the write and puts
# them back; "lose" entries would be overwritten, and usb() refuses rather than
# discover that afterwards. reads an image file as happily as a block device,
# which is what lets G43 run the real thing instead of a re-implementation.
tail_parts() { # $1 device or image  $2 bytes the flash writes  $3 keep|lose
  # a blank stick has no table to dump, and this file runs under `set -e -o
  # pipefail`: an unguarded sfdisk exit code here would abort the whole flash
  # on exactly the disk that has nothing to lose.
  { sfdisk -d "$1" 2>/dev/null || true; } | awk -v d="$1" -v s="$(( $2 / 512 ))" -v w="$3" '
    index($0, d) != 1 || !/start=/ { next }
    { n = substr($1, length(d) + 1); sub(/^p/, "", n)
      if (n + 0 < 3) next
      line = $0; sub(/^[^:]*:[ \t]*/, "", line)
      st = line; sub(/^.*start=[ \t]*/, "", st); sub(/[^0-9].*$/, "", st)
      if ((st + 0 >= s) == (w == "keep")) print line }'
}

# luks_at -- does a LUKS header start at this sector? cheap enough to point at
# one exact place, which is all that is wanted: the old flash orphaned p3 at a
# known offset, and writing a fresh partition over a live encrypted volume is
# the one mistake addstate must never make.
luks_at() { # $1 device or image  $2 sector
  [ "$( { dd if="$1" bs=512 skip="$2" count=1 status=none 2>/dev/null || true; } \
        | head -c 6 | od -An -tx1 | tr -d ' \n')" = "4c554b53babe" ]   # "LUKS" 0xbabe
}

# a missing host tool used to surface as a mid-build failure -- the exact fail
# mode this repo eliminates everywhere else. name every one up front instead.
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
# ────────────────────────────────────────────────────────────────────────────
# the host toolchain, and the pinned sources it is pointed at
# ────────────────────────────────────────────────────────────────────────────
deps() {
  say "checking host toolchain"
  local miss=() cmd
  # cmd:package pairs so the error names what to install (arch/paru)
  for cmd in gcc:gcc ld:binutils strip:binutils readelf:binutils make:make \
             curl:curl tar:tar python3:python openssl:openssl \
             mksquashfs:squashfs-tools unsquashfs:squashfs-tools \
             veritysetup:cryptsetup sbsign:sbsigntools sbverify:sbsigntools \
             ukify:systemd virt-fw-vars:python-virt-firmware \
             mcopy:mtools mmd:mtools mkfs.fat:dosfstools sfdisk:util-linux \
             wipefs:util-linux lsblk:util-linux qemu-system-x86_64:qemu-base \
             cmake:cmake flex:flex bison:bison bc:bc pkg-config:pkgconf \
             partprobe:parted strings:binutils objdump:binutils xz:xz; do
    command -v "${cmd%%:*}" >/dev/null 2>&1 || miss+=("${cmd%%:*} (${cmd##*:})")
  done
  # musl is linked into every binary but is NOT built from source here -- it is
  # host-provided. SOURCES.md records this honestly; the build must have it.
  [ -f /usr/lib/musl/lib/rcrt1.o ] || miss+=("/usr/lib/musl/lib/rcrt1.o (musl)")
  # the mounted-disk guard in usb()/addstate() reads this column; an lsblk
  # without it prints nothing and the guard would pass on a mounted stick.
  lsblk -nro MOUNTPOINTS >/dev/null 2>&1 \
    || miss+=("lsblk with MOUNTPOINTS column (util-linux >= 2.37)")
  [ -f "$STUB" ]      || miss+=("$STUB (systemd)")
  [ -f "$OVMF_CODE" ] || miss+=("$OVMF_CODE (edk2-ovmf)")
  [ -f "$OVMF_VARS" ] || miss+=("$OVMF_VARS (edk2-ovmf)")
  if [ "${#miss[@]}" -gt 0 ]; then
    echo "FAIL: missing host dependencies:" >&2
    printf '  - %s\n' "${miss[@]}" >&2
    return 1
  fi
  printf '  all host tools present\n'
}

# download, verify, extract ONE pinned tarball. verification is per-source and
# happens before extraction -- the old bulk `sha256sum -c` ran after only two of
# five sources had been downloaded, so on a clean clone it failed, and in a tree
# that already had src/ populated it passed. that is why nobody saw it.
# pull ONE url into $XOS_CACHE/$tar, or fail. split out of get() so the fallback
# below is a loop over urls rather than a second copy of the curl line.
# --retry-all-errors because the transient failures here are resets and TLS
# handshakes, which plain --retry does not count; --speed-limit turns a
# stalled mirror into a retry instead of a build that hangs until someone
# notices. a half-written tarball must not survive to be taken for a cached
# one: the [ -f ] in get() would skip re-fetching it, and the digest check
# would then blame the mirror for a truncation curl caused.
# retries are 2, not 5: with a fallback behind it, spending 110s proving one
# dead host is dead is 110s not spent on the host that is up.
pull() { # $1 url  $2 tarball
  curl -fL --progress-bar --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
      --retry 2 --retry-delay 2 --retry-all-errors "$1" -o "$XOS_CACHE/$2" \
    || { rm -f "$XOS_CACHE/$2"; return 1; }
}

get() {
  local url="$1" tar="$2" dir="$3"
  # one reset must not end a build that has already fetched gigabytes.
  #
  # WHY A FALLBACK IS SAFE HERE. every source is pinned by sha256 in
  # sources.sha256 and most also carry a committed maintainer signature, both
  # checked before anything is extracted. the url is therefore not the trust
  # anchor -- it only decides where the bytes arrive from. a mirror cannot make
  # a bad tarball acceptable; it can only make a good one reachable when
  # upstream is down. busybox.net was down for a whole afternoon on 2026-09-07
  # and took the build with it, five retries against the same dead host.
  #
  # the fallback is the wayback machine's raw-bytes view of the SAME url, not a
  # per-source mirror table, for the reason the ELF magic check below the
  # commit wall gives: a table is a list of the outages you have already had,
  # and would not have covered busybox.net the first time. `2999id_` asks for
  # the snapshot closest to year 2999 -- always the latest -- so it does not
  # rot the way a pinned year would, and id_ returns the stored bytes rather
  # than a rewritten page.
  if [ ! -f "$XOS_CACHE/$tar" ]; then
    pull "$url" "$tar" || {
      printf '  %s: %s unreachable -- trying the wayback machine\n' "$tar" "${url#*//}" >&2
      pull "https://web.archive.org/web/2999id_/$url" "$tar"
    } || {
      # wayback does not hold everything (abduco and LVM2 are not archived), so
      # say the part that is true of every source: any mirror will do, because
      # the digest and the signature are what decide. this is the sentence that
      # turns the next outage into a one-minute fix.
      echo "FAIL: could not fetch $tar from $url or the wayback machine" >&2
      printf '      the url is not the trust anchor here. fetch %s from ANY\n' "$tar" >&2
      printf '      mirror, drop it at %s, and rerun -- the pinned\n' "$XOS_CACHE/$tar" >&2
      printf '      digest %s\n' "$(grep " $tar$" sources.sha256 | cut -d' ' -f1)" >&2
      printf '      and the committed maintainer signature still decide.\n' >&2
      return 1
    }
  fi
  grep -q " $tar$" sources.sha256 || { echo "FAIL: $tar not pinned in sources.sha256" >&2; return 1; }
  local want have
  want=$(grep " $tar$" sources.sha256 | cut -d' ' -f1)
  have=$(sha256sum < "$XOS_CACHE/$tar" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$have" ] || {
    echo "FAIL: $tar digest mismatch -- refusing to extract" >&2; return 1; }
  [ -d "src/$dir" ] || tar -C src -xf "$XOS_CACHE/$tar"
}

# judge one gpg --status-fd stream against the pinned fingerprint.
#   0 good   2 valid, but the key has expired   3 the key is REVOKED   1 no match
# the fingerprint on its own is not enough. gpg prints VALIDSIG for an expired
# and for a revoked key just as happily as for a live one, so matching that line
# alone means a leaked maintainer key goes on verifying forever -- and expiry and
# revocation are the only two things that ever limit that damage. GOODSIG is the
# line that means good *now*. every pattern is anchored to the status prefix so a
# user id carrying the word GOODSIG cannot spoof a verdict.
sigok() { # $1 pinned fingerprint  [gpg status stream on stdin]
  local st; st=$(cat)
  if ! printf '%s\n' "$st" | has "VALIDSIG $1"; then return 1; fi
  if printf '%s\n' "$st" | has '^\[GNUPG:\] REVKEYSIG'; then return 3; fi
  if printf '%s\n' "$st" | has '^\[GNUPG:\] GOODSIG'; then return 0; fi
  if printf '%s\n' "$st" | has '^\[GNUPG:\] EXPKEYSIG'; then return 2; fi
  return 1
}

# verify one tarball against a COMMITTED detached signature and pubkey. the
# digest pin (G8) already stops later substitution; this anchors what the
# first sighting WAS to the maintainer's key instead of trust-on-first-use.
# gpg is host-optional: absence skips loudly, the digest pin still holds.
# $5=xz: kernel.org signs the UNCOMPRESSED tar (one .tar.sign covers .gz and
# .xz), so the tarball is decompressed into gpg's stdin. a truncated or
# corrupt .xz cannot pass: gpg sees a short stream and the signature fails.
# $6=expired-ok: this upstream signs releases with a key it let expire. the
# exception is per-source, printed on every build, and never covers revocation
# -- a revoked key means the private half is presumed stolen, which is the one
# case a fingerprint pin cannot save you from.
sigver() { # $1 tarball  $2 committed sig  $3 committed pubkey  $4 pinned fingerprint  [$5 xz]  [$6 expired-ok]
  command -v gpg >/dev/null 2>&1 || {
    printf '  %s: gpg not installed -- signature not checked (digest pin still enforced)\n' "$1"; return 0; }
  local gh st rc=0; gh=$(mktemp -d) || return 1
  gpg -q --homedir "$gh" --import "$3" 2>/dev/null
  if [ "${5:-}" = xz ]; then
    st=$( { xz -dc "$XOS_CACHE/$1" | gpg --homedir "$gh" --status-fd 1 --verify "$2" - 2>/dev/null; } || true)
  else
    st=$(gpg --homedir "$gh" --status-fd 1 --verify "$2" "$XOS_CACHE/$1" 2>/dev/null || true)
  fi
  rm -rf "$gh"
  printf '%s\n' "$st" | sigok "$4" || rc=$?
  case "$rc" in
    0) printf '  %s: maintainer signature verified (%s...)\n' "$1" "$(printf '%s' "$4" | cut -c1-16)" ;;
    2) local exp; exp=$(printf '%s\n' "$st" | sed -n 's/^\[GNUPG:\] KEYEXPIRED \([0-9]*\).*/\1/p' | head -1)
       [ -n "$exp" ] && exp=$(date -u -d "@$exp" +%Y-%m-%d 2>/dev/null) || exp="an unknown date"
       [ "${6:-}" = expired-ok ] || {
         echo "FAIL: $1 is signed by a key that expired on $exp" >&2
         echo "  the signature is the maintainer's, but an expired key stops limiting" >&2
         echo "  the damage of a leak. refresh sigs/ from upstream, or mark this source" >&2
         echo "  expired-ok in fetch() once you have decided that is acceptable." >&2
         return 1; }
       printf '  \033[1;33m%s: signed by a key that expired on %s -- accepted by an explicit\033[0m\n' "$1" "$exp"
       printf '  \033[1;33m  exception in fetch(); fingerprint and digest are still pinned\033[0m\n' ;;
    3) echo "FAIL: $1 is signed by a REVOKED key -- the private half is presumed stolen" >&2
       echo "  there is no exception for this. do not build against this tarball." >&2
       return 1 ;;
    *) echo "FAIL: $1 does not match the committed maintainer signature" >&2; return 1 ;;
  esac
}

fetch() {
  say "fetching + verifying sources"
  local here="$PWD"
  mkdir -p src "$XOS_CACHE"

  # G8 -- every source pinned, verified BEFORE extraction. a verified boot
  # chain rooted in an unverified tarball proves nothing.
  # kernel.org sources: the maintainer's detached signature over the tar,
  # matched against a fingerprint pinned above. a digest is only ever pinned
  # for a tarball whose signature verified first.
  get "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz" \
      "linux-$KVER.tar.xz" "linux-$KVER"
  sigver "linux-$KVER.tar.xz" "sigs/linux-$KVER.tar.sign" sigs/linux-release-key.asc "$LNX_FPR" xz
  get "https://busybox.net/downloads/busybox-$BBVER.tar.bz2" \
      "busybox-$BBVER.tar.bz2" "busybox-$BBVER"
  sigver "busybox-$BBVER.tar.bz2" "sigs/busybox-$BBVER.tar.bz2.sig" sigs/busybox-release-key.asc "$BB_FPR"
  # ii: suckless publishes no signature, so this pin is trust-on-first-use
  # over TLS only. see SOURCES.md -- it is weaker than the others on purpose.
  get "https://dl.suckless.org/tools/ii-$IIVER.tar.gz" \
      "ii-$IIVER.tar.gz" "ii-$IIVER"
  # abduco: brain-dump.org publishes no signature either -- see SOURCES.md.
  # 0.6 is from 2015 and has not needed a release since, which is the good kind
  # of stale: four C files that do one thing.
  get "https://www.brain-dump.org/projects/abduco/abduco-$ABDVER.tar.gz" \
      "abduco-$ABDVER.tar.gz" "abduco-$ABDVER"
  # cryptsetup and its four libraries. cryptsetup and util-linux are signed by
  # their maintainers (kernel.org hosting); popt and json-c are
  # trust-on-first-use. see SOURCES.md, which records which is which rather
  # than letting one digest look as authoritative as another.
  get "https://cdn.kernel.org/pub/linux/utils/cryptsetup/v${CSVER%.*}/cryptsetup-$CSVER.tar.xz" \
      "cryptsetup-$CSVER.tar.xz" "cryptsetup-$CSVER"
  sigver "cryptsetup-$CSVER.tar.xz" "sigs/cryptsetup-$CSVER.tar.sign" sigs/cryptsetup-release-key.asc "$CS_FPR" xz
  get "https://sourceware.org/pub/lvm2/LVM2.$LVMVER.tgz" \
      "LVM2.$LVMVER.tgz" "LVM2.$LVMVER"
  # lvm2 signs releases with a key it let expire on 2022-06-09 and has not
  # extended on any keyserver -- checked, not assumed. the fingerprint pin and
  # the digest pin both still apply; only the freshness of the key is waived.
  sigver "LVM2.$LVMVER.tgz" "sigs/LVM2.$LVMVER.tgz.asc" sigs/lvm2-release-key.asc "$LVM_FPR" "" expired-ok
  # popt: ftp.rpm.org is plain http (its tls certificate is for another
  # name). fedora's source cache carries the identical bytes over tls, at a
  # url that names their sha512 -- so the host cannot serve anything else there.
  get "https://src.fedoraproject.org/lookaside/pkgs/popt/popt-$POPTVER.tar.gz/sha512/$POPT_SHA512/popt-$POPTVER.tar.gz" \
      "popt-$POPTVER.tar.gz" "popt-$POPTVER"
  get "https://github.com/json-c/json-c/archive/refs/tags/json-c-$JSONCVER.tar.gz" \
      "json-c-$JSONCVER.tar.gz" "json-c-json-c-$JSONCVER"
  get "https://cdn.kernel.org/pub/linux/utils/util-linux/v${UTLVER%.*}/util-linux-$UTLVER.tar.xz" \
      "util-linux-$UTLVER.tar.xz" "util-linux-$UTLVER"
  sigver "util-linux-$UTLVER.tar.xz" "sigs/util-linux-$UTLVER.tar.sign" sigs/util-linux-release-key.asc "$UTL_FPR" xz
  # wireguard-tools: git.zx2c4.com publishes no per-release signature; the
  # github mirror tag is trust-on-first-use over TLS.
  get "https://github.com/WireGuard/wireguard-tools/archive/refs/tags/v$WGTVER.tar.gz" \
      "wireguard-tools-$WGTVER.tar.gz" "wireguard-tools-$WGTVER"
  # dropbear: the OFFICIAL release tarball, which is what the maintainer
  # signs -- the github tag tarball is a different artifact no signature
  # covers, and dropbear is the one listening service.
  get "https://matt.ucc.asn.au/dropbear/releases/dropbear-$DBVER.tar.bz2" \
      "dropbear-$DBVER.tar.bz2" "dropbear-$DBVER"
  sigver "dropbear-$DBVER.tar.bz2" "sigs/dropbear-$DBVER.tar.bz2.asc" sigs/dropbear-release-key.asc "$DB_FPR"
  # bearssl: also no upstream signature -- see SOURCES.md
  get "https://bearssl.org/bearssl-$BSSLVER.tar.gz" \
      "bearssl-$BSSLVER.tar.gz" "bearssl-$BSSLVER"

  # completeness: now that every source is present, re-check the whole pinned
  # set. this catches a tarball that is pinned but no longer fetched, which the
  # per-source checks above cannot see.
  ( cd "$XOS_CACHE" && grep -E '\.(tar\.(xz|bz2|gz)|tgz)$' "$here/sources.sha256" | sha256sum -c --strict - >/dev/null ) || {
    echo "FAIL: pinned source set does not match $XOS_CACHE" >&2; return 1; }
  printf '  %d sources verified against sources.sha256\n' \
    "$(grep -cE '\.(tar\.(xz|bz2|gz)|tgz)$' sources.sha256)"
}

# ────────────────────────────────────────────────────────────────────────────
# components -- each built from a pinned tarball, musl static-pie
# ────────────────────────────────────────────────────────────────────────────
kernel() {
  say "building kernel $KVER"
  local d="src/linux-$KVER"
  make -C "$d" tinyconfig
  # kernel.config now has two classes of line: `CONFIG_X=y` (must be on) and
  # `CONFIG_X=n` (must be off). split them -- feeding a `=n` line to --enable
  # would turn hardening-disable requests into enables.
  local enables disables
  # `=y\s*$`: a trailing space on a line used to drop that option from both
  # the enable pass AND the gate, silently. whitespace is not a config change.
  enables=$(grep -oP '^CONFIG_[A-Z0-9_]+(?==y\s*$)' kernel.config)
  disables=$(grep -oP '^CONFIG_[A-Z0-9_]+(?==n\s*$)' kernel.config)
  # olddefconfig silently drops any option whose deps are unmet, so enable to a
  # fixpoint (a parent enabled on pass N unlocks its children on pass N+1) and
  # then GATE on it -- a kernel quietly missing squashfs still "builds fine".
  # disables run each pass too: olddefconfig can re-select a choice default
  # (e.g. the lockdown FORCE_NONE member) that an earlier pass turned off.
  for _pass in 1 2 3; do
    while read -r opt; do
      [ -n "$opt" ] && "$d/scripts/config" --file "$d/.config" --enable "$opt"
    done <<< "$enables"
    while read -r opt; do
      [ -n "$opt" ] && "$d/scripts/config" --file "$d/.config" --disable "$opt"
    done <<< "$disables"
    make -C "$d" olddefconfig >/dev/null
  done
  local missing=() present=()
  while read -r opt; do
    [ -n "$opt" ] || continue
    grep -q "^$opt=y" "$d/.config" || missing+=("$opt")
  done <<< "$enables"
  # a `=n` opt that is present as =y is a hardening request that silently lost
  while read -r opt; do
    [ -n "$opt" ] || continue
    grep -q "^$opt=y" "$d/.config" && present+=("$opt")
  done <<< "$disables"
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "FAIL: kernel options requested but not enabled: ${missing[*]}" >&2
    return 1
  fi
  if [ "${#present[@]}" -gt 0 ]; then
    echo "FAIL: kernel options requested off but still enabled: ${present[*]}" >&2
    return 1
  fi
  grep -q '^CONFIG_MODULES=y' "$d/.config" && { echo "FAIL: module loader enabled" >&2; return 1; }
  echo 0 > "$d/.version"
  make -C "$d" -j"$JOBS" bzImage
  cp "$d/arch/x86/boot/bzImage" bzImage
  # bind the binary to the config it was built from. G14 checks .config, not
  # bzImage, so a kernel built days before kernel.config changed passed every
  # gate while failing the boot-time asserts -- the config said lockdown and
  # no-vsyscall, the running kernel disagreed, and nothing in the build noticed.
  # two digests: the expanded config (what was really compiled) and our source
  # kernel.config (the only one a gate can recompute without rebuilding).
  {
    sha256sum < "$d/.config"   | awk '{print "expanded " $1}'
    sha256sum < kernel.config  | awk '{print "source   " $1}'
  } > bzImage.config.sha256
}

bbset() {
  local d="$1" opt="$2" val="$3"
  sed -i "/^CONFIG_$opt=/d;/^# CONFIG_$opt is not set\$/d" "$d/.config"
  if [ "$val" = y ]; then
    echo "CONFIG_$opt=y" >> "$d/.config"
  else
    echo "# CONFIG_$opt is not set" >> "$d/.config"
  fi
}

headers() {
  say "installing kernel headers into sysroot"
  local d="src/linux-$KVER"
  rm -rf sysroot
  make -C "$d" headers_install INSTALL_HDR_PATH="$PWD/sysroot" >/dev/null
  printf '  sysroot/include: %s headers\n' "$(find sysroot/include -name '*.h' | wc -l)"
}

busybox() {
  say "building busybox $BBVER (${BBMODE:-trim})"
  [ -d sysroot/include/linux ] || headers
  local d="src/busybox-$BBVER"
  make -C "$d" defconfig >/dev/null

  # static-PIE: plain -static is an ASLR downgrade (fixed load address), so we
  # drive it through EXTRA flags instead of CONFIG_STATIC, which would inject a
  # conflicting -static. G3 verifies the result is ET_DYN.
  bbset "$d" STATIC n
  bbset "$d" PIE n
  for off in TC PAM FEATURE_WTMP FEATURE_UTMP; do bbset "$d" "$off" n; done
  sed -i '/^CONFIG_EXTRA_CFLAGS=/d;/^CONFIG_EXTRA_LDFLAGS=/d' "$d/.config"
  echo "CONFIG_EXTRA_CFLAGS=\"$XCF\"" >> "$d/.config"
  echo 'CONFIG_EXTRA_LDFLAGS=""' >> "$d/.config"

  if [ "${BBMODE:-trim}" = trim ]; then
    local all keep; all=$(mktemp)
    grep -o '^CONFIG_[A-Z0-9_]*=y' "$d/.config" | sed 's/^CONFIG_//;s/=y$//' > "$all"
    keep=$( { grep -v '^[[:space:]]*#' busybox.config.applets
              sed 's/#.*//' busybox.config.features
            } | tr ' ' '\n' | grep -v '^$' | tr 'a-z' 'A-Z' | sort -u)
    while read -r sym; do
      case "$sym" in
        STATIC|*FEATURE*|*PLATFORM*|*LFS*|DESKTOP|LONG_OPTS|SHOW_USAGE|*_PREFIX*|INSTALL_*|*_APPLET_*) continue ;;
      esac
      grep -qx "$sym" <<< "$keep" || bbset "$d" "$sym" n
    done < "$all"
    rm -f "$all"
  fi

  # keeping a symbol out of the trim list only means trim will not turn it OFF;
  # it says nothing about defconfig having it ON. assert it instead of hoping.
  local feat
  for feat in $(sed 's/#.*//' busybox.config.features); do bbset "$d" "$feat" y; done

  # `yes |` takes SIGPIPE when make exits; pipefail would turn that into exit 141
  # and silently abort before compiling. this bit us twice.
  yes '' | make -C "$d" oldconfig >/dev/null 2>&1 || true

  rm -f "$d/busybox"
  local specs="$PWD/musl-static-pie.specs"
  [ -f "$specs" ] || { echo "FAIL: $specs missing" >&2; return 1; }
  local cc="gcc -specs=$specs"
  make -C "$d" -j"$JOBS" CC="$cc" HOSTCC=gcc
  [ -f "$d/busybox" ] || { echo "busybox build failed" >&2; return 1; }
  strip "$d/busybox"
  cp "$d/busybox" busybox
  # form gates can pass on a binary that segfaults -- so prove it executes
  ./busybox true 2>/dev/null || { echo "FAIL: built busybox does not run" >&2; return 1; }
  # oldconfig can silently drop a symbol whose dependencies were trimmed away.
  # a feature that vanishes here is exactly the quiet shrink this repo exists to
  # catch, so read it back out of the config we just compiled.
  local missing=""
  for feat in $(sed 's/#.*//' busybox.config.features); do
    grep -qx "CONFIG_$feat=y" "$d/.config" || missing="$missing $feat"
  done
  [ -z "$missing" ] || { echo "FAIL: busybox dropped requested features:$missing" >&2; return 1; }
  printf '  busybox binary: %d bytes (musl static-pie, runs)\n' "$(stat -c%s busybox)"
}

ta() {
  say "compiling trust anchors"
  local d="src/bearssl-$BSSLVER"
  [ -x "$d/build/brssl" ] || { echo "FAIL: brssl missing, run tls first" >&2; return 1; }
  local pems; pems=$(find trust -name '*.pem' | sort)
  [ -n "$pems" ] || { echo "FAIL: trust/ is empty -- refusing to build a client that trusts nothing" >&2; return 1; }
  # shellcheck disable=SC2086
  "$d/build/brssl" ta $pems > ta.h || return 1
  local n; n=$(grep -oE 'TAs_NUM[[:space:]]+[0-9]+' ta.h | grep -oE '[0-9]+$')
  [ "${n:-0}" -gt 0 ] || { echo "FAIL: ta.h has no anchors" >&2; return 1; }
  printf '  %s trust anchor(s) compiled in:\n' "$n"
  local f; for f in $pems; do printf '    %s\n' "$(openssl x509 -in "$f" -noout -subject | sed 's/^subject=//')"; done
}

tls() {
  say "building bearssl + tlstunnel"
  local d="src/bearssl-$BSSLVER" specs="$PWD/musl-static-pie.specs"
  # from clean every time: make does not track CFLAGS, so a library left from
  # an earlier run would keep its old flags and nothing downstream could tell.
  make -C "$d" clean >/dev/null 2>&1
  make -C "$d" -j"$JOBS" CC="gcc -specs=$specs" CFLAGS="-W -Wall $XCF" \
      build/libbearssl.a build/brssl >/dev/null 2>&1
  [ -f "$d/build/libbearssl.a" ] && [ -x "$d/build/brssl" ] \
    || { echo "FAIL: bearssl did not build" >&2; return 1; }
  ta || return 1
  # shellcheck disable=SC2086
  gcc -specs="$specs" $XCF \
    -I"$d/inc" -I. -o tlstunnel tlstunnel.c "$d/build/libbearssl.a" || return 1
  { ./tlstunnel 2>&1 || true; } | has usage || { echo "FAIL: tlstunnel does not run" >&2; return 1; }
  printf '  tlstunnel: %d bytes\n' "$(stat -c%s tlstunnel)"
}

wg_() {
  say "building wireguard-tools (wg, musl static-pie)"
  local d="src/wireguard-tools-$WGTVER/src" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: wireguard-tools source missing, run fetch" >&2; return 1; }
  make -C "$d" clean >/dev/null 2>&1 || true
  # RUNSTATEDIR and the bundled uapi headers are normally added by the
  # makefile's own CFLAGS; supplying ours drops both, so put them back. the
  # bundled linux/wireguard.h goes FIRST: wg is written against the newest
  # netlink attributes and only sends the ones the operator's conf uses, so
  # it must see its own header, never an older one in the kernel sysroot.
  make -C "$d" CC="gcc -specs=$specs" \
    CFLAGS="-isystem $PWD/$d/uapi/linux $XCF -DRUNSTATEDIR='\"/run\"'" \
    LDFLAGS="" WITH_BASHCOMPLETION=no WITH_WGQUICK=no WITH_SYSTEMDUNITS=no wg >/dev/null 2>&1
  [ -f "$d/wg" ] || { echo "FAIL: wg did not build" >&2; return 1; }
  strip "$d/wg"; cp "$d/wg" wg
  { ./wg --version 2>&1 || true; } | has 'wireguard-tools' \
    || { echo "FAIL: built wg does not run" >&2; return 1; }
  printf '  wg: %d bytes\n' "$(stat -c%s wg)"
}

dropbear_() {
  say "building dropbear $DBVER (ssh, pubkey-only, musl static-pie)"
  local d="src/dropbear-$DBVER" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: dropbear source missing, run fetch" >&2; return 1; }
  [ -f dropbear.localoptions.h ] || { echo "FAIL: dropbear.localoptions.h missing" >&2; return 1; }
  # our hardening (no password auth, ed25519 only) as a tracked overlay, so the
  # security-relevant deltas from upstream defaults show up in a diff.
  cp dropbear.localoptions.h "$d/src/localoptions.h"
  # every knob the header sets must still be a knob upstream knows. a dropbear
  # bump that renames DROPBEAR_SVR_PASSWORD_AUTH would turn our #define into a
  # no-op and ship password auth on the one listening service -- green. the
  # busybox build reads its features back out of .config for the same reason.
  local knob unknown=""
  for knob in $(sed -n 's/^#define \(DROPBEAR_[A-Z0-9_]*\).*/\1/p' dropbear.localoptions.h); do
    grep -q "^#define $knob\b" "$d/src/default_options.h" || unknown="$unknown $knob"
  done
  [ -z "$unknown" ] || { echo "FAIL: dropbear.localoptions.h sets knobs upstream $DBVER no longer has:$unknown" >&2; return 1; }
  ( cd "$d" && ./configure --disable-zlib --disable-lastlog --disable-utmp \
      --disable-utmpx --disable-wtmp --disable-wtmpx --disable-pututline \
      --disable-pututxline \
      CC="gcc -specs=$specs" CFLAGS="$XCF" \
      >/dev/null 2>&1 ) || { echo "FAIL: dropbear configure failed" >&2; return 1; }
  # do NOT pass STATIC=1 -- it injects a plain -static that fights the specs
  # file's -static-pie and produces a fixed-load-address (ASLR-off) binary.
  # the artifact goes first: an existence check after a failed make otherwise
  # passes on whatever the previous run left behind.
  rm -f "$d/dropbearmulti"
  make -C "$d" PROGRAMS="dropbear dbclient dropbearkey" MULTI=1 >/dev/null 2>&1
  [ -f "$d/dropbearmulti" ] || { echo "FAIL: dropbear did not build" >&2; return 1; }
  strip "$d/dropbearmulti"; cp "$d/dropbearmulti" dropbearmulti
  { ./dropbearmulti dropbear -V 2>&1 || true; } | has 'Dropbear' \
    || { echo "FAIL: built dropbear does not run" >&2; return 1; }
  printf '  dropbearmulti: %d bytes\n' "$(stat -c%s dropbearmulti)"
}

cryptsetup_() {
  say "building cryptsetup $CSVER + its four libraries (musl static-pie)"
  local specs="$PWD/musl-static-pie.specs" root="$PWD"
  # XCF carries -ffile-prefix-map: json-c bakes __FILE__ into assert strings,
  # which put the absolute build path inside the shipped cryptsetup -- two
  # clean clones built different bytes and reproducibility quietly broke.
  local cc="gcc -specs=$specs" cf="$XCF"
  local dep="$root/src/cs-dep"
  rm -rf "$dep"; mkdir -p "$dep/lib" "$dep/include/json-c" "$dep/include/uuid"

  # pkg-config on the BUILD HOST will happily answer for the host's shared
  # libraries -- it pulled in -ludev and broke the static link. point it at an
  # empty directory so only what we built here can be found.
  mkdir -p "$dep/nopc"
  export PKG_CONFIG_LIBDIR="$dep/nopc" PKG_CONFIG_PATH="$dep/nopc"

  # libdevmapper: the dm ioctl wrapper. only the library is wanted -- lvm2's
  # own dmsetup tool wants libblkid and is not built.
  # every artifact is removed before its build: the existence checks below
  # must prove THIS run built it, not that some earlier run did.
  local d="src/LVM2.$LVMVER"
  rm -f "$d/libdm/ioctl/libdevmapper.a"
  ( cd "$d" && ./configure --enable-static_link --disable-selinux --disable-udev_sync \
      --disable-udev_rules --disable-readline --disable-nls --disable-shared \
      --with-cache=none --with-thin=none --with-vdo=none --with-writecache=none \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -C libdm >/dev/null 2>&1 ) || true
  [ -f "$d/libdm/ioctl/libdevmapper.a" ] || { echo "FAIL: libdevmapper did not build" >&2; return 1; }
  cp "$d/libdm/ioctl/libdevmapper.a" "$dep/lib/"
  cp "$d/libdm/libdevmapper.h" "$dep/include/"

  d="src/popt-$POPTVER"
  rm -f "$d/src/libpopt.la" "$d/src/.libs/libpopt.a"   # libtool: the .la is the target
  ( cd "$d" && ./configure --disable-shared --enable-static --disable-nls \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/src/.libs/libpopt.a" ] || { echo "FAIL: popt did not build" >&2; return 1; }
  cp "$d/src/.libs/libpopt.a" "$dep/lib/"; cp "$d/src/popt.h" "$dep/include/"

  d="src/json-c-json-c-$JSONCVER"
  rm -f "$d/b/libjson-c.a"
  ( cd "$d" && cmake -S . -B b -DCMAKE_C_COMPILER=gcc -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="-specs=$specs $cf" -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
      -DDISABLE_WERROR=ON -DBUILD_TESTING=OFF -DBUILD_APPS=OFF >/dev/null 2>&1 \
    && cmake --build b -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/b/libjson-c.a" ] || { echo "FAIL: json-c did not build" >&2; return 1; }
  cp "$d/b/libjson-c.a" "$dep/lib/"; cp "$d"/*.h "$d"/b/*.h "$dep/include/json-c/" 2>/dev/null

  d="src/util-linux-$UTLVER"
  rm -f "$d/libuuid.la" "$d/.libs/libuuid.a"
  ( cd "$d" && ./configure --disable-all-programs --enable-libuuid --disable-shared \
      --enable-static --without-systemd --without-udev --disable-nls --disable-asciidoc \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/.libs/libuuid.a" ] || { echo "FAIL: libuuid did not build" >&2; return 1; }
  cp "$d/.libs/libuuid.a" "$dep/lib/"; cp "$d/libuuid/src/uuid.h" "$dep/include/uuid/"

  d="src/cryptsetup-$CSVER"
  rm -f "$d/cryptsetup.static"
  ( cd "$d" && ./configure --disable-shared --enable-static --enable-static-cryptsetup \
      --with-crypto_backend=kernel --disable-ssh-token --disable-external-tokens \
      --disable-selinux --disable-nls --disable-blkid --disable-udev \
      --disable-veritysetup --disable-integritysetup --disable-asciidoc \
      --disable-hw-opal \
      CC="$cc" CFLAGS="$cf -I$dep/include" LDFLAGS="-L$dep/lib" \
      DEVMAPPER_CFLAGS="-I$dep/include" DEVMAPPER_LIBS="-L$dep/lib -ldevmapper" \
      JSON_C_CFLAGS="-I$dep/include/json-c" JSON_C_LIBS="-L$dep/lib -ljson-c" \
      UUID_CFLAGS="-I$dep/include" UUID_LIBS="-L$dep/lib -luuid" \
      POPT_LIBS="-L$dep/lib -lpopt" >/dev/null 2>&1 \
    && make -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/cryptsetup.static" ] || { echo "FAIL: cryptsetup did not build" >&2; return 1; }
  cp "$d/cryptsetup.static" cryptsetup; strip cryptsetup
  unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH

  # form gates pass on a binary that segfaults, and this one must also have the
  # KERNEL_CAPI backend -- an openssl-linked build would be a silent dependency.
  { ./cryptsetup --version 2>&1 || true; } | has 'KERNEL_CAPI' \
    || { echo "FAIL: cryptsetup missing or not using the kernel crypto backend" >&2; return 1; }
  printf '  cryptsetup: %d bytes\n' "$(stat -c%s cryptsetup)"
}

abduco() {
  say "building abduco $ABDVER (session detach, musl static-pie)"
  local d="src/abduco-$ABDVER" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: abduco source missing, run fetch" >&2; return 1; }
  # upstream defaults to running dvtm, which this system does not ship. the
  # override is a tracked file so the change shows up in a diff.
  [ -f abduco.config.h ] || { echo "FAIL: abduco.config.h missing" >&2; return 1; }
  cp abduco.config.h "$d/config.h"
  rm -f "$d/abduco"
  # -lutil for forkpty(). musl keeps forkpty in libc and ships an empty
  # libutil.a for compatibility, so this resolves and costs nothing.
  # shellcheck disable=SC2086
  gcc -specs="$specs" $XCF \
    -std=c99 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 \
    -DVERSION="\"$ABDVER\"" -DNDEBUG -I"$d" \
    -o abduco "$d/abduco.c" -lutil || return 1
  strip abduco
  # form gates pass on a binary that segfaults, so prove it executes
  { ./abduco 2>&1 || true; } | has 'Active sessions' \
    || { echo "FAIL: built abduco does not run" >&2; return 1; }
  printf '  abduco: %d bytes\n' "$(stat -c%s abduco)"
}

ii_() {
  say "building ii $IIVER (irc, musl static-pie)"
  local d="src/ii-$IIVER" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: ii source missing, run fetch" >&2; return 1; }
  make -C "$d" clean >/dev/null 2>&1 || true
  make -C "$d" CC="gcc -specs=$specs" \
    CFLAGS="$XCF" LDFLAGS="" >/dev/null 2>&1
  [ -f "$d/ii" ] || { echo "FAIL: ii did not build" >&2; return 1; }
  strip "$d/ii"; cp "$d/ii" ii
  # ii exits non-zero when printing usage, and pipefail would read that as a
  # build failure, so the producer is neutralised as well as the consumer.
  { ./ii 2>&1 || true; } | has usage || { echo "FAIL: built ii does not run" >&2; return 1; }
  printf '  ii: %d bytes\n' "$(stat -c%s ii)"
}

# ────────────────────────────────────────────────────────────────────────────
# the image -- root filesystem, verity tree, keys, signed UKI, stick
# ────────────────────────────────────────────────────────────────────────────
rootfs() {
  say "building read-only root"
  rm -rf root
  mkdir -p root/bin root/proc root/sys root/dev root/etc root/tmp
  cp busybox root/bin/
  # one binary, many names: busybox reads argv[0] to decide what to be.
  # names come from busybox itself, not our config list -- the two drift
  # (CONFIG_TEST1 is the applet named "["), and a missing applet makes
  # shell tests fail open rather than fail loud.
  local applets; applets=$(mktemp)
  ./busybox --list > "$applets" 2>/dev/null || {
    echo "FAIL: busybox --list unavailable (enable the busybox applet)" >&2; rm -f "$applets"; return 1; }
  [ -s "$applets" ] || { echo "FAIL: empty applet list" >&2; rm -f "$applets"; return 1; }
  while read -r a; do
    ln -sf busybox "root/bin/$a"
  done < "$applets"
  grep -qx '\[' "$applets" || { echo "FAIL: '[' applet missing -- shell tests would fail open" >&2; rm -f "$applets"; return 1; }
  rm -f "$applets"
  # every component is REQUIRED. these were `[ -f x ] && cp x` -- one missing
  # binary silently produced a smaller image that still passed every gate.
  # a build that ships less than it claims must fail, not shrink.
  local b
  for b in ii tlstunnel abduco cryptsetup wg; do
    [ -f "$b" ] || { echo "FAIL: $b not built -- run ./build.sh all" >&2; return 1; }
    cp "$b" "root/bin/$b"
  done
  # dropbear is a multi-call binary like busybox: one file, argv[0] chooses the
  # tool. the ssh server, client and keygen are three names for it.
  [ -f dropbearmulti ] || { echo "FAIL: dropbearmulti not built -- run ./build.sh all" >&2; return 1; }
  cp dropbearmulti root/bin/dropbearmulti
  local dbn
  for dbn in dropbear dbclient dropbearkey; do ln -sf dropbearmulti "root/bin/$dbn"; done

  # learn is this repo's own: an ash script over a plain-text corpus. on a
  # read-only root the filesystem IS the lookup table, so it needs no shell
  # data structures -- which is what lets the one shell be ash.
  [ -x learn/learn ] || { echo "FAIL: learn/learn missing or not executable" >&2; return 1; }
  local part
  for part in ref lib pools levels scenarios; do
    [ -d "learn/$part" ] || { echo "FAIL: learn/$part missing -- run ./build.sh seed" >&2; return 1; }
  done
  for _f in skip builtins phrases syntax vs chains; do
    [ -f "learn/$_f" ] || { echo "FAIL: learn/$_f missing" >&2; return 1; }
  done
  install -m 0755 learn/learn root/bin/learn
  mkdir -p root/usr/share/learn
  cp -r learn/ref learn/lib learn/pools learn/levels learn/scenarios root/usr/share/learn/
  cp learn/skip learn/builtins learn/phrases learn/chains learn/syntax learn/vs root/usr/share/learn/

  # overlay carries the udhcpc script, without which dhcp silently configures
  # nothing, and the wordlist init turns the roothash into four spoken words. it was optional; under `set -e` a
  # failing test in an && list does not abort, so a missing overlay just
  # produced a quieter, more broken image.
  [ -d overlay ] || { echo "FAIL: overlay/ missing" >&2; return 1; }
  cp -r overlay/. root/

  cp init root/init
  chmod +x root/init
  echo 'xos' > root/etc/hostname
  # without /etc/passwd, anything calling getpwuid() fails -- ii did exactly that
  # nobody: the uid learn drops to before it runs an answer. root is the only
  # human; this account owns nothing, logs in nowhere, and exists so that
  # plain file permissions -- not a denylist of command names -- are what
  # stand between a learner's typo and the encrypted state partition.
  printf 'root:x:0:0:root:/tmp/home:/bin/sh\nnobody:x:65534:65534:nobody:/:/bin/false\n' > root/etc/passwd
  printf 'root:x:0:\nnobody:x:65534:\n' > root/etc/group
  # ssh: the dir where a baked authorized_keys lives (verity-covered). empty by
  # default. set XOS_SSH_KEY=path/to/key.pub to bake a public key in here so
  # remote login works on first boot without any p3 -- baking it into the
  # verity-covered root means the key itself is attested, not just present.
  mkdir -p root/etc/dropbear
  if [ -n "${XOS_SSH_KEY:-}" ]; then
    [ -f "$XOS_SSH_KEY" ] || { echo "FAIL: XOS_SSH_KEY=$XOS_SSH_KEY not found" >&2; return 1; }
    install -m 0600 "$XOS_SSH_KEY" root/etc/dropbear/authorized_keys
    # init concatenates this with the p3 key file. a baked key with no final
    # newline fused with the first p3 line into one unparseable key -- and
    # rejected BOTH, locking the image key out. the newline is part of the key.
    sed -i -e '$a\' root/etc/dropbear/authorized_keys
    echo "  baked $XOS_SSH_KEY -> etc/dropbear/authorized_keys"
  fi
  # sourced by every interactive ash (via $ENV). vi editing on by default --
  # the shell has emacs keys too and there is no busybox option to remove them,
  # but nothing here ever leaves vi, so it is vi-only in practice.
  #
  # scrub: flash rots in a drawer, and verity only checks blocks it READS -- a
  # stick can be half-dead and boot fine until the mission needs the bad half.
  # reading every covered byte forces the check now: a rotten block panics the
  # machine on the spot (that is the alarm working), a clean pass means every
  # byte still matches the signed hash tree. a function, not a binary: the
  # command surface (and the learn corpus that must cover it) stays fixed.
  cat > root/etc/shrc <<'SHRC'
set -o vi
scrub() {
	echo "reading every verity-covered byte -- a rotten block panics the machine, and that is the alarm working"
	local d dev=""
	for d in /sys/block/dm-*; do
		[ "$(cat "$d/dm/name" 2>/dev/null)" = vroot ] && dev="/dev/${d##*/}" && break
	done
	if [ -n "$dev" ] && dd if="$dev" of=/dev/null bs=1M 2>/dev/null; then
		echo "scrub clean: every byte on this stick still matches the signed hash tree"
	else
		echo "scrub could not read the device (and no panic fired) -- reflash this stick"
	fi
}
# recon reports a changed machine on every boot until a human says this is
# the machine now. that is this: the reported inventory becomes the baseline.
recon_accept() {
	local f n=0
	for f in /tmp/home/recon/*.new; do
		[ -f "$f" ] || continue
		mv "$f" "${f%.new}" && sync && n=$((n + 1)) && echo "accepted: machine ${f##*/recon/} is the baseline now"
	done
	[ "$n" -gt 0 ] || echo "nothing to accept -- no machine is reported as changed"
}
SHRC
  # root is read-only, so resolv.conf must live on the tmpfs udhcpc writes to
  ln -sf /tmp/resolv.conf root/etc/resolv.conf
  # same reason: cryptsetup takes lock files under /run/cryptsetup and refuses
  # to touch a device without them. /run points into the tmpfs init creates.
  ln -sf /tmp/run root/run
  # squashfs-tools >= 4.6 reads SOURCE_DATE_EPOCH itself and clamps every
  # timestamp to it -- and hard-errors if you also pass -mkfs-time, which is
  # how this was caught. -processors 1 keeps block ordering deterministic.
  mksquashfs root rootfs.squashfs -noappend -no-xattrs -all-root -comp gzip -quiet -processors 1
  printf '  rootfs.squashfs: %d bytes (%d files)\n' "$(stat -c%s rootfs.squashfs)" "$(find root -type f -o -type l | wc -l)"
}

keys() {
  say "generating xos secure boot keys"
  # idempotent against BOTH states: plaintext keys/db.key (freshly generated)
  # and sealed keys/db.key.enc (seal deletes db.key, so checking only the
  # plaintext made `all` regenerate certs over a sealed key -- old key, new
  # cert, sbverify fails. this was silent because `all` never ran end to end.)
  { [ -f keys/db.key ] || [ -f keys/db.key.enc ]; } && { echo "  already present (delete keys/ to regenerate)"; return 0; }
  # born private: the directory is 0700 and the umask 077 BEFORE any key is
  # written. a chmod after the loop left three plaintext keys world-readable
  # for the length of three keygens.
  mkdir -p keys && chmod 700 keys || return 1
  ( umask 077
    for k in PK KEK db; do
      openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -subj "/CN=xos $k/" -keyout "keys/$k.key" -out "keys/$k.crt" 2>/dev/null || exit 1
      openssl x509 -in "keys/$k.crt" -outform DER -out "keys/$k.der" || exit 1
    done ) || { echo "FAIL: key generation failed" >&2; return 1; }
  echo "  PK/KEK/db written to keys/ (gitignored, xos-only -- never your host's)"
  # loud, because the quiet version of this costs a boot. keys/ is gitignored,
  # so a fresh clone AND every new git worktree starts without one and mints
  # its own here -- and an image signed by a keyset the firmware has never
  # heard of does not boot, with nothing in the build saying why.
  echo "  NOTE: this is a NEW keyset, not the one another clone or worktree holds."
  echo "        an image signed with it boots only on firmware enrolled to it."
  echo "        copy keys/ across first if you meant to sign with an existing one."
}

seal() {
  say "encrypting private keys"
  # fail loud rather than no-op: silently skipping an already-sealed keyset is
  # how you end up believing a new passphrase took effect when it did not.
  if [ ! -f keys/db.key ] && [ -f keys/db.key.enc ]; then
    echo "FAIL: keys are already sealed. use './build.sh reseal' to change the passphrase." >&2
    return 1
  fi
  [ -f keys/db.key ] || { echo "FAIL: no keys/db.key -- run ./build.sh keys first" >&2; return 1; }
  local pass
  if [ -n "${XOS_KEYPASS:-}" ]; then pass="$XOS_KEYPASS"
  else read -rsp "  passphrase for xos signing keys: " pass; echo; fi
  [ -n "$pass" ] || { echo "FAIL: empty passphrase" >&2; return 1; }
  local k
  for k in PK KEK db; do
    [ -f "keys/$k.key" ] || continue
    XOS_PASS="$pass" openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -in "keys/$k.key" -out "keys/$k.key.enc" -pass env:XOS_PASS || return 1
    shred -u "keys/$k.key" 2>/dev/null || rm -f "keys/$k.key"
  done
  chmod 600 keys/*.enc
  echo "  sealed. plaintext keys removed from disk."
}

reseal() {
  say "changing the signing passphrase"
  unlock || return 1
  local newpass
  if [ -n "${XOS_NEWKEYPASS:-}" ]; then newpass="$XOS_NEWKEYPASS"
  else read -rsp "  NEW passphrase: " newpass; echo; fi
  [ -n "$newpass" ] || { echo "FAIL: empty passphrase" >&2; return 1; }
  # every key is re-encrypted before any is swapped in: one passphrase opens
  # all three, so a failure after PK.key.enc had moved left a set no single
  # passphrase could unlock. the plaintext copies are wiped on every exit path.
  local k ok=0
  for k in PK KEK db; do
    [ -f "$RAMKEYS/$k.key" ] || continue
    XOS_PASS="$newpass" openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -in "$RAMKEYS/$k.key" -out "keys/$k.key.enc.new" -pass env:XOS_PASS && continue
    ok=1; break
  done
  if [ "$ok" -ne 0 ]; then
    rm -f keys/*.key.enc.new; lock
    echo "FAIL: re-encryption failed -- keys/ untouched, passphrase unchanged" >&2; return 1
  fi
  for k in PK KEK db; do
    [ -f "keys/$k.key.enc.new" ] && mv "keys/$k.key.enc.new" "keys/$k.key.enc"
  done
  chmod 600 keys/*.enc
  lock
  echo "  passphrase changed."
}

# the unlocked key must be the one keys/db.crt attests to. unlock() used to
# early-return on the mere EXISTENCE of $RAMKEYS/db.key, so a stale unlock from
# a different keyset was reused without ever being checked against this tree's
# certificate -- the build would then sign with one key and enroll another.
keymatch() {
  [ -f "$RAMKEYS/db.key" ] && [ -f keys/db.crt ] || return 1
  local a b
  a=$(openssl pkey -in "$RAMKEYS/db.key" -pubout 2>/dev/null) || return 1
  b=$(openssl x509 -in keys/db.crt -noout -pubkey 2>/dev/null) || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}

unlock() {
  keymatch && return 0
  # "nothing lands on disk" (top of file) only holds if tmpfs never spills to a
  # disk-backed swap. zram swap is compressed RAM -- still never disk -- but a
  # swap partition or file could page a decrypted key out. refuse by default so
  # the guarantee is enforced, not assumed; XOS_ALLOW_SWAP=1 is the escape hatch.
  local badswap
  badswap=$(sed '1d' /proc/swaps 2>/dev/null | awk '$1 !~ /^\/dev\/zram/ {print $1}' | tr '\n' ' ')
  if [ -n "${badswap# }" ] && [ "${XOS_ALLOW_SWAP:-0}" != 1 ]; then
    echo "FAIL: disk-backed swap active ($badswap) -- an unlocked key could be paged to disk." >&2
    echo "      'sudo swapoff $badswap' first, or set XOS_ALLOW_SWAP=1 to accept the risk." >&2
    return 1
  fi
  # present but not ours: wipe it rather than sign with it.
  [ -f "$RAMKEYS/db.key" ] && { echo "  cached key does not match keys/db.crt -- re-unlocking"; rm -rf "$RAMKEYS"; }
  [ -f keys/db.key.enc ] || { echo "FAIL: keys/db.key.enc missing -- run ./build.sh keys then seal" >&2; return 1; }
  local pass
  if [ -n "${XOS_KEYPASS:-}" ]; then pass="$XOS_KEYPASS"
  else read -rsp "  passphrase to unlock signing keys: " pass; echo; fi
  mkdir -p "$RAMKEYS"; chmod 700 "$RAMKEYS"
  local k
  for k in PK KEK db; do
    [ -f "keys/$k.key.enc" ] || continue
    XOS_PASS="$pass" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
      -in "keys/$k.key.enc" -out "$RAMKEYS/$k.key" -pass env:XOS_PASS 2>/dev/null \
      || { rm -rf "$RAMKEYS"; echo "FAIL: wrong passphrase" >&2; return 1; }
  done
  chmod 600 "$RAMKEYS"/*.key
  openssl rsa -in "$RAMKEYS/db.key" -noout 2>/dev/null \
    || { rm -rf "$RAMKEYS"; echo "FAIL: decrypted key is not a valid RSA key" >&2; return 1; }
  keymatch \
    || { rm -rf "$RAMKEYS"; echo "FAIL: unlocked db.key does not match keys/db.crt" >&2; return 1; }
  echo "  unlocked into RAM ($RAMKEYS)"
}

ramkeys() { echo "$RAMKEYS"; }

lock() {
  rm -rf "$RAMKEYS"
  echo "  locked -- plaintext keys wiped from RAM"
}

uki() {
  say "building + signing unified kernel image"
  [ -f cmdline.txt ] || { echo "FAIL: run verity first" >&2; return 1; }
  local stub="$STUB"
  [ -f "$stub" ] || { echo "FAIL: systemd-stub missing" >&2; return 1; }
  grep -q '^CONFIG_EFI_STUB=y' "src/linux-$KVER/.config" || {
    echo "FAIL: kernel lacks EFI_STUB -- firmware cannot load it" >&2; return 1; }

  unlock || return 1
  ukify build --linux=bzImage --cmdline="$(cat cmdline.txt)" --stub="$stub" --output=xos.efi >/dev/null
  sbsign --key "$RAMKEYS/db.key" --cert keys/db.crt --output xos-signed.efi xos.efi >/dev/null \
    || { echo "FAIL: signing failed -- refusing to ship an unsigned image" >&2; rm -f xos-signed.efi; return 1; }
  [ -f xos-signed.efi ] || { echo "FAIL: no signed image produced" >&2; return 1; }
  sbverify --cert keys/db.crt xos-signed.efi >/dev/null 2>&1 || {
    echo "FAIL: signature does not verify" >&2; return 1; }

  mkdir -p esp/EFI/BOOT
  cp xos-signed.efi esp/EFI/BOOT/BOOTX64.EFI

  cp "$OVMF_VARS" ovmf-vars.fd
  # errors here used to go to /dev/null with no status check: enrollment could
  # fail and leave a firmware with NO keys, which does not enforce secure boot
  # at all -- and the build still said it was done.
  virt-fw-vars --input ovmf-vars.fd --output ovmf-vars.fd \
    --set-pk  "$SBGUID" keys/PK.der \
    --add-kek "$SBGUID" keys/KEK.der \
    --add-db  "$SBGUID" keys/db.der >/dev/null 2>&1 \
    || { echo "FAIL: could not enroll keys into ovmf-vars.fd" >&2; return 1; }
  printf '  signed UKI: %d bytes, keys enrolled into ovmf-vars.fd\n' "$(stat -c%s xos-signed.efi)"
  dbx || return 1
}

# a signature says who signed it, never when. an image signed a year ago
# verifies exactly as well as today's, so an attacker who can write the ESP --
# which is plain FAT, by design, because something has to boot -- can put back
# a superseded image with its old kernel and old bugs. dbx is the one link in
# the chain that can refuse it.
dbx() {
  [ -f ovmf-vars.fd ] || { echo "FAIL: no ovmf-vars.fd -- run ./build.sh uki first" >&2; return 1; }
  [ -f revoked ] || { echo "FAIL: revoked missing -- it is tracked; do not delete it" >&2; return 1; }
  local args=() h n=0
  # `|| [ -n "$h" ]`: read returns nonzero on a final line with no newline,
  # and a hand-edited file ending that way would drop exactly one revocation.
  while read -r h rest || [ -n "$h" ]; do
    case "$h" in ''|'#'*) continue ;; esac
    # a malformed line must stop the build. skipping it would silently drop a
    # revocation, and nothing downstream can tell that apart from success.
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] \
      || { echo "FAIL: revoked: not a sha256 hash: $h" >&2; return 1; }
    args+=(--add-dbx-hash "$SBGUID" "$h"); n=$((n+1))
  done < revoked
  if [ "$n" -eq 0 ]; then
    echo "  dbx: nothing revoked yet"
    return 0
  fi
  virt-fw-vars --input ovmf-vars.fd --output ovmf-vars.fd "${args[@]}" >/dev/null 2>&1 \
    || { echo "FAIL: could not enroll dbx into ovmf-vars.fd" >&2; return 1; }

  # ovmf-vars.fd is the QEMU varstore and nothing else. for years that was the
  # only thing revoke() produced, so a revocation held in the test rig and did
  # nothing whatsoever on real hardware -- the one machine it needed to hold on.
  # write the enrollable form too, beside the PK/KEK/db the operator already
  # enrolls from the stick.
  #
  # this .auth carries no KEK signature, so it is accepted in SETUP MODE only --
  # which is exactly the documented order: clear the keys, enroll dbx, db and
  # KEK, and PK last, because enrolling PK is what turns enforcement on. adding
  # a revocation to a machine already in user mode means re-enrolling, and the
  # README says so rather than pretending otherwise.
  rm -rf dbxauth && mkdir -p dbxauth
  virt-fw-vars --input ovmf-vars.fd --output-auth dbxauth >/dev/null 2>&1 \
    && [ -s dbxauth/dbx.auth ] \
    || { echo "FAIL: could not write an enrollable dbx.auth" >&2; return 1; }
  printf '  dbx: %d image(s) revoked -- qemu varstore + dbxauth/dbx.auth (%d bytes)\n' \
    "$n" "$(stat -c%s dbxauth/dbx.auth)"
}

revoke() {
  local img="${1:-}"
  [ -n "$img" ] && [ -f "$img" ] || { echo "usage: ./build.sh revoke IMAGE.efi" >&2; return 1; }
  local h; h=$(python3 pehash.py --verify "$img") \
    || { echo "FAIL: refusing to revoke an image whose digest we cannot confirm" >&2; return 1; }
  if [ "$(grep -c "^$h" revoked || true)" != 0 ]; then
    echo "  already revoked: $h"; return 0
  fi
  # revoking the image you are about to ship bricks the next boot. G14 catches
  # it at build time, but say it here too, while it is still one line to undo.
  if [ -f xos-signed.efi ] && [ "$h" = "$(python3 pehash.py xos-signed.efi)" ]; then
    echo "FAIL: that is the CURRENT signed image -- revoking it would refuse your own boot" >&2
    return 1
  fi
  printf '%s  %s\n' "$h" "revoked $(date -u +%Y-%m-%d) -- $(basename "$img")" >> revoked
  echo "  revoked $h"
  echo "  run ./build.sh uki to re-enroll dbx"
}

# assemble the bootable stick image: GPT (fixed GUIDs) + FAT32 ESP carrying the
# signed UKI and the public keys for enrollment + raw xos.img as p2. entirely
# deterministic (no root, no loop mount -- sfdisk + mtools), so the layout is
# reproducible even though we do not pin it: everything that MATTERS on the stick
# is already covered (p2 by image.sha256 + the verity tree, BOOTX64.EFI by the db
# signature). only FAT/GPT metadata is unauthenticated, and tampering it can at
# most deny boot, never change what runs.
stick() {
  say "assembling stick.img"
  [ -f xos-signed.efi ] || { echo "FAIL: no signed UKI -- run ./build.sh uki" >&2; return 1; }
  [ -f xos.img ]        || { echo "FAIL: no xos.img -- run ./build.sh verity" >&2; return 1; }
  for k in PK KEK db; do [ -f "keys/$k.der" ] || { echo "FAIL: keys/$k.der missing" >&2; return 1; }; done

  local esp_bytes root_bytes esp_size_s total
  esp_bytes=$((STICK_ESP_MIB * 1024 * 1024))
  root_bytes=$(stat -c%s xos.img)                 # already a 4K multiple (verity padded it)
  esp_size_s=$((esp_bytes / 512))
  # p2 is IMAGE_MAX, not this image's size -- see the layout constants. G1 and
  # G19 keep the image under that number, but a partition silently too small for
  # its own contents is not a thing this should be able to ship.
  [ "$root_bytes" -le "$IMAGE_MAX" ] \
    || { echo "FAIL: xos.img is $root_bytes bytes -- p2 is $IMAGE_MAX and cannot hold it" >&2; return 1; }
  total=$(( STATE_START_S * 512 ))                # stops exactly where p3 starts

  rm -f stick.img
  truncate -s "$total" stick.img

  # deterministic GPT: fixed disk id + per-partition uuids/types/names, no
  # timestamps in GPT (only CRCs), so identical inputs -> identical bytes.
  # named fields + sizes in SECTORS -- sfdisk rejects a bare 'B' byte suffix.
  sfdisk stick.img >/dev/null <<EOF
label: gpt
label-id: $GPT_DISK
start=$ESP_START_S, size=$esp_size_s, type=C12A7328-F81F-11D2-BA4B-00A08693446B, uuid=$PU_ESP, name="XOS-ESP"
start=$ROOT_START_S, size=$ROOT_SIZE_S, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$PU_ROOT, name="XOS-ROOT"
EOF

  # FAT32 in a temp file, then dd into the ESP slot. --invariant drops the
  # volume id + creation timestamp that would otherwise randomise the bytes.
  rm -f esp.part; truncate -s "$esp_bytes" esp.part
  mkfs.fat --invariant -F 32 -n XOS esp.part >/dev/null
  # pin mtime of everything we copy so mcopy writes deterministic dir entries
  touch -d "@$SOURCE_DATE_EPOCH" xos-signed.efi keys/PK.der keys/KEK.der keys/db.der
  mmd   -i esp.part ::/EFI ::/EFI/BOOT ::/xos-keys
  mcopy -pm -i esp.part xos-signed.efi ::/EFI/BOOT/BOOTX64.EFI
  mcopy -pm -i esp.part keys/PK.der keys/KEK.der keys/db.der ::/xos-keys/
  # the revocation list, in the form firmware can actually take. without this
  # `revoke` only ever reached the qemu varstore. safe on the unauthenticated
  # ESP: firmware validates it, and in setup mode it is the operator who
  # decides to enroll it at all.
  if [ -s dbxauth/dbx.auth ]; then
    touch -d "@$SOURCE_DATE_EPOCH" dbxauth/dbx.auth
    mcopy -pm -i esp.part dbxauth/dbx.auth ::/xos-keys/
  fi
  dd if=esp.part    of=stick.img bs=1M seek=1                     conv=notrunc status=none
  dd if=xos.img  of=stick.img bs=1M seek=$((1 + STICK_ESP_MIB)) conv=notrunc status=none
  rm -f esp.part
  printf '  stick.img: %d bytes (esp %d MiB + p2 %d fixed, holding %d) -- p3 starts at sector %d\n' \
    "$(stat -c%s stick.img)" "$STICK_ESP_MIB" "$IMAGE_MAX" "$root_bytes" "$STATE_START_S"
}

# write stick.img to a real removable disk. this is dd-to-wrong-disk territory,
# so every guard is fail-closed and there is deliberately NO --force flag.
usb() {
  local dev="${1:-}"
  [ -n "$dev" ] || { echo "FAIL: usage: ./build.sh usb /dev/sdX" >&2; return 1; }
  [ -b "$dev" ] || { echo "FAIL: $dev is not a block device" >&2; return 1; }
  local n; n=$(basename "$dev")
  guard_removable "$dev" || return 1
  [ -f stick.img ] || stick || return 1
  # the gates, every time. a stick.img left behind by a gate-FAILED `all` (stick
  # runs before the gates) used to flash straight through here; the only check on
  # this path was a readback against a pin that the same failed run had
  # regenerated. gates are stateless and cheap next to a wrong stick in the field.
  gates || { echo "FAIL: gates failed -- not writing $dev" >&2; return 1; }

  local dev_bytes img_bytes model
  dev_bytes=$(( $(cat "/sys/block/$n/size") * 512 ))
  img_bytes=$(stat -c%s stick.img)
  [ "$dev_bytes" -ge "$img_bytes" ] || { echo "FAIL: $dev too small ($dev_bytes < $img_bytes)" >&2; return 1; }
  if [ "$dev_bytes" -gt $((128 * 1024 * 1024 * 1024)) ]; then
    echo "WARN: $dev is $((dev_bytes / 1024 / 1024 / 1024)) GiB -- larger than any usb stick, is this the right disk?" >&2
  fi
  # a flash writes only the first $img_bytes of the device, so a partition
  # living past that keeps every byte -- but the fresh GPT that lands on top of
  # it describes two partitions, and p3's ENTRY is gone. that is how updating a
  # stick used to be a factory reset. save those entries now and put them back
  # after the write. everything out there is preserved, not just ours: flashing
  # has no business orphaning a partition it never writes to.
  local keep_tail lose_tail
  keep_tail=$(tail_parts "$dev" "$img_bytes" keep)
  lose_tail=$(tail_parts "$dev" "$img_bytes" lose)
  # an xos state partition INSIDE that region is the old layout, where p3 began
  # right after p2. writing this image would go straight through it, so stop --
  # a stranger's partitions on a stick being deliberately flashed are a
  # different matter, and the wipefs warning below already covers those.
  if printf '%s\n' "$lose_tail" | grep -qi "$PU_STATE"; then
    echo "FAIL: $dev has an xos state partition inside the region this image writes:" >&2
    printf '    %s\n' "$lose_tail" >&2
    echo "  it was placed by the old layout, which put p3 directly after p2; flashing" >&2
    echo "  would write over it. copy what you need off it, delete that partition" >&2
    echo "  deliberately, then flash again -- addstate now places p3 past the image," >&2
    echo "  where an update cannot reach it." >&2
    return 1
  fi

  model=$(disk_model "$dev")
  echo "  target: $dev  size: $((dev_bytes / 1024 / 1024)) MiB  model: ${model:-unknown}"
  [ -z "$keep_tail" ] || echo "  keeping $(printf '%s\n' "$keep_tail" | grep -c .) partition(s) past the image -- encrypted state survives this write"
  [ -z "$lose_tail" ] || echo "  WARNING: $(printf '%s\n' "$lose_tail" | grep -c .) partition(s) sit inside the image region and WILL be destroyed."
  if wipefs -n "$dev" 2>/dev/null | has .; then
    echo "  WARNING: $dev already contains a filesystem/partition signature -- it will be DESTROYED."
  fi
  confirm_model "$dev" || return 1
  say "writing stick.img to $dev"
  dd if=stick.img of="$dev" bs=1M oflag=direct conv=fsync status=progress

  # verify by DIRECT-IO readback -- a page-cache read would just echo what we
  # wrote and prove nothing. compare the whole stick, then the p2 root region
  # against the pinned image digest.
  say "verifying written bytes"
  local want_stick have_stick want_root have_root
  want_stick=$(sha256sum < stick.img | awk '{print $1}')
  have_stick=$(dd if="$dev" bs=1M iflag=direct,count_bytes count="$img_bytes" status=none | sha256sum | awk '{print $1}')
  [ "$want_stick" = "$have_stick" ] || { echo "FAIL: stick readback mismatch -- write did not land" >&2; return 1; }
  want_root=$(awk '$1=="image"{print $2}' image.sha256)
  [ -n "$want_root" ] || { echo "FAIL: image.sha256 carries no image digest -- run ./build.sh pin" >&2; return 1; }
  have_root=$(dd if="$dev" bs=1M skip=$((1 + STICK_ESP_MIB)) iflag=direct,count_bytes count="$(stat -c%s xos.img)" status=none | sha256sum | awk '{print $1}')
  [ "$want_root" = "$have_root" ] \
    || { echo "FAIL: root partition on disk does not match pinned image digest" >&2; return 1; }
  # stick.img is 74 MiB; the stick is not. dd copies the GPT verbatim, so the
  # backup header and the "last usable LBA" still describe the IMAGE, and every
  # sector past it reads as unpartitionable: sfdisk -F reported 0 B free on a
  # 16 GB stick and addstate could not place p3 at all. move the backup header
  # to the real end of the device so the rest of the stick becomes usable.
  # deliberately AFTER the readback above, which compares against stick.img
  # byte for byte -- this is the one edit that intentionally diverges from it,
  # and it touches only GPT metadata, which no signature covers.
  sfdisk --relocate gpt-bak-std "$dev" >/dev/null 2>&1 \
    || echo "WARN: could not move the backup GPT to the end of $dev -- addstate may find no free space" >&2

  # and put the saved entries back. their sectors were never written, so the
  # data is untouched -- only the table forgot them. this is a hard failure, not
  # a warning: the image boots either way, and an operator who walks away
  # believing the update kept their state is the whole bug.
  if [ -n "$keep_tail" ]; then
    printf '%s\n' "$keep_tail" | sfdisk --no-reread -a "$dev" >/dev/null 2>&1 || true
    # --no-reread, so tell the kernel yourself -- otherwise ${dev}3 does not
    # come back as a node and install() offers to create the p3 that is already
    # sitting there.
    partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" 2>/dev/null || true
    if [ "$(tail_parts "$dev" "$img_bytes" keep)" = "$keep_tail" ]; then
      say "state partition preserved across the update"
    else
      echo "FAIL: the image is written and boots, and p3's DATA is intact -- but its" >&2
      echo "  partition entry did not come back. re-add it by hand, exactly:" >&2
      printf '    sfdisk --no-reread -a %s <<EOF\n%s\nEOF\n' "$dev" "$keep_tail" >&2
      return 1
    fi
  fi
  sync
  printf '\n  \033[1;32mdone -- %s carries a verified xos\033[0m\n' "$dev"
  echo "  boot it: firmware boot menu -> USB. secure boot: enroll keys from the"
  echo "  stick's /xos-keys (db, KEK, then PK last). see README."
}

verity() {
  say "building verity hash tree"
  cp rootfs.squashfs xos.img
  local data blocks
  data=$(stat -c%s xos.img)
  if [ $((data % 4096)) -ne 0 ]; then
    data=$(( (data / 4096 + 1) * 4096 ))
    truncate -s "$data" xos.img
  fi
  blocks=$((data / 4096))

  # fixed salt AND fixed uuid: the image must be reproducible. a random salt
  # would change the root hash for identical content; a random uuid left the
  # root hash stable and still changed the image bytes on every single build.
  veritysetup format xos.img xos.img \
    --hash-offset="$data" --data-blocks="$blocks" --salt="$SALT" --uuid="$VUUID" > verity.info
  local rh
  rh=$(awk '/Root hash/{print $NF}' verity.info)
  [ ${#rh} -eq 64 ] || { echo "FAIL: no root hash from veritysetup" >&2; return 1; }
  echo "$rh" > verity.roothash

  # veritysetup writes a superblock AT the hash offset, so the hash tree
  # itself starts one block later -- pointing the table at $blocks lands on
  # the superblock and the root mount fails with no verity error at all.
  # xos.test is DEBUG scaffolding, and the cmdline lives INSIDE the UKI
  # signature -- so it must never ship in a production image. selftest.sh
  # rebuilds a test-flavoured UKI for its own runs.
  local testflag=""
  [ "${XOS_TEST:-0}" = 1 ] && testflag=" xos.test xos.teststate xos.testwg"
  # the root is named by PARTUUID, not /dev/vda: on a real machine the stick is
  # /dev/sda|sdb, and dm-init resolves PARTUUID= via early_lookup_bdev. one
  # cmdline, inside one signature, boots qemu and metal alike.
  #
  # dm-mod.waitfor polls (5ms) until the device exists -- usb enumeration takes
  # a second or two, and without this dm-init tries exactly once and the root
  # never appears (a silent hang rootwait cannot fix). there is NO timeout knob
  # in the kernel: an unsupported controller hangs at "waiting for device", visibly.
  #
  # console: serial LAST so it owns /dev/console (harness scrapes serial, output
  # stays byte-identical); tty0 first mirrors printk to a real screen.
  #
  # default dm-verity refuses only the bad block and lets boot continue if
  # nothing essential needed it. panic_on_corruption makes ANY corruption
  # anywhere fatal -- the machine refuses to run at all, which is the point.
  #
  # random.trust_cpu=1: nothing persists here, so the entropy pool starts empty
  # on every boot with no seed file to carry across. the kernel already defaults this
  # to true and dropped the Kconfig symbol, so pinning it on the signed cmdline
  # is how it stays true across a kernel bump. the kernel always MIXES rdrand
  # rather than using it alone -- a backdoored instruction cannot dictate the
  # output, only fail to contribute.
  #
  # oops=panic + panic=-1: any oops becomes a fatal, non-recoverable halt (no
  # boot-and-limp). page_alloc.shuffle=1 activates SHUFFLE_PAGE_ALLOCATOR. the
  # rest of the hardening is compiled in (lockdown, kstack offset, slab), which
  # is stronger than a cmdline flag -- there is no runtime knob left to flip.
  local dev="PARTUUID=$PU_ROOT"
  printf 'dm-mod.waitfor=%s dm-mod.create="vroot,,,ro,0 %d verity 1 %s %s 4096 4096 %d %d sha256 %s %s 1 panic_on_corruption" root=/dev/dm-0 ro rootfstype=squashfs rootwait init=/init oops=panic panic=-1 page_alloc.shuffle=1 random.trust_cpu=1 xos.epoch=%s console=tty0 console=ttyS0,115200%s\n' \
    "$dev" "$((blocks * 8))" "$dev" "$dev" "$blocks" "$((blocks + 1))" "$rh" "$SALT" "$SOURCE_DATE_EPOCH" "$testflag" > cmdline.txt

  printf '  xos.img: %d bytes  root hash: %s
' "$(stat -c%s xos.img)" "$rh"
}

toolchain() {
  { gcc --version | head -1
    ld --version | head -1
    mksquashfs -version 2>&1 | head -1
    veritysetup --version
    sha256sum musl-static-pie.specs | awk '{print $1}'
    # the EFI stub is not built here -- it comes from the host's systemd and
    # is then wrapped in the signature. two hosts with different systemd
    # versions produce different signed bytes from identical source, which is
    # a toolchain difference, so it belongs in the fingerprint rather than in
    # the pin: G13 then says "toolchain differs" instead of crying wolf.
    sha256sum "$STUB" 2>/dev/null | awk '{print $1}'
    umask
  } | sha256sum | awk '{print $1}'
}

pin() {
  say "pinning the bytes this source produces"
  [ -f xos.img ] || { echo "FAIL: no xos.img -- build first" >&2; return 1; }
  [ -f bzImage ] || { echo "FAIL: no bzImage -- build first" >&2; return 1; }
  # a pin is a claim about COMMITTED source. one taken while a tracked file
  # was modified pinned bytes no clone can rebuild -- repro caught exactly
  # that once (a level file edited between rootfs and pin). refuse the tree
  # until it is clean; untracked files are not part of the claim.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "FAIL: tracked files are modified -- commit (or discard) before pinning:" >&2
    git status --porcelain --untracked-files=no >&2
    return 1
  fi
  { echo "# the exact artifact this source builds. regenerate with ./build.sh pin."
    echo "# G13 compares against this. a mismatch on the SAME toolchain means the"
    echo "# image no longer corresponds to the source; on a different toolchain it"
    echo "# only means you cannot independently verify this build."
    printf 'image     %s\n'   "$(sha256sum < xos.img      | awk '{print $1}')"
    printf 'squashfs  %s\n'   "$(sha256sum < rootfs.squashfs | awk '{print $1}')"
    printf 'roothash  %s\n'   "$(cat verity.roothash)"
    # the kernel is NOT inside the squashfs, so image/squashfs/roothash can all
    # match while bzImage differs -- and the kernel is what enforces every
    # hardening claim the other three rest on. pin it too.
    printf 'kernel    %s\n'   "$(sha256sum < bzImage | awk '{print $1}')"
    printf 'toolchain %s\n'   "$(toolchain)"
  } > image.sha256
  cat image.sha256
}

# seed the learn corpus from the built busybox's OWN help text. busybox help is
# compiled per-config, so this is the exact flag set THIS build ships -- a ref
# generated any other way could document a flag that is not there. seeded
# entries are committed and then improved by hand; this only fills gaps, it
# never overwrites prose someone wrote.
seed() {
  say "seeding learn/ref from the built binaries"
  [ -f busybox ] || { echo "FAIL: busybox not built -- run ./build.sh busybox" >&2; return 1; }
  mkdir -p learn/ref
  local a n=0 kept=0 help
  # NOTE: several applets exit non-zero on --help ('[' evaluates it as a test
  # expression), so every help call is guarded -- under `set -e` + pipefail an
  # unguarded one aborts the loop after the first applet and silently seeds
  # nothing. that is the same class of bug the `yes |` note above records.
  for a in $(./busybox --list | sort); do
    if [ -f "learn/ref/$a" ]; then
      kept=$((kept + 1))
      continue
    fi
    help=$({ ./busybox "$a" --help 2>&1 || true; } | sed -n '/^Usage:/,$p')
    if [ -z "$help" ]; then
      help="TODO: no --help text; write this entry by hand."
    fi
    printf '%s
%s
' "$a" "$help" > "learn/ref/$a"
    n=$((n + 1))
  done
  # non-busybox binaries have no --help convention worth scraping; stub them so
  # G24 names what still needs prose instead of silently passing.
  for a in $EXTRA_BINS; do
    if [ -f "learn/ref/$a" ]; then
      kept=$((kept + 1))
      continue
    fi
    printf '%s
TODO: write this entry by hand.
' "$a" > "learn/ref/$a"
    n=$((n + 1))
  done
  printf '  seeded %d new, kept %d existing
' "$n" "$kept"
}

# is TOK a legitimate flag cluster for the command documented by REF?
# handles bundling (-rf = -r -f) and attached values (-f1 = -f with arg "1").
# gate roster -- every G-number that exists, in one place, so a silently
# dropped gate is visible instead of hiding in a diff. most run in gates()
# below; G8 runs in fetch(), G9 lives in githooks/pre-commit (not this
# script).
#   G1  image <= IMAGE_MAX
#   G2  no dynamic loader (no INTERP segment on any ELF)
#   G3  every ELF is PIE
#   G4  no setuid/setgid files
#   G5  no world-writable files
#   G6  cmdline root hash matches the built tree
#   G7  kernel has no module loader
#   G8  every source pinned + verified before extraction; six upstreams
#       also matched to committed maintainer signatures    (fetch())
#   G9  no build artifacts/keys committed                  (githooks/pre-commit)
#   G10 build clock pinned (busybox banner matches SOURCE_DATE_EPOCH)
#   G11 no plaintext private key on disk
#   G12 image has every manifest entry
#   G13 image matches the committed digest (reproducibility)
#   G14 kernel honours the hardening config
#   G15 cmdline carries every hardening param
#   G16 no executable stack
#   G17 stick.img coherent with the pinned artifacts
#   G18 no firmware blobs in image
#   G19 UKI + image <= IMAGE_MAX (the binding size gate)
#   G20 shipped image is not revoked
#   G21 revocation digest matches the signature
#   G22 stack protector present in every shipped ELF
#   G23 exactly one shell (busybox ash)
#   G24 learn corpus covers the shipped surface exactly
#   G25 learn selftest passes under the built busybox
#   G26 curriculum covers the surface (nothing untaught)
#   G27 levels only use commands already taught, in order
#   G28 bzImage was built from the on-disk kernel.config
#   G29 challenge track holds its shape
#   G30 clock floor is fresh, not stale
#   G31 no test flags on the production cmdline
#   G32 fingerprint wordlist holds its shape (256 unique words)
#   G33 init remote-access arg-building, run through the real ash
#   G34 signed UKI's embedded roothash matches the tree
#   G35 first-party scripts parse under the shipped ash
#   G36 learn reaches its prompt on a silent terminal, under that ash
#   G37 the between-cards pause takes one keypress and gives the tty back
#   G38 build.sh and selftest.sh parse under bash
#   G39 both destructive disk paths go through the shared guard
#   G40 the respawn backoff counts and sleeps as written
#   G41 a flashed stick yields a p3 that fills the device
#   G42 a revocation is shipped in a form real firmware can enroll
#   G43 an update preserves p3 -- its entry and its bytes
#   G44 a planted digest cannot buy a pass from the revocation check
#   G45 a source signed by an expired or revoked key is refused
# ────────────────────────────────────────────────────────────────────────────
# the gates -- every claim this repo makes, checked before it ships
# ────────────────────────────────────────────────────────────────────────────
gates() {
  say "gates"
  local bad=0 ran=0
  local EXPECTED_GATES=43   # roster above, minus G8/G9 (checked elsewhere)
  g() { printf '  %-42s %s
' "$1" "$2"; ran=$((ran+1)); [ "$2" = ok ] || bad=1; }

  local sz; sz=$(stat -c%s xos.img)
  g "G1 image <= $IMAGE_MAX ($sz)" "$([ "$sz" -le "$IMAGE_MAX" ] && echo ok || echo FAIL)"

  # the ELF gates. `for f in $elfs` word-split paths and an empty root/ made
  # every counter 0 -> ok, so: read paths line by line, and count the ELFs so
  # an empty tree is a FAIL instead of a vacuous pass.
  local elfs interp exec_type n_elf=0 rwe_stack=0 ssp_miss=0 f
  elfs=$(find root -type f -exec sh -c 'head -c4 "$1" | grep -q ELF && echo "$1"' _ {} \; 2>/dev/null)
  interp=0; exec_type=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n_elf=$((n_elf+1))
    readelf -l "$f" 2>/dev/null | has INTERP && interp=$((interp+1))
    readelf -h "$f" 2>/dev/null | has 'Type:.*EXEC' && exec_type=$((exec_type+1))
    # GNU_STACK marked RWE = executable stack (the noexecstack link flag failed).
    # this one IS kernel-enforced, unlike RELRO in a static-pie binary. the
    # flags are the second-to-last column -- the last is the alignment, and
    # reading it made this gate unable to fail for as long as it existed.
    readelf -lW "$f" 2>/dev/null | awk '/GNU_STACK/{print $(NF-1)}' | has RWE && rwe_stack=$((rwe_stack+1))
    # G22 -- the stack protector claim. a protected function loads the canary
    # from the TLS slot (%fs:0x28 on x86_64) in its prologue; a binary with no
    # such load anywhere was compiled without -fstack-protector. musl prints
    # no message on a canary failure (it just crashes), so the code is the
    # only evidence there is.
    [ "$(objdump -d "$f" 2>/dev/null | grep -c '%fs:0x28')" -gt 0 ] || ssp_miss=$((ssp_miss+1))
  done <<< "$elfs"
  # the executable-stack detector must be able to say RWE at all: link a
  # deliberately bad object and ask. a detector that cannot fail is not one.
  local g16d; g16d=$(mktemp -d)
  printf 'int main(void){return 0;}\n' > "$g16d/x.c"
  local g16_self=FAIL
  if gcc -o "$g16d/x" "$g16d/x.c" -z execstack 2>/dev/null \
     && readelf -lW "$g16d/x" | awk '/GNU_STACK/{print $(NF-1)}' | has RWE; then g16_self=ok; fi
  rm -rf "$g16d"
  g "G2 no dynamic loader ($interp with INTERP, $n_elf ELF)" "$([ "$interp" -eq 0 ] && [ "$n_elf" -gt 0 ] && echo ok || echo FAIL)"
  g "G3 all ELF are PIE ($exec_type non-PIE)"    "$([ "$exec_type" -eq 0 ] && [ "$n_elf" -gt 0 ] && echo ok || echo FAIL)"
  g "G16 no executable stack ($rwe_stack RWE, detector $g16_self)" \
    "$([ "$rwe_stack" -eq 0 ] && [ "$n_elf" -gt 0 ] && [ "$g16_self" = ok ] && echo ok || echo FAIL)"
  g "G22 stack protector in every ELF ($ssp_miss without)" "$([ "$ssp_miss" -eq 0 ] && [ "$n_elf" -gt 0 ] && echo ok || echo FAIL)"

  local suid ww
  suid=$(find root -type f \( -perm -4000 -o -perm -2000 \) | wc -l)
  ww=$(find root -type f -perm -0002 | wc -l)
  g "G4 no setuid/setgid ($suid)"      "$([ "$suid" -eq 0 ] && echo ok || echo FAIL)"
  g "G5 no world-writable ($ww)"       "$([ "$ww" -eq 0 ] && echo ok || echo FAIL)"

  local want have
  want=$(cat verity.roothash)
  have=$(grep -oE 'sha256 [0-9a-f]{64}' cmdline.txt | awk '{print $2}')
  g "G6 cmdline root hash matches tree" "$([ "$want" = "$have" ] && echo ok || echo FAIL)"

  # a full reproducibility check needs two builds; this asserts the mechanism
  # that makes it possible is still in place, which is cheap and catches drift.
  local pinned; pinned=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%d 2>/dev/null)
  g "G10 build clock pinned ($pinned)" \
    "$(strings busybox 2>/dev/null | has "BusyBox v.*$pinned" && echo ok || echo FAIL)"

  # by CONTENT, the way the pre-commit hook does it: a key is a file that says
  # PRIVATE KEY inside, wherever it sits and whatever it is called. the old
  # check was `keys/*.key` -- one directory, one extension -- so a decrypted
  # copy left at the tree root during debugging passed as 0. src/ and root/
  # are upstream and image trees (dropbear ships test keys); .git is history.
  local plain
  plain=$(grep -rlE 'BEGIN (RSA |EC |OPENSSH |ENCRYPTED |)PRIVATE KEY' . \
            --exclude-dir=src --exclude-dir=root --exclude-dir=.git --exclude-dir=sysroot \
            --exclude-dir=.worktrees 2>/dev/null | grep -c . || true)
  g "G11 no plaintext private key on disk ($plain)" "$([ "$plain" -eq 0 ] && echo ok || echo FAIL)"

  # G12 -- the image contains everything the manifest declares. component
  # copies were `[ -f x ] && cp x`, so a component that failed to build made
  # the image smaller and every other gate still went green.
  local listing missing=0 want_n=0 p
  listing=$(unsquashfs -l rootfs.squashfs 2>/dev/null | sed 's|^squashfs-root/||')
  while read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    want_n=$((want_n+1))
    if [ "$(printf '%s\n' "$listing" | grep -cFx -- "$p" || true)" = 0 ]; then
      missing=$((missing+1)); printf '    missing from image: %s\n' "$p" >&2
    fi
  done < manifest
  g "G12 image has all $want_n manifest entries ($missing missing)" \
    "$([ "$missing" -eq 0 ] && [ "$want_n" -gt 0 ] && echo ok || echo FAIL)"

  # G13 -- the artifact matches the digest committed alongside the source.
  # this is the whole point of a pinned clock, salt and uuid: without it,
  # "reproducible" is a claim in a README that nothing ever checks.
  if [ -f image.sha256 ]; then
    local want_img have_img want_sq have_sq want_tc have_tc want_rh have_rh want_kv have_kv
    want_img=$(awk '$1=="image"{print $2}'     image.sha256)
    want_sq=$(awk '$1=="squashfs"{print $2}'   image.sha256)
    want_tc=$(awk '$1=="toolchain"{print $2}'  image.sha256)
    want_rh=$(awk '$1=="roothash"{print $2}'   image.sha256)
    want_kv=$(awk '$1=="kernel"{print $2}'     image.sha256)
    have_img=$(sha256sum < xos.img | awk '{print $1}')
    have_sq=$(sha256sum < rootfs.squashfs | awk '{print $1}')
    have_rh=$(cat verity.roothash 2>/dev/null)
    have_kv=$(sha256sum < bzImage 2>/dev/null | awk '{print $1}')
    have_tc=$(toolchain)
    if [ "$want_tc" != "$have_tc" ]; then
      g "G13 reproducible (toolchain differs, not checked)" ok
      printf '    this gcc/squashfs-tools is not the one the pin was taken with,\n' >&2
      printf '    so a byte mismatch here would prove nothing. rebuild is unverified.\n' >&2
    else
      # check the squashfs and roothash digests too -- pin() records both, so a
      # mismatch localises drift (filesystem vs verity padding/tree), and stops
      # either recorded line from being decoration nothing ever reads.
      # want_kv is empty on a pin taken before the kernel line existed; treat
      # that as a stale pin rather than silently skipping the kernel.
      g "G13 image matches committed digest" \
        "$([ "$want_img" = "$have_img" ] && [ "$want_sq" = "$have_sq" ] && [ "$want_rh" = "$have_rh" ] \
           && [ -n "$want_kv" ] && [ "$want_kv" = "$have_kv" ] && echo ok || echo FAIL)"
      [ -n "$want_kv" ] || printf '    image.sha256 predates the kernel pin -- ./build.sh pin\n' >&2
      [ "$want_img" = "$have_img" ] || \
        printf '    image pinned %s\n    image built  %s\n' "${want_img:0:32}..." "${have_img:0:32}..." >&2
      [ "$want_sq" = "$have_sq" ] || \
        printf '    squashfs pinned %s\n    squashfs built  %s\n' "${want_sq:0:32}..." "${have_sq:0:32}..." >&2
      [ "$want_rh" = "$have_rh" ] || \
        printf '    roothash pinned %s\n    roothash built  %s\n' "${want_rh:0:32}..." "${have_rh:0:32}..." >&2
      [ -z "$want_kv" ] || [ "$want_kv" = "$have_kv" ] || \
        printf '    kernel pinned %s\n    kernel built  %s\n' "${want_kv:0:32}..." "${have_kv:0:32}..." >&2
      # the remedy, because it is nearly always this one and `all && pin` can
      # never reach it: the gates run at the END of `all`, so a stale pin fails
      # the run that would have refreshed it. pin cannot move inside `all`
      # either -- taken before the gates it would satisfy G13 by construction
      # and stop meaning anything.
      [ "$want_img" = "$have_img" ] && [ "$want_sq" = "$have_sq" ] && [ "$want_rh" = "$have_rh" ] \
        && [ -n "$want_kv" ] && [ "$want_kv" = "$have_kv" ] || \
        printf '    if this build is the one you meant: ./build.sh pin\n' >&2
    fi
  else
    g "G13 image digest pinned" FAIL
    printf '    no image.sha256 -- run ./build.sh pin\n' >&2
  fi

  # G20 -- never ship an image we have revoked. one `revoke` on the wrong file
  # and the next boot is refused by our own firmware, with a secure boot error
  # that looks like an attack rather than a typo.
  local cur="" rev=0
  if [ -f xos-signed.efi ]; then
    cur=$(python3 pehash.py xos-signed.efi 2>/dev/null || true)
    [ -n "$cur" ] && rev=$(grep -c "^$cur" revoked || true)
  fi
  g "G20 shipped image is not revoked" \
    "$([ -n "$cur" ] && [ "$rev" = 0 ] && echo ok || echo FAIL)"
  [ -n "$cur" ] || printf '    no xos-signed.efi to check -- run ./build.sh uki\n' >&2

  # G21 -- the revocation hash function agrees with the signature it revokes.
  # dbx matches an authenticode digest, not sha256sum of the file; if pehash.py
  # computed the wrong number every dbx entry would match nothing, revoke
  # nothing, and look exactly like revocation that works.
  g "G21 revocation digest matches signature" \
    "$([ -n "$cur" ] && python3 pehash.py --verify xos-signed.efi >/dev/null 2>&1 && echo ok || echo FAIL)"

  # G44 -- G21 is only worth its line if it cannot be lied to. --verify used to
  # look for its own digest anywhere in the PKCS#7 blob, and everything in there
  # beyond the signed content comes from the image and is signed by nobody. so an
  # image could carry a planted copy of a wrong digest, pass, and hand `revoke` a
  # dbx entry that matches nothing while looking exactly like one that works.
  # this replays that forgery byte for byte and demands a refusal.
  local g44=ok
  if [ -f xos-signed.efi ]; then
    # -B: this is the one python invocation that imports pehash as a module, and
    # a stray __pycache__ would leave the tree dirty -- which `pin` refuses.
    PYTHONDONTWRITEBYTECODE=1 python3 -B - xos-signed.efi <<'G44EOF' >&2 || g44=FAIL
import os, shutil, struct, sys, tempfile, pehash

src = sys.argv[1]
b = bytearray(open(src, "rb").read())
pe = struct.unpack_from("<I", b, 0x3C)[0]
opt = pe + 24
dd = opt + (96 if struct.unpack_from("<H", b, opt)[0] == 0x10B else 112)
cert_dd = dd + 32
off, size = struct.unpack_from("<II", b, cert_dd)
if not size:
    sys.exit("    the signed image carries no signature")

d = tempfile.mkdtemp(prefix="xos-g44-")
f = os.path.join(d, "forged.efi")
try:
    if pehash.verify(src) != pehash.pe_hash(src):
        sys.exit("    --verify does not return the digest it checked")

    # flip one hashed byte: the image no longer hashes to what sbsign signed
    b[off // 2] ^= 0xFF
    open(f, "wb").write(b)
    wrong = pehash.pe_hash(f)

    # now plant that wrong digest in the certificate blob -- space the image owns
    # and nobody signs. the cert-table entry is an excluded region and the tail
    # boundary moves with the blob, so the hashed spans do not shift by a byte.
    struct.pack_into("<I", b, cert_dd + 4, size + 32)
    b += bytes.fromhex(wrong)
    open(f, "wb").write(b)

    # if either of these slips the forgery is not a forgery and the gate is theatre
    if pehash.pe_hash(f) != wrong:
        sys.exit("    planting the digest moved the hash -- the gate proves nothing")
    _, o2, s2 = pehash._regions(bytes(b))
    if bytes.fromhex(wrong) not in bytes(b[o2 + 8:o2 + s2]):
        sys.exit("    the wrong digest is not in the blob a substring check reads")

    try:
        pehash.verify(f)
    except ValueError:
        pass                      # the only acceptable outcome
    else:
        sys.exit("    a planted digest passed --verify -- dbx would revoke nothing")
finally:
    shutil.rmtree(d, ignore_errors=True)
G44EOF
  else
    g44=FAIL; printf '    no xos-signed.efi to forge against\n' >&2
  fi
  g "G44 a planted digest cannot pass revocation" "$g44"

  g "G7 kernel has no module loader" \
    "$([ -f "src/linux-$KVER/.config" ] && ! grep -q '^CONFIG_MODULES=y' "src/linux-$KVER/.config" && echo ok || echo FAIL)"

  # G14 -- the built kernel actually honours the config contract. kernel() checks
  # this at build time; re-checking here catches a stale prebuilt .config that
  # was never rebuilt after kernel.config changed.
  local kc="src/linux-$KVER/.config" k_miss=0 k_bad=0 k_want=0 opt
  if [ -f "$kc" ] && [ -s kernel.config ]; then
    while read -r opt; do
      [ -n "$opt" ] || continue
      k_want=$((k_want+1))
      grep -q "^$opt=y" "$kc" || { k_miss=$((k_miss+1)); printf '    config not enabled: %s\n' "$opt" >&2; }
    done < <(grep -oP '^CONFIG_[A-Z0-9_]+(?==y\s*$)' kernel.config)
    while read -r opt; do
      [ -n "$opt" ] || continue
      k_want=$((k_want+1))
      grep -q "^$opt=y" "$kc" && { k_bad=$((k_bad+1)); printf '    config still on: %s\n' "$opt" >&2; }
    done < <(grep -oP '^CONFIG_[A-Z0-9_]+(?==n\s*$)' kernel.config)
    # a kernel.config that parses to nothing is a contract with no clauses
    [ "$k_want" -gt 0 ] || { k_miss=$((k_miss+1)); printf '    kernel.config declares no options\n' >&2; }
    # CONFIG_EXTRA_FIRMWARE bakes a vendor blob straight into bzImage, which
    # G18 (squashfs only) cannot see. it is a string option, so the =n leak
    # scan above skips it -- assert its absence explicitly.
    grep -q '^CONFIG_EXTRA_FIRMWARE="..*"' "$kc" \
      && { k_bad=$((k_bad+1)); printf '    firmware blob embedded in kernel: CONFIG_EXTRA_FIRMWARE\n' >&2; }
    g "G14 kernel hardening config ($k_miss off, $k_bad leaked)" \
      "$([ "$k_miss" -eq 0 ] && [ "$k_bad" -eq 0 ] && echo ok || echo FAIL)"
  else
    g "G14 kernel hardening config" FAIL
    printf '    no %s\n' "$kc" >&2
  fi

  # G15 -- the tamper-proof hardening lives on the cmdline (inside the UKI
  # signature). assert every param that must be there is.
  local c15=0 want15
  for want15 in 'panic_on_corruption' 'oops=panic' 'panic=-1' 'page_alloc.shuffle=1' 'random.trust_cpu=1' 'xos.epoch=' 'dm-mod.waitfor=PARTUUID='; do
    grep -qF "$want15" cmdline.txt || { c15=$((c15+1)); printf '    cmdline missing: %s\n' "$want15" >&2; }
  done
  # ...and assert NO param is present that would neuter the compiled-in
  # hardening at boot. G15 checked only for presence; a runtime override like
  # mitigations=off or init_on_free=0 keeps every config gate green while
  # switching the protection off, and the cmdline is signed, so it must be
  # caught here before it ships inside the signature.
  local c15b=0 deny15
  for deny15 in 'mitigations=off' 'init_on_alloc=0' 'init_on_free=0' 'nokaslr' 'lockdown=none' 'nosmep' 'nosmap' 'nopti' 'no_hash_pointers' 'page_alloc.shuffle=0' 'random.trust_cpu=0'; do
    grep -qF "$deny15" cmdline.txt && { c15b=$((c15b+1)); printf '    cmdline FORBIDDEN: %s\n' "$deny15" >&2; }
  done
  g "G15 cmdline hardening params ($c15 missing, $c15b forbidden)" \
    "$([ "$c15" -eq 0 ] && [ "$c15b" -eq 0 ] && echo ok || echo FAIL)"

  # G18 -- no firmware blobs in the image. r8169 pulls in FW_LOADER; if a blob
  # ever gets shipped it is unverified-by-vendor content on a verified system.
  local fw fw_list
  fw_list=$(unsquashfs -l rootfs.squashfs 2>/dev/null) || fw_list=""
  fw=$(printf '%s\n' "$fw_list" | grep -c 'squashfs-root/lib/firmware' || true)
  g "G18 no firmware blobs in image ($fw)" "$([ -n "$fw_list" ] && [ "${fw:-0}" -eq 0 ] && echo ok || echo FAIL)"

  # G32 -- the fingerprint wordlist. init indexes it 1..256 by roothash byte;
  # a short, duplicated, or malformed list makes two images share words or
  # prints empty ones, silently -- exactly the quiet shrink gates exist for.
  local wl=overlay/usr/share/xos/words wl_n wl_u wl_bad
  wl_n=$(grep -c . "$wl" 2>/dev/null || true)
  wl_u=$(sort -u "$wl" 2>/dev/null | grep -c . || true)
  wl_bad=$(grep -cvE '^[a-z]+$' "$wl" 2>/dev/null || true)
  g "G32 fingerprint wordlist ($wl_n words, $((wl_n - wl_u)) dup, $wl_bad malformed)" \
    "$([ "${wl_n:-0}" -eq 256 ] && [ "${wl_u:-0}" -eq 256 ] && [ "${wl_bad:-1}" -eq 0 ] && echo ok || echo FAIL)"

  # G33 -- init's remote-access arg-building, exercised through the SAME busybox
  # ash the image runs. the wg-address parse and its two consumers (the route
  # keeps the CIDR, the ssh bind takes the bare address) are the exact lines a
  # prior fix inverted -- $wgip carried the CIDR into `dropbear -p`, and neither
  # the gates nor the boot self-test caught it, because the real state_open()
  # / wg block never runs in the harness (it needs a partitioned LUKS stick and
  # an interactive passphrase). this runs init's own parse bytes and asserts the
  # split; the structural checks pin the two consumers and the partition scan so
  # a future edit that swaps them fails here instead of on a stick in the field.
  local g33=ok bb33 wgp33 t33 got33
  t33=$(mktemp -d)
  bb33=./busybox; [ -x "$bb33" ] || bb33=$(command -v busybox 2>/dev/null)
  wgp33=$(sed -n '/^[[:space:]]*wgcidr=/,/^[[:space:]]*case /p' init)
  _wg33() {   # $1 = Address value ('' for none), $2 = expected "wgcidr|wgip"
    if [ -n "$1" ]; then printf 'Address = %s\n' "$1" > "$t33/wg0.conf"; else : > "$t33/wg0.conf"; fi
    got33=$(STATE_DIR="$t33" "$bb33" ash -c "$wgp33"'; printf "%s|%s" "$wgcidr" "$wgip"' 2>/dev/null)
    [ "$got33" = "$2" ] || { g33=FAIL; printf '    wg-parse %s -> %s (want %s)\n' "${1:-none}" "$got33" "$2" >&2; }
  }
  _wg33 "10.9.0.2/32" "10.9.0.2/32|10.9.0.2"
  _wg33 "10.9.0.1/24" "10.9.0.1/24|10.9.0.1"
  _wg33 "10.9.0.5"    "10.9.0.5/24|10.9.0.5"
  _wg33 ""            "|"
  # the signed-cmdline reader, same treatment: a key in FIRST position used to
  # come back empty (`[ ^]` was a bracket set, not an anchor), and xos.epoch --
  # the clock floor -- is read through it.
  local cg33 cl33
  cg33=$(grep '^cmdline_get()' init)
  for cl33 in 'xos.epoch=7 a=1|7' 'a=1 xos.epoch=7|7' 'a=1 xos.epoch=7 b=2|7' 'a=1 xos.epochs=9|'; do
    got33=$(CMDLINE="${cl33%|*}" "$bb33" ash -c "$cg33"'; cmdline_get xos.epoch' 2>/dev/null)
    [ "$got33" = "${cl33#*|}" ] || { g33=FAIL; printf '    cmdline_get on "%s" -> "%s" (want "%s")\n' "${cl33%|*}" "$got33" "${cl33#*|}" >&2; }
  done
  rm -rf "$t33"
  grep -q 'ip addr add "\$wgcidr" dev wg0' init          || { g33=FAIL; printf '    wg route no longer uses $wgcidr\n' >&2; }
  grep -q 'dropbear .*-p "\$wgip:22"' init               || { g33=FAIL; printf '    ssh bind no longer uses bare $wgip\n' >&2; }
  grep -q 'for p in /sys/class/block/\*/partition' init  || { g33=FAIL; printf '    state_open no longer scans */partition\n' >&2; }
  grep -q 'for dev in \$cands' init                      || { g33=FAIL; printf '    state_open no longer tries every candidate\n' >&2; }
  grep -q 'wg setconf wg0 /tmp/wgset.conf' init          || { g33=FAIL; printf '    setconf fed the raw conf -- Address= lines make strict wg error out\n' >&2; }
  g "G33 init remote-access logic (real ash)" "$g33"

  # G34 -- the signed UKI's EMBEDDED roothash must match the tree. G6 pins
  # cmdline.txt (a file) to verity.roothash (a file), and G17 pins the ESP to
  # xos-signed.efi -- but nothing pinned what is INSIDE the signed efi to
  # either. a uki step that fails (locked keys) while verity and stick succeed
  # leaves a stale signed efi beside a fresh image, every gate green, and a
  # stick that panics at the verity mount on real hardware. seen happen.
  local g34_have
  g34_have=$(strings xos-signed.efi 2>/dev/null | grep -o 'sha256 [0-9a-f]\{64\}' | head -1 | cut -d' ' -f2)
  g "G34 signed UKI embeds the tree's roothash" \
    "$([ -n "$g34_have" ] && [ "$g34_have" = "$(cat verity.roothash)" ] && echo ok || echo FAIL)"

  # G35 -- every first-party script parses under the ash that ships. shellcheck
  # is host-optional (lint()); this is not: a script the shipped shell cannot
  # even parse is a boot- or lease-time failure no other gate can see, because
  # init and the dhcp hook only ever run on the stick.
  local g35=ok bb35 f35 e35
  bb35=./busybox; [ -x "$bb35" ] || bb35=$(command -v busybox 2>/dev/null)
  for f35 in init learn/learn learn/lib/* overlay/usr/share/udhcpc/default.script; do
    e35=$("$bb35" ash -n "$f35" 2>&1) \
      || { g35=FAIL; printf '    %s does not parse: %s\n' "$f35" "$e35" >&2; }
  done
  g "G35 first-party scripts parse under shipped ash" "$g35"

  # G38 -- build.sh and selftest.sh parse. G35 covers what ships; these two
  # never ship, and until now nothing looked at them at all. that matters most
  # for usb() and addstate(): no test calls them, so a syntax error in either
  # is invisible until the moment someone flashes a real disk with it. bash,
  # not ash -- these are the two files that are allowed to be bash.
  local g38=ok f38 e38
  for f38 in build.sh selftest.sh; do
    e38=$(bash -n "$f38" 2>&1) \
      || { g38=FAIL; printf '    %s does not parse: %s\n' "$f38" "$e38" >&2; }
  done
  g "G38 build scripts parse under bash" "$g38"

  # G39 -- the only two functions here that write to a raw block device must
  # both go through the shared guard. they were near-identical copies, which is
  # how a guard gets fixed in one and forgotten in the other; one implementation
  # is only worth anything if nothing can quietly stop calling it.
  local g39=ok fn39 body39 need39
  for fn39 in usb addstate; do
    body39=$(sed -n "/^$fn39() {/,/^}/p" build.sh)
    for need39 in guard_removable confirm_model; do
      printf '%s' "$body39" | has "$need39 \"" \
        || { g39=FAIL; printf '    %s() no longer calls %s\n' "$fn39" "$need39" >&2; }
    done
  done
  g "G39 destructive disk paths share one guard" "$g39"

  # G40 -- the respawn backoff, run for real. it is written once now, but the
  # dropbear copy it replaced was never reached by any boot, healthy or not, so
  # the arithmetic had no coverage whatsoever. sleep is shadowed by a stub, so
  # the 30-second branch is observable without waiting 30 seconds.
  # each case is "starting _fail : seconds the payload ran : want _fail : want sleep".
  local g40=ok rw40 out40 c40 f40 r40 wf40 ws40
  rw40=$(sed -n '/^respawn_wait()/,/^}/p' init)
  for c40 in 0:1:1:1 3:1:4:1 4:1:5:30 4:9:0:1 7:5:0:1 5:1:6:30; do
    f40=$(printf '%s' "$c40" | cut -d: -f1); r40=$(printf '%s' "$c40" | cut -d: -f2)
    wf40=$(printf '%s' "$c40" | cut -d: -f3); ws40=$(printf '%s' "$c40" | cut -d: -f4)
    out40=$("$bb35" ash -c "sleep() { printf 'slept=%s ' \"\$1\"; }
$rw40
_fail=$f40
respawn_wait $r40
printf 'fail=%s' \"\$_fail\"" 2>&1)
    [ "$out40" = "slept=$ws40 fail=$wf40" ] \
      || { g40=FAIL; printf '    respawn_wait: _fail=%s ran=%ss -> [%s] (want [slept=%s fail=%s])\n' \
             "$f40" "$r40" "$out40" "$ws40" "$wf40" >&2; }
  done
  g "G40 respawn backoff counts and sleeps as written" "$g40"

  # G41 -- flashing the stick must leave a device whose free space can actually
  # become p3. no test could call usb()/addstate() (they demand a real removable
  # disk), and both of the bugs this catches shipped for exactly that reason:
  # dd left the backup GPT describing the IMAGE, so sfdisk saw 0 B free
  # on a 16 GB stick, and the type was written as gdisk's 8309, which sfdisk
  # rejects outright -- addstate had never once produced a p3. a sparse file is
  # enough: sfdisk does the same arithmetic on a file as on a block device.
  # 1 GiB, not 16: /tmp is tmpfs on this host, so a 16 GB scratch file is 16 GB
  # of RAM competing with the qemu boots the self-test runs. the property under
  # test is "p3 fills whatever device it is given", and a device 15x the image
  # proves that as well as one 240x it. the assertions are stated as "everything
  # past the image, less the backup GPT" for the same reason -- exact, and
  # indifferent to how big the stick is.
  local g41=ok f41 free41 p3sz41 p2sz41 want41 dev41=$((1024 * 1024 * 1024 / 512))
  if [ -f stick.img ]; then
    want41=$(( dev41 - STATE_START_S - 2048 ))
    f41=$(mktemp -u /tmp/xos-g41.XXXXXX.img)
    truncate -s $((dev41 * 512)) "$f41" 2>/dev/null && dd if=stick.img of="$f41" bs=1M conv=notrunc status=none 2>/dev/null
    sfdisk --relocate gpt-bak-std "$f41" >/dev/null 2>&1
    free41=$(sfdisk -F "$f41" 2>/dev/null | awk '/^ *[0-9]+ /{print $3; exit}')
    # every sector past the image must be free once the backup GPT is at the end
    [ "${free41:-0}" -ge "$want41" ] \
      || { g41=FAIL; printf '    only %s of %s sectors free after relocate -- the backup GPT still describes the image\n' "${free41:-0}" "$want41" >&2; }
    # p2 is the same sectors in every version or p3's start is not a constant,
    # and then no update can preserve it. this is the layout claim itself.
    p2sz41=$(partx -g -o SECTORS -n 2:2 "$f41" 2>/dev/null | tr -d ' ')
    [ "${p2sz41:-0}" -eq "$ROOT_SIZE_S" ] \
      || { g41=FAIL; printf '    p2 is %s sectors, not the fixed %s -- p3 would move with the image\n' "${p2sz41:-0}" "$ROOT_SIZE_S" >&2; }
    sfdisk --no-reread -a "$f41" >/dev/null 2>&1 <<G41EOF
start=$STATE_START_S, type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
G41EOF
    p3sz41=$(partx -g -o SECTORS -n 3:3 "$f41" 2>/dev/null | tr -d ' ')
    [ "${p3sz41:-0}" -ge "$want41" ] \
      || { g41=FAIL; printf '    p3 is %s of %s sectors -- addstate cannot fill the stick\n' "${p3sz41:-0}" "$want41" >&2; }
    rm -f "$f41"
  else
    g41=FAIL; printf '    no stick.img to flash\n' >&2
  fi
  g "G41 a flashed stick yields a p3 that fills the device" "$g41"

  # G42 -- a revocation that only reaches the qemu varstore is not a revocation.
  # dbx() wrote nothing else for as long as revoke has existed, so `./build.sh
  # revoke` passed every gate, went green in the harness, and left the machine
  # it was meant to protect completely unchanged. if anything is revoked, the
  # stick must carry the enrollable list beside the keys.
  local g42=ok nrev42
  # grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` used to
  # append a second line and the gate label came out as "(0\n0".
  nrev42=$(grep -cE '^[0-9a-f]{64}' revoked 2>/dev/null || true); nrev42=${nrev42:-0}
  if [ "${nrev42:-0}" -eq 0 ]; then
    g "G42 revocation shipped enrollably (nothing revoked)" ok
  else
    [ -s dbxauth/dbx.auth ] \
      || { g42=FAIL; printf '    %s revoked but no dbxauth/dbx.auth -- run ./build.sh dbx\n' "$nrev42" >&2; }
    [ -f stick.img ] && { mdir -i stick.img@@$((1024 * 1024)) ::/xos-keys 2>/dev/null | has 'dbx.auth' \
      || { g42=FAIL; printf '    the stick does not carry /xos-keys/dbx.auth -- revocation would hold in qemu only\n' >&2; }; }
    g "G42 revocation shipped enrollably ($nrev42 revoked)" "$g42"
  fi

  # G43 -- an update must not be a factory reset. `usb` writes stick.img over the
  # whole front of the device, GPT included, so the new two-partition table
  # forgets p3 even though the flash never reaches a single one of its bytes.
  # that is verified behaviour, not a theory: dd was proven to orphan p3. the fix
  # is the fixed layout (p3 begins where stick.img ends) plus tail_parts, and
  # this gate runs the real function over a scratch device through a whole
  # flash -> addstate -> REflash cycle, then checks the entry AND the data.
  local g43=ok f43 dev43=$((1024 * 1024 * 1024 / 512)) sz43 before43 after43 mark43 gone43
  if [ -f stick.img ]; then
    sz43=$(stat -c%s stick.img)
    f43=$(mktemp -u /tmp/xos-g43.XXXXXX.img)
    truncate -s $((dev43 * 512)) "$f43" 2>/dev/null \
      && dd if=stick.img of="$f43" bs=1M conv=notrunc status=none 2>/dev/null
    sfdisk --relocate gpt-bak-std "$f43" >/dev/null 2>&1
    sfdisk --no-reread -a "$f43" >/dev/null 2>&1 <<G43EOF
start=$STATE_START_S, type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
G43EOF
    # a byte pattern where p3's luks header would be, so "preserved" has to mean
    # the data too and not merely a partition entry pointing at rubble.
    printf 'XOS-G43-STATE' | dd of="$f43" bs=512 seek="$STATE_START_S" conv=notrunc status=none 2>/dev/null
    before43=$(tail_parts "$f43" "$sz43" keep)
    [ -n "$before43" ] \
      || { g43=FAIL; printf '    p3 is not past the flashed region -- an update would write over it\n' >&2; }
    [ -z "$(tail_parts "$f43" "$sz43" lose)" ] \
      || { g43=FAIL; printf '    p3 starts INSIDE the region a flash writes\n' >&2; }
    # the update, byte for byte what usb() does to the device
    dd if=stick.img of="$f43" bs=1M conv=notrunc status=none 2>/dev/null
    gone43=$(tail_parts "$f43" "$sz43" keep)
    [ -z "$gone43" ] \
      || { g43=FAIL; printf '    the reflash did not drop p3 at all -- this gate is proving nothing\n' >&2; }
    sfdisk --relocate gpt-bak-std "$f43" >/dev/null 2>&1
    printf '%s\n' "$before43" | sfdisk --no-reread -a "$f43" >/dev/null 2>&1 || true
    after43=$(tail_parts "$f43" "$sz43" keep)
    [ -n "$after43" ] && [ "$after43" = "$before43" ] \
      || { g43=FAIL; printf '    p3 entry did not come back identical\n      was: %s\n      now: %s\n' "$before43" "$after43" >&2; }
    mark43=$(dd if="$f43" bs=512 skip="$STATE_START_S" count=1 status=none 2>/dev/null | head -c 13 || true)
    [ "$mark43" = "XOS-G43-STATE" ] \
      || { g43=FAIL; printf '    the flash wrote over p3 data -- stick.img reaches past sector %s\n' "$STATE_START_S" >&2; }
    # the other direction: a stick from the OLD layout, p3 sitting where the
    # image now writes. usb() must SEE that, not discover it afterwards.
    rm -f "$f43"; f43=$(mktemp -u /tmp/xos-g43b.XXXXXX.img)
    truncate -s $((dev43 * 512)) "$f43" 2>/dev/null \
      && dd if=stick.img of="$f43" bs=1M conv=notrunc status=none 2>/dev/null
    sfdisk --relocate gpt-bak-std "$f43" >/dev/null 2>&1
    sfdisk --no-reread -a "$f43" >/dev/null 2>&1 <<G43OLD
start=$(( ROOT_START_S + ROOT_SIZE_S )), type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
G43OLD
    # -i: sfdisk dumps uuids upper-case and PU_STATE is written lower-case here,
    # which is exactly why usb() greps case-insensitively too.
    printf '%s' "$(tail_parts "$f43" "$sz43" lose)" | grep -qi "$PU_STATE" \
      || { g43=FAIL; printf '    a p3 inside the flashed region is not reported as at risk -- the refusal cannot fire\n' >&2; }
    [ -z "$(tail_parts "$f43" "$sz43" keep)" ] \
      || { g43=FAIL; printf '    an old-layout p3 was misreported as safe to keep\n' >&2; }
    # and the orphan guard: addstate must not lay a new p3 over a live volume
    # whose entry an older flash threw away. both directions, or it is decoration.
    dd if=/dev/zero of="$f43" bs=512 seek=$(( ROOT_START_S + ROOT_SIZE_S )) count=1 conv=notrunc status=none 2>/dev/null
    luks_at "$f43" $(( ROOT_START_S + ROOT_SIZE_S )) \
      && { g43=FAIL; printf '    luks_at says LUKS on a sector that has none\n' >&2; }
    printf 'LUKS\272\276' | dd of="$f43" bs=512 seek=$(( ROOT_START_S + ROOT_SIZE_S )) conv=notrunc status=none 2>/dev/null
    luks_at "$f43" $(( ROOT_START_S + ROOT_SIZE_S )) \
      || { g43=FAIL; printf '    luks_at misses a real LUKS header -- an orphaned p3 would be written over\n' >&2; }
    rm -f "$f43"
  else
    g43=FAIL; printf '    no stick.img to flash\n' >&2
  fi
  # and the real path has to still use it -- the same reason G39 exists.
  local body43; body43=$(sed -n '/^usb() {/,/^}/p' build.sh)
  printf '%s' "$body43" | has 'keep_tail=$(tail_parts "$dev" "$img_bytes" keep)' \
    || { g43=FAIL; printf '    usb() no longer saves the partitions past the image\n' >&2; }
  printf '%s' "$body43" | has '"$keep_tail" | sfdisk --no-reread -a "$dev"' \
    || { g43=FAIL; printf '    usb() no longer puts the saved partitions back after the write\n' >&2; }
  printf '%s' "$body43" | has 'grep -qi "\$PU_STATE"' \
    || { g43=FAIL; printf '    usb() no longer refuses a p3 inside the region it writes\n' >&2; }
  printf '%s' "$(sed -n '/^addstate() {/,/^}/p' build.sh)" | has 'luks_at "\$dev"' \
    || { g43=FAIL; printf '    addstate() no longer checks for an orphaned state volume\n' >&2; }
  g "G43 an update preserves p3, entry and data" "$g43"

  # G45 -- a dead maintainer key must not keep verifying. gpg prints VALIDSIG for
  # an expired key and for a revoked one exactly as it does for a live one, so
  # matching that line alone -- which sigver did -- means a leaked key goes on
  # passing forever, and expiry and revocation are the only things that ever
  # limit that damage. two layers: the verdicts, against recorded status text, so
  # this holds on a host without gpg; then the same verdicts against keys really
  # generated here, so a gpg that renames a status line is caught too.
  local g45=ok r45=0
  local F45=DEADBEEF0000000000000000000000000000CAFE
  r45=0; printf '[GNUPG:] GOODSIG AAAA Some One\n[GNUPG:] VALIDSIG %s x\n' "$F45" | sigok "$F45" || r45=$?
  [ "$r45" = 0 ] || { g45=FAIL; printf '    sigok refuses a good signature (rc %s)\n' "$r45" >&2; }
  r45=0; printf '[GNUPG:] EXPKEYSIG AAAA Some One\n[GNUPG:] KEYEXPIRED 1654819200\n[GNUPG:] VALIDSIG %s x\n' "$F45" | sigok "$F45" || r45=$?
  [ "$r45" = 2 ] || { g45=FAIL; printf '    an expired key is not flagged (rc %s, wanted 2)\n' "$r45" >&2; }
  r45=0; printf '[GNUPG:] REVKEYSIG AAAA Some One\n[GNUPG:] VALIDSIG %s x\n' "$F45" | sigok "$F45" || r45=$?
  [ "$r45" = 3 ] || { g45=FAIL; printf '    a revoked key is not flagged (rc %s, wanted 3)\n' "$r45" >&2; }
  r45=0; printf '[GNUPG:] GOODSIG AAAA Some One\n[GNUPG:] VALIDSIG %s x\n' 0000000000000000000000000000000000000000 | sigok "$F45" || r45=$?
  [ "$r45" = 1 ] || { g45=FAIL; printf '    a signature by an unpinned key is accepted (rc %s)\n' "$r45" >&2; }
  # the uid is free text that travels with the key -- it must not spoof a verdict
  r45=0; printf '[GNUPG:] EXPKEYSIG AAAA GOODSIG Impersonator\n[GNUPG:] VALIDSIG %s x\n' "$F45" | sigok "$F45" || r45=$?
  [ "$r45" = 2 ] || { g45=FAIL; printf '    a user id spoofed the verdict (rc %s, wanted 2)\n' "$r45" >&2; }

  if command -v gpg >/dev/null 2>&1; then
    local h45 fpr45 st45
    for k45 in live expired; do
      h45=$(mktemp -d) || continue
      chmod 700 "$h45"; printf 'payload\n' > "$h45/f"
      # a key made and used two years ago with a one-day life is expired now
      local age45=""; [ "$k45" = expired ] && age45=--faked-system-time=20240101T000000!
      gpg -q --batch --homedir "$h45" --pinentry-mode loopback --passphrase '' $age45 \
        --quick-gen-key 'xos gate <g45@invalid>' default default \
        "$([ "$k45" = expired ] && echo seconds=86400 || echo never)" 2>/dev/null
      gpg -q --batch --homedir "$h45" --pinentry-mode loopback --passphrase '' $age45 \
        --detach-sign -o "$h45/f.sig" "$h45/f" 2>/dev/null
      fpr45=$(gpg --batch --homedir "$h45" --with-colons -k 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
      st45=$(gpg --batch --homedir "$h45" --status-fd 1 --verify "$h45/f.sig" "$h45/f" 2>/dev/null || true)
      r45=0; printf '%s\n' "$st45" | sigok "${fpr45:-none}" || r45=$?
      if [ "$k45" = live ]; then
        [ "$r45" = 0 ] || { g45=FAIL; printf '    real gpg: a live key does not verify (rc %s)\n' "$r45" >&2; }
        # gpg writes a revocation certificate at generation time, so revoking the
        # same key needs no interactive step
        sed 's/^:-----BEGIN/-----BEGIN/' "$h45"/openpgp-revocs.d/*.rev 2>/dev/null \
          | gpg -q --batch --homedir "$h45" --import 2>/dev/null || true
        st45=$(gpg --batch --homedir "$h45" --status-fd 1 --verify "$h45/f.sig" "$h45/f" 2>/dev/null || true)
        r45=0; printf '%s\n' "$st45" | sigok "${fpr45:-none}" || r45=$?
        [ "$r45" = 3 ] || { g45=FAIL; printf '    real gpg: a REVOKED key is not refused (rc %s, wanted 3)\n' "$r45" >&2; }
      else
        [ "$r45" = 2 ] || { g45=FAIL; printf '    real gpg: an EXPIRED key is not flagged (rc %s, wanted 2)\n' "$r45" >&2; }
      fi
      rm -rf "$h45"
    done
  else
    printf '    gpg absent -- the recorded-status verdicts ran, the live-gpg layer did not\n' >&2
  fi

  # and the real path has to still route through it, with revocation inescapable
  local body45; body45=$(sed -n '/^sigver() {/,/^}/p' build.sh)
  printf '%s' "$body45" | has 'sigok "\$4"' \
    || { g45=FAIL; printf '    sigver() no longer judges the status stream through sigok\n' >&2; }
  printf '%s' "$body45" | has 'REVOKED key' \
    || { g45=FAIL; printf '    sigver() no longer refuses a revoked key outright\n' >&2; }
  local n45; n45=$(sed -n '/^fetch() {/,/^}/p' build.sh | grep -c 'expired-ok' || true)
  [ "${n45:-0}" -eq 1 ] \
    || { g45=FAIL; printf '    %s source(s) waive key expiry -- exactly 1 (lvm2) is accounted for\n' "${n45:-0}" >&2; }
  g "G45 expired or revoked source key refused" "$g45"

  # G36 -- learn REACHES its first prompt on a terminal that answers nothing.
  # parsing is not running: the unicode probe asks the terminal a question, and
  # a shell whose read ignores VMIN/VTIME waits for a newline the reply never
  # sends. that hung learn before it drew anything, on the shipped ash, while
  # the host's shell honoured the same stty and made it look fine. G35 cannot
  # see it and no test that is not a terminal can either -- so open one, stay
  # silent, and require an exit.
  local g36=FAIL
  python3 - "$bb35" <<'G36' >/dev/null 2>&1 && g36=ok
import os, pty, select, sys, time
bb = sys.argv[1]
env = dict(os.environ, LEARN_ROOT=os.getcwd() + "/learn", TERM="xterm-256color")
env.pop("COLUMNS", None); env.pop("LINES", None)
pid, fd = pty.fork()
if pid == 0:
    os.execve(bb, [bb, "ash", "learn/learn", "ref", "cut"], env)
end = time.time() + 10
while time.time() < end:                  # answer nothing, ever
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: os.read(fd, 65536)           # drain, so a full pty cannot block it
        except OSError: pass
    try:
        if os.waitpid(pid, os.WNOHANG)[0]: sys.exit(0)
    except ChildProcessError: sys.exit(0)
os.kill(pid, 9); sys.exit(1)
G36
  g "G36 learn starts on a terminal that answers nothing" "$g36"

  # G37 -- the between-cards pause takes ONE keypress and gives the terminal
  # back. it reads a bare key under -icanon, the same corner that hung the
  # UTF-8 probe: busybox ash ignores VMIN/VTIME, so a read shaped even slightly
  # wrong blocks for a newline that never comes. every card screen sits behind
  # this, so a hang here is a hang everywhere.
  local g37=FAIL
  python3 - "$bb35" <<'G37' >/dev/null 2>&1 && g37=ok
import os, pty, select, sys, time
bb = sys.argv[1]
env = dict(os.environ, LEARN_ROOT=os.getcwd() + "/learn", TERM="xterm-256color")
sh = 'ROOT="$LEARN_ROOT"; . "$ROOT/lib/ui"; pause_card; echo "RC=$?"'
for key, want in ((b"\r", "RC=0"), (b"q", "RC=2"), (b"\x04", "RC=2")):
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(bb, [bb, "ash", "-c", sh], env)
    time.sleep(1)                          # let the prompt settle, then one key
    os.write(fd, key)
    out, end = b"", time.time() + 10
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: c = os.read(fd, 65536)
            except OSError: break
            if not c: break
            out += c
        try:
            if os.waitpid(pid, os.WNOHANG)[0]: break
        except ChildProcessError: break
    else:
        os.kill(pid, 9); sys.exit(1)       # never returned: it hung
    if want.encode() not in out: sys.exit(1)
sys.exit(0)
G37
  g "G37 the card pause answers one keypress" "$g37"

  # G17 -- stick.img is coherent with the pinned artifacts: right PARTUUIDs, p2
  # byte-equal to xos.img, ESP carries the exact signed UKI.
  if [ -f stick.img ]; then
    local s_ok=1 j esp_uki
    esp_uki=$(mktemp)
    j=$(sfdisk -J stick.img 2>/dev/null || true)
    printf '%s' "$j" | grep -qi "\"$PU_ESP\""  || { s_ok=0; printf '    esp PARTUUID absent\n' >&2; }
    printf '%s' "$j" | grep -qi "\"$PU_ROOT\"" || { s_ok=0; printf '    root PARTUUID absent\n' >&2; }
    cmp -s -n "$(stat -c%s xos.img)" xos.img <(dd if=stick.img bs=1M skip=$((1 + STICK_ESP_MIB)) count=$(( ($(stat -c%s xos.img) + 1048575) / 1048576 )) status=none 2>/dev/null) \
      || { s_ok=0; printf '    p2 region != xos.img\n' >&2; }
    mcopy -o -n -i stick.img@@1M ::/EFI/BOOT/BOOTX64.EFI "$esp_uki" 2>/dev/null \
      && cmp -s xos-signed.efi "$esp_uki" || { s_ok=0; printf '    ESP UKI != xos-signed.efi\n' >&2; }
    rm -f "$esp_uki"
    g "G17 stick.img coherent with artifacts" "$([ "$s_ok" -eq 1 ] && echo ok || echo FAIL)"
  else
    g "G17 stick.img coherent" FAIL
    printf '    no stick.img -- run ./build.sh stick\n' >&2
  fi

  # G19 -- the whole bootable system fits the size claim, not just the disk
  # image. the UKI (kernel + cmdline) lives on the ESP and was never gated.
  if [ -f xos-signed.efi ]; then
    local whole; whole=$(( $(stat -c%s xos-signed.efi) + $(stat -c%s xos.img) ))
    g "G19 UKI + image <= $IMAGE_MAX ($whole)" "$([ "$whole" -le "$IMAGE_MAX" ] && echo ok || echo FAIL)"
  else
    g "G19 UKI + image size" FAIL
    printf '    no xos-signed.efi -- run ./build.sh uki\n' >&2
  fi

  # G23 -- exactly one shell, by construction: every executable in the image
  # is busybox, a busybox link, a dropbearmulti link, or a name in EXTRA_BINS.
  # the old check was a list of six shell NAMES in two directories -- the same
  # blocklist-of-past-mistakes the pre-commit hook explains it stopped using.
  # a shell shipped as /bin/rc, or bash under /usr/local, passed it. an
  # undeclared executable of any kind fails this one.
  local sh_ok=1 undecl=0 x base
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    base=$(basename "$x")
    case "$base" in busybox|dropbearmulti) continue ;; esac
    case " $EXTRA_BINS " in *" $base "*) continue ;; esac
    # a first-party script the manifest declares (init, the dhcp hook)
    grep -qxF -- "${x#root/}" manifest && continue
    if [ -L "$x" ]; then
      # a link is judged by its target: the applet links point at busybox
      # or dropbearmulti; /etc/resolv.conf and /run point into the tmpfs
      # (nothing executable lives there). anything else is an executable
      # under a name nobody declared.
      case "$(readlink "$x")" in busybox|dropbearmulti|/tmp/*) continue ;; esac
    fi
    undecl=$((undecl+1)); printf '    undeclared executable in image: %s\n' "$x" >&2
  done <<< "$(find root \( -type f -o -type l \) -perm -0100 2>/dev/null)"
  [ "$undecl" -eq 0 ] || sh_ok=0
  readlink root/bin/sh 2>/dev/null | grep -qx busybox \
    || { sh_ok=0; printf '    /bin/sh is not busybox\n' >&2; }
  g "G23 exactly one shell ($undecl undeclared executables)" "$([ "$sh_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G24 -- learn documents the system that actually ships, in both directions,
  # and the applet list is what was asked for. the third check closes a real
  # gap: rootfs() symlinks whatever `busybox --list` reports, so an applet
  # dropped by oldconfig (unmet dep, typo) shipped silently -- manifest names
  # only a handful of applets, so G12 never saw it. same silent-shrink failure
  # this repo already learned about with components and with artifact names.
  local c_ok=1 want_ap have_ap miss_ref miss_cmd miss_ap
  want_ap=$(grep -v '^[[:space:]]*#' busybox.config.applets | tr ' ' '\n' | grep -v '^$' | sort -u)
  have_ap=$(./busybox --list 2>/dev/null | sort -u)
  # two names in the config list are not applet names and never appear in
  # --list: CONFIG_TEST1 builds the applet called '[', and 'busybox' is the
  # binary itself. everything else missing is a real silent shrink.
  miss_ap=$(comm -23 <(printf '%s\n' "$want_ap") <(printf '%s\n' "$have_ap") \
    | grep -vxE 'test1|busybox' | grep -c . || true)
  [ "${miss_ap:-0}" -eq 0 ] || { c_ok=0; printf '    %s requested applet(s) did not build\n' "$miss_ap" >&2; }
  # shell builtins are part of the surface but never appear in --list. verify
  # each declared one really IS a builtin of the ash THIS build produced, so the
  # list cannot drift into fiction.
  local builtins bi_bad=0 b
  builtins=$(grep -v '^[[:space:]]*#' learn/builtins | tr ' ' '\n' | grep -v '^$' | sort -u)
  for b in $builtins; do
    printf 'type %s\n' "$b" | ./busybox ash 2>&1 | has builtin \
      || { bi_bad=$((bi_bad + 1)); printf '    %s is not a builtin of the built ash\n' "$b" >&2; }
  done
  [ "$bi_bad" -eq 0 ] || c_ok=0
  # every shipped command has a ref ...
  # "." is a real builtin and can never be a filename -- that name always means
  # the directory itself -- so its page is stored as "dot" and learn translates.
  refname() { [ "$1" = "." ] && echo dot || echo "$1"; }
  miss_ref=$( { printf '%s\n' "$have_ap"; printf '%s\n' "$builtins"; printf '%s\n' $EXTRA_BINS; } | sort -u | while read -r c; do
      [ -n "$c" ] && [ ! -f "learn/ref/$(refname "$c")" ] && echo "$c"; done | grep -c . || true)
  [ "${miss_ref:-0}" -eq 0 ] || { c_ok=0; printf '    %s shipped command(s) undocumented\n' "$miss_ref" >&2; }
  # ... and every ref is a shipped command
  miss_cmd=$(ls -1 learn/ref 2>/dev/null | sed 's/^dot$/./' | while read -r r; do
      # -F: command names are literals. '[' is a real applet and an invalid regex.
      printf '%s\n' "$have_ap" | grep -qxF "$r" && continue
      printf '%s\n' "$builtins" | grep -qxF "$r" && continue
      case " $EXTRA_BINS " in *" $r "*) continue ;; esac
      echo "$r"; done | grep -c . || true)
  [ "${miss_cmd:-0}" -eq 0 ] || { c_ok=0; printf '    %s ref(s) document nothing shipped\n' "$miss_cmd" >&2; }
  # ... and every ref still matches the binary's own --help flag for flag.
  # seed() never overwrites a page, so without this a busybox bump that added
  # a flag to an existing applet was invisible to G26 -- the claim that a bump
  # stops the build held only for brand-new applets.
  local rc_out
  rc_out=$(PATH="$PWD/root/bin:$PATH" LEARN_ROOT="$PWD/learn" NO_COLOR=1 ./busybox ash learn/learn refcheck 2>&1) \
    || { c_ok=0; printf '%s\n' "$rc_out" | grep STALE | sed 's/^/    /' >&2; }
  g "G24 learn corpus covers the surface exactly ($(printf '%s' "$rc_out" | sed -n 's/^learn: refcheck: //p' | tail -1))" "$([ "$c_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G25/G26 -- the curriculum checks itself, using the shell that will run it.
  #
  # these used to be two hundred lines of host awk that re-implemented learn's
  # own parser: a second answer checker, a second flag table, a second notion
  # of what "documented" means. two implementations of one rule drift, and the
  # copy that runs at build time is the one nobody exercises by hand.
  #
  # so the build now runs the real thing, under the real busybox, against the
  # real corpus. learn selftest renders every question, feeds each of its own
  # answers back through the grader, and EXECUTES them against the sandbox --
  # so a question that teaches a flag this build compiled out fails here.
  # busybox decides what to be from argv[0], so `busybox -c ...` is not a
  # shell -- it needs a name. give it one that lives for the length of the run.
  # PATH leads with root/bin (the image's own applet links): without it, every
  # command an answer runs resolves to the HOST's GNU tools, and a busybox
  # flag difference sails through green. the host stays as fallback for the
  # few non-applet binaries the corpus mentions.
  local st_out st_ok=1 lsh
  lsh=$(mktemp -d); ln -sf "$PWD/busybox" "$lsh/sh"
  st_out=$(PATH="$PWD/root/bin:$PATH" LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           ./busybox ash learn/learn selftest 2>&1) || st_ok=0
  printf '%s\n' "$st_out" | grep -v '^learn: ' >&2 || true
  g "G25 $(printf '%s' "$st_out" | sed -n 's/^learn: //p' | tail -1)" \
    "$([ "$st_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G26 -- every documented flag is taught or explicitly retired in learn/skip.
  # this is the gate the whole "we teach everything" claim rests on, and it is
  # only checkable because the program surface is fixed at build time. a
  # busybox bump that adds a flag lands in neither set and stops the build.
  local cv_out cv_ok=1
  cv_out=$(PATH="$PWD/root/bin:$PATH" LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           ./busybox ash learn/learn coverage 2>&1) || cv_ok=0
  local cv_t cv_s cv_u
  cv_t=$(printf '%s\n' "$cv_out" | awk '$1 == "taught"   {print $2}')
  cv_s=$(printf '%s\n' "$cv_out" | awk '$1 == "skipped"  {print $2}')
  cv_u=$(printf '%s\n' "$cv_out" | awk '$1 == "untaught" {print $2}')
  [ "$cv_ok" -eq 1 ] || printf '    %s flags are neither taught nor listed in learn/skip\n' "$cv_u" >&2
  g "G26 curriculum covers the surface (${cv_t:-0} taught, ${cv_s:-0} retired, ${cv_u:-?} open)" \
    "$([ "$cv_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G27 -- optimal order, enforced. a level may only use commands that it or an
  # earlier level introduces. learn's own header claims it teaches "in order";
  # this is what stops that being a claim nobody checks. it caught six real
  # violations the first time it ran -- awk and cut used three levels before
  # they were taught, and printf used in four.
  local or_out or_ok=1
  or_out=$(LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           ./busybox ash learn/learn order 2>&1) || or_ok=0
  printf '%s\n' "$or_out" | grep -v '^learn: ' >&2 || true
  g "G27 $(printf '%s' "$or_out" | sed -n 's/^learn: //p' | tail -1)" \
    "$([ "$or_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G29 -- the challenge track holds its shape. at least twelve stages, every
  # stage a real chain, the difficulty never falling and ending in the deep
  # end, and no stage claiming a lvl: whose commands the levels have not
  # taught by then. this is what makes "a challenge track that stops getting
  # harder" a build failure instead of a slow disappointment.
  local ch_out ch_ok=1
  ch_out=$(LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           PATH="$PWD/root/bin:$PATH" \
           ./busybox ash learn/learn challenge check 2>&1) || ch_ok=0
  printf '%s\n' "$ch_out" | grep -v '^learn: ' >&2 || true
  g "G29 $(printf '%s' "$ch_out" | sed -n 's/^learn: //p' | tail -1)" \
    "$([ "$ch_ok" -eq 1 ] && echo ok || echo FAIL)"

  # not a gate: hint coverage and wording variety are judgment calls, and a
  # hard gate on them would breed filler. printed here so drift is visible.
  LEARN_ROOT="$PWD/learn" ./busybox ash learn/learn lint 2>/dev/null \
    | sed -n 's/^learn: /  /p' || true

  rm -rf "$lsh"

  # G28 -- the bzImage on disk was built from the kernel.config on disk.
  #
  # G14 reads kernel.config and confirms the hardening lines are present. it
  # never looks at the binary, so a bzImage built days before kernel.config
  # last changed passes it while failing the boot-time asserts: the config
  # promised lockdown and no vsyscall page, the running kernel disagreed, and
  # nothing in the build noticed. that cost three red self-test sections and
  # an afternoon chasing them in the wrong place.
  local kb_ok=1 kb_want kb_have kx_want kx_have
  if [ ! -f bzImage ] || [ ! -f bzImage.config.sha256 ]; then
    kb_ok=0; printf '    no bzImage or no config stamp -- run ./build.sh kernel\n' >&2
  else
    kb_want=$(sha256sum < kernel.config | awk '{print $1}')
    kb_have=$(awk '/^source/ {print $2}' bzImage.config.sha256)
    [ "$kb_want" = "$kb_have" ] || {
      kb_ok=0
      printf '    kernel.config has changed since bzImage was built -- rebuild the kernel\n' >&2; }
    # the expanded line is the digest of what was really compiled. it was
    # written and never read: a `scripts/config --enable` on the tree's own
    # .config followed by `make` left kernel.config untouched and this green.
    kx_want=$(sha256sum < "src/linux-$KVER/.config" 2>/dev/null | awk '{print $1}')
    kx_have=$(awk '/^expanded/ {print $2}' bzImage.config.sha256)
    [ -n "$kx_want" ] && [ "$kx_want" = "$kx_have" ] || {
      kb_ok=0
      printf '    the kernel tree .config is not the one bzImage was compiled from -- rebuild the kernel\n' >&2; }
  fi
  g "G28 bzImage was built from this kernel.config" \
    "$([ "$kb_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G30 -- SOURCE_DATE_EPOCH doubles as xos.epoch, the security floor init
  # refuses to boot before. it is a pinned literal (never build-time `date
  # +%s` -- that would break G13 reproducibility), so nothing else stops it
  # going stale and quietly re-opening the window to roll a clock back onto
  # an expired or revoked cert. 90 days is tunable; it just has to be shorter
  # than "nobody noticed".
  local floor_age floor_max=7776000
  floor_age=$(( $(date +%s) - SOURCE_DATE_EPOCH ))
  g "G30 clock floor fresh (epoch $((floor_age / 86400)) days old, max $((floor_max / 86400)))" \
    "$([ "$floor_age" -le "$floor_max" ] && echo ok || echo FAIL)"

  # G31 -- a leaked test build must never pass as production. XOS_TEST=1
  # appends these to cmdline.txt (verity()); selftest.sh restores a clean
  # build afterward, but a hard gate here means that restore is enforced,
  # not just intended.
  local tf=0 tfword
  for tfword in xos.test xos.teststate xos.testwg xos.testtether; do
    grep -qF "$tfword" cmdline.txt && tf=$((tf+1))
  done
  g "G31 no test flags on production cmdline" "$([ "$tf" -eq 0 ] && echo ok || echo FAIL)"

  # a gate that dies mid-run under set -e looked exactly like a passing one,
  # so prove every gate actually executed.
  if [ "$ran" -ne "$EXPECTED_GATES" ]; then
    printf '\033[1;31m  only %d of %d gates ran -- the gate run was truncated\033[0m\n\n' "$ran" "$EXPECTED_GATES"
    return 1
  fi

  echo
  # report the G19 headroom, not G1's. this printed IMAGE_MAX - xos.img, so a
  # green build claimed ~7.7 MB free while the binding gate had ~4.8 MB. the
  # kernel is 82% of the budget; the userland is the small part.
  local whole_sz=$sz
  [ -f xos-signed.efi ] && whole_sz=$(( $(stat -c%s xos-signed.efi) + sz ))
  [ "$bad" -eq 0 ] && printf '\033[1;32m  all gates green -- %d bytes on disk, %d of %d used, %d to spare\033[0m\n\n' \
                        "$sz" "$whole_sz" "$IMAGE_MAX" "$((IMAGE_MAX - whole_sz))" \
                   || { printf '\033[1;31m  GATES FAILED\033[0m\n\n'; return 1; }
  return 0
}

# boot the WHOLE partitioned stick under qemu -- the exact bytes that get dd'd
# to a real disk. OVMF finds BOOTX64.EFI on the stick's own ESP (p1); root is
# resolved by PARTUUID from p2, identically to real hardware. no more fat:esp.
# both boots are the same firmware and the same stick; only the way the disk is
# attached differs, so that is the only thing either one spells out.
# ────────────────────────────────────────────────────────────────────────────
# qemu -- the development rig; the stick is the product
# ────────────────────────────────────────────────────────────────────────────
qboot() { # $@ -- how to attach the disk
  [ -f ovmf-vars.fd ] || { echo "FAIL: run ./build.sh uki first" >&2; return 1; }
  [ -f stick.img ] || stick || return 1
  qemu-system-x86_64 -machine q35,smm=on -m 256 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file=ovmf-vars.fd \
    "$@" \
    -nic user,model=virtio-net-pci \
    -nographic -no-reboot
}

boot() {
  qboot -drive file="${1:-stick.img}",if=virtio,format=raw,readonly=on
}

# same, but attach the stick as an emulated USB mass-storage device on xHCI --
# exercises the real boot path (usb enumeration, dm-mod.waitfor polling, the
# removable-media \EFI\BOOT\BOOTX64.EFI fallback) without any hardware.
bootusb() {
  qboot -device qemu-xhci,id=xhci \
    -drive if=none,id=stick,format=raw,readonly=on,file="${1:-stick.img}" \
    -device usb-storage,bus=xhci.0,drive=stick
}


# addstate DEV -- turn the free space after p2 on a flashed stick into p3: an
# encrypted, authenticated ext4 volume that xos unlocks at boot. this is the
# only thing that makes anything persist. it touches the free space only; it
# never writes to p1 or p2. run it once, against the physical stick.
# ────────────────────────────────────────────────────────────────────────────
# writing to real disks -- the only code here that can destroy data
# ────────────────────────────────────────────────────────────────────────────
addstate() {
  local dev="${1:-}"
  [ -b "$dev" ] || { echo "usage: $0 addstate /dev/sdX  (the whole stick, not a partition)" >&2; return 1; }
  # tools addstate needs that a plain build does not -- check them here so it
  # fails with a clear message up front, never half way through partitioning.
  local t miss=""
  for t in cryptsetup:cryptsetup mkfs.ext4:e2fsprogs partx:util-linux sfdisk:util-linux \
           partprobe:parted lsblk:util-linux; do
    command -v "${t%%:*}" >/dev/null 2>&1 || miss="$miss ${t%%:*}(${t##*:})"
  done
  [ -z "$miss" ] || { echo "FAIL: addstate needs:$miss" >&2; return 1; }
  # this rewrites a partition table and luksFormats: every guard usb() has, it
  # has -- literally the same two functions. it used to have one (removable), so
  # a removable sd card of photos with two partitions qualified, with no prompt.
  guard_removable "$dev" || return 1
  # it must be an xos stick: p1 and p2 carry the fixed PARTUUIDs stick() wrote.
  local ptable
  ptable=$(sfdisk -J "$dev" 2>/dev/null) || { echo "FAIL: cannot read the partition table on $dev" >&2; return 1; }
  printf '%s' "$ptable" | grep -qi "\"$PU_ESP\""  || { echo "FAIL: $dev p1 is not the xos ESP -- flash the image first" >&2; return 1; }
  printf '%s' "$ptable" | grep -qi "\"$PU_ROOT\"" || { echo "FAIL: $dev p2 is not the xos root -- flash the image first" >&2; return 1; }

  # never reformat an existing p3. re-running this used to luksFormat whatever
  # third partition was already there and destroy everything on it, with no
  # prompt. if a p3 exists, stop and make the operator remove it deliberately.
  local ep3="${dev}3"; [ -b "$ep3" ] || ep3="${dev}p3"
  if [ -b "$ep3" ]; then
    if cryptsetup isLuks "$ep3" 2>/dev/null; then
      echo "FAIL: $ep3 already holds an encrypted state volume -- refusing to reformat it." >&2
      echo "  unlock it at boot as usual; to REPLACE it, wipe $ep3 deliberately first." >&2
    else
      echo "FAIL: $ep3 already exists and is not xos state -- refusing to touch it." >&2
      echo "  remove that partition deliberately if you mean to add state here." >&2
    fi
    return 1
  fi

  # a stick flashed by an older build still has the image's backup GPT, so the
  # free space is invisible. usb() does this now; repeat it here so an existing
  # stick is repaired rather than refused.
  sfdisk --relocate gpt-bak-std "$dev" >/dev/null 2>&1 || true

  # p3 goes at a FIXED sector -- the first one past stick.img -- not wherever
  # this build's p2 happens to end. that constant is the whole reason an update
  # can preserve it: `usb` writes exactly up to here and stops, and restores the
  # entry afterwards. placing it at p2end+1 (what this used to do) puts it under
  # the next image's backup GPT slack.
  local p2end
  p2end=$(partx -g -o END -n 2:2 "$dev" 2>/dev/null | tr -d ' ') \
    || { echo "FAIL: cannot read the partition table on $dev -- flash the image first" >&2; return 1; }
  [ -n "$p2end" ] || { echo "FAIL: no second partition on $dev" >&2; return 1; }
  [ "$p2end" -lt "$STATE_START_S" ] \
    || { echo "FAIL: p2 ends at sector $p2end, at or past the fixed state start $STATE_START_S" >&2
         echo "  -- this stick was not flashed by this build. reflash it first." >&2; return 1; }
  local dev_s; dev_s=$(cat "/sys/block/$(basename "$dev")/size" 2>/dev/null || echo 0)
  [ "$dev_s" -gt $((STATE_START_S + 2048)) ] \
    || { echo "FAIL: $dev has no room past sector $STATE_START_S for a state partition" >&2; return 1; }

  # a stick flashed by the old code lost p3's ENTRY -- the two-partition GPT
  # went over it -- while every byte of p3 stayed exactly where it was, at
  # p2end+1. creating a fresh p3 now would write over a live encrypted volume.
  # the entry is the only thing missing, so hand back the line that restores it.
  if luks_at "$dev" $((p2end + 1)); then
    echo "FAIL: a LUKS header sits at sector $((p2end + 1)) with no partition entry." >&2
    echo "  an older flash orphaned it; the data is intact. put the entry back rather" >&2
    echo "  than create a new p3 over it:" >&2
    printf '    sfdisk --no-reread -a %s <<EOF\n    start=%s, type=%s, uuid=%s, name="XOS-STATE"\n    EOF\n' \
      "$dev" "$((p2end + 1))" "$PT_LUKS" "$PU_STATE" >&2
    return 1
  fi

  echo "  target: $dev  model: $(disk_model "$dev")  -- p3 starts at sector $STATE_START_S and fills the rest"
  confirm_model "$dev" || return 1
  sfdisk --no-reread -a "$dev" >/dev/null 2>&1 <<SFDISK || { echo "FAIL: sfdisk could not add p3 to $dev (no free space at sector $STATE_START_S, or an unreadable table)" >&2; return 1; }
start=$STATE_START_S, type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
SFDISK
  partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" 2>/dev/null || true
  sleep 1
  local p3="${dev}3"; [ -b "$p3" ] || p3="${dev}p3"
  [ -b "$p3" ] || { echo "FAIL: p3 did not appear as ${dev}3 or ${dev}p3" >&2; return 1; }

  echo "  formatting p3 as LUKS2 with hmac-sha256 integrity -- you will be asked for a passphrase"
  cryptsetup luksFormat --type luks2 --integrity hmac-sha256 --label XOS-STATE "$p3" || return 1
  cryptsetup open "$p3" xosstate_setup || return 1
  make_ext4 /dev/mapper/xosstate_setup || { cryptsetup close xosstate_setup; return 1; }
  cryptsetup close xosstate_setup
  echo "  done. p3 is encrypted + authenticated. xos will offer to unlock it at boot."
}

# thin wrapper so the mkfs call sits behind a name (keeps blunt greps happy).
make_ext4() { "mkfs.ext4" -q -L xos-state "$1"; }


# detect_removable -- echo the removable whole-disks currently attached, one per
# line. the host's fixed disks are excluded, so this cannot surface the drive
# you booted the build machine from.
detect_removable() {
  local d n
  for d in /sys/block/*; do
    n=$(basename "$d")
    [ "$(cat "$d/removable" 2>/dev/null)" = 1 ] || continue
    # skip zero-size card readers with no card in them
    [ "$(cat "$d/size" 2>/dev/null || echo 0)" -gt 0 ] || continue
    echo "/dev/$n"
  done
}

# install [DEV] -- the whole install, in one command: pick the stick, flash a
# verified xos onto it, and offer to add encrypted persistent state. safe by
# construction -- it only ever writes a removable disk, verifies every byte it
# wrote against the pinned digest, and makes you type the disk model before it
# touches anything. with no DEV it auto-detects, and only proceeds when exactly
# one removable disk is present.
stick_install() {
  local dev="${1:-}"
  if [ -z "$dev" ]; then
    local found; found=$(detect_removable)
    local count; count=$(printf '%s\n' "$found" | grep -c . || true)
    if [ "$count" = 0 ]; then
      echo "FAIL: no removable disk found -- plug in the usb stick and try again" >&2
      echo "  (fixed disks are never listed, on purpose)" >&2
      return 1
    elif [ "$count" -gt 1 ]; then
      echo "FAIL: more than one removable disk is attached:" >&2
      printf '%s\n' "$found" | while read -r c; do
        [ -n "$c" ] && echo "    $c  ($(( $(cat "/sys/block/$(basename "$c")/size") / 2048 )) MiB)" >&2
      done
      echo "  name the one you mean: ./build.sh install /dev/sdX" >&2
      return 1
    fi
    dev=$(printf '%s\n' "$found" | grep . | head -1)
    echo "  auto-detected the only removable disk: $dev"
  fi

  # build everything if it is not already sitting here, so a fresh clone can go
  # straight to install.
  [ -f stick.img ] || { echo "  no stick.img yet -- building the whole image first"; build_all || return 1; }

  # the flash + byte-for-byte verification lives in usb(); reuse it rather than
  # keeping a second copy of the careful part.
  usb "$dev" || return 1

  # offer persistent state -- unless the flash just preserved one, which is the
  # normal case for an update. prompting there would walk into addstate's
  # refusal to reformat an existing p3 and read as a failure.
  echo
  local ep3="${dev}3"; [ -b "$ep3" ] || ep3="${dev}p3"
  if [ -b "$ep3" ]; then
    echo "  encrypted state (p3) was already here and came through the update intact --"
    echo "  unlock it at boot as usual."
    echo
    printf '  \033[1;32minstall complete\033[0m\n'
    return 0
  fi
  local ans
  read -rp "  add encrypted persistent state (p3) now? [y/N]: " ans
  case "$ans" in
    y|Y|yes)
      addstate "$dev" || { echo "  state setup failed -- the stick still boots, just without persistence" >&2; return 0; }
      ;;
    *)
      echo "  skipped. add it later with: ./build.sh addstate $dev"
      ;;
  esac

  echo
  printf '  \033[1;32minstall complete\033[0m\n'
}

# lint -- shellcheck over every shell source in the tree. wired into `all`
# after the gates: errors fail the build, but a machine without shellcheck
# must still be able to build, so absence is a printed skip, not a failure
# (G35 still parse-checks the shipped scripts either way). warnings print but
# don't fail the run; errors do. learn/lib/* are sourced fragments with no
# shebang of their own, so they need -s sh spelled out -- learn/learn (their
# one caller) is #!/bin/sh.
lint() {
  say "shellcheck"
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  shellcheck not installed -- skipping (paru -S shellcheck)"
    return 0
  fi
  local out=""
  out+=$(shellcheck build.sh selftest.sh init learn/learn overlay/usr/share/udhcpc/default.script; echo)
  out+=$(shellcheck -s sh learn/lib/*; echo)
  printf '%s\n' "$out"
  # warnings/info are noise until they aren't; only error-severity fails the
  # run, so a bump in shellcheck's own defaults can't silently red the tree.
  if printf '%s' "$out" | has '(error):'; then
    printf '  \033[1;31mshellcheck found errors\033[0m\n'
    return 1
  fi
  printf '  \033[1;32mno shellcheck errors\033[0m\n'
  return 0
}

# build_all -- the whole pipeline, front to back. a real function (not just a
# case arm) so other commands (stick_install on a clean tree) can call it too.
# repro -- the claim, actually tested. G13 compares THIS tree's artifacts to
# the committed pin, which proves the pin was taken from this tree and nothing
# more. this clones committed HEAD into a scratch dir, builds it from scratch
# with its own hands (pinned sources re-verified on extraction, same pinned
# clock), and compares the result against the SAME committed pin. no signing:
# the pin covers xos.img and rootfs.squashfs, both born before any key is
# touched, so a clean clone needs no passphrase and mints no keys. tarballs
# are already in the shared XOS_CACHE, so the clone builds off the network;
# get() re-checks their digests, so a poisoned copy still fails loudly. only meaningful on the
# toolchain the pin was taken with -- same rule G13 already enforces.
# ────────────────────────────────────────────────────────────────────────────
# reproducibility -- a clean clone, built and compared to the pin
# ────────────────────────────────────────────────────────────────────────────
repro() {
  say "independent rebuild -- clone committed HEAD, build, compare to the pin"
  local d want_img have_img want_sq have_sq
  d=$(mktemp -d /tmp/xos-repro.XXXXXX) || return 1
  git clone -q --depth 1 "file://$PWD" "$d/tree" || { rm -rf "$d"; return 1; }
  if ! ( cd "$d/tree" && ./build.sh deps && ./build.sh fetch && ./build.sh kernel \
      && ./build.sh headers && ./build.sh busybox && ./build.sh tls && ./build.sh ii_ \
      && ./build.sh abduco && ./build.sh cryptsetup_ && ./build.sh wg_ \
      && ./build.sh dropbear_ && ./build.sh rootfs && ./build.sh verity ) > "$d/build.log" 2>&1
  then
    echo "FAIL: the clean-clone build itself failed -- tail of the log:" >&2
    tail -5 "$d/build.log" >&2
    rm -rf "$d"; return 1
  fi
  want_img=$(awk '$1=="image"{print $2}'   image.sha256)
  want_sq=$(awk '$1=="squashfs"{print $2}' image.sha256)
  have_img=$(sha256sum < "$d/tree/xos.img" | awk '{print $1}')
  have_sq=$(sha256sum < "$d/tree/rootfs.squashfs" | awk '{print $1}')
  rm -rf "$d"
  if [ "$want_img" = "$have_img" ] && [ "$want_sq" = "$have_sq" ]; then
    printf '  \033[1;32mreproduced\033[0m -- a stranger cloning this repo builds these exact bytes\n'
  else
    printf '  \033[1;31mNOT REPRODUCIBLE\033[0m -- clean clone built different bytes than the pin:\n' >&2
    printf '    image:    pin %s  clone %s\n' "$want_img" "$have_img" >&2
    printf '    squashfs: pin %s  clone %s\n' "$want_sq" "$have_sq" >&2
    return 1
  fi
}

build_all() {
  deps; fetch; kernel; headers; busybox; tls; ii_; abduco; cryptsetup_; wg_; dropbear_; rootfs; verity; keys
  # clean clone makes plaintext keys; seal them so uki's unlock has db.key.enc
  # and G11 stays green. a sealed tree short-circuits keys() and skips this.
  if [ -f keys/db.key ]; then seal; fi
  uki; stick; gates; lint
}

case "${1:-all}" in
  install) shift; stick_install "$@" ;;
  deps|fetch|kernel|headers|busybox|ii_|abduco|cryptsetup_|wg_|dropbear_|addstate|tls|ta|rootfs|verity|keys|seal|reseal|unlock|lock|ramkeys|uki|dbx|revoke|stick|usb|pin|seed|gates|boot|bootusb|lint|repro) "$@" ;;
  all) build_all ;;
  *) echo "usage: $0 {deps|fetch|kernel|headers|busybox|ii_|abduco|cryptsetup_|wg_|dropbear_|addstate|tls|ta|rootfs|verity|keys|seal|reseal|unlock|lock|ramkeys|uki|dbx|revoke IMAGE|stick|usb <dev>|install <dev>|pin|seed|gates|boot|bootusb|lint|repro|all}"; exit 1 ;;
esac

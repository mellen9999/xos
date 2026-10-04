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
# prebuilt blobs blob() cuts out of a pinned arch package (the EFI stub). same
# sharing rule as the tarballs: immutable, digest-checked, fetched once.
XOS_BLOBS="${XOS_BLOBS:-$XOS_CACHE/blobs}"

KVER="${KVER:-6.18.55}"
BBVER="${BBVER:-1.38.0}"
IIVER="${IIVER:-2.0}"
BSSLVER="${BSSLVER:-0.6}"
ABDVER="${ABDVER:-0.6}"
# p3 needs cryptsetup, and cryptsetup needs four libraries. that takes this repo
# from four pinned upstreams to nine, which is the largest single increase in
# trust surface it has ever taken -- recorded in SOURCES.md rather than waved
# through. the kernel crypto backend (AF_ALG) is what avoids a fifth: no
# openssl, no gcrypt, no nettle.
CSVER="${CSVER:-2.8.8}"
LVMVER="${LVMVER:-2.03.42}"
POPTVER="${POPTVER:-1.19}"
JSONCVER="${JSONCVER:-0.19-20260627}"
UTLVER="${UTLVER:-2.42.4}"
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
# the xos RELEASE key: the one key that says "this commit built these bytes,
# and I am the one saying so". deliberately NOT keys/db -- keys() mints a
# secure-boot PK/KEK/db per clone and CI mints throwaways, so a db signature
# proves nothing about who built anything.
#
# a LIST, newest first, so a rotation appends instead of orphaning every
# signature ever made. attest/release-key.asc is a convenience copy; a swapped
# pubkey cannot satisfy these pins.
#
# NO EXPIRY DATE, on purpose. gpg reports EXPKEYSIG for a signature made while
# a key was valid if the key is expired NOW -- so an expiry would turn the
# entire historical log red on expiry day and buy nothing, because continuity
# already comes from the hash chain. compromise is handled by publishing the
# revocation certificate, which sigok()'s REVKEYSIG branch already turns red.
# do not "fix" this by adding one.
RELEASE_FPRS="227F91A83156DECA2B8BEA93958CD4D44A09531E"
# the private-key pattern, in ONE place. a real optional group, not an
# alternation ending in an empty branch: the old `(RSA |EC |OPENSSH |ENCRYPTED |)`
# is a regex error to ugrep and some BSD greps, and the gate that used it
# discarded the error and counted zero. githooks/pre-commit carries the same
# literal and G11 fails if the two ever stop matching.
KEYPAT='BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY'
# lvm2's maintainer key expired 2022-06-09 and has NOT been extended anywhere:
# checked against keys.openpgp.org (404) and keyserver.ubuntu.com (same key,
# same expiry) on 2026-09-17. the signature still proves who made it; what an
# expired key stops doing is limiting the damage of a leak.
#
# re-anchoring it to a live downstream signer was the plan and it does not work:
# debian is eleven releases behind (2.03.31 in sid) and REPACKS the orig tarball
# as .tar.xz, so its signed .dsc does not cover these bytes at all. written down
# here so nobody spends an afternoon rediscovering it.
#
# fedora does corroborate: rawhide packages this exact LVM2.2.03.42.tgz and
# publishes the sha512 below. two independent parties therefore agree on these
# bytes -- the maintainer, by a signature from a key now dead, and fedora, by a
# digest published today. that is a second opinion on the FIRST SIGHTING, which
# is precisely what a dead key stops providing. it is not a live signature and
# SOURCES.md does not call it one.
#
# the teeth are on the NEXT bump: re-pin lvm2 without re-corroborating and the
# build refuses, which forces whoever does it to go and get a second opinion
# again -- exactly when the first-sighting problem recurs.
LVM_SHA512=0d65f37521eb6a472011aee52a72a4e65a14ce71050aac04451a01f84e177282d6a4bdc3db0807f360101824a399803bedb93aa1c6dc894c0ae8347a35a68f29
# popt has no signature; this sha512 is part of the fetch url (see fetch()).
POPT_SHA512=5d1b6a15337e4cd5991817c1957f97fc4ed98659870017c08f26f754e34add31d639d55ee77ca31f29bb631c0b53368c1893bd96cf76422d257f7997a11f6466

# this tree's OWN provenance -- the pins above cover what comes IN, these cover
# what this repo IS. the key blob lives in `signers`, its fingerprint here, so
# a swapped pubkey file cannot satisfy both. the epoch is the first signed
# commit: everything before it is unsigned and always will be, because signing
# an object changes its hash and would invalidate every digest anyone holds.
# checked by vouch() and G52. see SOURCES.md, "this tree's own commits".
SIGN_FPR=SHA256:bx1WU9z4RCs344i+7dMptTQZgavHxofR0XF0FD2D7Pw
SIGN_EPOCH=e187b513c8057079c18a26861384c7a275d5db2e
# one cflags line for every first-party and upstream userland build. the
# -ffile-prefix-map used to live only in cryptsetup_(), where a __FILE__ in an
# assert string had already leaked the absolute build path into the image; a
# fix applied at the one place a bug was seen is a fix waiting to be needed at
# the next. set once, inherited everywhere, so no consumer can drift.
XCF="-fPIE -Os -isystem $PWD/sysroot/include -ffile-prefix-map=$PWD=xos"
# the binaries that are not busybox applets. this used to be written out at
# every site that needed it, so adding one meant editing each and forgetting
# any of them failed confusingly. one list, read everywhere.
EXTRA_BINS="ii tlstunnel learn tutorial abduco cryptsetup wg dropbear dbclient dropbearkey"
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
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$SOURCE_DATE_EPOCH" 2>/dev/null); export KBUILD_BUILD_TIMESTAMP
export KBUILD_BUILD_USER=xos
export KBUILD_BUILD_HOST=xos

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

# grep -q exits the moment it matches, SIGPIPEs whatever is feeding it, and
# under `set -o pipefail` that reads as failure -- so a SUCCESSFUL match looks
# like a failed command. this trap bit five separate checks in this script.
# always pipe into `has` instead of `grep -q`.
has() { local n; n=$(grep -c -- "$1" || true); [ "${n:-0}" -gt 0 ]; }

# fnbody NAME [TREE] -- the text of one build function, from whichever file
# under TREE defines it (build.sh or a build/ module). the gates that hold a
# function to a shape (G39/G43/G45/G49/G53/G58/G64/G66, srcpin_cover,
# learnship, trustver) read through this, so a function may live in any
# module. a name defined twice or not at all prints nothing and a red line:
# the caller's own check then fails on the empty body, and set -e never sees
# a non-zero assignment (the trap that once killed thirty gates in silence).
fnbody() {
  local n=$1 t=${2:-.} hits k
  hits=$(grep -lE "^${n}\(\) *\{" "$t/build.sh" "$t"/build/*.sh 2>/dev/null || true)
  k=$(printf '%s\n' "$hits" | grep -c . || true)
  [ "$k" -eq 1 ] || { printf '  \033[1;31m%s() is defined in %s files (want exactly one)\033[0m\n' "$n" "$k" >&2; return 0; }
  sed -n "/^${n}() *{/,/^}/p" "$hits"
}
# roster_of [TREE] -- the gate roster (every rostered G-number), read from the
# comment block above gates() wherever that lives: build/gates.sh since the
# split, build.sh in an older tree -- verify() reads the ATTESTED commit's
# tree, which may predate the split, so the fallback is load-bearing.
roster_of() {
  local t=${1:-.} f
  f="$t/build/gates.sh"; [ -f "$f" ] || f="$t/build.sh"
  sed -n 's/^#   \(G[0-9][0-9]*\) .*/\1/p' "$f"
}
# nothing on $1 may be mounted. lsblk failing is a refusal, not a pass.
# ────────────────────────────────────────────────────────────────────────────
# helpers -- shell traps, disk guards, and the one place each lives
# ────────────────────────────────────────────────────────────────────────────
# patch_tree DIR PATCHDIR -- apply every patch in PATCHDIR to an unpacked
# source tree, once.
#
# src/ survives between builds, so this has to tell an unpatched tree from one
# it has already patched, and it does it with a stamp rather than by asking
# patch(1). asking was the first attempt and it was wrong in the silent
# direction: `patch -R --dry-run` on an UNPATCHED tree prints "Unreversed
# patch detected! Ignoring -R", dry-runs it forwards instead, succeeds, and
# reports the tree as already patched -- so the build shipped a stock binary
# and said "patch already applied" while doing it. a stamp cannot be talked
# into the wrong answer, and it dies with the tree: get() only extracts when
# the directory is missing, so a fresh extract is a fresh stamp directory.
#
# a patch that does not apply is fatal. upstream moved under a change we
# carry, and the build stops there rather than quietly dropping it.
patch_tree() {
  local d=$1 pd=$2 p n
  [ -d "$pd" ] || return 0
  mkdir -p "$d/.xos-patched"
  for p in "$pd"/*.patch; do
    [ -f "$p" ] || continue
    n=${p##*/}
    [ -f "$d/.xos-patched/$n" ] && continue
    patch -d "$d" -p1 --batch --forward --silent < "$p" \
      || { echo "FAIL: $n does not apply to $d" >&2; return 1; }
    : > "$d/.xos-patched/$n"
    echo "  patched: $n"
  done
}

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
# the stub is NOT a host path any more: blob() cuts it out of the arch package
# blobs.sha256 pins and parks it here, so the host's systemd is irrelevant.
STUB="$XOS_BLOBS/linuxx64.efi.stub"
# OVMF ships as MATCHED PAIRS, and only the .secboot CODE build enforces
# signatures at all. these two paths used to be independent literals pointing
# into Arch's layout, which is two problems in one line. the portability half
# is the obvious one -- the lab was Arch-only, though crepro/verify never were,
# since they run in the container. the DANGEROUS half is the pairing: probing
# each half separately on a distro that lays them out differently can select a
# secboot CODE beside a plain VARS, or the reverse. that firmware boots, ignores
# every signature, and lets selftest's A3/A4/A11 -- the sections whose whole
# claim is "an unsigned or superseded image is REFUSED" -- pass an image that
# should have been refused. a false pass on exactly the thing under test.
#
# so: a table of PAIRS, taken whole. the first pair whose BOTH halves exist
# wins, and XOS_OVMF_CODE/XOS_OVMF_VARS override BOTH or NEITHER. every CODE
# here is a secboot build; a plain OVMF_CODE is deliberately absent, because a
# lab that runs without signature enforcement proves nothing this repo claims.
OVMF_PAIRS="
/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd|/usr/share/edk2/x64/OVMF_VARS.4m.fd
/usr/share/edk2/x64/OVMF_CODE.secboot.fd|/usr/share/edk2/x64/OVMF_VARS.fd
/usr/share/OVMF/OVMF_CODE_4M.secboot.fd|/usr/share/OVMF/OVMF_VARS_4M.fd
/usr/share/OVMF/OVMF_CODE.secboot.fd|/usr/share/OVMF/OVMF_VARS.fd
/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd|/usr/share/edk2/ovmf/OVMF_VARS.fd
/usr/share/qemu/edk2-x86_64-secure-code.fd|/usr/share/qemu/edk2-i386-vars.fd
"
ovmf_pair() {
  local pair c v
  if [ -n "${XOS_OVMF_CODE:-}" ] || [ -n "${XOS_OVMF_VARS:-}" ]; then
    # both or neither: half an override is how a mismatched pair gets built by
    # hand, which is the failure this table exists to prevent.
    [ -n "${XOS_OVMF_CODE:-}" ] && [ -n "${XOS_OVMF_VARS:-}" ] || {
      echo "FAIL: set XOS_OVMF_CODE and XOS_OVMF_VARS together or not at all" >&2
      echo "  OVMF is a matched pair -- half an override can pair a signature-" >&2
      echo "  enforcing CODE with a variable store that does not enforce." >&2
      return 1; }
    # a typo'd override must not reach qemu as an empty -drive path.
    [ -f "$XOS_OVMF_CODE" ] || { echo "FAIL: XOS_OVMF_CODE: no such file: $XOS_OVMF_CODE" >&2; return 1; }
    [ -f "$XOS_OVMF_VARS" ] || { echo "FAIL: XOS_OVMF_VARS: no such file: $XOS_OVMF_VARS" >&2; return 1; }
    printf '%s %s\n' "$XOS_OVMF_CODE" "$XOS_OVMF_VARS"; return 0
  fi
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    c=${pair%%|*}; v=${pair##*|}
    [ -f "$c" ] && [ -f "$v" ] || continue
    printf '%s %s\n' "$c" "$v"; return 0
  done <<< "$OVMF_PAIRS"
  return 1
}
# resolved once, at load, so every consumer sees the same pair. empty when no
# pair is installed -- deps() names it then, rather than qemu failing later on
# an empty -drive path.
# quiet here on purpose: a bad or half override leaves both empty, deps()
# names the gap, and `./build.sh ovmf` prints the real reason once when asked.
OVMF_CODE=$(ovmf_pair 2>/dev/null | awk '{print $1}') || true
OVMF_VARS=$(ovmf_pair 2>/dev/null | awk '{print $2}') || true
# selftest.sh needs the same pair and must NOT re-read it as a literal out of
# this file (`grep ^OVMF_CODE=` would hand it the unexpanded command
# substitution and qemu would fail on a nonsense path, looking like a lab
# problem rather than a parsing one). it asks for it instead.
ovmf() { # [code|vars]
  local c v; read -r c v < <(ovmf_pair) || true
  [ -n "${c:-}" ] && [ -n "${v:-}" ] || {
    echo "FAIL: no matched OVMF secure-boot firmware pair found. install edk2-ovmf" >&2
    echo "  (arch) / ovmf (debian,fedora), or set XOS_OVMF_CODE + XOS_OVMF_VARS." >&2
    return 1; }
  case "${1:-both}" in
    code) printf '%s\n' "$c" ;;
    vars) printf '%s\n' "$v" ;;
    *)    printf 'code %s\nvars %s\n' "$c" "$v" ;;
  esac
}

# the four artifact values image.sha256 pins, compared in ONE place. G13 and
# repro() each did this inline and drifted apart: repro checked two of the
# four, so a kernel or a roothash that did not reproduce still printed
# "reproduced" -- on the single command a stranger is told to run. the pin is
# always THIS tree's committed claim; $1 says where the bytes being judged
# were built. prints one line per mismatch, returns 1 if any differ or any is
# unpinned -- an unpinned value is a FAIL, never a skip, because a pin taken
# before a line existed is stale, not permissive.
# IMAGE_SRC -- every tracked path whose bytes end up in the four pinned
# artifacts, in ONE list. pin() records a digest of them (`source`), ci refuses
# a HEAD whose digest moved since the pin, and srcpin_cover() proves rootfs()
# copies nothing tracked that this list leaves out. the pin drifted FOUR times
# before this existed (2f0698a fb7e3f1 619b2de, then 3 README commits after
# d22d3a5), each one a day of red repro CI that nothing at push time refused:
# README.md ships in the image, so a docs commit moves the squashfs.
# build.sh and build/ are in the list because rootfs()'s file layout and every
# build flag live there; a gate-only edit therefore also asks for a re-pin.
# that is the honest cost -- cpin is three minutes, a wrong pin is a false claim.
IMAGE_SRC="README.md init tutorial overlay
  learn/learn learn/ref learn/lib learn/pools learn/levels learn/scenarios learn/projects
  learn/skip learn/skip-syntax learn/builtins learn/verbs learn/phrases learn/chains
  learn/syntax learn/vs learn/bashisms learn/migrations learn/rekeys learn/acts learn/syn
  build.sh build kernel.config busybox.config.applets busybox.config.features patches
  dropbear.localoptions.h abduco.config.h tlstunnel.c trust musl-static-pie.specs sources.sha256"

# ────────────────────────────────────────────────────────────────────────────
# attestation -- the claim, published in a form a stranger can check
# ────────────────────────────────────────────────────────────────────────────
# image.sha256 is a self-claim in a git repo: it says what bytes this source
# builds, but nothing says WHO said it or WHEN, and a git remote can rewrite
# it at will. attest/ adds the two missing halves.
#
#   attest/NNNN.manifest      one release's claim, in image.sha256's idiom
#   attest/NNNN.manifest.asc  its DETACHED signature, made at that time
#   attest/log                SEQ  MANIFEST-SHA256  LINK -- a hash chain
#   attest/release-key.asc    the public half of the signing key
#
# ONE signature per manifest, not one growing signed file. a single signed log
# has to be re-signed on every append, which destroys every earlier signature
# -- so whoever holds today's key could re-sign a rewritten history and nothing
# would detect it. per-entry signatures mean each claim was signed at its time.
#
# LINK is the sha256 of the PREVIOUS line's literal bytes including its
# newline; the first line's link is 64 zeros. comment lines are not part of the
# chain. three columns only: everything else lives in the manifest that column
# two binds, and a second copy of a fact is a second thing that can disagree.
ATTEST=attest
ZERO=0000000000000000000000000000000000000000000000000000000000000000

# sha256 of a file's bytes, bare.
h256() { sha256sum < "$1" | awk '{print $1}'; }

# ────────────────────────────────────────────────────────────────────────────
# reproducibility BY BYTES -- the toolchain pinned as a container, not versions
# ────────────────────────────────────────────────────────────────────────────
# repro() proves the source rebuilds its own bytes on whatever toolchain is
# here; cpin/crepro tie that to ONE toolchain fixed by content -- a base image
# by digest plus a frozen Arch archive day (repro/Dockerfile). a version string
# only describes a toolchain; a pinned container IS one, so a stranger on any
# distro lands on the exact same xos.img. cpin takes the canonical pin inside
# it; crepro verifies a clean clone reproduces that pin inside it.
CTAG=xos-toolchain

# ────────────────────────────────────────────────────────────────────────────
# the modules -- build.sh keeps the constants every outside reader greps for
# (IMAGE_MAX for the commit hook, SIGN_EPOCH for the push hook, KVER for
# xos-ci-status, SBGUID/STICK_ESP_MIB for selftest.sh, every *VER for bump),
# the helpers, and the dispatch. the work lives in build/, one file per
# concern, sourced here. a module defines functions and nothing else, so the
# order is free; a missing one is a refusal, not a silent loss of verbs.
# ────────────────────────────────────────────────────────────────────────────
# unrolled, not a loop: each `source=` directive lets shellcheck follow the
# module and check it in this file's context (-x), which a loop cannot say.
[ -f build/fetch.sh ] || { echo "FAIL: build/fetch.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/fetch.sh
. build/fetch.sh
[ -f build/components.sh ] || { echo "FAIL: build/components.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/components.sh
. build/components.sh
[ -f build/rootfs.sh ] || { echo "FAIL: build/rootfs.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/rootfs.sh
. build/rootfs.sh
[ -f build/keys.sh ] || { echo "FAIL: build/keys.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/keys.sh
. build/keys.sh
[ -f build/stick.sh ] || { echo "FAIL: build/stick.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/stick.sh
. build/stick.sh
[ -f build/pin.sh ] || { echo "FAIL: build/pin.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/pin.sh
. build/pin.sh
[ -f build/gates.sh ] || { echo "FAIL: build/gates.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/gates.sh
. build/gates.sh
[ -f build/qemu.sh ] || { echo "FAIL: build/qemu.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/qemu.sh
. build/qemu.sh
[ -f build/attest.sh ] || { echo "FAIL: build/attest.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/attest.sh
. build/attest.sh
[ -f build/ci.sh ] || { echo "FAIL: build/ci.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/ci.sh
. build/ci.sh
[ -f build/repro.sh ] || { echo "FAIL: build/repro.sh is missing -- a partial checkout cannot build" >&2; exit 1; }
# shellcheck source=build/repro.sh
. build/repro.sh


build_all() {
  deps; fetch; kernel; headers; busybox; tls; ii_; abduco; cryptsetup_; wg_; dropbear_; rootfs; verity; keys
  # clean clone makes plaintext keys; seal them so uki's unlock has db.key.enc
  # and G11 stays green. a sealed tree short-circuits keys() and skips this.
  if [ -f keys/db.key ]; then seal; fi
  uki; stick; gates
  # lint is host-optional here: 2 is "shellcheck absent", a skip for a host
  # build. any other non-zero is a real shellcheck error and still fails.
  local lrc=0; lint || lrc=$?
  [ "$lrc" -eq 0 ] || [ "$lrc" -eq 2 ] || return 1
}

# flash -- the one-word install for a newbie: build a signed xos, then flash it
# to the usb stick. run it as yourself, NOT root -- the build must not run as
# root (it writes keys and gitignored trees), so flash builds as you and then
# re-invokes only the device write under sudo. it asks twice by design: your
# signing passphrase (to sign the image) and your login password (sudo, to
# write the disk), then makes you type the stick's model back before it touches
# anything. plug in only the target stick first.
flash() {
  [ "$(id -u)" -ne 0 ] || { echo "FAIL: run './build.sh flash' as your normal user, not root -- it escalates the flash step itself" >&2; return 1; }
  build_all || return 1
  say "flashing to the usb stick -- sudo will ask for your login password to write the device"
  sudo "$(readlink -f "$0")" install "$@"
}

help() {
  cat <<'HELP'
usage: ./build.sh <verb> [args]      (no verb prints this; `all` is the build)

  make a stick
    all                   build everything: sources, kernel, image, keys, signed uki, gates
    flash                 build as you, then sudo only for the write (asks which stick)
    install /dev/sdX      the same, you handle root
    usb /dev/sdX          write the built image to a stick (install wraps this)
    addstate /dev/sdX     add the encrypted state partition (p3) to a written stick
    clone /dev/SRC /dev/DST   copy a whole stick, p3 and all, to a spare

  try it with no hardware
    boot                  boot the signed image in qemu, secure boot on
    bootusb               the same, through an emulated usb stick
    ./selftest.sh         the qemu rounds (A1..A22) -- a separate script

  check the tree
    gates                 every build gate against the built tree
    ci                    the buildless tier: shellcheck, parse, learn corpus, pins -- no key, no build
    lint                  shellcheck alone
    vouch                 every commit since the epoch is signed by the pinned key
    verify                re-derive this build's attestation: docker + git + gpg, nothing else
    verify_log            the attestation chain alone (prints its head), no docker
    verify_sigs           the upstream signatures over the pinned sources
    repro / crepro        rebuild a clean clone (host / pinned container) and compare to the pin
    outdated              which pinned upstream has a newer stable release (looks only)
    trustver / toolver    the trust manifest / the host toolchain, against their pins

  keys and signing
    keys                  mint a secure-boot keyset (once per tree)
    seal / reseal         encrypt the keys under a passphrase / change it
    unlock / lock         decrypt the keys into ram / wipe that copy
    ramkeys               where the unlocked copy lives
    sign EFI              db-sign another os's efi (docs/carrier.md)
    revoke IMAGE          retire a superseded image through dbx
    attest                mint the next attestation for committed HEAD

  pins -- what the tree trusts
    pin / cpin            record the built image's digests (host / pinned container)
    bump NAME VER         move one upstream pin to a new release, signature-checked
    blobpin PKGVER        re-derive the efi stub pin from the arch archive
    toolpin               regenerate the container toolchain pin

  single steps, in the order `all` runs them
    deps fetch kernel headers busybox tls ii_ abduco cryptsetup_ wg_ dropbear_
    rootfs verity uki stick   and: dbx ta ovmf blob stub blobver seed
    libparity learnship xexecproof build_repro   (pieces of ci)
HELP
}

case "${1:-help}" in
  install) shift; stick_install "$@" ;;
  flash) shift; flash "$@" ;;
  help|-h|--help) help ;;
  deps|fetch|kernel|headers|busybox|ii_|abduco|cryptsetup_|wg_|dropbear_|addstate|tls|ta|rootfs|verity|keys|seal|reseal|unlock|lock|ramkeys|sign|uki|dbx|revoke|stick|usb|clone|pin|seed|gates|boot|bootusb|ovmf|blob|stub|blobver|blobpin|attest|verify|verify_log|verify_sigs|toolver|toolpin|trustver|lint|ci|libparity|learnship|xexecproof|outdated|bump|vouch|repro|build_repro|cpin|crepro) "$@" ;;
  all) build_all ;;
  *) echo "unknown verb: $1" >&2; help >&2; exit 1 ;;
esac

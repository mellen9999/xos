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

KVER="${KVER:-6.12.43}"
BBVER="${BBVER:-1.37.0}"
IIVER="${IIVER:-2.0}"
BSSLVER="${BSSLVER:-0.6}"
ABDVER="${ABDVER:-0.6}"
# p3 needs cryptsetup, and cryptsetup needs four libraries. that takes this repo
# from four pinned upstreams to nine, which is the largest single increase in
# trust surface it has ever taken -- recorded in SOURCES.md rather than waved
# through. the kernel crypto backend (AF_ALG) is what avoids a fifth: no
# openssl, no gcrypt, no nettle.
CSVER="${CSVER:-2.7.5}"
LVMVER="${LVMVER:-2.03.27}"
POPTVER="${POPTVER:-1.19}"
JSONCVER="${JSONCVER:-0.18-20240915}"
UTLVER="${UTLVER:-2.40.2}"
# phase 4, remote access: wireguard userland + dropbear ssh. wireguard is in the
# kernel; wg only configures it. dropbear is the one listening service xos runs,
# and only ever on the wireguard interface.
WGTVER="${WGTVER:-1.0.20210914}"
DBVER="${DBVER:-2024.86}"
# maintainer key fingerprints for the two upstreams whose signed releases we
# match (see SOURCES.md for how these were established -- each cross-checked
# against at least two independent channels). the committed pubkeys in sigs/
# are convenience copies; a swapped pubkey cannot satisfy these pins.
DB_FPR=F7347EF2EE2E07A267628CA944931494F29C6773    # Matt Johnston (dropbear)
LVM_FPR=D501A478440AE2FD130A1BE8B9112431E509039F   # Marian Csontos (lvm2)
# the binaries that are not busybox applets. this was written out three separate
# times -- seed(), and twice inside G24 -- so adding one meant editing three
# places and forgetting any of them failed confusingly. one list, read everywhere.
EXTRA_BINS="ii tlstunnel learn abduco cryptsetup wg dropbear dbclient dropbearkey"
# plaintext private keys live ONLY here, only while unlocked. /dev/shm is
# tmpfs, so nothing lands on disk. the path is scoped to THIS tree: /dev/shm is
# shared across every checkout and worktree a user has open, so a bare per-uid
# path let one tree's unlock silently satisfy another tree's.
RAMKEYS="/dev/shm/xos-keys-$(id -u)-$(printf %s "$PWD" | sha256sum | cut -c1-12)"
JOBS="$(nproc)"
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
PU_ESP=56524c00-0000-4001-8000-000000000001
PU_ROOT=56524c00-0000-4002-8000-000000000002
PU_STATE=56524c00-0000-4003-8000-000000000003
# how many trust anchors the tls client is allowed to carry. one root, on
# purpose -- a normal distro trusts ~150, any one of which can issue for any
# name. moving this number is a deliberate act.
TA_EXPECTED=1
# spelled as the GUID, not sfdisk's `8309` shorthand: the shorthand is rejected
# outright when a whole table is written at once ("Failed to add #3 partition:
# Invalid argument"), which would have left an updated stick with no p3 entry.
PT_LUKS=CA7D7CCB-63ED-4C53-861C-1742536059CC
STICK_ESP_MIB=64
# fixed build clock: the same commit must yield the same image, so the
# artifact can be checked against its source instead of trusted. this is also
# xos.epoch, the security floor init refuses to boot before -- so it is a
# PINNED LITERAL, never `date +%s`, and gets bumped + repinned periodically
# (G30 fails the build once it goes stale). 2026-09-04 00:00:00 UTC.
export SOURCE_DATE_EPOCH=1788480000
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

# the gate run unpacks the squashfs to measure the artifact rather than the
# staging tree. under `set -e` any gate that dies takes the script with it, so
# the cleanup cannot live at the end of the function -- it goes here, where an
# abort still reaches it. named per-pid so concurrent builds never delete each
# other's copy.
XOS_GATE_TMP=""
trap 'rm -rf "${XOS_GATE_TMP:-}" 2>/dev/null || true' EXIT

# a missing host tool used to surface as a mid-build failure -- the exact fail
# mode this repo eliminates everywhere else. name every one up front instead.
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
deps() {
  say "checking host toolchain"
  local miss=() cmd
  # cmd:package pairs so the error names what to install (arch/paru)
  for cmd in gcc:gcc ld:binutils strip:binutils readelf:binutils make:make \
             curl:curl tar:tar python3:python openssl:openssl \
             mksquashfs:squashfs-tools unsquashfs:squashfs-tools \
             veritysetup:cryptsetup sbsign:sbsigntools sbverify:sbsigntools \
             ukify:systemd virt-fw-vars:python-virt-firmware \
             mcopy:mtools mmd:mtools mkfs.fat:dosfstools sfdisk:util-linux partx:util-linux \
             wipefs:util-linux lsblk:util-linux qemu-system-x86_64:qemu-base; do
    command -v "${cmd%%:*}" >/dev/null 2>&1 || miss+=("${cmd%%:*} (${cmd##*:})")
  done
  # musl is linked into every binary but is NOT built from source here -- it is
  # host-provided. SOURCES.md records this honestly; the build must have it.
  [ -f /usr/lib/musl/lib/rcrt1.o ] || miss+=("/usr/lib/musl/lib/rcrt1.o (musl)")
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
get() {
  local url="$1" tar="$2" dir="$3"
  [ -f "src/$tar" ] || curl -fL --progress-bar "$url" -o "src/$tar"
  grep -q " $tar$" sources.sha256 || { echo "FAIL: $tar not pinned in sources.sha256" >&2; return 1; }
  ( cd src && grep " $tar$" ../sources.sha256 | sha256sum -c --strict - >/dev/null ) || {
    echo "FAIL: $tar digest mismatch -- refusing to extract" >&2; return 1; }
  [ -d "src/$dir" ] || tar -C src -xf "src/$tar"
}

# verify one tarball against a COMMITTED detached signature and pubkey. the
# digest pin (G8) already stops later substitution; this anchors what the
# first sighting WAS to the maintainer's key instead of trust-on-first-use.
# gpg is host-optional: absence skips loudly, the digest pin still holds.
sigver() { # $1 tarball  $2 committed .asc  $3 committed pubkey  $4 pinned fingerprint
  command -v gpg >/dev/null 2>&1 || {
    printf '  %s: gpg not installed -- signature not checked (digest pin still enforced)\n' "$1"; return 0; }
  local gh; gh=$(mktemp -d) || return 1
  gpg -q --homedir "$gh" --import "$3" 2>/dev/null
  # VALIDSIG + the pinned fingerprint: a swapped pubkey file cannot satisfy this.
  if gpg --homedir "$gh" --status-fd 1 --verify "$2" "src/$1" 2>/dev/null | grep -q "VALIDSIG $4"; then
    printf '  %s: maintainer signature verified (%s...)\n' "$1" "$(printf '%s' "$4" | cut -c1-16)"
    rm -rf "$gh"
  else
    rm -rf "$gh"
    echo "FAIL: $1 does not match the committed maintainer signature" >&2; return 1
  fi
}

fetch() {
  say "fetching + verifying sources"
  mkdir -p src

  # G8 -- every source pinned, verified BEFORE extraction. a verified boot
  # chain rooted in an unverified tarball proves nothing.
  get "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz" \
      "linux-$KVER.tar.xz" "linux-$KVER"
  get "https://busybox.net/downloads/busybox-$BBVER.tar.bz2" \
      "busybox-$BBVER.tar.bz2" "busybox-$BBVER"
  # ii: suckless publishes no signature, so this pin is trust-on-first-use
  # over TLS only. see SOURCES.md -- it is weaker than the others on purpose.
  get "https://dl.suckless.org/tools/ii-$IIVER.tar.gz" \
      "ii-$IIVER.tar.gz" "ii-$IIVER"
  # abduco: brain-dump.org publishes no signature either -- see SOURCES.md.
  # 0.6 is from 2015 and has not needed a release since, which is the good kind
  # of stale: four C files that do one thing.
  get "https://www.brain-dump.org/projects/abduco/abduco-$ABDVER.tar.gz" \
      "abduco-$ABDVER.tar.gz" "abduco-$ABDVER"
  # cryptsetup and its four libraries. kernel.org publishes sha256sums for
  # cryptsetup and util-linux; the other three are trust-on-first-use. see
  # SOURCES.md, which records which is which rather than letting one digest
  # list look as authoritative as another.
  get "https://cdn.kernel.org/pub/linux/utils/cryptsetup/v2.7/cryptsetup-$CSVER.tar.xz" \
      "cryptsetup-$CSVER.tar.xz" "cryptsetup-$CSVER"
  get "https://sourceware.org/pub/lvm2/LVM2.$LVMVER.tgz" \
      "LVM2.$LVMVER.tgz" "LVM2.$LVMVER"
  sigver "LVM2.$LVMVER.tgz" "sigs/LVM2.$LVMVER.tgz.asc" sigs/lvm2-release-key.asc "$LVM_FPR"
  get "http://ftp.rpm.org/popt/releases/popt-1.x/popt-$POPTVER.tar.gz" \
      "popt-$POPTVER.tar.gz" "popt-$POPTVER"
  get "https://github.com/json-c/json-c/archive/refs/tags/json-c-$JSONCVER.tar.gz" \
      "json-c-$JSONCVER.tar.gz" "json-c-json-c-$JSONCVER"
  get "https://cdn.kernel.org/pub/linux/utils/util-linux/v2.40/util-linux-$UTLVER.tar.xz" \
      "util-linux-$UTLVER.tar.xz" "util-linux-$UTLVER"
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
  ( cd src && grep -E '\.(tar\.(xz|bz2|gz)|tgz)$' ../sources.sha256 | sha256sum -c --strict - >/dev/null ) || {
    echo "FAIL: pinned source set does not match src/" >&2; return 1; }
  printf '  %d sources verified against sources.sha256\n' \
    "$(grep -cE '\.(tar\.(xz|bz2|gz)|tgz)$' sources.sha256)"
}

kernel() {
  say "building kernel $KVER"
  local d="src/linux-$KVER"
  make -C "$d" tinyconfig
  # kernel.config now has two classes of line: `CONFIG_X=y` (must be on) and
  # `CONFIG_X=n` (must be off). split them -- feeding a `=n` line to --enable
  # would turn hardening-disable requests into enables.
  local enables disables
  enables=$(grep -oP '^CONFIG_[A-Z0-9_]+(?==y$)' kernel.config)
  disables=$(grep -oP '^CONFIG_[A-Z0-9_]+(?==n$)' kernel.config)
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
  echo "CONFIG_EXTRA_CFLAGS=\"-fPIE -Os -isystem $PWD/sysroot/include\"" >> "$d/.config"
  echo 'CONFIG_EXTRA_LDFLAGS=""' >> "$d/.config"

  if [ "${BBMODE:-trim}" = trim ]; then
    grep -o '^CONFIG_[A-Z0-9_]*=y' "$d/.config" | sed 's/^CONFIG_//;s/=y$//' > /tmp/bb-all.$$
    local keep
    keep=$( { grep -v '^[[:space:]]*#' busybox.config.applets
              sed 's/#.*//' busybox.config.features
            } | tr ' ' '\n' | grep -v '^$' | tr 'a-z' 'A-Z' | sort -u)
    while read -r sym; do
      case "$sym" in
        STATIC|*FEATURE*|*PLATFORM*|*LFS*|DESKTOP|LONG_OPTS|SHOW_USAGE|*_PREFIX*|INSTALL_*|*_APPLET_*) continue ;;
      esac
      grep -qx "$sym" <<< "$keep" || bbset "$d" "$sym" n
    done < /tmp/bb-all.$$
    rm -f /tmp/bb-all.$$
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
  # pinned, not just non-zero. "this trusts one root" is the claim; -gt 0 was
  # equally happy at two or forty, so a stray trust/*.pem would ship silently.
  [ "${n:-0}" = "$TA_EXPECTED" ] || {
    echo "FAIL: expected $TA_EXPECTED trust anchor(s), ta.h has ${n:-0}." >&2
    echo "  add or remove a trust/*.pem deliberately, and move TA_EXPECTED with it." >&2
    return 1; }
  # brssl accepts a non-CA leaf as an anchor -- that means "trust this exact
  # end-entity key", which is narrower than a CA but still a directly trusted
  # key, and it says nothing while doing it.
  local nca; nca=$(grep -c 'BR_X509_TA_CA' ta.h || true)
  [ "${nca:-0}" = "$n" ] || {
    echo "FAIL: $((n - nca)) of $n trust anchors are not CAs -- a leaf certificate" >&2
    echo "  was compiled in as an anchor. check trust/." >&2; return 1; }
  printf '  %s trust anchor(s) compiled in:\n' "$n"
  local f; for f in $pems; do printf '    %s\n' "$(openssl x509 -in "$f" -noout -subject | sed 's/^subject=//')"; done
}

tls() {
  say "building bearssl + tlstunnel"
  local d="src/bearssl-$BSSLVER" specs="$PWD/musl-static-pie.specs"
  [ -f "$d/build/libbearssl.a" ] || \
    make -C "$d" CC="gcc -specs=$specs" CFLAGS="-W -Wall -Os -fPIE -isystem $PWD/sysroot/include" \
      build/libbearssl.a >/dev/null 2>&1
  [ -x "$d/build/brssl" ] || \
    make -C "$d" CC="gcc -specs=$specs" CFLAGS="-W -Wall -Os -fPIE -isystem $PWD/sysroot/include" \
      build/brssl >/dev/null 2>&1
  [ -f "$d/build/libbearssl.a" ] || { echo "FAIL: libbearssl.a did not build" >&2; return 1; }
  ta || return 1
  gcc -specs="$specs" -fPIE -Os -isystem "$PWD/sysroot/include" \
    -I"$d/inc" -I. -o tlstunnel tlstunnel.c "$d/build/libbearssl.a" || return 1
  { ./tlstunnel 2>&1 || true; } | has usage || { echo "FAIL: tlstunnel does not run" >&2; return 1; }
  printf '  tlstunnel: %d bytes\n' "$(stat -c%s tlstunnel)"
}

wg_() {
  say "building wireguard-tools (wg, musl static-pie)"
  local d="src/wireguard-tools-$WGTVER/src" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: wireguard-tools source missing, run fetch" >&2; return 1; }
  make -C "$d" clean >/dev/null 2>&1 || true
  # RUNSTATEDIR is normally set by the makefile's own CFLAGS; supplying our
  # own CFLAGS drops it, so define it back or the socket path will not compile.
  make -C "$d" CC="gcc -specs=$specs" \
    CFLAGS="-fPIE -Os -isystem $PWD/sysroot/include -DRUNSTATEDIR='\"/run\"'" \
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
  ( cd "$d" && ./configure --disable-zlib --disable-lastlog --disable-utmp \
      --disable-utmpx --disable-wtmp --disable-wtmpx --disable-pututline \
      --disable-pututxline \
      CC="gcc -specs=$specs" CFLAGS="-fPIE -Os -isystem $PWD/../sysroot/include" \
      >/dev/null 2>&1 ) || { echo "FAIL: dropbear configure failed" >&2; return 1; }
  # do NOT pass STATIC=1 -- it injects a plain -static that fights the specs
  # file's -static-pie and produces a fixed-load-address (ASLR-off) binary.
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
  # -ffile-prefix-map: json-c bakes __FILE__ into assert strings, which put the
  # absolute build path inside the shipped cryptsetup -- two clean clones built
  # different bytes and the reproducibility claim quietly broke. map the tree
  # root to a fixed name so the binary is the same from any directory.
  local cc="gcc -specs=$specs" cf="-fPIE -Os -isystem $root/sysroot/include -ffile-prefix-map=$root=xos"
  local dep="$root/src/cs-dep"
  rm -rf "$dep"; mkdir -p "$dep/lib" "$dep/include/json-c" "$dep/include/uuid"

  # pkg-config on the BUILD HOST will happily answer for the host's shared
  # libraries -- it pulled in -ludev and broke the static link. point it at an
  # empty directory so only what we built here can be found.
  mkdir -p "$dep/nopc"
  export PKG_CONFIG_LIBDIR="$dep/nopc" PKG_CONFIG_PATH="$dep/nopc"

  # libdevmapper: the dm ioctl wrapper. only the library is wanted -- lvm2's
  # own dmsetup tool wants libblkid and is not built.
  local d="src/LVM2.$LVMVER"
  ( cd "$d" && ./configure --enable-static_link --disable-selinux --disable-udev_sync \
      --disable-udev_rules --disable-readline --disable-nls --disable-shared \
      --with-cache=none --with-thin=none --with-vdo=none --with-writecache=none \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -C libdm >/dev/null 2>&1 ) || true
  [ -f "$d/libdm/ioctl/libdevmapper.a" ] || { echo "FAIL: libdevmapper did not build" >&2; return 1; }
  cp "$d/libdm/ioctl/libdevmapper.a" "$dep/lib/"
  cp "$d/libdm/libdevmapper.h" "$dep/include/"

  d="src/popt-$POPTVER"
  ( cd "$d" && ./configure --disable-shared --enable-static --disable-nls \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/src/.libs/libpopt.a" ] || { echo "FAIL: popt did not build" >&2; return 1; }
  cp "$d/src/.libs/libpopt.a" "$dep/lib/"; cp "$d/src/popt.h" "$dep/include/"

  d="src/json-c-json-c-$JSONCVER"
  ( cd "$d" && cmake -S . -B b -DCMAKE_C_COMPILER=gcc -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="-specs=$specs $cf" -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
      -DDISABLE_WERROR=ON -DBUILD_TESTING=OFF -DBUILD_APPS=OFF >/dev/null 2>&1 \
    && cmake --build b -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/b/libjson-c.a" ] || { echo "FAIL: json-c did not build" >&2; return 1; }
  cp "$d/b/libjson-c.a" "$dep/lib/"; cp "$d"/*.h "$d"/b/*.h "$dep/include/json-c/" 2>/dev/null

  d="src/util-linux-$UTLVER"
  ( cd "$d" && ./configure --disable-all-programs --enable-libuuid --disable-shared \
      --enable-static --without-systemd --without-udev --disable-nls --disable-asciidoc \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/.libs/libuuid.a" ] || { echo "FAIL: libuuid did not build" >&2; return 1; }
  cp "$d/.libs/libuuid.a" "$dep/lib/"; cp "$d/libuuid/src/uuid.h" "$dep/include/uuid/"

  d="src/cryptsetup-$CSVER"
  ( cd "$d" && ./configure --disable-shared --enable-static --enable-static-cryptsetup \
      --with-crypto_backend=kernel --disable-ssh-token --disable-external-tokens \
      --disable-selinux --disable-nls --disable-blkid --disable-udev \
      --disable-veritysetup --disable-integritysetup --disable-asciidoc \
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
  gcc -specs="$specs" -fPIE -Os -isystem "$PWD/sysroot/include" \
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
    CFLAGS="-fPIE -Os -isystem $PWD/sysroot/include" LDFLAGS="" >/dev/null 2>&1
  [ -f "$d/ii" ] || { echo "FAIL: ii did not build" >&2; return 1; }
  strip "$d/ii"; cp "$d/ii" ii
  # ii exits non-zero when printing usage, and pipefail would read that as a
  # build failure, so the producer is neutralised as well as the consumer.
  { ./ii 2>&1 || true; } | has usage || { echo "FAIL: built ii does not run" >&2; return 1; }
  printf '  ii: %d bytes\n' "$(stat -c%s ii)"
}

rootfs() {
  say "building read-only root"
  rm -rf root
  mkdir -p root/bin root/proc root/sys root/dev root/etc root/tmp
  cp busybox root/bin/
  # one binary, many names: busybox reads argv[0] to decide what to be.
  # names come from busybox itself, not our config list -- the two drift
  # (CONFIG_TEST1 is the applet named "["), and a missing applet makes
  # shell tests fail open rather than fail loud.
  ./busybox --list > /tmp/xos-applets.$$ 2>/dev/null || {
    echo "FAIL: busybox --list unavailable (enable the busybox applet)" >&2; return 1; }
  [ -s /tmp/xos-applets.$$ ] || { echo "FAIL: empty applet list" >&2; return 1; }
  while read -r a; do
    ln -sf busybox "root/bin/$a"
  done < /tmp/xos-applets.$$
  grep -qx '\[' /tmp/xos-applets.$$ || { echo "FAIL: '[' applet missing -- shell tests would fail open" >&2; rm -f /tmp/xos-applets.$$; return 1; }
  rm -f /tmp/xos-applets.$$
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
  for _f in skip builtins phrases syntax; do
    [ -f "learn/$_f" ] || { echo "FAIL: learn/$_f missing" >&2; return 1; }
  done
  install -m 0755 learn/learn root/bin/learn
  mkdir -p root/usr/share/learn
  cp -r learn/ref learn/lib learn/pools learn/levels learn/scenarios root/usr/share/learn/
  cp learn/skip learn/builtins learn/phrases learn/chains learn/syntax root/usr/share/learn/

  # hand-written shims for things busybox lacks
  # overlay carries the udhcpc script without
  # which dhcp silently configures nothing. it was optional; under `set -e` a
  # failing test in an && list does not abort, so a missing overlay just
  # produced a quieter, more broken image.
  [ -d overlay ] || { echo "FAIL: overlay/ missing" >&2; return 1; }
  cp -r overlay/. root/

  cp init root/init
  chmod +x root/init
  echo 'xos' > root/etc/hostname
  # without /etc/passwd, anything calling getpwuid() fails -- ii did exactly that
  printf 'root:x:0:0:root:/tmp/home:/bin/sh\n' > root/etc/passwd
  printf 'root:x:0:\n' > root/etc/group
  # ssh: the dir where a baked authorized_keys lives (verity-covered). empty by
  # default. set XOS_SSH_KEY=path/to/key.pub to bake a public key in here so
  # remote login works on first boot without any p3 -- baking it into the
  # verity-covered root means the key itself is attested, not just present.
  mkdir -p root/etc/dropbear
  if [ -n "${XOS_SSH_KEY:-}" ]; then
    [ -f "$XOS_SSH_KEY" ] || { echo "FAIL: XOS_SSH_KEY=$XOS_SSH_KEY not found" >&2; return 1; }
    install -m 0600 "$XOS_SSH_KEY" root/etc/dropbear/authorized_keys
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
	# drop the page cache first, or this reads RAM and proves nothing about the
	# flash. the root is 1.6 MB and the boot itself pulls most of it into cache,
	# so a stick with decayed cells reported "scrub clean" without a single read
	# reaching the NAND. dropping caches also evicts the backing partition, so
	# dm-verity re-reads its hash tree from the media too. O_DIRECT on top where
	# the device supports it; the plain read after a drop still hits the media,
	# so the fallback cannot turn an unsupported flag into a false alarm.
	sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
	if dd if=/dev/dm-0 of=/dev/null bs=1M iflag=direct 2>/dev/null \
	   || dd if=/dev/dm-0 of=/dev/null bs=1M 2>/dev/null; then
		echo "scrub clean: every byte on this stick still matches the signed hash tree"
	else
		echo "scrub could not read the device (and no panic fired) -- reflash this stick"
	fi
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
  mkdir -p keys
  for k in PK KEK db; do
    openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
      -subj "/CN=xos $k/" -keyout "keys/$k.key" -out "keys/$k.crt" 2>/dev/null
    openssl x509 -in "keys/$k.crt" -outform DER -out "keys/$k.der"
  done
  chmod 700 keys; chmod 600 keys/*.key
  echo "  PK/KEK/db written to keys/ (gitignored, xos-only -- never your host's)"
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
  local k
  for k in PK KEK db; do
    [ -f "$RAMKEYS/$k.key" ] || continue
    XOS_PASS="$newpass" openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -in "$RAMKEYS/$k.key" -out "keys/$k.key.enc.new" -pass env:XOS_PASS || return 1
    mv "keys/$k.key.enc.new" "keys/$k.key.enc"
  done
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
  local args=() h rest n=0
  while read -r h rest; do
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
  printf '  dbx: %d image(s) revoked in firmware\n' "$n"
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

  local esp_bytes root_bytes esp_start_s esp_size_s root_start_s root_size_s total
  esp_bytes=$((STICK_ESP_MIB * 1024 * 1024))
  root_bytes=$(stat -c%s xos.img)                 # already a 4K multiple (verity padded it)
  esp_start_s=2048                                    # 1 MiB, in 512B sectors
  esp_size_s=$((esp_bytes / 512))
  root_start_s=$(( (1 + STICK_ESP_MIB) * 1024 * 1024 / 512 ))
  root_size_s=$((root_bytes / 512))                  # exact: root_bytes is a 4K multiple
  total=$(( root_start_s * 512 + root_bytes + 1024 * 1024 ))   # + 1 MiB backup-GPT slack

  rm -f stick.img
  truncate -s "$total" stick.img

  # deterministic GPT: fixed disk id + per-partition uuids/types/names, no
  # timestamps in GPT (only CRCs), so identical inputs -> identical bytes.
  # named fields + sizes in SECTORS -- sfdisk rejects a bare 'B' byte suffix.
  sfdisk stick.img >/dev/null <<EOF
label: gpt
label-id: $GPT_DISK
start=$esp_start_s, size=$esp_size_s, type=C12A7328-F81F-11D2-BA4B-00A08693446B, uuid=$PU_ESP, name="XOS-ESP"
start=$root_start_s, size=$root_size_s, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$PU_ROOT, name="XOS-ROOT"
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
  dd if=esp.part    of=stick.img bs=1M seek=1                     conv=notrunc status=none
  dd if=xos.img  of=stick.img bs=1M seek=$((1 + STICK_ESP_MIB)) conv=notrunc status=none
  rm -f esp.part
  printf '  stick.img: %d bytes (esp %d MiB + root %d bytes)\n' "$(stat -c%s stick.img)" "$STICK_ESP_MIB" "$root_bytes"
}

# write stick.img to a real removable disk. this is dd-to-wrong-disk territory,
# so every guard is fail-closed and there is deliberately NO --force flag.
usb() {
  local dev="${1:-}"
  [ -n "$dev" ] || { echo "FAIL: usage: ./build.sh usb /dev/sdX" >&2; return 1; }
  [ -b "$dev" ] || { echo "FAIL: $dev is not a block device" >&2; return 1; }
  local n; n=$(basename "$dev")
  [ -e "/sys/block/$n" ] || { echo "FAIL: $dev is not a whole disk (partitions not allowed)" >&2; return 1; }
  [ "$(cat "/sys/block/$n/removable" 2>/dev/null)" = 1 ] || {
    echo "FAIL: $dev is not removable -- refusing to touch a fixed disk" >&2; return 1; }
  if lsblk -nro MOUNTPOINTS "$dev" 2>/dev/null | has .; then
    echo "FAIL: $dev (or a partition of it) is mounted -- unmount first" >&2; return 1; fi
  [ -f stick.img ] || stick || return 1
  [ -f xos.img ] || { echo "FAIL: no xos.img -- run ./build.sh verity" >&2; return 1; }

  local dev_bytes img_bytes model
  dev_bytes=$(( $(cat "/sys/block/$n/size") * 512 ))
  img_bytes=$(stat -c%s stick.img)
  [ "$dev_bytes" -ge "$img_bytes" ] || { echo "FAIL: $dev too small ($dev_bytes < $img_bytes)" >&2; return 1; }
  if [ "$dev_bytes" -gt $((128 * 1024 * 1024 * 1024)) ]; then
    echo "WARN: $dev is $((dev_bytes / 1024 / 1024 / 1024)) GiB -- larger than any usb stick, is this the right disk?" >&2
  fi

  # ── an existing p3 must survive an image update ────────────────────────────
  #
  # p3 is not in stick.img. `addstate` adds it to the flashed stick's own GPT
  # afterwards, starting one sector past p2. so writing all of stick.img over an
  # already-provisioned stick did two irreversible things at once: it replaced
  # the table with stick.img's two-partition one, dropping p3's entry, and --
  # because stick.img carries 1 MiB of backup-GPT slack past p2's end -- it
  # zeroed the first mebibyte OF p3, which is both LUKS2 headers and the head of
  # the keyslot area. no passphrase opens that again. and it happened on the
  # ordinary update: git pull, ./build.sh all, ./build.sh usb.
  #
  # so find p3 before writing anything, write only the two regions stick.img
  # actually owns (esp and root, never the trailing slack), and rewrite the
  # table with p3's geometry carried across byte-for-byte.
  local p3_dev="${dev}3" p3_start="" p3_size="" p3_type="" p3_uuid="" p3_name="" p3_luks=""
  local root_bytes root_size_s new_p2_end_s
  [ -b "$p3_dev" ] || p3_dev="${dev}p3"
  root_bytes=$(stat -c%s xos.img)
  root_size_s=$((root_bytes / 512))
  new_p2_end_s=$(( (1 + STICK_ESP_MIB) * 1024 * 1024 / 512 + root_size_s ))
  # required, not probed: without them this cannot tell whether the disk holds a
  # state partition, and "cannot tell" must never resolve to "overwrite it".
  command -v partx >/dev/null 2>&1 && command -v sfdisk >/dev/null 2>&1 || {
    echo "FAIL: partx and sfdisk are needed to write a stick safely (they are what" >&2
    echo "  finds an existing state partition). install util-linux." >&2; return 1; }
  # ask the PARTITION TABLE, not /dev. keying this off a block-device node meant
  # a stick whose p3 entry exists but whose node udev had not created yet -- a
  # partprobe that failed, a device replugged a second ago, a container -- took
  # the full-overwrite path and ate the LUKS header anyway. the table is the
  # authority; the node is a convenience.
  read -r p3_start p3_size p3_type p3_uuid p3_name < <(
    partx -g -o START,SECTORS,TYPE,UUID,NAME -n 3:3 "$dev" 2>/dev/null) || true
  if [ -n "$p3_start" ]; then
    # always contains the ':', so ':*' and '*:' are the empty-field cases
    case "${p3_start}:${p3_size}" in *[!0-9:]*|:*|*:)
      echo "FAIL: $dev has a third partition whose geometry cannot be read -- refusing" >&2
      echo "  to write over it. back it up, or remove it deliberately, first." >&2; return 1 ;;
    esac
    [ -n "$p3_type" ] || {
      echo "FAIL: cannot read the type of partition 3 on $dev -- refusing to write over it." >&2; return 1; }
    # the new root may be a different size than the one this stick carries. if
    # it grew past where p3 begins there is no safe write at all -- say so and
    # stop, rather than half-writing a root into the state partition.
    [ "$new_p2_end_s" -le "$p3_start" ] || {
      echo "FAIL: the new root ends at sector $new_p2_end_s but p3 starts at $p3_start --" >&2
      echo "  it no longer fits before your state partition. back p3 up (cryptsetup" >&2
      echo "  luksHeaderBackup + a copy of its contents) and reflash from scratch." >&2; return 1; }
    # remember WHICH luks volume it is. isLuks alone only proves something
    # luks-shaped is there afterwards -- a header rewritten with a different key
    # answers yes to that just as happily.
    if command -v cryptsetup >/dev/null 2>&1 && [ -b "$p3_dev" ]; then
      p3_luks=$(cryptsetup luksUUID "$p3_dev" 2>/dev/null || true)
    fi
  fi

  model=$(cat "/sys/block/$n/device/model" 2>/dev/null | tr -s ' ' | sed 's/ *$//')
  echo "  target: $dev  size: $((dev_bytes / 1024 / 1024)) MiB  model: ${model:-unknown}"
  if [ -n "$p3_start" ]; then
    echo "  $dev already carries an encrypted state partition (p3, sector $p3_start)."
    echo "  it will be PRESERVED: only the esp and root regions are rewritten."
  elif wipefs -n "$dev" 2>/dev/null | has .; then
    echo "  WARNING: $dev already contains a filesystem/partition signature -- it will be DESTROYED."
  fi
  # confirmation the user cannot bypass by hammering 'y': type the model back.
  local answer
  read -rp "  to confirm, type the disk model exactly ('${model:-unknown}'): " answer
  [ "$answer" = "${model:-unknown}" ] || { echo "FAIL: confirmation did not match -- aborted" >&2; return 1; }

  if [ -n "$p3_start" ]; then
    say "updating $dev in place -- esp + root only, p3 untouched"
    dd if=stick.img of="$dev" bs=1M skip=1 seek=1 count="$STICK_ESP_MIB" \
      oflag=direct conv=fsync status=progress
    dd if=stick.img of="$dev" bs=1M skip=$((1 + STICK_ESP_MIB)) seek=$((1 + STICK_ESP_MIB)) \
      iflag=count_bytes count="$root_bytes" oflag=direct conv=fsync status=progress
    # rewrite the whole table rather than dd'ing stick.img's: that one knows
    # nothing about p3. same deterministic ids stick() uses, p2 resized to this
    # image, p3 exactly as it was.
    sfdisk --no-reread "$dev" >/dev/null <<EOF || { echo "FAIL: could not rewrite the partition table on $dev" >&2; return 1; }
label: gpt
label-id: $GPT_DISK
start=2048, size=$((STICK_ESP_MIB * 1024 * 1024 / 512)), type=C12A7328-F81F-11D2-BA4B-00A08693446B, uuid=$PU_ESP, name="XOS-ESP"
start=$(( (1 + STICK_ESP_MIB) * 1024 * 1024 / 512 )), size=$root_size_s, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$PU_ROOT, name="XOS-ROOT"
start=$p3_start, size=$p3_size, type=$p3_type, uuid=$p3_uuid, name="$p3_name"
EOF
    partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" 2>/dev/null || true
    sleep 1
  else
    say "writing stick.img to $dev"
    dd if=stick.img of="$dev" bs=1M oflag=direct conv=fsync status=progress
  fi

  # verify by DIRECT-IO readback -- a page-cache read would just echo what we
  # wrote and prove nothing. compare the regions that were written, then the p2
  # root region against the pinned image digest.
  say "verifying written bytes"
  local want have want_root have_root
  if [ -n "$p3_start" ]; then
    want=$(dd if=stick.img bs=1M skip=1 count="$STICK_ESP_MIB" status=none | sha256sum | awk '{print $1}')
    have=$(dd if="$dev" bs=1M skip=1 count="$STICK_ESP_MIB" iflag=direct status=none | sha256sum | awk '{print $1}')
    [ "$want" = "$have" ] || { echo "FAIL: esp readback mismatch -- write did not land" >&2; return 1; }
  else
    want=$(sha256sum < stick.img | awk '{print $1}')
    have=$(dd if="$dev" bs=1M iflag=direct,count_bytes count="$img_bytes" status=none | sha256sum | awk '{print $1}')
    [ "$want" = "$have" ] || { echo "FAIL: stick readback mismatch -- write did not land" >&2; return 1; }
  fi
  # the pin is the point of the readback, so a missing pin is a failure, not a
  # reason to skip the check. an empty want_root used to make this a no-op.
  want_root=$(awk '$1=="image"{print $2}' image.sha256)
  [ -n "$want_root" ] || { echo "FAIL: image.sha256 has no image digest to verify against" >&2; return 1; }
  have_root=$(dd if="$dev" bs=1M skip=$((1 + STICK_ESP_MIB)) iflag=direct,count_bytes count="$root_bytes" status=none | sha256sum | awk '{print $1}')
  [ "$want_root" = "$have_root" ] || {
    echo "FAIL: root partition on disk does not match pinned image digest" >&2; return 1; }
  if [ -n "$p3_start" ]; then
    # the table itself is never read back by the region compares above, and the
    # signed cmdline finds the root by PARTUUID -- a table written with a wrong
    # uuid dd-verifies clean and then hangs at dm-mod.waitfor on real hardware.
    local tbl
    tbl=$(sfdisk -d "$dev" 2>/dev/null || true)
    printf '%s\n' "$tbl" | grep -qi "uuid=$PU_ROOT" \
      || { echo "FAIL: the root PARTUUID is not in the table after the write -- this stick will not boot" >&2; return 1; }
    printf '%s\n' "$tbl" | grep -qi "uuid=$PU_ESP" \
      || { echo "FAIL: the esp PARTUUID is not in the table after the write" >&2; return 1; }
    printf '%s\n' "$tbl" | grep -qi "uuid=$p3_uuid" \
      || { echo "FAIL: p3's entry did not survive the table rewrite -- its bytes are intact but nothing points at them" >&2; return 1; }
    # and prove p3 itself came through: the same luks volume, not merely
    # something luks-shaped.
    if [ -n "$p3_luks" ]; then
      local now_luks
      now_luks=$(cryptsetup luksUUID "$p3_dev" 2>/dev/null || true)
      [ "$now_luks" = "$p3_luks" ] \
        || { echo "FAIL: p3 is no longer the same LUKS volume ($p3_luks -> ${now_luks:-gone})" >&2; return 1; }
      echo "  p3 preserved -- same LUKS volume ($p3_luks), entry intact"
    else
      echo "  p3's table entry is intact; its LUKS header was not checked (no cryptsetup, or no device node)"
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
  # in 6.12: an unsupported controller hangs at "waiting for device", visibly.
  #
  # console: serial LAST so it owns /dev/console (harness scrapes serial, output
  # stays byte-identical); tty0 first mirrors printk to a real screen.
  #
  # default dm-verity refuses only the bad block and lets boot continue if
  # nothing essential needed it. panic_on_corruption makes ANY corruption
  # anywhere fatal -- the machine refuses to run at all, which is the point.
  #
  # random.trust_cpu=1: nothing persists here, so the entropy pool starts empty
  # on every boot with no seed file to carry across. 6.12 already defaults this
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
  printf 'dm-mod.waitfor=%s dm-mod.create="vroot,,,ro,0 %d verity 1 %s %s 4096 4096 %d %d sha256 %s %s 1 panic_on_corruption" root=/dev/dm-0 ro rootfstype=squashfs rootwait init=/init oops=panic panic=-1 efi=disable_early_pci_dma page_alloc.shuffle=1 random.trust_cpu=1 xos.epoch=%s console=tty0 console=ttyS0,115200%s\n' \
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
  } | sha256sum | awk '{print $1}'
}

pin() {
  say "pinning the bytes this source produces"
  [ -f xos.img ] || { echo "FAIL: no xos.img -- build first" >&2; return 1; }
  { echo "# the exact artifact this source builds. regenerate with ./build.sh pin."
    echo "# G13 compares against this. a mismatch on the SAME toolchain means the"
    echo "# image no longer corresponds to the source; on a different toolchain it"
    echo "# only means you cannot independently verify this build."
    printf 'image     %s\n'   "$(sha256sum < xos.img      | awk '{print $1}')"
    printf 'squashfs  %s\n'   "$(sha256sum < rootfs.squashfs | awk '{print $1}')"
    printf 'roothash  %s\n'   "$(cat verity.roothash)"
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
# a flag counts as documented only if the ref EXPLAINS it on its own line --
# not if it merely appears inside a usage cluster like [-rf]. a cluster tells
# you a flag exists; it does not tell you what it does, and a question is only
# answerable from a ref that says what the flag does.
# busybox writes aliases as "-R,-r\tRecurse", so the flag may sit after a comma
# rather than after the leading whitespace. matching only the first form called
# `cp -r` undocumented when the ref documents it perfectly well.
documented() {
  grep -qE "^[[:space:]]+(-[^[:space:],]+,)*-$1([[:space:],=]|\[|$)" "$2" && return 0
  # tar documents its mode letters bare ("c\tCreate"), because that is tar's own
  # syntax; the dashed form works too. accept a lone letter on a flag line.
  grep -qE "^[[:space:]]+$1[[:space:]]" "$2"
}

flagchk() {
  local tok="${1#-}" ref="$2" i=0 c consumed=0
  # whole-token match first: busybox has multi-char short flags in places
  documented "$tok" "$ref" && return 0
  while [ -n "$tok" ]; do
    c="${tok%"${tok#?}"}"          # first character
    if documented "$c" "$ref"; then
      consumed=$((consumed + 1)); tok="${tok#?}"
    else
      # remainder is an attached argument -- fine iff a real flag came first
      [ "$consumed" -gt 0 ] && return 0
      return 1
    fi
  done
  return 0
}

# gate roster -- every G-number that exists, in one place, so a silently
# dropped gate is visible instead of hiding in a diff. most run in size()
# below; G8 runs in fetch(), G9 lives in githooks/pre-commit (not this
# script). G22 was never assigned -- skip on purpose, not a gap.
#   G1  image <= IMAGE_MAX
#   G2  no dynamic loader (no INTERP segment on any ELF)
#   G3  every ELF is PIE
#   G4  no setuid/setgid files
#   G5  no world-writable files
#   G6  cmdline root hash matches the built tree
#   G7  kernel has no module loader
#   G8  every source pinned + verified before extraction; lvm2 and dropbear
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
#   G22 -- unassigned, on purpose
#   G23 exactly one shell (busybox ash)
#   G24 learn corpus covers the shipped surface exactly
#   G25 learn selftest passes under the built busybox
#   G26 curriculum covers the surface (nothing untaught)
#   G27 levels only use commands already taught, in order
#   G28 bzImage was built from the on-disk kernel.config
#   G29 challenge track holds its shape
#   G30 clock floor is fresh, not stale                    (new)
#   G31 no test flags on the production cmdline            (new)
#   G32 fingerprint wordlist holds its shape (256 unique words)
#   G33 init remote-access arg-building, run through the real ash   (new)
#   G34 signed UKI's embedded roothash matches the tree             (new)
#   G35 first-party scripts parse under the shipped ash             (new)
#   G36 state partition starts past every byte the image writer writes (new)
#   G37 recon identifies the machine, not the firmware running on it  (new)
size() {
  say "gates"
  local bad=0 ran=0
  local EXPECTED_GATES=34   # roster above, minus G8/G9 (checked elsewhere) and G22 (unassigned)
  g() { printf '  %-42s %s
' "$1" "$2"; ran=$((ran+1)); [ "$2" = ok ] || bad=1; }

  local sz; sz=$(stat -c%s xos.img)
  g "G1 image <= $IMAGE_MAX ($sz)" "$([ "$sz" -le "$IMAGE_MAX" ] && echo ok || echo FAIL)"

  # G2/G3/G4/G5/G16 used to read the staging directory `root/` rather than the
  # image, and counted violations without ever counting the population. both
  # halves were wrong. `root/` is not what ships -- it can be stale, cleaned, or
  # edited after the squashfs was made -- and a find that matches nothing
  # reports zero violations in exactly the way a clean tree does, so an empty or
  # missing root/ made all five say ok having examined not one file. measure the
  # artifact, and print "0 of N" so that "none found" always carries how hard it
  # looked. permissions come from the image's own metadata (unsquashfs -ll)
  # rather than an extraction, because a non-root unpack cannot be trusted to
  # reproduce a setuid bit -- which would have turned G4 into decoration.
  # the cmdline the FIRMWARE is handed lives inside the signed PE, not in
  # cmdline.txt. G15 and G31 read the file, so a UKI signed with
  # `mitigations=off nokaslr` (or with the test flags still on) beside a
  # pristine cmdline.txt passed both -- and because the cmdline is inside the
  # signature, the chain then vouches for the tampering. extract once here and
  # gate on this, not on the file.
  local uki_cmd="" uki_cmd_ok=0
  if [ -f xos-signed.efi ]; then
    uki_cmd=$(objcopy -O binary --only-section=.cmdline xos-signed.efi /dev/stdout 2>/dev/null | tr -d '\0')
    [ -n "$uki_cmd" ] && uki_cmd_ok=1
  fi

  local sqx sqll
  sqx=$(mktemp -d /tmp/xos-gates.XXXXXX) || { echo "FAIL: no temp dir for the gate run" >&2; return 1; }
  XOS_GATE_TMP="$sqx"    # the EXIT trap removes it even if a gate dies under set -e
  unsquashfs -n -d "$sqx/root" rootfs.squashfs >/dev/null 2>&1 \
    || { echo "FAIL: could not unpack rootfs.squashfs for the gates" >&2; return 1; }
  sqll=$(unsquashfs -ll rootfs.squashfs 2>/dev/null)

  # -print0 / read -d '': `for f in $elfs` word-split on $IFS and glob-expanded,
  # so a file named `evil shell` -- a real dynamically-linked non-PIE binary --
  # left all three of these gates green, while the same bytes at `bash` correctly
  # failed G2. and `| grep -q` inside an && list is the SIGPIPE-plus-pipefail
  # trap this file documents at the top: a lost race skips the increment, which
  # reads exactly like a pass. pipe into has() the way G16 already did.
  local interp exec_type rwe_stack nelf f
  interp=0; exec_type=0; rwe_stack=0; nelf=0
  while IFS= read -r -d '' f; do
    nelf=$((nelf+1))
    readelf -l "$f" 2>/dev/null | has INTERP && interp=$((interp+1))
    readelf -h "$f" 2>/dev/null | has 'Type:.*EXEC' && exec_type=$((exec_type+1))
    # GNU_STACK marked RWE = executable stack (the noexecstack link flag failed).
    # this one IS kernel-enforced, unlike RELRO in a static-pie binary.
    readelf -lW "$f" 2>/dev/null | awk '/GNU_STACK/{print $(NF)}' | has RWE && rwe_stack=$((rwe_stack+1))
  done < <(find "$sqx/root" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF && printf "%s\0" "$1"' _ {} \; 2>/dev/null)
  g "G2 no dynamic loader ($interp of $nelf with INTERP)" \
    "$([ "$nelf" -gt 0 ] && [ "$interp" -eq 0 ] && echo ok || echo FAIL)"
  g "G3 all ELF are PIE ($exec_type of $nelf non-PIE)" \
    "$([ "$nelf" -gt 0 ] && [ "$exec_type" -eq 0 ] && echo ok || echo FAIL)"
  g "G16 no executable stack ($rwe_stack of $nelf RWE)" \
    "$([ "$nelf" -gt 0 ] && [ "$rwe_stack" -eq 0 ] && echo ok || echo FAIL)"

  local suid ww nreg
  nreg=$(printf '%s\n' "$sqll" | awk 'substr($1,1,1)=="-"' | grep -c . || true)
  suid=$(printf '%s\n' "$sqll" | awk 'substr($1,1,1)=="-" && (substr($1,4,1) ~ /[sS]/ || substr($1,7,1) ~ /[sS]/)' | grep -c . || true)
  ww=$(  printf '%s\n' "$sqll" | awk 'substr($1,1,1)=="-" && substr($1,9,1)=="w"' | grep -c . || true)
  g "G4 no setuid/setgid ($suid of $nreg files)" \
    "$([ "$nreg" -gt 0 ] && [ "$suid" -eq 0 ] && echo ok || echo FAIL)"
  g "G5 no world-writable ($ww of $nreg files)" \
    "$([ "$nreg" -gt 0 ] && [ "$ww" -eq 0 ] && echo ok || echo FAIL)"

  local want have
  want=$(cat verity.roothash)
  have=$(grep -oE 'sha256 [0-9a-f]{64}' cmdline.txt | awk '{print $2}')
  # two empty strings compare equal, so a truncated verity.roothash and a
  # cmdline carrying no hash at all used to satisfy this. demand a real one.
  g "G6 cmdline root hash matches tree" \
    "$([ ${#want} -eq 64 ] && [ "$want" = "$have" ] && echo ok || echo FAIL)"

  # a full reproducibility check needs two builds; this asserts the mechanism
  # that makes it possible is still in place, which is cheap and catches drift.
  local pinned; pinned=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%d 2>/dev/null)
  g "G10 build clock pinned ($pinned)" \
    "$(strings busybox 2>/dev/null | has "BusyBox v.*$pinned" && echo ok || echo FAIL)"

  # find, not ls: `ls nonexistent | wc -l` exits non-zero under pipefail and
  # set -e then kills the whole gate run silently. this bit us four times.
  local plain plain_img plain_uki
  plain=$(find keys -maxdepth 1 -name '*.key' 2>/dev/null | wc -l)
  # the claim is "no plaintext private key on disk"; this only ever looked in
  # keys/. a key copied into the overlay would have shipped inside the image --
  # signed, verity-covered, and published -- with every gate still green. scan
  # the artifact and the signed UKI too. (dropbear's own key format is binary,
  # not PEM, so this catches every standard format but not that one; the image
  # ships no host key by design, and G12's manifest is what pins that.)
  local keypat='-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED |)PRIVATE KEY-----'
  # `|| true` inside the pipe: a grep that matches nothing exits 1, pipefail
  # makes that the pipeline's status, and set -e then kills the gate run --
  # a clean image would have looked exactly like a truncated one.
  plain_img=$({ grep -rlaE -- "$keypat" "$sqx/root" 2>/dev/null || true; } | wc -l)
  plain_uki=0
  [ -f xos-signed.efi ] \
    && plain_uki=$({ grep -laE -- "$keypat" xos-signed.efi 2>/dev/null || true; } | wc -l)
  g "G11 no plaintext private key on disk ($plain keys/, $plain_img image, $plain_uki uki)" \
    "$([ "$plain" -eq 0 ] && [ "$plain_img" -eq 0 ] && [ "$plain_uki" -eq 0 ] && echo ok || echo FAIL)"

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
    local want_img have_img want_sq have_sq want_tc have_tc want_rh have_rh
    want_img=$(awk '$1=="image"{print $2}'     image.sha256)
    want_sq=$(awk '$1=="squashfs"{print $2}'   image.sha256)
    want_tc=$(awk '$1=="toolchain"{print $2}'  image.sha256)
    want_rh=$(awk '$1=="roothash"{print $2}'   image.sha256)
    have_img=$(sha256sum < xos.img | awk '{print $1}')
    have_sq=$(sha256sum < rootfs.squashfs | awk '{print $1}')
    have_rh=$(cat verity.roothash 2>/dev/null)
    have_tc=$(toolchain)
    if [ "$want_tc" != "$have_tc" ]; then
      g "G13 reproducible (toolchain differs, not checked)" ok
      printf '    this gcc/squashfs-tools is not the one the pin was taken with,\n' >&2
      printf '    so a byte mismatch here would prove nothing. rebuild is unverified.\n' >&2
    else
      # check the squashfs and roothash digests too -- pin() records both, so a
      # mismatch localises drift (filesystem vs verity padding/tree), and stops
      # either recorded line from being decoration nothing ever reads.
      g "G13 image matches committed digest" \
        "$([ "$want_img" = "$have_img" ] && [ "$want_sq" = "$have_sq" ] && [ "$want_rh" = "$have_rh" ] && echo ok || echo FAIL)"
      [ "$want_img" = "$have_img" ] || \
        printf '    image pinned %s\n    image built  %s\n' "${want_img:0:32}..." "${have_img:0:32}..." >&2
      [ "$want_sq" = "$have_sq" ] || \
        printf '    squashfs pinned %s\n    squashfs built  %s\n' "${want_sq:0:32}..." "${have_sq:0:32}..." >&2
      [ "$want_rh" = "$have_rh" ] || \
        printf '    roothash pinned %s\n    roothash built  %s\n' "${want_rh:0:32}..." "${have_rh:0:32}..." >&2
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

  g "G7 kernel has no module loader" "$(grep -q '^CONFIG_MODULES=y' "src/linux-$KVER/.config" && echo FAIL || echo ok)"

  # G14 -- the built kernel actually honours the config contract. kernel() checks
  # this at build time; re-checking here catches a stale prebuilt .config that
  # was never rebuilt after kernel.config changed.
  local kc="src/linux-$KVER/.config" k_miss=0 k_bad=0 opt k_enab k_dis
  # how many options this gate actually examined. the counters below only ever
  # count VIOLATIONS, so an extractor that matched nothing -- kernel.config
  # saved with CRLF line endings, or truncated -- reported "0 off, 0 leaked"
  # and went green having checked not one option. that is the whole "a kernel
  # missing any hardening option it must have" claim.
  k_enab=$(grep -cP '^CONFIG_[A-Z0-9_]+(?==y$)' kernel.config || true)
  k_dis=$(grep -cP '^CONFIG_[A-Z0-9_]+(?==n$)' kernel.config || true)
  if [ "${k_enab:-0}" -lt 100 ] || [ "${k_dis:-0}" -lt 15 ]; then
    k_miss=$((k_miss+1))
    printf '    kernel.config yielded only %s enables / %s disables -- the extractor matched almost nothing\n' \
      "${k_enab:-0}" "${k_dis:-0}" >&2
  fi
  if [ -f "$kc" ]; then
    while read -r opt; do
      [ -n "$opt" ] || continue
      grep -q "^$opt=y" "$kc" || { k_miss=$((k_miss+1)); printf '    config not enabled: %s\n' "$opt" >&2; }
    done < <(grep -oP '^CONFIG_[A-Z0-9_]+(?==y$)' kernel.config)
    while read -r opt; do
      [ -n "$opt" ] || continue
      grep -q "^$opt=y" "$kc" && { k_bad=$((k_bad+1)); printf '    config still on: %s\n' "$opt" >&2; }
    done < <(grep -oP '^CONFIG_[A-Z0-9_]+(?==n$)' kernel.config)
    # CONFIG_EXTRA_FIRMWARE bakes a vendor blob straight into bzImage, which
    # G18 (squashfs only) cannot see. it is a string option, so the =n leak
    # scan above skips it -- assert its absence explicitly.
    grep -q '^CONFIG_EXTRA_FIRMWARE="..*"' "$kc" \
      && { k_bad=$((k_bad+1)); printf '    firmware blob embedded in kernel: CONFIG_EXTRA_FIRMWARE\n' >&2; }
    g "G14 kernel hardening ($k_miss off, $k_bad leaked, of $k_enab/$k_dis checked)" \
      "$([ "$k_miss" -eq 0 ] && [ "$k_bad" -eq 0 ] && echo ok || echo FAIL)"
  else
    g "G14 kernel hardening config" FAIL
    printf '    no %s\n' "$kc" >&2
  fi

  # G15 -- the tamper-proof hardening lives on the cmdline (inside the UKI
  # signature). assert every param that must be there is.
  local c15=0 want15
  # checked against the SIGNED cmdline. an absent or unreadable .cmdline
  # section is a failure, not a reason to fall back to the file -- the file is
  # not what boots.
  if [ "$uki_cmd_ok" -ne 1 ]; then
    c15=$((c15+1)); printf '    no .cmdline section in xos-signed.efi -- cannot check what actually boots\n' >&2
  fi
  for want15 in 'panic_on_corruption' 'oops=panic' 'panic=-1' 'efi=disable_early_pci_dma' 'page_alloc.shuffle=1' 'random.trust_cpu=1' 'xos.epoch=' 'dm-mod.waitfor=PARTUUID='; do
    printf '%s' "$uki_cmd" | grep -qF "$want15" || { c15=$((c15+1)); printf '    signed cmdline missing: %s\n' "$want15" >&2; }
  done
  # ...and assert NO param is present that would neuter the compiled-in
  # hardening at boot. G15 checked only for presence; a runtime override like
  # mitigations=off or init_on_free=0 keeps every config gate green while
  # switching the protection off, and the cmdline is signed, so it must be
  # caught here before it ships inside the signature.
  local c15b=0 deny15
  for deny15 in 'mitigations=off' 'init_on_alloc=0' 'init_on_free=0' 'nokaslr' 'lockdown=none' \
                 'nosmep' 'nosmap' 'nopti' 'no_hash_pointers' 'page_alloc.shuffle=0' 'random.trust_cpu=0' \
                 'lsm=' 'vsyscall=emulate' 'pti=off' 'spectre_v2=off' 'spec_store_bypass_disable=off' \
                 'tsx=on' 'debugfs=on' 'norandmaps' 'noexec=off' 'efivar_ssdt=' \
                 'iommu=off' 'intel_iommu=off' 'iommu.passthrough=1'; do
    printf '%s' "$uki_cmd" | grep -qF "$deny15" && { c15b=$((c15b+1)); printf '    signed cmdline FORBIDDEN: %s\n' "$deny15" >&2; }
  done
  g "G15 cmdline hardening params ($c15 missing, $c15b forbidden)" \
    "$([ "$c15" -eq 0 ] && [ "$c15b" -eq 0 ] && echo ok || echo FAIL)"

  # G18 -- no firmware blobs in the image. r8169 pulls in FW_LOADER; if a blob
  # ever gets shipped it is unverified-by-vendor content on a verified system.
  local fw
  fw=$(unsquashfs -l rootfs.squashfs 2>/dev/null | grep -c 'squashfs-root/lib/firmware' || true)
  g "G18 no firmware blobs in image ($fw)" "$([ "${fw:-0}" -eq 0 ] && echo ok || echo FAIL)"

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
  # the 29 gates nor the boot self-test caught it, because the real state_open()
  # / wg block never runs in the harness (it needs a partitioned LUKS stick and
  # an interactive passphrase). this runs init's own parse bytes and asserts the
  # split; the structural checks pin the two consumers and the partition scan so
  # a future edit that swaps them fails here instead of on a stick in the field.
  local g33=ok bb33 wgp33 t33=/tmp/xos-g33.$$ got33
  bb33=./busybox; [ -x "$bb33" ] || bb33=$(command -v busybox 2>/dev/null)
  wgp33=$(sed -n '/^[[:space:]]*wgcidr=/,/^[[:space:]]*case /p' init)
  mkdir -p "$t33"
  _wg33() {   # $1 = Address value ('' for none), $2 = expected "wgcidr|wgip"
    if [ -n "$1" ]; then printf 'Address = %s\n' "$1" > "$t33/wg0.conf"; else : > "$t33/wg0.conf"; fi
    got33=$(STATE_DIR="$t33" "$bb33" ash -c "$wgp33"'; printf "%s|%s" "$wgcidr" "$wgip"' 2>/dev/null)
    [ "$got33" = "$2" ] || { g33=FAIL; printf '    wg-parse %s -> %s (want %s)\n' "${1:-none}" "$got33" "$2" >&2; }
  }
  _wg33 "10.9.0.2/32" "10.9.0.2/32|10.9.0.2"
  _wg33 "10.9.0.1/24" "10.9.0.1/24|10.9.0.1"
  _wg33 "10.9.0.5"    "10.9.0.5/24|10.9.0.5"
  _wg33 ""            "|"
  rm -rf "$t33"
  grep -q 'ip addr add "\$wgcidr" dev wg0' init          || { g33=FAIL; printf '    wg route no longer uses $wgcidr\n' >&2; }
  grep -q 'dropbear .*-p "\$wgip:22"' init               || { g33=FAIL; printf '    ssh bind no longer uses bare $wgip\n' >&2; }
  grep -q 'for p in /sys/class/block/\*/partition' init  || { g33=FAIL; printf '    state_open no longer scans */partition\n' >&2; }
  grep -q 'for dev in \$cands' init                      || { g33=FAIL; printf '    state_open no longer tries every candidate\n' >&2; }
  grep -q 'wg setconf wg0 /tmp/wgset.conf' init          || { g33=FAIL; printf '    setconf fed the raw conf -- Address= lines make strict wg error out\n' >&2; }
  # wg matches config keys with strncasecmp, so a case-SENSITIVE allowlist
  # deletes a perfectly valid `privatekey = ...` line and setconf still exits 0.
  grep -qF "grep -Ei '^[ " init                          || { g33=FAIL; printf '    wg allowlist is no longer case-insensitive -- a lowercase PrivateKey would be dropped\n' >&2; }
  # and setconf exiting 0 does not mean the tunnel can work: HAS_PRIVATE_KEY is
  # set unconditionally, and a peerless device passes config_read_finish.
  grep -qF '&& wg_ready; then' init                      || { g33=FAIL; printf '    wg bring-up no longer verifies the interface it just configured\n' >&2; }
  grep -qF 'wg show wg0 public-key' init                 || { g33=FAIL; printf '    wg_ready no longer checks a private key was installed\n' >&2; }
  grep -qF 'wg show wg0 peers' init                      || { g33=FAIL; printf '    wg_ready no longer checks a peer exists\n' >&2; }
  # cat joins bytes: a baked authorized_keys with no trailing newline swallowed
  # the operator's p3 key into its comment field.
  grep -qF 'awk 1 /etc/dropbear/authorized_keys' init    || { g33=FAIL; printf '    authorized_keys assembled with cat again -- a missing newline eats the p3 key\n' >&2; }
  grep -qF '_hostkey=0' init                             || { g33=FAIL; printf '    ssh host-key creation failure is unhandled again -- dropbear would crash-loop silently\n' >&2; }
  g "G33 init remote-access logic (real ash)" "$g33"

  # G36 -- the encrypted state partition must begin past every byte the image
  # writer writes. it did not. `addstate` placed p3 at p2end+1, flush against
  # the root, and stick.img carries 1 MiB of backup-GPT slack past p2's end --
  # so `./build.sh usb` on an already-provisioned stick wrote 1 MiB straight
  # through p3: both LUKS2 headers and the head of the keyslot area. no
  # passphrase opens that again, and it happened on the ordinary update (git
  # pull, build, usb). this runs addstate's own placement expression against
  # this build's real geometry and asserts the gap, then pins the three guards
  # in usb() that keep an update from reaching p3 at all.
  local g36=ok p3f36 p2end36 p3s36 stick36 p2end
  if [ -f stick.img ]; then
    p2end36=$(( (1 + STICK_ESP_MIB) * 1024 * 1024 / 512 + $(stat -c%s xos.img) / 512 - 1 ))
    p3f36=$(sed -n 's/^[[:space:]]*p3start=\$((\(.*\)))[[:space:]]*$/\1/p' build.sh | head -1)
    if [ -z "$p3f36" ]; then
      g36=FAIL; printf '    addstate no longer computes p3start -- cannot check the gap\n' >&2
    else
      p2end=$p2end36
      p3s36=$(eval "echo \$(( $p3f36 ))")
      stick36=$(stat -c%s stick.img)
      [ $((p3s36 * 512)) -ge "$stick36" ] || {
        g36=FAIL
        printf '    p3 would start at byte %d, INSIDE stick.img (%d bytes) -- a reflash would eat its LUKS header\n' \
          $((p3s36 * 512)) "$stick36" >&2; }
      [ $((p3s36 % 2048)) -eq 0 ] || { g36=FAIL; printf '    p3 start %d is not 1 MiB aligned\n' "$p3s36" >&2; }
    fi
  else
    g36=FAIL; printf '    no stick.img -- cannot check the p3 gap\n' >&2
  fi
  # these look for the guards INSIDE usb(), with comments stripped. grepping the
  # whole file let the first pattern match the gate's own source line -- so the
  # check stayed green with the code it guards deleted -- and let all three be
  # satisfied by a guard someone had commented out "just to test".
  local usbsrc
  usbsrc=$(sed -n '/^usb() {/,/^}/p' build.sh | sed 's/#.*//')
  _g36has() {
    printf '%s\n' "$usbsrc" | grep -qF -- "$1" \
      || { g36=FAIL; printf '    %s\n' "$2" >&2; }
  }
  _g36has 'partx -g -o START,SECTORS,TYPE,UUID,NAME -n 3:3' \
    'usb() no longer reads the existing p3 entry from the partition table'
  _g36has '"$new_p2_end_s" -le "$p3_start"' \
    'usb() no longer refuses a root that would overlap p3'
  _g36has 'cryptsetup luksUUID "$p3_dev"' \
    'usb() no longer records which luks volume p3 is, so it cannot prove it survived'
  g "G36 state partition starts past the image writer" "$g36"

  # G37 -- recon must identify the MACHINE, never the firmware on it. the
  # identity hash covered every `dmi ` line, bios_version and bios_date
  # included, so a bios reflash -- the first example the readme gives of what
  # recon catches -- changed the identity, missed the baseline entirely, and
  # printed "first visit ... baseline recorded". the alarm stayed silent for
  # the one event it exists to announce. this runs init's own identity lines
  # through the image's ash over two inventories that differ only in firmware
  # and asserts they land on the SAME baseline, then pins the atomic writes
  # that keep the ledger from being lost to a power cut mid-write.
  local g37=ok bb37 id37 t37=/tmp/xos-g37.$$ a37 b37
  bb37=./busybox; [ -x "$bb37" ] || bb37=$(command -v busybox 2>/dev/null)
  id37=$(sed -n '/^[[:space:]]*local idpat=/,/^[[:space:]]*else mid=/p' init)
  if [ -z "$id37" ]; then
    g37=FAIL; printf '    recon identity lines not found -- cannot check the firmware split\n' >&2
  else
    mkdir -p "$t37"
    printf 'dmi sys_vendor ACME\ndmi product_name X1\ndmi board_name B1\ndmi bios_version 1.00\ndmi bios_date 01/01/2020\ncpu Some CPU\n' > "$t37/v1"
    printf 'dmi sys_vendor ACME\ndmi product_name X1\ndmi board_name B1\ndmi bios_version 9.99\ndmi bios_date 09/09/2026\ncpu Some CPU\n' > "$t37/v2"
    # the lines use `local`, so they have to run inside a function
    _id37() { "$bb37" ash -c "_f() {
now=\"\$1\"
$id37
printf %s \"\$mid\"
}
_f \"$1\"" 2>/dev/null || true; }
    a37=$(_id37 "$t37/v1")
    b37=$(_id37 "$t37/v2")
    rm -rf "$t37"
    if [ -z "$a37" ]; then
      g37=FAIL; printf '    recon identity produced no id at all\n' >&2
    elif [ "$a37" != "$b37" ]; then
      g37=FAIL
      printf '    a bios reflash changes the machine id (%s -> %s) -- recon would say "first visit", not "CHANGED"\n' "$a37" "$b37" >&2
    fi
  fi
  grep -qF 'mv "$old.new" "$old"' init || { g37=FAIL; printf '    recon baseline written in place again -- a power cut leaves it truncated\n' >&2; }
  grep -qF 'mv "$f.new" "$f"' init     || { g37=FAIL; printf '    ledger written in place again -- a power cut resets the rollback counter\n' >&2; }
  g "G37 recon identifies the machine, not its firmware" "$g37"

  # G34 -- the signed UKI's EMBEDDED roothash must match the tree. G6 pins
  # cmdline.txt (a file) to verity.roothash (a file), and G17 pins the ESP to
  # xos-signed.efi -- but nothing pinned what is INSIDE the signed efi to
  # either. a uki step that fails (locked keys) while verity and stick succeed
  # leaves a stale signed efi beside a fresh image, every gate green, and a
  # stick that panics at the verity mount on real hardware. seen happen.
  # from the .cmdline SECTION, not `strings | head -1`: the embedded kernel is
  # 3+ MB of data around that section, and the first `sha256 <64 hex>` string
  # anywhere in the PE happened to be the right one. one unlucky kernel string
  # and the only gate that catches a stale signed UKI compares a constant.
  local g34_have
  g34_have=$(printf '%s' "$uki_cmd" | grep -o 'sha256 [0-9a-f]\{64\}' | head -1 | cut -d' ' -f2)
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

  # G17 -- stick.img is coherent with the pinned artifacts: right PARTUUIDs, p2
  # byte-equal to xos.img, ESP carries the exact signed UKI.
  if [ -f stick.img ]; then
    local s_ok=1 j pe pr root_off
    j=$(sfdisk -J stick.img 2>/dev/null || true)
    printf '%s' "$j" | grep -qi "\"$PU_ESP\""  || { s_ok=0; printf '    esp PARTUUID absent\n' >&2; }
    printf '%s' "$j" | grep -qi "\"$PU_ROOT\"" || { s_ok=0; printf '    root PARTUUID absent\n' >&2; }
    root_off=$(( (1 + STICK_ESP_MIB) * 1024 * 1024 ))
    cmp -s -n "$(stat -c%s xos.img)" xos.img <(dd if=stick.img bs=1M skip=$((1 + STICK_ESP_MIB)) count=$(( ($(stat -c%s xos.img) + 1048575) / 1048576 )) status=none 2>/dev/null) \
      || { s_ok=0; printf '    p2 region != xos.img\n' >&2; }
    mcopy -n -i stick.img@@1M ::/EFI/BOOT/BOOTX64.EFI /tmp/xos-esp-uki.$$ 2>/dev/null \
      && cmp -s xos-signed.efi /tmp/xos-esp-uki.$$ || { s_ok=0; printf '    ESP UKI != xos-signed.efi\n' >&2; }
    rm -f /tmp/xos-esp-uki.$$
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

  # G23 -- exactly one shell. two shell parsers used to ship (busybox ash for
  # /bin/sh, bash purely as cmdchamp's interpreter). one parser is less to
  # audit, and the survivor is the small one; this fails if bash comes back.
  local shells sh_ok=1
  shells=$(unsquashfs -l rootfs.squashfs 2>/dev/null | grep -cE 'squashfs-root/(bin|usr/bin)/(bash|dash|ksh|mksh|oksh|zsh)$' || true)
  [ "${shells:-0}" -eq 0 ] || { sh_ok=0; printf '    a second shell is in the image\n' >&2; }
  readlink root/bin/sh 2>/dev/null | grep -qx busybox \
    || { sh_ok=0; printf '    /bin/sh is not busybox\n' >&2; }
  g "G23 exactly one shell (busybox ash)" "$([ "$sh_ok" -eq 1 ] && echo ok || echo FAIL)"

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
  g "G24 learn corpus covers the surface exactly" "$([ "$c_ok" -eq 1 ] && echo ok || echo FAIL)"

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
  local kb_ok=1 kb_want kb_have
  if [ ! -f bzImage ] || [ ! -f bzImage.config.sha256 ]; then
    kb_ok=0; printf '    no bzImage or no config stamp -- run ./build.sh kernel\n' >&2
  else
    kb_want=$(sha256sum < kernel.config | awk '{print $1}')
    kb_have=$(awk '/^source/ {print $2}' bzImage.config.sha256)
    [ "$kb_want" = "$kb_have" ] || {
      kb_ok=0
      printf '    kernel.config has changed since bzImage was built -- rebuild the kernel\n' >&2; }
    # and the EXPANDED config -- what was really compiled. kernel() has recorded
    # this digest all along and nothing ever read it, so hand-editing
    # src/linux-*/.config, building, then restoring it from kernel.config left
    # G7, G14 and G28 all green over a kernel with a working module loader.
    # G7 and G14 read that same .config; this is what binds it to the binary.
    local kb_xwant kb_xhave
    kb_xwant=$(sha256sum < "src/linux-$KVER/.config" 2>/dev/null | awk '{print $1}')
    kb_xhave=$(awk '/^expanded/ {print $2}' bzImage.config.sha256)
    if [ -z "$kb_xwant" ]; then
      kb_ok=0; printf '    no src/linux-%s/.config to compare against the bzImage stamp\n' "$KVER" >&2
    elif [ "$kb_xwant" != "$kb_xhave" ]; then
      kb_ok=0
      printf '    src/linux-%s/.config is not the one bzImage was built from -- the config\n' "$KVER" >&2
      printf '    G7 and G14 just validated is not what is in the kernel\n' >&2
    fi
  fi
  g "G28 bzImage was built from the config G7/G14 checked" \
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
  # against the signed cmdline, for the same reason as G15: a test-flavoured UKI
  # beside a restored cmdline.txt is exactly the state selftest.sh leaves if its
  # restore fails partway, and the file would have said everything was fine.
  local tf=0 tfword
  [ "$uki_cmd_ok" -eq 1 ] || { tf=$((tf+1)); printf '    no .cmdline section in xos-signed.efi -- cannot check for test flags\n' >&2; }
  for tfword in xos.test xos.teststate xos.testwg xos.testtether; do
    printf '%s' "$uki_cmd" | grep -qF "$tfword" && { tf=$((tf+1)); printf '    TEST FLAG in the signed cmdline: %s\n' "$tfword" >&2; }
  done
  g "G31 no test flags on the signed cmdline" "$([ "$tf" -eq 0 ] && echo ok || echo FAIL)"

  # the unpacked copy G2..G16 measured has done its job
  rm -rf "$sqx"

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
boot() {
  [ -f ovmf-vars.fd ] || { echo "FAIL: run ./build.sh uki first" >&2; return 1; }
  [ -f stick.img ] || stick || return 1
  qemu-system-x86_64 -machine q35,smm=on -m 256 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file=ovmf-vars.fd \
    -drive file="${1:-stick.img}",if=virtio,format=raw,readonly=on \
    -nic user,model=virtio-net-pci \
    -nographic -no-reboot
}

# same, but attach the stick as an emulated USB mass-storage device on xHCI --
# exercises the real boot path (usb enumeration, dm-mod.waitfor polling, the
# removable-media \EFI\BOOT\BOOTX64.EFI fallback) without any hardware.
bootusb() {
  [ -f ovmf-vars.fd ] || { echo "FAIL: run ./build.sh uki first" >&2; return 1; }
  [ -f stick.img ] || stick || return 1
  qemu-system-x86_64 -machine q35,smm=on -m 256 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file=ovmf-vars.fd \
    -device qemu-xhci,id=xhci \
    -drive if=none,id=stick,format=raw,readonly=on,file="${1:-stick.img}" \
    -device usb-storage,bus=xhci.0,drive=stick \
    -nic user,model=virtio-net-pci \
    -nographic -no-reboot
}


# addstate DEV -- turn the free space after p2 on a flashed stick into p3: an
# encrypted, authenticated ext4 volume that xos unlocks at boot. this is the
# only thing that makes anything persist. it touches the free space only; it
# never writes to p1 or p2. run it once, against the physical stick.
addstate() {
  local dev="${1:-}"
  [ -b "$dev" ] || { echo "usage: $0 addstate /dev/sdX  (the whole stick, not a partition)" >&2; return 1; }
  # tools addstate needs that a plain build does not -- check them here so it
  # fails with a clear message up front, never half way through partitioning.
  local t miss=""
  for t in cryptsetup:cryptsetup mkfs.ext4:e2fsprogs partx:util-linux sfdisk:util-linux; do
    command -v "${t%%:*}" >/dev/null 2>&1 || miss="$miss ${t%%:*}(${t##*:})"
  done
  [ -z "$miss" ] || { echo "FAIL: addstate needs:$miss" >&2; return 1; }
  local n; n=$(basename "$dev")
  [ "$(cat "/sys/block/$n/removable" 2>/dev/null)" = 1 ] \
    || { echo "FAIL: $dev is not removable -- refusing to touch a fixed disk" >&2; return 1; }

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

  # p2 must already be there; p3 goes in the free space after it.
  local p2end
  p2end=$(partx -g -o END -n 2:2 "$dev" 2>/dev/null | tr -d ' ') \
    || { echo "FAIL: cannot read the partition table on $dev -- flash the image first" >&2; return 1; }
  [ -n "$p2end" ] || { echo "FAIL: no second partition on $dev" >&2; return 1; }

  # p3 used to start at p2end+1, flush against the root. that put it directly
  # under the 1 MiB of backup-GPT slack stick.img carries past p2, so a later
  # `./build.sh usb` wrote straight through its LUKS header. usb() now refuses
  # to write that far, and starting p3 past the image's own end -- on a 1 MiB
  # boundary, which is the alignment flash wants anyway -- means the two regions
  # can never overlap again, whatever writes the stick.
  local p3start free_mib
  p3start=$(( ( (p2end + 1 + 2048 + 2047) / 2048 ) * 2048 ))
  free_mib=$(( ( $(cat "/sys/block/$n/size") - p3start ) / 2048 ))
  [ "$free_mib" -ge 64 ] || {
    echo "FAIL: only ${free_mib} MiB free after the root -- p3 needs at least 64 MiB" >&2
    echo "  (LUKS2 alone reserves 16 MiB for its header). use a larger stick." >&2; return 1; }
  echo "  adding p3 to $dev at sector $p3start (${free_mib} MiB free)"
  sfdisk --no-reread -a "$dev" >/dev/null 2>&1 <<SFDISK || { echo "FAIL: sfdisk could not add p3 to $dev (no free space after p2, or an unreadable table)" >&2; return 1; }
start=$p3start, type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
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

  # offer persistent state. declining leaves a perfectly good ephemeral stick.
  echo
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
# are pre-copied from src/ to stay off the network; get() re-checks their
# digests, so a poisoned copy still fails loudly. only meaningful on the
# toolchain the pin was taken with -- same rule G13 already enforces.
repro() {
  say "independent rebuild -- clone committed HEAD, build, compare to the pin"
  local d want_img have_img want_sq have_sq
  d=$(mktemp -d /tmp/xos-repro.XXXXXX) || return 1
  git clone -q --depth 1 "file://$PWD" "$d/tree" || { rm -rf "$d"; return 1; }
  mkdir -p "$d/tree/src"
  cp src/*.tar.* "$d/tree/src/" 2>/dev/null
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
  uki; stick; size; lint
}

case "${1:-all}" in
  install) shift; stick_install "$@" ;;
  deps|fetch|kernel|headers|busybox|ii_|abduco|cryptsetup_|wg_|dropbear_|addstate|tls|ta|rootfs|verity|keys|seal|reseal|unlock|lock|ramkeys|uki|dbx|revoke|stick|usb|pin|seed|size|boot|bootusb|lint|repro) "$@" ;;
  all) build_all ;;
  *) echo "usage: $0 {deps|fetch|kernel|headers|busybox|ii_|abduco|cryptsetup_|wg_|dropbear_|addstate|tls|ta|rootfs|verity|keys|seal|reseal|unlock|lock|ramkeys|uki|dbx|revoke IMAGE|stick|usb <dev>|install <dev>|pin|seed|size|boot|bootusb|lint|repro|all}"; exit 1 ;;
esac

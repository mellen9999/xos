#!/bin/bash
# build/fetch.sh -- the host toolchain, and the pinned sources it is pointed at (deps, fetch, the signature anchors)
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.
# ────────────────────────────────────────────────────────────────────────────
# the host toolchain, and the pinned sources it is pointed at
# ────────────────────────────────────────────────────────────────────────────
deps() {
  local mode="${1:-full}"
  say "checking host toolchain${mode:+ ($mode)}"
  local miss=() cmd
  # cmd:package pairs so the error names what to install (arch/paru).
  # the build toolchain proper: everything the reproducible path (kernel..verity)
  # compiles and links with -- the tools whose behaviour ends up in the image and
  # that the repro container pins. `deps repro` checks ONLY these.
  local base="gcc:gcc ld:binutils strip:binutils readelf:binutils make:make
    curl:curl tar:tar python3:python openssl:openssl
    mksquashfs:squashfs-tools unsquashfs:squashfs-tools veritysetup:cryptsetup
    cmake:cmake flex:flex bison:bison bc:bc pkg-config:pkgconf
    strings:binutils objdump:binutils xz:xz cmp:diffutils rsync:rsync patch:patch"
  # signing, boot and disk tooling: used only by uki/stick/boot/dbx/install,
  # never by the repro path -- so `deps repro` skips them, and the repro
  # container need not ship qemu/ovmf/sbsign, staying lean and free of the
  # package drift that a fat toolchain image invites.
  local extra="sbsign:sbsigntools sbverify:sbsigntools ukify:systemd zstd:zstd
    virt-fw-vars:virt-firmware mcopy:mtools mmd:mtools mkfs.fat:dosfstools
    sfdisk:util-linux wipefs:util-linux lsblk:util-linux
    qemu-system-x86_64:qemu-base partprobe:parted"
  for cmd in $base $( [ "$mode" = repro ] || printf '%s' "$extra" ); do
    command -v "${cmd%%:*}" >/dev/null 2>&1 || miss+=("${cmd%%:*} (${cmd##*:})")
  done
  # musl is linked into every binary but is NOT built from source here -- it is
  # host-provided. SOURCES.md records this honestly; the build must have it.
  [ -f /usr/lib/musl/lib/rcrt1.o ] || miss+=("/usr/lib/musl/lib/rcrt1.o (musl)")
  if [ "$mode" != repro ]; then
    # the mounted-disk guard in usb()/addstate() reads this column; an lsblk
    # without it prints nothing and the guard would pass on a mounted stick.
    lsblk -nro MOUNTPOINTS >/dev/null 2>&1 \
      || miss+=("lsblk with MOUNTPOINTS column (util-linux >= 2.37)")
    # one entry, not two: the halves are only ever useful together.
    [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] \
      || miss+=("a matched OVMF secure-boot pair (edk2-ovmf / ovmf) -- see ./build.sh ovmf")
  fi
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
  # extract only when the tree is COMPLETE, not merely present. a bare `[ -d ]`
  # skips re-extraction the moment src/$dir exists for any reason -- an
  # interrupted tar, or patch_tree's own `mkdir -p $d/.xos-patched` landing
  # first -- leaving a source-less tree that every later build fails on with a
  # cryptic "patch does not apply", forever, until someone deletes it by hand.
  # gate on a sentinel only a finished extraction writes, and wipe any partial
  # tree before redoing it, so an interrupted build self-heals on the next run.
  if [ ! -f "src/$dir/.xos-extracted" ]; then
    rm -rf "src/$dir"
    tar -C src -xf "$XOS_CACHE/$tar"
    : > "src/$dir/.xos-extracted"
  fi
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
  if ! printf '%s\n' "$st" | has "^\\[GNUPG:\\] VALIDSIG $1 "; then return 1; fi
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
# $6=expired-ok:YYYY-MM-DD: this upstream signs releases with a key it let
# expire. the exception is per-source, printed on every build, and never covers
# revocation -- a revoked key means the private half is presumed stolen, which
# is the one case a fingerprint pin cannot save you from.
#
# the DATE is the point. a waiver with no end is a waiver nobody ever looks at
# again, and this one has outlived the key it excuses by years. past that day
# the build refuses until someone renews it deliberately -- the same staleness
# shape G30 already applies to the clock floor. a waiver you renew on purpose
# is not the same thing as one you forgot.
sigver() { # $1 tarball  $2 committed sig  $3 committed pubkey  $4 pinned fingerprint  [$5 xz]  [$6 expired-ok:DATE]
  command -v gpg >/dev/null 2>&1 || {
    # host-optional, with one exception. on a dev box the digest pin still
    # binds the tarball, so skipping is honest. under XOS_STRICT -- the repro
    # container, and any build whose output gets published -- it is not: a
    # build that verified nothing must not be able to claim it did.
    [ -z "${XOS_STRICT:-}" ] || {
      printf '  \033[1;31mFAIL: %s: gpg is not installed and XOS_STRICT is set\033[0m\n' "$1" >&2
      printf '    a published build does not fall back to the digest pin alone.\n' >&2
      return 1; }
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
       case "${6:-}" in
         expired-ok:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
         *) echo "FAIL: $1 is signed by a key that expired on $exp" >&2
            echo "  the signature is the maintainer's, but an expired key stops limiting" >&2
            echo "  the damage of a leak. refresh sigs/ from upstream, or mark this source" >&2
            echo "  expired-ok:YYYY-MM-DD in fetch() once you have decided that is" >&2
            echo "  acceptable -- the date is when you will look at it again." >&2
            return 1 ;;
       esac
       local until="${6#expired-ok:}"
       if [ "$(date -u +%Y-%m-%d)" \> "$until" ]; then
         echo "FAIL: the expiry waiver for $1 lapsed on $until" >&2
         echo "  it was never meant to be permanent. re-anchor this source to a live" >&2
         echo "  signer, or move the date forward in fetch() on purpose." >&2
         return 1
       fi
       printf '  \033[1;33m%s: signed by a key that expired on %s -- waived until %s by an\033[0m\n' "$1" "$exp" "$until"
       printf '  \033[1;33m  explicit exception in fetch(); fingerprint and digest are still pinned\033[0m\n' ;;
    3) echo "FAIL: $1 is signed by a REVOKED key -- the private half is presumed stolen" >&2
       echo "  there is no exception for this. do not build against this tarball." >&2
       return 1 ;;
    *) echo "FAIL: $1 does not match the committed maintainer signature" >&2; return 1 ;;
  esac
}

# a second party's published digest for the same bytes. not a signature and
# never presented as one -- it says an independent distributor, fetching from a
# different place at a different time, got the same tarball. that is a second
# opinion on the first sighting, which a digest pin alone cannot give you and an
# expired key has stopped giving you.
corrob() { # $1 tarball  $2 pinned sha512  $3 who publishes it
  local have; have=$(sha512sum < "$XOS_CACHE/$1" | awk '{print $1}')
  [ -n "$2" ] || { echo "FAIL: $1 has no corroborating digest pinned" >&2; return 1; }
  [ "$2" = "$have" ] || {
    echo "FAIL: $1 does not match the sha512 $3 publishes for it" >&2
    printf '  pinned %s\n  built  %s\n' "$2" "$have" >&2
    printf '  if you bumped this source, re-take the corroborating digest from %s\n' "$3" >&2
    printf '  rather than deleting the check -- it is the only live second opinion\n' >&2
    printf '  this source has.\n' >&2
    return 1; }
  printf '  %s: digest corroborated by %s\n' "$1" "$3"
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
  get "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz" \
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
  sigver "LVM2.$LVMVER.tgz" "sigs/LVM2.$LVMVER.tgz.asc" sigs/lvm2-release-key.asc "$LVM_FPR" "" expired-ok:2027-03-31
  # the second anchor, because the first one's key is dead. see LVM_SHA512.
  corrob "LVM2.$LVMVER.tgz" "$LVM_SHA512" "fedora rawhide"
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

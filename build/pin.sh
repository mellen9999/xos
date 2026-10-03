#!/bin/bash
# build/pin.sh -- the pins: image digests, the toolchain, host blobs, the trust surface, upstream versions
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# the toolchain identity, line by line. the fingerprint (toolchain(), below) is
# a hash of exactly this stream, and pin() records these same lines as comments
# in image.sha256 -- so a stranger reading the pin knows which gcc/binutils/
# squashfs-tools to install to reproduce the bytes, not just an opaque hash.
# ONE source of truth for both: change a line here and the fingerprint moves
# with it. keep the order and format frozen -- the hash is taken over it.
toolchain_versions() {
  gcc --version | head -1
  ld --version | head -1
  mksquashfs -version 2>&1 | head -1
  veritysetup --version
  sha256sum musl-static-pie.specs | awk '{print $1}'
  umask
}
# the EFI stub used to be hashed into the line above, on the reasoning that two
# systemd versions give different signed bytes from identical source. that
# reasoning is right about the SIGNED bytes and wrong about this fingerprint:
# build_repro contains no uki(), so not one of the four digests image.sha256
# pins can depend on the stub. its presence here could only ever make G13 SKIP
# after an innocent systemd upgrade -- monthly, on arch -- and could never catch
# anything. it also read `sha256sum "$STUB" 2>/dev/null`, which on a host with
# no systemd emitted nothing and let the fingerprint compute anyway.
#
# clean split, and blobs.sha256 is the other half of it:
#   toolchain()     things that move the PINNED bytes
#   blobs.sha256    things that move the SIGNED bytes
# the payoff is that G13 now runs on every host whose gcc, binutils,
# squashfs-tools and veritysetup match, instead of only those whose systemd
# happens to match too.
toolchain() { toolchain_versions | sha256sum | awk '{print $1}'; }

# the source digest: blob ids + paths of every IMAGE_SRC entry at HEAD -- the
# COMMITTED bytes, which is what a clone rebuilds. safe.directory because cpin
# runs this as root inside the container on a tree the host user owns.
# shellcheck disable=SC2086
srcpin() {
  git -c safe.directory='*' ls-tree -r HEAD -- $IMAGE_SRC | awk '{print $3, $4}' | sha256sum | awk '{print $1}'
}
srcpin_covers() { local p; for p in $IMAGE_SRC; do [ "$1" = "$p" ] && return 0; case "$1" in "$p"/*) return 0 ;; esac; done; return 1; }
# every tracked operand of a cp/install inside rootfs() must be in IMAGE_SRC.
# untracked operands are build outputs (busybox, dropbearmulti) and are what
# IMAGE_SRC's listed inputs produce, so they are skipped; a quoted or $-bearing
# operand is a variable the static read cannot resolve, skipped too.
srcpin_cover() {
  local body line t bad=0
  body=$(fnbody rootfs | sed -e ':a' -e '/\\$/N; s/\\\n//; ta')
  while read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    while [ $# -gt 1 ]; do                # the last word is the destination
      t=$1; shift
      case "$t" in -m) shift; continue ;; -*) continue ;; esac
      case "$t" in *'$'*|'"'*|"'"*) continue ;; esac
      t=${t%/.}
      git ls-files --error-unmatch -- "$t" >/dev/null 2>&1 || continue
      srcpin_covers "$t" || { bad=1; printf '    rootfs() copies %s into the image but IMAGE_SRC leaves it out\n' "$t" >&2; }
    done
  done <<< "$(printf '%s\n' "$body" | grep -E '^[[:space:]]*(cp|install) ' | sed -E 's/^[[:space:]]*(cp|install) //')"
  return $bad
}

cmp_pin() { # $1 dir holding xos.img/rootfs.squashfs/verity.roothash/bzImage
  local d="${1:-.}" k want have rc=0
  for k in image squashfs roothash kernel; do
    want=$(awk -v k="$k" '$1==k{print $2}' image.sha256)
    case "$k" in
      image)    have=$(sha256sum < "$d/xos.img"         | awk '{print $1}') ;;
      squashfs) have=$(sha256sum < "$d/rootfs.squashfs" | awk '{print $1}') ;;
      roothash) have=$(cat "$d/verity.roothash" 2>/dev/null) ;;
      kernel)   have=$(sha256sum < "$d/bzImage"         | awk '{print $1}') ;;
    esac
    if [ -z "$want" ]; then
      printf '    %-9s not pinned -- image.sha256 is stale, run ./build.sh cpin\n' "$k" >&2
      rc=1; continue
    fi
    [ "$want" = "$have" ] && continue
    printf '    %-9s pinned %s\n              built  %s\n' "$k" "${want:0:32}..." "${have:0:32}..." >&2
    rc=1
  done
  return $rc
}

# ────────────────────────────────────────────────────────────────────────────
# host blobs -- prebuilt binaries that enter the SIGNED artifact
# ────────────────────────────────────────────────────────────────────────────
# the systemd EFI stub is a 134 KB prebuilt PE this build wraps into the UKI,
# signs, and ships as BOOTX64.EFI. it runs BEFORE anything dm-verity covers,
# and for as long as it existed the only thing checked about it was that the
# file was there. its sha256 sat in image.sha256 as a comment nothing parsed.
#
# blobs.sha256, not sources.sha256: that file means "tarballs I fetch into
# $XOS_CACHE", and both get() and the completeness sweep assume that shape.
# ONE accepted digest per path, never a list -- a multi-digest file decays into
# "every version I have ever seen" and the diff stops meaning anything.
#
# what this does NOT claim: pinning does not make the stub trustworthy. the
# bytes still came from a distro's build servers. it makes them FIXED, NAMED,
# and visible in a diff -- so the stub cannot change under a signed image
# without someone deciding to change it. that is the whole claim.
#
# WHERE THE BYTES COME FROM. the stub used to be read off the build host's
# own systemd install, which made the signed build hostage to the
# host's systemd: one `pacman -Syu` and every signed build halted on a digest
# the host could no longer produce -- which is exactly what happened on
# 2026-09-28, and took the full CI tier down with it. so the pin now names the
# arch PACKAGE the stub is cut from, and blob() fetches that package by name
# from the arch linux archive -- the same frozen archive the repro toolchain is
# pinned to -- verifies it, extracts the member, verifies that too. the host's
# systemd can be anything or absent; the signed bytes do not move. the package
# digest is the anchor; the url, as with get(), only says where bytes arrive.
# crepro and verify are unaffected -- neither runs uki().
#
# blobs.sha256 lines are "<sha256>  <name>": one package (*.pkg.tar.zst, lives
# in $XOS_CACHE like the tarballs) and then each member taken from it, by
# basename, landing in $XOS_BLOBS. blob_path() is the one place that mapping is
# written down.
blob_path() { case "$1" in *.pkg.tar.zst) printf '%s/%s' "$XOS_CACHE" "$1" ;; *) printf '%s/%s' "$XOS_BLOBS" "$1" ;; esac; }
blob_pkg()  { awk '!/^[[:space:]]*(#|$)/ && $2 ~ /\.pkg\.tar\.zst$/ {print $2}' blobs.sha256; }
# archive.archlinux.org/packages/<first letter>/<pkgname>/<file>. the pkgname is
# the file name less "-<ver>-<rel>-<arch>.pkg.tar.zst", i.e. the last three
# dash-groups -- so a dashed pkgname (systemd-ukify) still resolves.
ala_pkg_url() { local n=${1%-*-*-*}; printf 'https://archive.archlinux.org/packages/%s/%s/%s' "${n:0:1}" "$n" "$1"; }

blob() {
  local f=blobs.sha256 pkg want have name member tmp n=0
  [ -f "$f" ] || { echo "FAIL: blobs.sha256 is missing -- nothing says where the stub comes from" >&2; return 1; }
  pkg=$(blob_pkg)
  [ "$(printf '%s\n' "$pkg" | grep -c .)" -eq 1 ] || {
    echo "FAIL: blobs.sha256 must pin exactly ONE package (*.pkg.tar.zst), found:" >&2
    printf '%s\n' "${pkg:-none}" | sed 's/^/  /' >&2; return 1; }
  mkdir -p "$XOS_CACHE" "$XOS_BLOBS"
  if [ ! -f "$XOS_CACHE/$pkg" ]; then
    pull "$(ala_pkg_url "$pkg")" "$pkg" || {
      printf '  %s: archive.archlinux.org unreachable -- trying the wayback machine\n' "$pkg" >&2
      pull "https://web.archive.org/web/2999id_/$(ala_pkg_url "$pkg")" "$pkg"
    } || {
      echo "FAIL: could not fetch $pkg from the arch linux archive or the wayback machine" >&2
      printf '      the url is not the trust anchor. fetch %s from ANY arch mirror or\n' "$pkg" >&2
      printf '      machine, drop it at %s, and rerun -- the pinned digest decides.\n' "$XOS_CACHE/$pkg" >&2
      return 1
    }
  fi
  want=$(awk -v n="$pkg" '$2==n{print $1}' "$f")
  have=$(sha256sum < "$XOS_CACHE/$pkg" | awk '{print $1}')
  [ -n "$want" ] && [ "$want" = "$have" ] || {
    echo "FAIL: $pkg does not match blobs.sha256 -- refusing to extract anything from it" >&2
    printf '  pinned %s\n  found  %s\n  delete %s and rerun; blob() refetches it.\n' "$want" "$have" "$XOS_CACHE/$pkg" >&2
    return 1; }
  while read -r want name; do
    case "$want" in ''|\#*) continue ;; esac
    case "$name" in ''|*.pkg.tar.zst) continue ;; esac
    # already cut and still the pinned bytes: nothing to do.
    [ -f "$XOS_BLOBS/$name" ] && [ "$(sha256sum < "$XOS_BLOBS/$name" | awk '{print $1}')" = "$want" ] && { n=$((n + 1)); continue; }
    # by basename, and it must be unique inside the package -- two candidates
    # would make "the stub" ambiguous, so that is a refusal, not a pick.
    member=$(tar --zstd -tf "$XOS_CACHE/$pkg" | grep -E "(^|/)$name\$" || true)
    [ "$(printf '%s\n' "$member" | grep -c .)" -eq 1 ] || {
      echo "FAIL: $pkg holds $(printf '%s\n' "$member" | grep -c .) member(s) named $name -- need exactly one" >&2
      return 1; }
    tmp="$XOS_BLOBS/.$name.tmp"
    tar --zstd -xOf "$XOS_CACHE/$pkg" "$member" > "$tmp" || { rm -f "$tmp"; echo "FAIL: could not extract $member from $pkg" >&2; return 1; }
    have=$(sha256sum < "$tmp" | awk '{print $1}')
    [ "$want" = "$have" ] || {
      rm -f "$tmp"
      echo "FAIL: $name cut from $pkg does not match blobs.sha256" >&2
      printf '  pinned %s\n  found  %s\n' "$want" "$have" >&2
      printf '  the package verified, so the pin names a member this package never held.\n' >&2
      printf '  re-pin deliberately with ./build.sh blobpin <pkgver>, in a commit.\n' >&2
      return 1; }
    mv -f "$tmp" "$XOS_BLOBS/$name"
    printf '  %s: cut from %s, matches blobs.sha256\n' "$name" "$pkg"
    n=$((n + 1))
  done < "$f"
  [ "$n" -gt 0 ] || { echo "FAIL: blobs.sha256 names no member to cut from $pkg" >&2; return 1; }
}

# `./build.sh stub` -- make sure the stub is here and say where. selftest.sh
# builds its own superseded UKI from it (A11) and must not grow a second copy of
# the path rule.
stub() { blob >&2 || return 1; printf '%s\n' "$STUB"; }

blobver() {
  local f=blobs.sha256 n=0 want name path have
  [ -f "$f" ] || {
    echo "FAIL: blobs.sha256 is missing -- the signed image would wrap an unpinned blob" >&2
    return 1; }
  while read -r want name; do
    case "$want" in ''|\#*) continue ;; esac
    [ -n "$name" ] || { echo "FAIL: blobs.sha256: malformed line: $want" >&2; return 1; }
    path=$(blob_path "$name")
    [ -f "$path" ] || {
      echo "FAIL: $name is pinned in blobs.sha256 but is not at $path -- run ./build.sh blob" >&2
      return 1; }
    have=$(sha256sum < "$path" | awk '{print $1}')
    [ "$want" = "$have" ] || {
      echo "FAIL: $name does not match blobs.sha256" >&2
      printf '  pinned %s\n  found  %s\n' "$want" "$have" >&2
      printf '  these bytes are wrapped into the SIGNED image. a cached copy has changed\n' >&2
      printf '  under the pin: delete %s and rerun (blob() refetches\n' "$path" >&2
      printf '  from the archive). a deliberate change is ./build.sh blobpin <pkgver>.\n' >&2
      return 1; }
    n=$((n + 1))
  done < "$f"
  # an emptied or reformatted file must be a hard refusal, never a vacuous
  # zero-of-zero pass -- the same floor the gate roster and the ELF sweep keep.
  # 2, not 1: the package AND at least one member cut from it.
  [ "$n" -ge 2 ] || { echo "FAIL: blobs.sha256 pins nothing (need the package and a member)" >&2; return 1; }
  printf '  %d pinned blob(s) match blobs.sha256\n' "$n"
}

# the container's package list, read from the ONE place it is written. the
# Dockerfile's ARG PKGS is the list; the build, toolpin and both gates read it
# from there rather than each keeping a copy that drifts.
dfpkgs() {
  # `|| true`: an empty list is a condition the callers report on, not a reason
  # for set -e to kill the script before they can.
  { sed -n 's/^ARG PKGS="\(.*\)"$/\1/p' repro/Dockerfile \
      | tr ' ' '\n' | grep -v '^$' | sort -u; } || true
}

# the container toolchain, by bytes.
#
# repro/Dockerfile pins the base image by digest and the Arch archive day. but
# an archive day is a PATH, not a digest: it says where the packages came from,
# never which bytes arrived. repro/toolchain.sha256 closes that for every
# package the Dockerfile names, and the Dockerfile checks it before installing
# a single one -- so the container's statement is "the compiler is these exact
# bytes", not "these version strings from this day".
#
# what it does not cover, and the file says so too: the dependency closure of
# those packages, which still rests on the archive day plus pacman's own
# signature checking.
toolver() {
  local f=repro/toolchain.sha256 rc=0 x names
  [ -f "$f" ] || { echo "FAIL: $f is missing -- the container's packages are unpinned" >&2; return 1; }
  # || true throughout: a file that matches nothing must reach the guard below
  # and be REPORTED, not abort the script silently at the assignment.
  names=$(grep -vE '^[[:space:]]*(#|$)' "$f" | awk '{print $2}' \
          | sed 's/-[^-]*-[^-]*-[^-]*\.pkg\.tar\.zst$//' | sort -u || true)
  [ -n "$names" ] || { echo "FAIL: $f pins no packages" >&2; return 1; }
  local want; want=$(dfpkgs || true)
  [ -n "$want" ] || { echo "FAIL: repro/Dockerfile has no ARG PKGS list" >&2; return 1; }
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    printf '%s\n' "$names" | grep -qxF "$x" \
      || { printf '    the container installs %s and toolchain.sha256 does not pin it\n' "$x" >&2; rc=1; }
  done <<< "$want"
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    printf '%s\n' "$want" | grep -qxF "$x" \
      || { printf '    toolchain.sha256 pins %s and the container does not install it\n' "$x" >&2; rc=1; }
  done <<< "$names"
  # and the check has to still happen BEFORE the install. a pin file the build
  # never reads is a file, not a pin.
  awk '/sha256sum -c/{c=NR} /pacman -Su /{i=NR} END{exit !(c && i && c < i)}' repro/Dockerfile \
    || { printf '    repro/Dockerfile no longer verifies toolchain.sha256 before installing\n' >&2; rc=1; }
  [ "$rc" -eq 0 ] && printf '  %d container package(s) pinned by digest\n' "$(printf '%s\n' "$names" | grep -c .)"
  return $rc
}

# regenerate repro/toolchain.sha256 from the pinned base image and archive day.
# it has to run inside the base image: the digests are of the package files
# THAT day's mirror serves, and nothing on the host can tell you those.
toolpin() {
  say "pinning the container toolchain by bytes"
  command -v docker >/dev/null 2>&1 || { echo "FAIL: toolpin needs docker" >&2; return 1; }
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "FAIL: tracked files are modified -- commit (or discard) before pinning:" >&2
    git status --porcelain --untracked-files=no >&2
    return 1
  fi
  local base ala pkgs out
  base=$(sed -n 's/^FROM[[:space:]]\+\(.*\)$/\1/p' repro/Dockerfile | head -1)
  ala=$(sed -n 's/^ARG ALA=\(.*\)$/\1/p' repro/Dockerfile | head -1)
  pkgs=$(dfpkgs | tr '\n' ' ')
  [ -n "$base" ] && [ -n "$ala" ] && [ -n "$pkgs" ] \
    || { echo "FAIL: repro/Dockerfile does not pin a base, an ALA day and a package list" >&2; return 1; }
  out=$(docker run --rm --network=host "$base" sh -euc '
    printf "Server=https://archive.archlinux.org/repos/%s/\$repo/os/\$arch\n" "$1" \
      > /etc/pacman.d/mirrorlist
    pacman -Syuw --noconfirm $2 >/dev/null 2>&1
    cd /var/cache/pacman/pkg
    for p in $2; do sha256sum "$(pacman -Sp --print-format "%f" "$p" | tail -1)"; done \
      | sort -u -k2' _ "$ala" "$pkgs") \
    || { echo "FAIL: could not download the packages in the pinned base image" >&2; return 1; }
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq "$(dfpkgs | grep -c .)" ] \
    || { echo "FAIL: got $(printf '%s\n' "$out" | grep -c .) digests for $(dfpkgs | grep -c .) packages" >&2; return 1; }
  { echo "# the container's toolchain, by BYTES."
    echo "#"
    echo "# repro/Dockerfile pins the base image by digest and aims pacman at a frozen"
    echo "# Arch Linux Archive day. but an archive day is a PATH, not a digest: it says"
    echo "# where the packages came from, not which bytes arrived. this closes that --"
    echo "# every package the Dockerfile names explicitly is checked against this file"
    echo "# before a single one is installed."
    echo "#"
    echo "# what it does NOT cover, said plainly: the dependency CLOSURE of these."
    echo "# those still rest on the archive day plus pacman's own signature checking."
    echo "# regenerate with ./build.sh toolpin; G59 checks this file against the"
    echo "# Dockerfile's package list in both directions."
    printf '%s\n' "$out"
  } > repro/toolchain.sha256
  cat repro/toolchain.sha256
}

# ────────────────────────────────────────────────────────────────────────────
# the trust surface, checked against the tree
# ────────────────────────────────────────────────────────────────────────────
# four documents describe this repo's trust surface well, in prose, and nothing
# checked a word of any of them against the tree. the EFI stub is the proof of
# what that costs: honestly described in SOURCES.md, sitting beside an unpinned
# binary for as long as it existed.
#
# trust.manifest is the index. this is the check. six set-differences, each
# BOTH ways, so neither a new thing in the tree nor a stale row in the file can
# survive unnoticed. lives here rather than inline in gates() because ci()
# needs it too: a trust-surface regression should be named on the push that
# caused it, not on the next full build.
trustver() {
  local f=trust.manifest rc=0 x
  [ -f "$f" ] || { echo "FAIL: trust.manifest is missing" >&2; return 1; }
  local rows tm_tool tm_source tm_pkg tm_blob tm_ca tm_prefix
  rows=$(grep -vE '^[[:space:]]*(#|$)' "$f" || true)
  # an emptied or reformatted file must not pass vacuously.
  [ "$(printf '%s\n' "$rows" | grep -c .)" -gt 0 ] \
    || { echo "FAIL: trust.manifest holds no rows" >&2; return 1; }
  tmcol() { printf '%s\n' "$rows" | awk -v k="$1" '$1==k{print $2}' | sort -u; }
  tm_tool=$(tmcol tool); tm_source=$(tmcol source); tm_pkg=$(tmcol pkg)
  tm_blob=$(tmcol blob); tm_ca=$(tmcol ca)
  tm_prefix=$(printf '%s\n' "$rows" | awk '$1=="host"||$1=="img"{print $2}' | sort -u)

  # name what is on one side and not the other, in the caller's words.
  _d() { # $1 message  $2 list to walk  $3 list to look in
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      printf '%s\n' "$3" | grep -qxF "$x" || { printf '    %s: %s\n' "$1" "$x" >&2; rc=1; }
    done <<< "$2"
  }

  # 1. host tools. this is the class that actually grows, so it has the teeth.
  local deps_tools
  deps_tools=$(fnbody deps | awk '/local (base|extra)="/{i=1} i{print} i&&/"[[:space:]]*$/{i=0}' \
               | grep -oE '[a-z0-9_.+-]+:[a-z0-9_.+-]+' | awk -F: '{print $1}' | sort -u || true)
  _d "deps() needs a host tool with no trust.manifest row" "$deps_tools" "$tm_tool"

  # 1b. the reverse, widened to the trust-doers. deps() lists the BUILD
  # toolchain; it never lists the tools that sign, hash, clone, verify and write
  # the disk (gpg, git, docker, the hashers, dd, sudo...) because they are
  # assumed-present, not build inputs. so the old "tool deps() no longer needs"
  # check flagged those legitimate rows, and before them this index -- meant to
  # hold the WHOLE trust surface -- simply omitted the tools the trust rests on.
  # the honest reverse: a tool row is stale only if it is NEITHER a deps() tool
  # NOR invoked by name in a first-party script. a build dep consumed by a
  # sub-build (bison, bc) is covered by the deps() arm and never needs to appear
  # by name; a trust-doer must appear, since nothing else accounts for it.
  # here-strings, not pipes: `printf "$big" | grep -q` trips pipefail -- grep -q
  # exits on the first match and printf takes a SIGPIPE, so a SUCCESSFUL match
  # reads as a failed pipeline. feeding grep by here-string has no such pipe.
  local script_text nd
  script_text=$(cat build.sh build/*.sh selftest.sh githooks/pre-commit githooks/pre-push \
                    ci/xos-ci-full ci/xos-repro ci/xos-ci-status ci/lib.sh arsenal/*.sh 2>/dev/null || true)
  while IFS= read -r nd; do
    [ -n "$nd" ] || continue
    grep -qxF "$nd" <<< "$deps_tools" && continue   # a build dep, covered by 1
    grep -qE "(^|[^a-zA-Z0-9_.-])$nd([^a-zA-Z0-9_.-]|$)" <<< "$script_text" \
      || { printf '    trust.manifest names tool %s that is neither a deps() tool nor invoked by any first-party script\n' "$nd" >&2; rc=1; }
  done <<< "$tm_tool"

  # 2. pinned sources, by version-stripped name so a bump is not a churn.
  local src_names
  src_names=$(grep -vE '^[[:space:]]*(#|$)' sources.sha256 | awk '{print $2}' \
              | sed 's/[-.][0-9].*$//' | sort -u || true)
  _d "a pinned source with no trust.manifest row" "$src_names" "$tm_source"
  _d "trust.manifest names a source that is no longer pinned" "$tm_source" "$src_names"

  # 2b. and a claimed signature anchor must be REAL. this is the failure mode a
  # hand-maintained doc always eventually has: the manifest says a source is
  # signature-anchored and the build never checks one.
  local a v fbody
  fbody=$(fnbody fetch)
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    a=$(printf '%s\n' "$rows" | awk -v n="$x" '$1=="source"&&$2==n{print $3}')
    case "$a" in
      sig:*|dsc:*) v=${a#*:}
        grep -qE "^$v=" build.sh \
          || { printf '    %s claims %s but build.sh assigns no such variable\n' "$x" "$a" >&2; rc=1; continue; }
        printf '%s\n' "$fbody" | has "sigver .*\\\$$v" \
          || { printf '    %s claims %s but fetch() never calls sigver with it\n' "$x" "$a" >&2; rc=1; } ;;
    esac
  done <<< "$tm_source"
  # and the reverse, which is the mistake that actually happened: a row that
  # UNDERSTATES its anchor. lvm2 sat at `tofu` in the first version of this
  # file while fetch() had verified its signature all along -- the check above
  # cannot see that, because an honest-looking weaker claim raises no flag.
  local sv
  for sv in $(printf '%s\n' "$fbody" | sed -n 's/^[[:space:]]*sigver[[:space:]]*"\([^"]*\)".*/\1/p' \
              | sed 's/[-.]\$.*//' | sort -u); do
    a=$(printf '%s\n' "$rows" | awk -v n="$sv" '$1=="source"&&$2==n{print $3}')
    case "$a" in
      sig:*|dsc:*) ;;
      '') printf '    fetch() verifies a signature for %s and trust.manifest has no row for it\n' "$sv" >&2; rc=1 ;;
      *)  printf '    fetch() verifies a signature for %s but trust.manifest calls it %s\n' "$sv" "$a" >&2; rc=1 ;;
    esac
  done

  # 3. the blobs file, both ways.
  local blob_paths
  blob_paths=$(grep -vE '^[[:space:]]*(#|$)' blobs.sha256 | awk '{print $2}' | sort -u || true)
  _d "a pinned blob with no trust.manifest row" "$blob_paths" "$tm_blob"
  _d "trust.manifest names a blob that is not in blobs.sha256" "$tm_blob" "$blob_paths"

  # 4. the container's package list.
  local dpkgs; dpkgs=$(dfpkgs)
  _d "a container package with no trust.manifest row" "$dpkgs" "$tm_pkg"
  _d "trust.manifest names a package the container does not install" "$tm_pkg" "$dpkgs"

  # 5. the shipped trust anchors.
  local pems
  pems=$( { cd trust 2>/dev/null && ls -1 ./*.pem 2>/dev/null | sed 's|^\./||' | sort -u; } || true)
  _d "a shipped CA with no trust.manifest row" "$pems" "$tm_ca"
  _d "trust.manifest names a CA that is not in trust/" "$tm_ca" "$pems"

  # 6. absolute host paths. exact blob rows, or a host/img row that PREFIXES
  # them -- so the twelve OVMF alternatives are three rows, not twelve, and a
  # brand new /usr path still forces someone to say which it is.
  local up covered pre
  for up in $(cat build.sh build/*.sh | grep -oE '/usr/[A-Za-z0-9_./-]+' | sort -u); do
    covered=0
    # against the MANIFEST's blob rows, not blobs.sha256: this check asks
    # whether trust.manifest accounts for the path. check 3 above is what ties
    # the manifest to the pin file.
    printf '%s\n' "$tm_blob" | grep -qxF "$up" && covered=1
    if [ "$covered" -eq 0 ]; then
      for pre in $tm_prefix; do
        case "$up" in "$pre"*) covered=1; break ;; esac
      done
    fi
    [ "$covered" -eq 1 ] || {
      printf '    the build names %s and trust.manifest accounts for neither it nor\n' "$up" >&2
      printf '    a prefix of it -- say whether it is a blob, a host path, or in the image\n' >&2
      rc=1; }
  done
  [ "$rc" -eq 0 ] && printf '  trust.manifest accounts for %d row(s) against the tree\n' \
    "$(printf '%s\n' "$rows" | grep -c .)"
  return $rc
}

# re-pin the blobs to a named arch package. mirrors pin(): a pin is a claim
# about what gets signed, so it refuses a dirty tree and the result belongs in
# a commit. usage: ./build.sh blobpin <pkgver>   e.g. blobpin 261.3-1
# -- the systemd package version as the archive names it. nothing here reads
# the host's systemd: the bytes come from the archive, every time.
blobpin() {
  local ver="$1" pkg want_pkg want_m name member
  [ -n "$ver" ] || { echo "FAIL: usage: ./build.sh blobpin <pkgver>   e.g. 261.3-1 (see archive.archlinux.org/packages/s/systemd/)" >&2; return 1; }
  say "pinning the blobs this build signs into the image, from systemd-$ver"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "FAIL: tracked files are modified -- commit (or discard) before pinning:" >&2
    git status --porcelain --untracked-files=no >&2
    return 1
  fi
  pkg="systemd-$ver-x86_64.pkg.tar.zst"
  # the members this build cuts out, in one place. one today; a second is one
  # more word here, and blob()/blobver() read the file.
  local members=(linuxx64.efi.stub)
  mkdir -p "$XOS_CACHE" "$XOS_BLOBS"
  [ -f "$XOS_CACHE/$pkg" ] || pull "$(ala_pkg_url "$pkg")" "$pkg" \
    || { echo "FAIL: could not fetch $pkg from $(ala_pkg_url "$pkg")" >&2; return 1; }
  want_pkg=$(sha256sum < "$XOS_CACHE/$pkg" | awk '{print $1}')
  { echo "# prebuilt bytes that enter the SIGNED image but are not built here: the"
    echo "# systemd EFI stub, cut from ONE arch package fetched by name from the arch"
    echo "# linux archive -- the frozen archive the repro toolchain is pinned to --"
    echo "# never from whatever the build host has installed, so a host upgrade can"
    echo "# neither move the signed bytes nor halt the build. ONE digest per line: the"
    echo "# package, then each member blob() cuts from it. regenerate with"
    echo "# ./build.sh blobpin <pkgver>; blob() fetches + verifies both, blobver()"
    echo "# re-checks before uki() wraps anything, and G58 checks that it still does."
    echo "# pinning fixes the bytes and names them in a diff; it does not make them"
    echo "# trustworthy. see trust.manifest."
    printf '%s  %s\n' "$want_pkg" "$pkg"
    for name in "${members[@]}"; do
      member=$(tar --zstd -tf "$XOS_CACHE/$pkg" | grep -E "(^|/)$name\$" || true)
      [ "$(printf '%s\n' "$member" | grep -c .)" -eq 1 ] || { echo "FAIL: $pkg holds no unique member $name" >&2; return 1; }
      want_m=$(tar --zstd -xOf "$XOS_CACHE/$pkg" "$member" | sha256sum | awk '{print $1}')
      printf '%s  %s\n' "$want_m" "$name"
    done
  } > blobs.sha256.tmp || { rm -f blobs.sha256.tmp; return 1; }
  mv -f blobs.sha256.tmp blobs.sha256
  cat blobs.sha256
  # cut the members now so the next uki() finds them already pinned-and-present.
  blob
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
    # the committed source these bytes were built from, so ci can refuse a HEAD
    # that moved an image-affecting path without re-pinning (see IMAGE_SRC).
    printf 'source    %s\n'   "$(srcpin)"
    printf 'toolchain %s\n'   "$(toolchain)"
    # the fingerprint above is opaque; these comment lines say what it is, so a
    # stranger can install the same toolchain and rebuild the exact bytes. read
    # by nothing (the parsers key on the first word), there for a human.
    echo "# toolchain this pin was taken with -- install these to reproduce:"
    toolchain_versions | sed 's/^/#   /'
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

#!/bin/sh
# build-wordlists.sh -- stage a SecLists subset + rockyou for ~/wordlists/.
#
# SecLists is the de-facto standard wordlist collection every ffuf/gobuster/
# hydra tutorial assumes. we pull only Discovery/, Fuzzing/ and Passwords/ --
# the three trees the arsenal's fuzzers/crackers actually use -- and skip
# Passwords/Leaked-Databases/ (dozens of giant real-world leak dumps, not
# needed here) except rockyou.txt.tar.gz, which we decompress flat to
# $OUT/rockyou.txt: the one path every tutorial hardcodes.
#
# TRUST: SecLists tags a release but ships no signature/sha256, so this is
# trust-on-first-use over TLS (github release tarball), same tier as
# wireguard-tools in build.sh. the fetched tarball is cached OUTSIDE $OUT (next
# to build.sh's own $XOS_CACHE) and re-verified against the pin before reuse --
# not under $OUT, because provision-lib.sh's populate() copies $OUT/. onto p3
# verbatim and the 700MB source tarball has no business riding the stick.
#
# CASING: Discovery/, Fuzzing/, Passwords/ keep SecLists' own capitalisation
# as extracted -- do not rename. every recipe that references these paths
# (this repo's README included) copy-pastes SecLists' real casing.
#
# needs: wget, tar, sha256sum. output: ./wordlists/{Discovery,Fuzzing,
# Passwords,rockyou.txt}.
set -eu
OUT="${1:-wordlists}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
TAG=2026.1
TB_SHA=226c49d04974ec6c39dadbf38ba78e67fec8824d729e66907f6050329da98932
ASSET="SecLists-$TAG.tar.gz"
URL="https://github.com/danielmiessler/SecLists/archive/refs/tags/$TAG.tar.gz"
D="SecLists-$TAG"

CACHE="${XOS_CACHE:-$HOME/.cache/xos/tarballs}/arsenal"; mkdir -p "$CACHE"
TB="$CACHE/$ASSET"
if [ -f "$TB" ] && [ "$(sha256sum < "$TB" | cut -d' ' -f1)" = "$TB_SHA" ]; then
  echo "cached $ASSET already verified against pin -- skipping fetch"
else
  echo "fetching $ASSET ..."
  wget -q "$URL" -O "$TB.part" || {
    echo "  primary unreachable -- trying the wayback machine" >&2
    wget -q "https://web.archive.org/web/2999id_/$URL" -O "$TB.part"
  }
  got=$(sha256sum < "$TB.part" | cut -d' ' -f1)
  [ "$got" = "$TB_SHA" ] || {
    rm -f "$TB.part"
    echo "sha256 MISMATCH -- refusing" >&2
    echo "  got  $got" >&2
    echo "  want $TB_SHA" >&2
    exit 1
  }
  mv "$TB.part" "$TB"
  echo "sha256 verified against pin"
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tar -xzf "$TB" -C "$tmp" "$D/Discovery" "$D/Fuzzing" "$D/Passwords"
for want in Discovery Fuzzing Passwords; do
  [ -d "$tmp/$D/$want" ] || { echo "FAIL: $want missing from release tarball -- SecLists layout changed" >&2; exit 1; }
done
ry="$tmp/$D/Passwords/Leaked-Databases/rockyou.txt.tar.gz"
[ -f "$ry" ] || { echo "FAIL: rockyou.txt.tar.gz missing from Leaked-Databases/ -- SecLists layout changed" >&2; exit 1; }
tar -xzf "$ry" -O rockyou.txt > "$tmp/rockyou.txt"
rm -rf "$tmp/$D/Passwords/Leaked-Databases"   # the rest of the leak dumps: not needed

rm -rf "$OUT/Discovery" "$OUT/Fuzzing" "$OUT/Passwords" "$OUT/rockyou.txt"
mv "$tmp/$D/Discovery" "$OUT/Discovery"
mv "$tmp/$D/Fuzzing" "$OUT/Fuzzing"
mv "$tmp/$D/Passwords" "$OUT/Passwords"
mv "$tmp/rockyou.txt" "$OUT/rockyou.txt"

LOCK="$(dirname "$0")/wordlists.lock"
sz=$(du -sh "$OUT" | cut -f1)
{
  printf '# wordlists.lock -- SecLists subset staged %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
  printf '# source  tag  sha256  size\n'
  printf 'SecLists  %s  %s  %s\n' "$TAG" "$TB_SHA" "$sz"
} > "$LOCK"

echo
echo "== wordlists staged into $OUT/ =="
echo "  Discovery + Fuzzing + Passwords (SecLists $TAG) + rockyou.txt"
echo "  size: $sz"
echo "  use:  ffuf -w $OUT/Discovery/Web-Content/common.txt -u https://TARGET/FUZZ"
echo "        hydra -P $OUT/rockyou.txt ..."

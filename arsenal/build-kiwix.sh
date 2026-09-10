#!/bin/sh
# build-kiwix.sh -- stage the carried kiwix reader (serve + search) for ~/tools/.
#
# these read the offline zim corpus that rides the SECOND stick (exFAT): the
# knowledge payload -- wikipedia, where-there-is-no-doctor, ifixit, maps. two
# ways to consume it, in descending dependency:
#   kiwix-search <file.zim> "<query>"   pure CLI, no browser -- works on bare xos
#   kiwix-serve  --port 8080 zim/*.zim  then `links http://localhost:8080`
#
# WHY CARRIED, NOT BUILT: kiwix-tools static-musl from scratch drags in libzim +
# xapian + icu + zstd -- the same "dozens of static deps" wall as cpython, so we
# carry the upstream static-PIE musl release, pinned by sha256 and fail-closed,
# exactly like build-python.sh carries python-build-standalone. static-PIE means
# no INTERP and no libc on the target: it runs under xexec on noexec p3, and the
# zims it reads never need exec (read-only on the exFAT stick). the fort's W^X
# rule is untouched.
#
# TRUST: kiwix.org publishes only an md5 alongside the tarball (weaker than the
# maintainer signatures in SOURCES.md). so this pin is trust-on-first-use over
# TLS -- the same tier as ii/abduco/suckless. the sha256 below was taken from a
# download whose md5 matched upstream; a mismatch here aborts.
#
# needs: wget, tar, sha256sum. output: ./arsenal/kiwix-serve + ./arsenal/kiwix-search.
set -eu
OUT="${1:-arsenal}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
KIWIXVER=3.8.2
TB_SHA=6a09e5e054b606f03d1705cfca4ddab90cb2417c9effeb8382acb6066843e1fa
ASSET="kiwix-tools_linux-x86_64-musl-$KIWIXVER.tar.gz"
BASE="https://mirror.download.kiwix.org/release/kiwix-tools"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
echo "fetching $ASSET ..."
wget -q "$BASE/$ASSET" -O k.tgz || {
  echo "  primary unreachable -- trying the wayback machine" >&2
  wget -q "https://web.archive.org/web/2999id_/$BASE/$ASSET" -O k.tgz
}
got=$(sha256sum < k.tgz | cut -d' ' -f1)
[ "$got" = "$TB_SHA" ] || { echo "sha256 MISMATCH -- refusing" >&2; echo "  got  $got" >&2; echo "  want $TB_SHA" >&2; exit 1; }
echo "sha256 verified against pin"
tar xzf k.tgz                       # -> kiwix-tools_linux-x86_64-musl-<ver>/
d="kiwix-tools_linux-x86_64-musl-$KIWIXVER"
for b in kiwix-serve kiwix-search; do
  [ -f "$d/$b" ] || { echo "FAIL: $b missing from release tarball" >&2; exit 1; }
  cp "$d/$b" "$OUT/$b"; chmod +x "$OUT/$b"
  # a static-PIE binary has NO INTERP; a dynamic one would need a loader the
  # target lacks. gate it, so a changed upstream build fails loud not at runtime.
  readelf -l "$OUT/$b" 2>/dev/null | grep -q INTERP && {
    echo "FAIL: $b is dynamically linked (has INTERP) -- not portable to xos" >&2; exit 1; }
done
echo "staged: kiwix-serve + kiwix-search $KIWIXVER (static-PIE musl)"
echo "size: $(du -sh "$OUT/kiwix-serve" "$OUT/kiwix-search" | tr '\n' ' ')"
echo "note: keep arsenal/arsenal.lock in step (sha256 + sizes)."

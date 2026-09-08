#!/bin/sh
# build-python.sh -- stage a carried static musl python + pure-python tools.
#
# building cpython static from scratch is impractical (dozens of static C-ext
# deps), so we carry python-build-standalone: cpython built reproducibly FROM
# SOURCE by Astral's CI, pinned to a release and verified by sha256 -- the same
# spirit as xos's host-provided musl (SOURCES.md). x86_64 baseline (not v2/v3),
# so it runs on any host CPU. musl, so it needs no glibc on the target.
#
# it has dynamic .so stdlib extensions, which noexec p3 will not dlopen -- so
# on the stick it runs through xexec's TREE mode, which stages the whole python
# onto an ephemeral exec surface:
#
#   sh ~/tools/xexec -t ~/tools/python bin/python3 ~/tools/sqlmap/sqlmap.py -u ...
#
# needs: wget, tar, git, sha256sum. output: ./arsenal/python + ./arsenal/sqlmap.
#
# both artifacts are PINNED and verified: the tarball against a known sha256
# (fail-closed -- a wrong hash aborts), sqlmap to an exact revision. edit the
# three pins below to move versions; keep field/arsenal.lock in step.
set -eu
OUT="${1:-arsenal}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
REL=20260901; PYVER=3.12.14
PY_SHA=12d6539cd518eaf9a2fee52d52e457e48826e6c40d3d6e490459a898d2543fcd
SQLMAP_REV=d486742
BASE="https://github.com/astral-sh/python-build-standalone/releases/download/$REL"
ASSET="cpython-$PYVER+$REL-x86_64-unknown-linux-musl-install_only.tar.gz"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
echo "fetching $ASSET ..."
wget -q "$BASE/$ASSET" -O py.tgz
got=$(sha256sum < py.tgz | cut -d' ' -f1)
[ "$got" = "$PY_SHA" ] || { echo "sha256 MISMATCH -- refusing" >&2; echo "  got  $got" >&2; echo "  want $PY_SHA" >&2; exit 1; }
echo "sha256 verified against pin"
tar xzf py.tgz                      # -> python/
rm -rf "$OUT/python"; mv python "$OUT/python"
cd "$OUT"
# pinned checkout: clone then land on the exact rev, so the tool is reproducible
# (a bare --depth 1 would drift to whatever HEAD happens to be).
if [ ! -d sqlmap ]; then
  git clone --filter=blob:none https://github.com/sqlmapproject/sqlmap sqlmap >/dev/null 2>&1
  git -C sqlmap checkout -q "$SQLMAP_REV"
fi
echo "staged: python $("$OUT/python/bin/python3" --version 2>&1)  +  sqlmap @$(git -C sqlmap rev-parse --short HEAD)"
echo "size: python $(du -sh python|cut -f1), sqlmap $(du -sh sqlmap|cut -f1)"

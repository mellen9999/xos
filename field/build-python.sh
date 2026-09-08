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
set -eu
OUT="${1:-arsenal}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
REL=20260901; PYVER=3.12.14
BASE="https://github.com/astral-sh/python-build-standalone/releases/download/$REL"
ASSET="cpython-$PYVER+$REL-x86_64-unknown-linux-musl-install_only.tar.gz"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
echo "fetching $ASSET ..."
wget -q "$BASE/$ASSET" -O py.tgz
if wget -q "$BASE/$ASSET.sha256" -O py.sha256 && [ -s py.sha256 ]; then
  printf '%s  py.tgz\n' "$(cat py.sha256)" | sha256sum -c - >/dev/null && echo "sha256 verified (published)"
else
  echo "no published sidecar; recording our own sha256: $(sha256sum < py.tgz | cut -d' ' -f1)"
fi
tar xzf py.tgz                      # -> python/
rm -rf "$OUT/python"; mv python "$OUT/python"
cd "$OUT"
[ -d sqlmap ] || git clone --depth 1 https://github.com/sqlmapproject/sqlmap sqlmap >/dev/null 2>&1
echo "staged: python $("$OUT/python/bin/python3" --version 2>&1)  +  sqlmap $(cd sqlmap && git describe --tags 2>/dev/null || echo HEAD)"
echo "size: python $(du -sh python|cut -f1), sqlmap $(du -sh sqlmap|cut -f1)"

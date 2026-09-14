#!/bin/sh
# build-python.sh -- stage a carried static musl python + its python tools
# (sqlmap, impacket).
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
#   sh ~/tools/xexec -t ~/tools/python bin/python3 ~/tools/impacket/secretsdump.py ...
#
# impacket rides along too: pure python whose only native deps ship musllinux
# wheels, so it installs into python/'s site-packages with ZERO compilation
# (its .so must ride the same exec-tmpfs as the interpreter -- p3 is noexec).
# ~/tools/impacket/ carries only its 70 runnable example scripts.
#
# needs: wget, tar, git, sha256sum. output: ./arsenal/{python,sqlmap,impacket}.
#
# EVERY artifact is PINNED and verified fail-closed: the python tarball by
# sha256, sqlmap to an exact revision, the impacket sdist by sha256, and every
# impacket dependency wheel by sha256 via impacket.requirements (installed
# --require-hashes --no-deps). edit the pins below / that file to move versions;
# keep arsenal/arsenal.lock in step.
set -eu
OUT="${1:-arsenal}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
SELF=$(cd "$(dirname "$0")" && pwd)      # holds impacket.requirements
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
# ---- impacket: the carried python offensive suite -------------------------
# every wheel version+sha256-pinned in impacket.requirements; --require-hashes
# --no-deps makes pip refuse anything not named there (the complete 21-dist
# tree), so no unpinned byte is ever imported. installed INTO python/ so the
# musl .so ride xexec's exec-tmpfs with the interpreter.
REQ="$SELF/impacket.requirements"
IMP_VER=0.13.1
IMP_SDIST_SHA=ed91c802b6beff6546afd2262942bc1a188b4671fb91ec751d46a1d66d28c2cf
if [ -f "$REQ" ]; then
  echo "installing impacket deps into the carried python (require-hashes) ..."
  "$OUT/python/bin/python3" -m pip install --no-cache-dir --disable-pip-version-check \
    --require-hashes --no-deps -r "$REQ" >/dev/null
  # the runnable tools (secretsdump, GetUserSPNs, ntlmrelayx, psexec, ...) live
  # in the sdist's examples/, not the wheel; carry them as a pure tree run BY
  # the carried python. pin the sdist by sha256, fail-closed like the tarball.
  echo "fetching impacket $IMP_VER sdist for its example tools ..."
  wget -q "https://files.pythonhosted.org/packages/source/i/impacket/impacket-$IMP_VER.tar.gz" -O imp.tgz
  got=$(sha256sum < imp.tgz | cut -d' ' -f1)
  [ "$got" = "$IMP_SDIST_SHA" ] || { echo "impacket sdist sha256 MISMATCH -- refusing" >&2
                                     echo "  got  $got" >&2; echo "  want $IMP_SDIST_SHA" >&2; exit 1; }
  tar xzf imp.tgz
  rm -rf "$OUT/impacket"; mkdir "$OUT/impacket"
  cp "impacket-$IMP_VER"/examples/*.py "$OUT/impacket/"
  rm -rf "impacket-$IMP_VER" imp.tgz
  echo "impacket: $IMP_VER staged ($(ls "$OUT/impacket"/*.py | wc -l | tr -d ' ') tools)"
else
  echo "note: no impacket.requirements beside $0 -- skipping impacket" >&2
fi

echo "staged: python $("$OUT/python/bin/python3" --version 2>&1)  +  sqlmap @$(git -C sqlmap rev-parse --short HEAD)"
echo "size: python $(du -sh python|cut -f1), sqlmap $(du -sh sqlmap|cut -f1)$([ -d "$OUT/impacket" ] && echo ", impacket $(du -sh "$OUT/impacket"|cut -f1)")"

#!/bin/sh
# build-games.sh -- stage the carried interactive-fiction library for the
# XOS-KNOW stick's games/if/. frotz (built in build-arsenal-c.sh) plays these;
# this fetches the story files themselves, the game half of the payload.
#
# WHY IF: morale is a supply, and interactive fiction is the one game genre a
# text-only box runs natively -- one ~200KB frotz binary plays a whole library
# of .z5/.z8 story files, no gui, no curses, works on a busybox console.
#
# TRUST: the IF Archive serves over https but ships no per-file signature, so
# each story is pinned by sha256 here and verified before it is staged --
# trust-on-first-use, same tier as SecLists in build-wordlists.sh. a hash
# mismatch fails that story loud and does not stage it; the others still run.
#
# ZORK IS NOT HERE, BY LAW: the infocom zork trilogy is still copyrighted and
# not freely redistributable, so it is never auto-fetched -- same skip pattern
# as build-wordlists.sh leaving out the leaked-password dumps. drop your own
# legally-obtained zork1.z3 (etc) into games/if/ by hand; frotz plays it the
# same. the two staged below are freeware, released by their authors.
#
# needs: wget or curl, sha256sum. output: ./games/if/{spider-and-web.z5,
# anchorhead.z8} + games.lock committed next to this script.
set -eu
OUT="${1:-games/if}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

# name<TAB>on-stick filename<TAB>url<TAB>sha256 -- one story per line. the
# on-stick name is the friendly one the launcher/README reference; the IF
# Archive's own filename (Tangle.z5, anchor.z8) is only the fetch source.
STORIES="
spider-and-web	spider-and-web.z5	https://ifarchive.org/if-archive/games/zcode/Tangle.z5	dd5b510fb04daaa2fa9a40fc94414eee3719a72e274c77288b41629e32470817
anchorhead	anchorhead.z8	https://ifarchive.org/if-archive/games/zcode/anchor.z8	c2f28a4ddd9367c260946926a33c73a4b0cc38b1f327646cc1202182a28a10ff
"

fetch() { # url dest -- curl if present, else wget; fail non-zero on either
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 120 -o "$2" "$1"
  else wget -q -O "$2" "$1"; fi
}

printf '%s\n' "$STORIES" | while IFS='	' read -r name file url sha; do
  [ -n "$name" ] || continue
  dst="$OUT/$file"
  if ! fetch "$url" "$dst.tmp"; then
    echo "  $name: FETCH FAILED ($url)" >&2; rm -f "$dst.tmp"; echo x >>"$OUT/.fail"; continue
  fi
  got=$(sha256sum "$dst.tmp" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    echo "  $name: SHA MISMATCH -- got $got, want $sha" >&2; rm -f "$dst.tmp"; echo x >>"$OUT/.fail"; continue
  fi
  # sanity: byte 0 of a z-file is its z-machine version (5 or 8 here); a
  # served error page or truncation would not carry it.
  v=$(od -An -tu1 -N1 "$dst.tmp" | tr -d ' ')
  case "$v" in 5|8) : ;; *) echo "  $name: not a z-machine story (v=$v)" >&2; rm -f "$dst.tmp"; echo x >>"$OUT/.fail"; continue ;; esac
  mv -f "$dst.tmp" "$dst"
  echo "  $name -> if/$file  ($(du -h "$dst" | cut -f1), z$v)"
done
[ -f "$OUT/.fail" ] && { FAILED=1; rm -f "$OUT/.fail"; }

# emit the lock, one line per story actually staged -- same shape as
# docs.lock/wordlists.lock: a comment header, then source<space>pin<space>size.
LOCK="$HERE/games.lock"
{
  printf '# games.lock -- interactive-fiction library staged %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
  printf '# freeware only; infocom zork is copyright and operator-supplied by hand\n'
  printf '# name  source  sha256  size\n'
  printf '%s\n' "$STORIES" | while IFS='	' read -r name file url sha; do
    [ -n "$name" ] || continue
    f="$OUT/$file"; [ -f "$f" ] || continue
    printf '%s  ifarchive.org%s  %s  %s\n' \
      "$name" "$(printf '%s' "$url" | sed 's#https://ifarchive.org##')" "$sha" "$(du -h "$f" | cut -f1)"
  done
} > "$LOCK"

echo
echo "== if library staged into $OUT/ =="
ls -1 "$OUT" 2>/dev/null | sed 's/^/  /'
echo "lock: $LOCK"
[ "$FAILED" -eq 0 ] || { echo "one or more stories failed -- see above" >&2; exit 1; }

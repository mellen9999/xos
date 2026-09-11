#!/bin/sh
# build-docs.sh -- stage offline reference docs for ~/docs/: exploit-db,
# man-pages, gtfobins, an rfc bundle. four independent sub-fetches; one
# failing does not hide or skip the others, and any failure exits this
# script non-zero after all four have been attempted.
#
# needs: git, wget, tar, xz, sha256sum, rsync. gpg is used if present (see
# docs_manpages below); its absence downgrades that pin, it does not block.
set -eu
OUT="${1:-docs}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

# -- exploit-db: searchsploit + the CSV indexes -----------------------------
# gitlab.com/exploit-database/exploitdb is the canonical upstream (the github
# offensive-security/exploitdb repo is explicitly marked legacy/read-only,
# pointing here). a shallow clone of a moving branch can drift even at
# --depth 1 if the remote tip advances mid-fetch, so this pins an exact
# commit and verifies HEAD == pin after checkout, not just "clone succeeded".
docs_exploitdb() {
  pin=ef58d5f4e31fefec0e36298c0b3e718801afdeb8
  repo=https://gitlab.com/exploit-database/exploitdb.git
  d="$OUT/exploitdb"
  if [ -d "$d/.git" ] && [ "$(git -C "$d" rev-parse HEAD 2>/dev/null || true)" = "$pin" ]; then
    echo "  exploit-db: already at pinned commit $pin"
    return 0
  fi
  rm -rf "$d"
  git clone --quiet --no-checkout "$repo" "$d"
  git -C "$d" fetch --quiet origin "$pin" --depth 1
  git -C "$d" checkout --quiet "$pin"
  got=$(git -C "$d" rev-parse HEAD)
  [ "$got" = "$pin" ] || {
    echo "FAIL: exploit-db HEAD $got does not match pinned $pin" >&2
    return 1
  }
  echo "  exploit-db: verified @ $pin"
}

# -- man-pages: the section 2/3/etc reference ---------------------------------
# kernel.org hosts man-pages and its maintainer signs every release the same
# way linux/cryptsetup/util-linux are signed in build.sh -- so this reuses
# that trust chain (a committed detached signature + committed pubkey,
# matched against a pinned fingerprint) instead of inventing a weaker TOFU
# sha256 scheme for a source that already has a maintainer signature.
# fingerprint established via two channels (2026-09-10): keys.openpgp.org
# (independent keyserver) and WKD for alx@kernel.org (kernel.org's own
# web-key-directory), both resolving to the same signing subkey.
docs_manpages() {
  ver=6.19
  tb="man-pages-$ver.tar.xz"
  TB_SHA=88a7c42ad2e03d8b96dc72d95e451f2d875ff0f43103a8eb8ac8242133bdcb05
  FPR=4BB26DF6EF466E6956003022EB89995CC290C2A9   # Alejandro Colomar (man-pages)
  base="https://www.kernel.org/pub/linux/docs/man-pages"
  cache="${XOS_CACHE:-$HOME/.cache/xos/tarballs}/arsenal"; mkdir -p "$cache"
  t="$cache/$tb"

  if [ -f "$t" ] && [ "$(sha256sum < "$t" | cut -d' ' -f1)" = "$TB_SHA" ]; then
    echo "  man-pages: cached $tb already verified against pin"
  else
    echo "  man-pages: fetching $tb ..."
    wget -q "$base/$tb" -O "$t.part" || {
      echo "  man-pages: primary unreachable -- trying the wayback machine" >&2
      wget -q "https://web.archive.org/web/2999id_/$base/$tb" -O "$t.part"
    }
    got=$(sha256sum < "$t.part" | cut -d' ' -f1)
    [ "$got" = "$TB_SHA" ] || {
      rm -f "$t.part"
      echo "FAIL: $tb sha256 mismatch -- refusing" >&2
      echo "  got  $got" >&2
      echo "  want $TB_SHA" >&2
      return 1
    }
    mv "$t.part" "$t"
    echo "  man-pages: sha256 verified against pin"
  fi

  if command -v gpg >/dev/null 2>&1; then
    gh=$(mktemp -d)
    gpg -q --homedir "$gh" --import "$HERE/sigs/man-pages-release-key.asc" 2>/dev/null
    st=$(xz -dc "$t" | gpg --homedir "$gh" --status-fd 1 --verify "$HERE/sigs/man-pages-$ver.tar.sign" - 2>/dev/null || true)
    rm -rf "$gh"
    printf '%s\n' "$st" | grep -q "VALIDSIG $FPR" || {
      echo "FAIL: man-pages signature does not match pinned fingerprint $FPR" >&2
      return 1
    }
    printf '%s\n' "$st" | grep -q '^\[GNUPG:\] REVKEYSIG' && {
      echo "FAIL: man-pages signing key is REVOKED -- refusing" >&2
      return 1
    }
    printf '%s\n' "$st" | grep -q '^\[GNUPG:\] GOODSIG' || {
      echo "FAIL: man-pages signature not GOOD (expired key?)" >&2
      return 1
    }
    echo "  man-pages: maintainer signature verified ($(printf '%s' "$FPR" | cut -c1-16)...)"
  else
    echo "  man-pages: gpg not installed -- signature not checked (sha256 pin still enforced)"
  fi

  rm -rf "$OUT/man-pages-$ver"
  tmp=$(mktemp -d)
  tar -xJf "$t" -C "$tmp"
  [ -d "$tmp/man-pages-$ver" ] || { echo "FAIL: man-pages-$ver/ missing from tarball" >&2; rm -rf "$tmp"; return 1; }
  mv "$tmp/man-pages-$ver" "$OUT/man-pages-$ver"
  rm -rf "$tmp"
  echo "  man-pages: staged man-pages-$ver/"
}

# -- gtfobins: offline living-off-the-land / privesc reference --------------
# pairs with pspy (arsenal-catalog): pspy finds the SUID binary or cron job,
# this says what to do with it. same commit-pin-and-verify shape as
# exploit-db above -- small enough (~2.4MB, 478 binaries) that there is no
# tarball/cache tier to bother with, just a shallow clone at a pinned commit.
docs_gtfobins() {
  pin=acd524623f9c406acedd2754ebd9c2431f3675ad
  repo=https://github.com/GTFOBins/GTFOBins.github.io.git
  d="$OUT/gtfobins"
  if [ -d "$d/.git" ] && [ "$(git -C "$d" rev-parse HEAD 2>/dev/null || true)" = "$pin" ]; then
    echo "  gtfobins: already at pinned commit $pin"
    return 0
  fi
  rm -rf "$d"
  git clone --quiet --no-checkout "$repo" "$d"
  git -C "$d" fetch --quiet origin "$pin" --depth 1
  git -C "$d" checkout --quiet "$pin"
  got=$(git -C "$d" rev-parse HEAD)
  [ "$got" = "$pin" ] || {
    echo "FAIL: gtfobins HEAD $got does not match pinned $pin" >&2
    return 1
  }
  echo "  gtfobins: verified @ $pin"
}

# -- rfc bundle: the protocol reference ---------------------------------------
# rfc-editor.org retired its bulk RFC-all.tar.gz some years back (verified
# 2026-09-10: the path 404s, and the current /retrieve/bulk/ page documents
# rsync as the only supported bulk mechanism now). "rfcs-text-only" is the
# plain-text module -- readable with busybox less/grep, no pdf/json/html
# baggage -- at ~555MB, comfortably inside the docs budget (the full "rfcs"
# module with every format is ~4.8GB, which is not).
#
# this source gets NO fixed sha256 pin: the corpus gains new RFCs every week,
# so a hash frozen at build time would fail every subsequent run through no
# fault of the fetch. rsync itself has no TLS, so unlike the other two
# sub-fetches this is trust-on-first-use over an unauthenticated transport --
# the weakest tier in this repo (same as ii/abduco/bearssl), recorded here
# rather than dressed up as a real pin. the sanity floor that IS enforced: a
# file count so low it implies a wrong module name or an empty/broken mirror.
docs_rfcs() {
  command -v rsync >/dev/null 2>&1 || { echo "FAIL: rsync not installed" >&2; return 1; }
  d="$OUT/rfcs"; mkdir -p "$d"
  rsync -a --delete --timeout=120 rsync.rfc-editor.org::rfcs-text-only/ "$d/" || {
    echo "FAIL: rsync from rfc-editor.org failed" >&2
    return 1
  }
  n=$(find "$d" -maxdepth 1 -name 'rfc*.txt' | wc -l)
  [ "$n" -gt 5000 ] || {
    echo "FAIL: only $n rfc text files synced (expected 5000+) -- module renamed or mirror broken" >&2
    return 1
  }
  echo "  rfc-bundle: $n rfc text files synced from rfcs-text-only"
}

docs_exploitdb || FAILED=1
docs_manpages  || FAILED=1
docs_gtfobins  || FAILED=1
docs_rfcs      || FAILED=1

LOCK="$HERE/docs.lock"
{
  printf '# docs.lock -- staged %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
  printf '# source  pin  size\n'
  [ -d "$OUT/exploitdb" ] && printf 'exploit-db  gitlab.com/exploit-database/exploitdb@%s  %s\n' \
    "$(git -C "$OUT/exploitdb" rev-parse HEAD 2>/dev/null || echo unknown)" "$(du -sh "$OUT/exploitdb" | cut -f1)"
  [ -d "$OUT/man-pages-6.19" ] && printf 'man-pages   kernel.org/man-pages-6.19+sha256:%s+gpg:%s  %s\n' \
    "88a7c42ad2e03d8b96dc72d95e451f2d875ff0f43103a8eb8ac8242133bdcb05" "4BB26DF6EF466E6956003022EB89995CC290C2A9" \
    "$(du -sh "$OUT/man-pages-6.19" | cut -f1)"
  [ -d "$OUT/gtfobins" ] && printf 'gtfobins    github.com/GTFOBins/GTFOBins.github.io@%s  %s\n' \
    "$(git -C "$OUT/gtfobins" rev-parse HEAD 2>/dev/null || echo unknown)" "$(du -sh "$OUT/gtfobins" | cut -f1)"
  [ -d "$OUT/rfcs" ] && printf 'rfc-bundle  rsync.rfc-editor.org::rfcs-text-only(unpinned,point-in-time)  %s\n' \
    "$(du -sh "$OUT/rfcs" | cut -f1)"
} > "$LOCK"

echo
echo "== docs staged into $OUT/ =="
column -t "$LOCK" 2>/dev/null | sed 's/^/  /' || sed 's/^/  /' "$LOCK"
echo "  total: $(du -sh "$OUT" | cut -f1)"
echo "  use:  searchsploit <term>"
echo "        man -M $OUT/man-pages-6.19 <page>"
echo "        rg -i '<binary>' $OUT/gtfobins/_gtfobins/  (or: jq . $OUT/gtfobins/api.json)"
echo "        grep -ril '<topic>' $OUT/rfcs/"

[ "$FAILED" -eq 0 ] || { echo "FAIL: one or more sub-fetches failed -- see above" >&2; exit 1; }

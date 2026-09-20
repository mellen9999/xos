#!/bin/sh
# build-books.sh -- stage the carried reference shelf for the XOS-KNOW stick's
# books/. the long-form half of the offline knowledge payload: build-docs.sh
# carries what you LOOK UP (man-pages, rfcs, gtfobins), this carries what you
# READ THROUGH when there is nobody to ask and no search engine to ask it.
#
# WHY BOOKS: the stick already teaches the shell (`learn`) and already carries
# a compiler (tcc, in the arsenal). Neither of those teaches you C. A 16 GB
# stick spends ~400 MB on tools and has fifteen gigabytes doing nothing, and
# "how do I write a program on this thing" is the one question the machine
# cannot answer about itself. Thirty-six megabytes closes that.
#
# WHERE: books/ on the XOS-KNOW stick, not p3 -- same reasoning as the zims and
# the if library. It is knowledge payload: bigger than tooling, never needs
# exec, mounted read-only, and it must not eat the loot space on the operator
# partition.
#
# TRUST: none of these publish a signature, so each is pinned by sha256 here
# and verified before it is staged -- trust-on-first-use, the same tier as the
# IF stories in build-games.sh and SecLists in build-wordlists.sh. A mismatch
# fails that book loud and stages nothing for it; the others still land. These
# are living documents and a new edition WILL break its pin: that is the pin
# working. Re-read the licence, re-measure, bump the line.
#
# LICENCES ARE A COLUMN, NOT A MEMORY. Every other payload in this tree is
# pinned for integrity only, because a wordlist and a man page carry no terms.
# A book does. Five of the seven below are Creative Commons NonCommercial:
#
#     THE SHELF MAY BE GIVEN AWAY. A STICK CARRYING IT MAY NOT BE SOLD.
#
# and two are NoDerivatives, so they travel verbatim -- never re-typeset, never
# excerpted into another document. books.lock records the licence per title and
# books/LICENCES lands beside the files, so the constraint rides the payload
# instead of living in whoever built the stick. A title whose terms forbid
# redistribution is never auto-fetched -- the same rule that keeps zork out of
# build-games.sh and the leaked password dumps out of build-wordlists.sh. K&R,
# OSTEP and Crafting Interpreters are free to READ and not free to CARRY; put
# your own copy in books/ by hand if you own one.
#
# READING THEM ON THE STICK: the console is text-only, so a PDF needs
# `mutool draw -F txt book.pdf` (mutool is in the arsenal) piped to `less`.
# The python docs are carried as the official TEXT bundle for exactly that
# reason -- grep and less, no renderer in the way.
#
# needs: curl or wget, sha256sum, tar+bzip2 (for the python text bundle).
# output: ./books/ + books.lock committed next to this script.
set -eu
OUT="${1:-books}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

# name<TAB>on-stick file<TAB>url<TAB>sha256<TAB>licence<TAB>one-line what
#
# the on-stick name is the readable one; upstream's own filename (modernC.pdf,
# bgnet_usl_c_1.pdf) is only the fetch source. tabs, because the description
# field has spaces in it.
BOOKS="
modern-c	modern-c.pdf	https://inria.hal.science/hal-02383654v2/file/modernC.pdf	170dcbcaf98644f99703c4eb8529392739aa34bff4d1a4a131e719870251dfe9	CC-BY-NC-ND-4.0	C as it is actually written now, not in 1978
think-python	think-python.pdf	https://greenteapress.com/thinkpython2/thinkpython2.pdf	9d923cacf1b07e88a6314395a5afafae1aa01cd1aa0ce16b1851d38b18542487	CC-BY-NC-3.0	python from nothing, for someone who has never programmed
sicp	sicp.pdf	https://github.com/sarabander/sicp-pdf/raw/5b3a5b2165c414a689873fd316a7293bc587b1c7/sicp.pdf	08709a87567d8311d6fd29c4f4a5386801153e71450e628c4a5a5d7e85feda8b	CC-BY-SA-4.0	how to think about programs at all -- the one with no expiry date
tlcl	linux-command-line.pdf	https://sourceforge.net/projects/linuxcommand/files/TLCL/19.01/TLCL-19.01.pdf/download	deb86645911b629619134dac6e2c9cbdec6ae28a8faa56bd99381f1ee7112113	CC-BY-NC-ND-3.0	the shell in book form, where learn is the shell in card form
beej-net	beej-network-programming.pdf	https://beej.us/guide/bgnet/pdf/bgnet_usl_c_1.pdf	c1c6fb4652b933eb919d5220b4b37bcb7e11f5a226991de2ccf315262e28b3e7	CC-BY-NC-ND-3.0	sockets in C -- how the wireguard/tls side of this stick works underneath
pro-git	pro-git.pdf	https://github.com/progit/progit2/releases/download/2.1.450/progit.pdf	403f4051cdca2c585361d85f6e87d5dd87d8c544fc91dced007711babe81e8ef	CC-BY-NC-SA-3.0	git past the four commands, for a repo you cannot look up
python-docs	python-3.13-docs-text.tar.bz2	https://docs.python.org/3.13/archives/python-3.13-docs-text.tar.bz2	58a54e3ecb4067180d78fdeb87bc4859c60c0f21383423bc92b63fecfc8d6b77	PSF-2.0	the whole stdlib reference, as text, greppable
"

fetch() { # url dest -- curl if present, else wget; non-zero on either
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 600 -o "$2" "$1"
  else wget -q -O "$2" "$1"; fi
}

# a served error page is the failure this catches: it has a 200 and the wrong
# bytes. the sha pin would catch it too, but naming WHAT arrived turns "sha
# mismatch" into "that url is now a login wall".
shaped() { # FILE NAME -- 0 if FILE's bytes are the kind NAME claims. two
           # arguments because the file on disk is still called .tmp.
  case "$2" in
    *.pdf)      [ "$(dd if="$1" bs=4 count=1 2>/dev/null)" = '%PDF' ] ;;
    *.tar.bz2)  [ "$(dd if="$1" bs=3 count=1 2>/dev/null)" = 'BZh' ] ;;
    *)          [ -s "$1" ] ;;
  esac
}

printf '%s\n' "$BOOKS" | while IFS='	' read -r name file url sha lic what; do
  [ -n "$name" ] || continue
  dst="$OUT/$file"
  if [ -f "$dst" ] && [ "$(sha256sum < "$dst" | cut -d' ' -f1)" = "$sha" ]; then
    echo "  $name: already staged and verified"
    continue
  fi
  if ! fetch "$url" "$dst.tmp"; then
    echo "  $name: FETCH FAILED ($url)" >&2; rm -f "$dst.tmp"; echo x >>"$OUT/.fail"; continue
  fi
  got=$(sha256sum "$dst.tmp" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    echo "  $name: SHA MISMATCH -- got $got, want $sha" >&2
    shaped "$dst.tmp" "$file" \
      || echo "  $name: and the bytes are not a $file either -- check the url by hand" >&2
    rm -f "$dst.tmp"; echo x >>"$OUT/.fail"; continue
  fi
  mv -f "$dst.tmp" "$dst"
  echo "  $name -> books/$file  ($(du -h "$dst" | cut -f1), $lic)"
done
[ -f "$OUT/.fail" ] && { FAILED=1; rm -f "$OUT/.fail"; }

# the text bundle is carried compressed and read expanded: the console has no
# pdf renderer in the base image, and `grep -r` over a tree is the whole reason
# this one is text and not a pdf.
py="$OUT/python-3.13-docs-text.tar.bz2"
if [ -f "$py" ] && [ ! -d "$OUT/python-3.13-docs-text" ]; then
  if tar xjf "$py" -C "$OUT" 2>/dev/null; then
    echo "  python-docs: expanded to books/python-3.13-docs-text/"
  else
    echo "  python-docs: could not expand (no bzip2?) -- the tarball is staged" >&2
  fi
fi

# the licence text rides with the books, because the terms are a property of
# the payload and not of the machine that built it. whoever finds this stick in
# ten years gets the rules with the files.
{
  printf 'LICENCES -- the reference shelf on this stick\n'
  printf '=============================================\n\n'
  printf 'Every title here is carried under a licence that permits redistribution.\n'
  printf 'Most of them permit it NON-COMMERCIALLY ONLY:\n\n'
  printf '    THIS SHELF MAY BE GIVEN AWAY.\n'
  printf '    A STICK CARRYING IT MAY NOT BE SOLD.\n\n'
  printf 'The NoDerivatives titles travel verbatim: read them, copy them whole,\n'
  printf 'do not re-typeset or excerpt them into something else.\n\n'
  printf 'Attribution and terms, per title:\n\n'
  printf '%s\n' "$BOOKS" | while IFS='	' read -r name file url sha lic what; do
    [ -n "$name" ] || continue
    [ -f "$OUT/$file" ] || continue
    printf '  %-13s %-18s %s\n' "$name" "$lic" "$url"
  done
  printf '\nLicence texts: creativecommons.org/licenses/<id>/ ; PSF-2.0 at\n'
  printf 'docs.python.org/3/license.html . The full text is not carried because\n'
  printf 'every one of these documents already contains its own licence page.\n'
} > "$OUT/LICENCES"

# the lock, one line per book actually staged -- docs.lock/games.lock shape
# plus the column those two do not need: a licence.
LOCK="$HERE/books.lock"
{
  printf '# books.lock -- reference shelf staged %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
  printf '# redistributable only; NC titles may be given away, never sold\n'
  printf '# titles that are free to read but not to carry (k&r, ostep, crafting\n'
  printf '# interpreters) are operator-supplied by hand, like infocom zork\n'
  printf '# name  licence  sha256  size  source\n'
  printf '%s\n' "$BOOKS" | while IFS='	' read -r name file url sha lic what; do
    [ -n "$name" ] || continue
    f="$OUT/$file"; [ -f "$f" ] || continue
    printf '%s  %s  %s  %s  %s\n' "$name" "$lic" "$sha" "$(du -h "$f" | cut -f1)" \
      "$(printf '%s' "$url" | sed -e 's#^https://##')"
  done
} > "$LOCK"

echo
echo "== reference shelf staged into $OUT/ =="
ls -1 "$OUT" 2>/dev/null | sed 's/^/  /'
echo "  total: $(du -sh "$OUT" | cut -f1)"
echo "lock:  $LOCK"
echo "terms: $OUT/LICENCES  -- give it away, never sell it"
echo "read:  mutool draw -F txt books/modern-c.pdf | less"
echo "       grep -ri socket books/python-3.13-docs-text/"
[ "$FAILED" -eq 0 ] || { echo "one or more books failed -- see above" >&2; exit 1; }

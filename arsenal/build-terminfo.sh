#!/bin/sh
# build-terminfo.sh -- the terminfo entries the carried ncurses tools need.
#
# testdisk, photorec and dvtm link a static ncurses, and the stick has no
# terminfo database: each one stopped at "Terminfo file is missing" before
# drawing a screen. this copies the compiled entries for the terminals a stick
# meets -- its own consoles (linux, the vt serial family), the ssh clients that
# reach it, and dvtm's own (it sets TERM=dvtm-256color for what runs inside) --
# from the same alpine release the C set is built in, so the entries match the
# ncurses those binaries carry. provision ships the tree to ~/tools/terminfo
# and xexec points TERMINFO_DIRS at it.
#
# needs: docker. output: ./arsenal/terminfo/ (or $1/terminfo/), plus the
# arsenal.lock row to paste, printed last.
set -eu
OUT="${1:-arsenal}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
command -v docker >/dev/null || { echo "no docker" >&2; exit 1; }
rm -rf "$OUT/terminfo"
docker run --rm -i --network host -v "$OUT":/out alpine:3.20 sh -e <<'INNER'
apk add --no-cache ncurses-terminfo >/dev/null
for t in linux vt52 vt100 vt102 vt220 vt320 dumb ansi \
         xterm xterm-color xterm-256color screen screen-256color tmux tmux-256color \
         dvtm dvtm-256color foot alacritty st-256color; do
  f=/usr/share/terminfo/$(printf %.1s "$t")/$t
  [ -f "$f" ] || f=/etc/terminfo/$(printf %.1s "$t")/$t
  [ -f "$f" ] || { echo "terminfo: no entry for $t" >&2; exit 1; }
  mkdir -p "/out/terminfo/${t%"${t#?}"}"
  cp "$f" "/out/terminfo/${t%"${t#?}"}/$t"
done
apk list -I 2>/dev/null | sed -n 's/^ncurses-terminfo-\([0-9][^ ]*\) .*/\1/p' > /out/terminfo/.ncurses
chown -R "$(stat -c %u:%g /out)" /out/terminfo
INNER
v=$(cat "$OUT/terminfo/.ncurses"); rm -f "$OUT/terminfo/.ncurses"
# one sha over the whole tree: every entry's own sha, in a fixed order
sha=$(cd "$OUT" && find terminfo -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
bytes=$(cd "$OUT" && find terminfo -type f -exec cat {} + | wc -c)
echo "terminfo: $(find "$OUT/terminfo" -type f | wc -l) entries -> $OUT/terminfo"
printf 'terminfo    ncurses@%s(terminfo-db)  %s  %s\n' "$v" "$bytes" "$sha"

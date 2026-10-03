#!/bin/sh
# install.sh -- put the arsenal (tool index + graded school) on this host as a
# standalone `arsenal` command, no stick needed. the sibling of learn/install.sh.
#
# the corpus shares one dir with the carried tools (nmap, httpx, ...), exactly as
# ~/tools does on the stick: the dispatcher indexes the tools there and the
# school's jail resolves them through ARSENAL_BIN. so this NEVER wipes the share
# dir -- it replaces only the corpus items it owns and leaves staged tools alone.
#
# run-graded cards need their carried tool present (staged into the share dir or
# ~/tools); a card whose tool is absent notes+skips rather than failing, and on a
# non-root host the jail degrades to a plain scratch run as you (no nobody drop).
# progress lives under ~/.local/state and is NOT touched, so re-installing never
# costs you your streak. re-run it after any change to the trainer.
set -eu

src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)        # the repo root (arsenal/..)
a="$src/arsenal"
[ -f "$src/busybox" ] || { echo "install: no busybox at $src -- run ./build.sh fetch busybox" >&2
	echo "install: that is the only part of the image the arsenal school needs to run" >&2; exit 1; }
[ -x "$a/learn" ] || { echo "install: no arsenal school at $a/learn" >&2; exit 1; }

share="${XDG_DATA_HOME:-$HOME/.local/share}/xos-arsenal"
bindir="$HOME/.local/bin"
mkdir -p "$share" "$bindir"

# the corpus items this installer owns: the dispatcher, the school, the engine
# libs, and the content. everything else in the share dir -- the carried tool
# binaries -- is deliberately left untouched.
items="arsenal learn lib levels pools phrases ref rekeys arsenal-catalog arsenal-playbook xexec"
[ -f "$a/arsenal.lock" ] && items="$items arsenal.lock"

# stage every item, then swap each into place with a rename, so an arsenal
# running mid-install never reads a half-written corpus.
stage="$share/.staging.$$"
rm -rf "$stage"; mkdir -p "$stage"
cp -a "$src/busybox" "$stage/busybox"
# the shell-grammar table the Tab panel glosses is the fort's own; one source.
cp -a "$src/learn/syntax" "$stage/syntax"
for it in $items; do cp -a "$a/$it" "$stage/$it"; done
for it in busybox syntax $items; do
	rm -rf "$share/.old.$it" 2>/dev/null || true
	[ -e "$share/$it" ] && mv "$share/$it" "$share/.old.$it"
	mv "$stage/$it" "$share/$it"
	rm -rf "$share/.old.$it"
done
rm -rf "$stage"

# the applet names, rebuilt every install: answers run with these ahead of the
# host's own on PATH, so a card is graded by the commands the image has and not
# by whatever gnu coreutils prints this year.
rm -rf "$share/bb"; mkdir -p "$share/bb"
"$share/busybox" --install -s "$share/bb" 2>/dev/null ||
	for ap in $("$share/busybox" --list); do ln -sf "$share/busybox" "$share/bb/$ap"; done
# the multicall binary by its own name too, as /bin/busybox is on the stick
ln -sf "$share/busybox" "$share/bb/busybox"

# what this corpus is, written where it can be read back.
(cd "$src" && git rev-parse --short HEAD 2>/dev/null || echo unknown) > "$share/VERSION"

# one wrapper, kept in the tree beside the corpus.
cp "$a/wrapper" "$bindir/arsenal"
chmod +x "$bindir/arsenal"

# it is not installed until it runs: a corpus that copied but cannot start is
# exactly what a silent installer hides.
"$bindir/arsenal" --help >/dev/null 2>&1 || { echo "install: arsenal does not run after the copy" >&2; exit 1; }

echo "install: arsenal -> $bindir/arsenal ($(cat "$share/VERSION"), corpus + busybox in $share)"
echo "install: run-gradeable tools found in $share and ~/tools; absent ones note+skip"
case ":$PATH:" in *":$bindir:"*) ;; *) echo "install: note -- $bindir is not on PATH" >&2 ;; esac

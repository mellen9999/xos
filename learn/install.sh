#!/bin/sh
# install.sh -- put learn on this host as a standalone command, no stick needed.
# copies the corpus and the tree's static-pie busybox into a private share dir
# and drops a wrapper on PATH. re-run it after any change to the trainer; that
# is the whole point -- a hand-copied install drifts out of date silently, and
# an out-of-date copy is worse than none because it teaches the old answers.
#
# progress (cards, passed levels, answer history) lives under ~/.local/state
# and is NOT touched here, so re-installing never costs you your streak.
set -eu

src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)   # the repo's learn/ parent
[ -f "$src/busybox" ] || { echo "install: no busybox at $src -- run ./build.sh fetch busybox" >&2
	echo "install: that is the only part of the image learn needs; the kernel, the keys and the signing are not built by it" >&2; exit 1; }
[ -x "$src/learn/learn" ] || { echo "install: no learn at $src/learn" >&2; exit 1; }

share="${XDG_DATA_HOME:-$HOME/.local/share}/xos-learn"
bindir="$HOME/.local/bin"
mkdir -p "$share" "$bindir"

# stage into a sibling dir and swap it in with a rename, so a learn running
# mid-install never reads a half-written corpus. the old tree is removed only
# once the new one is fully in place.
stage="$share/.staging.$$"
rm -rf "$stage"; mkdir -p "$stage"
cp -a "$src/busybox" "$stage/busybox"
cp -a "$src/learn"   "$stage/learn"
rm -rf "$share/learn.old" 2>/dev/null || true
[ -e "$share/busybox" ] && mv "$share/busybox" "$stage/busybox.old"
[ -e "$share/learn" ]   && mv "$share/learn"   "$share/learn.old"
mv "$stage/busybox" "$share/busybox"
mv "$stage/learn"   "$share/learn"
rm -rf "$stage" "$share/learn.old"

# the applet names, rebuilt every install: the answers run with these ahead of
# the host's own on PATH, so a card is graded by the commands the image has and
# not by whatever gnu coreutils prints this year. rebuilt rather than patched,
# because a busybox that lost an applet would otherwise leave a dead symlink
# that fails in the middle of a card.
rm -rf "$share/bb"; mkdir -p "$share/bb"
"$share/busybox" --install -s "$share/bb" 2>/dev/null ||
	for a in $("$share/busybox" --list); do ln -sf "$share/busybox" "$share/bb/$a"; done

# what this corpus is, written where it can be read back: an install that
# claims to be current and is not is the failure mode this whole file is about.
(cd "$src" && git rev-parse --short HEAD 2>/dev/null || echo unknown) > "$share/VERSION"

# one wrapper, kept in the tree beside the corpus: install.sh and push both
# copy this same file, so learn behaves identically however it got here.
cp "$src/learn/wrapper" "$bindir/learn"
chmod +x "$bindir/learn"

# it is not installed until it runs: a corpus that copied but cannot start is
# exactly what a silent installer hides.
"$bindir/learn" stats >/dev/null 2>&1 || { echo "install: learn does not run after the copy" >&2; exit 1; }

echo "install: learn -> $bindir/learn ($(cat "$share/VERSION"), corpus + busybox in $share)"
case ":$PATH:" in *":$bindir:"*) ;; *) echo "install: note -- $bindir is not on PATH" >&2 ;; esac

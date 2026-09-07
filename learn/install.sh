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
[ -f "$src/busybox" ] || { echo "install: no busybox at $src -- run ./build.sh first" >&2; exit 1; }
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

cat > "$bindir/learn" <<WRAP
#!/bin/sh
# xos learn -- the shell curriculum, standalone. corpus + static-pie busybox
# copied out of the xos tree; runs anywhere, no stick required. progress saves
# under ~/.local/state. regenerate with learn/install.sh in the xos repo.
ROOT="\${XDG_DATA_HOME:-\$HOME/.local/share}/xos-learn"
export LEARN_ROOT="\$ROOT/learn"
exec "\$ROOT/busybox" ash "\$ROOT/learn/learn" "\$@"
WRAP
chmod +x "$bindir/learn"

echo "install: learn -> $bindir/learn (corpus + busybox in $share)"
case ":$PATH:" in *":$bindir:"*) ;; *) echo "install: note -- $bindir is not on PATH" >&2 ;; esac

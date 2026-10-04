#!/bin/bash
# build/ci.sh -- the buildless tier: shellcheck, parse, parity, the schools, pin staleness, README counts -- and bump/outdated
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# lint -- shellcheck over every shell source in the tree. wired into `all`
# after the gates, but a machine without shellcheck must still be able to
# build, so absence is a printed skip (G35 still parse-checks the shipped
# scripts either way). learn/lib/* are sourced fragments with no shebang of
# their own, so they need -s sh spelled out.
# keysealproof -- seal, unlock and reseal on throwaway keys in a temp tree: the
# one path where a bug is unrecoverable (a sealed key nothing can open) and the
# one no test ever ran. also a seal whose encryption silently writes garbage:
# it must FAIL and keep the plaintext, never shred the only good copy.
keysealproof() {
  say "keys: seal, unlock, reseal, refuse a bad seal -- throwaway keys"
  local t rc=0 real; t=$(mktemp -d) || return 1
  real=$(command -v openssl)
  ( cd "$t" || exit 90
    export XOS_ALLOW_SWAP=1; RAMKEYS=$t/ram; mkdir keys
    for k in PK KEK db; do
      openssl req -new -x509 -newkey rsa:2048 -nodes -keyout "keys/$k.key" -out "keys/$k.crt" \
        -subj /CN=t -days 1 >/dev/null 2>&1 || exit 91
      cp "keys/$k.key" "$k.orig"
    done
    # a broken encrypt: exits 0, writes junk. seal must notice and keep keys.
    mkdir bin; printf '#!/bin/sh\ncase " $* " in *" -d "*) exec %s "$@" ;; esac\nwhile [ $# -gt 0 ]; do [ "$1" = -out ] && echo junk > "$2"; shift; done\n' "$real" > bin/openssl
    chmod +x bin/openssl
    PATH=$t/bin:$PATH XOS_KEYPASS=one seal >/dev/null 2>&1 && exit 1
    for k in PK KEK db; do cmp -s "keys/$k.key" "$k.orig" || exit 2; done
    XOS_KEYPASS=one seal >/dev/null 2>&1 || exit 3
    [ ! -e keys/db.key ] || exit 4
    XOS_KEYPASS=wrong unlock >/dev/null 2>&1 && exit 5
    XOS_KEYPASS=one unlock >/dev/null 2>&1 || exit 6
    cmp -s "$RAMKEYS/db.key" db.orig || exit 7
    lock >/dev/null
    XOS_KEYPASS=one XOS_NEWKEYPASS=two reseal >/dev/null 2>&1 || exit 8
    XOS_KEYPASS=one unlock >/dev/null 2>&1 && exit 9
    XOS_KEYPASS=two unlock >/dev/null 2>&1 || exit 10
    for k in PK KEK db; do cmp -s "$RAMKEYS/$k.key" "$k.orig" || exit 11; done
    lock >/dev/null
  ) || rc=$?
  rm -rf "$t"
  case $rc in
    0)  printf '  seal reads back before it shreds; unlock and reseal round-trip\n'; return 0 ;;
    1|2) printf '  \033[1;31ma seal that wrote junk was accepted -- the plaintext keys were destroyed\033[0m\n' >&2 ;;
    9)  printf '  \033[1;31mthe OLD passphrase still opens the keys after reseal\033[0m\n' >&2 ;;
    9[01]) printf '  \033[1;31mcould not set up throwaway keys (rc %s)\033[0m\n' "$rc" >&2 ;;
    *)  printf '  \033[1;31mseal/unlock/reseal round trip broke at step %s\033[0m\n' "$rc" >&2 ;;
  esac
  return 1
}

lint() {
  say "shellcheck"
  if ! command -v shellcheck >/dev/null 2>&1; then
    # 2 is "did not run", distinct from 0 "passed" and 1 "found errors". a
    # host build may skip this (shellcheck is not in deps() and touches no
    # shipped byte) but ci() must not certify what it never ran.
    printf '  \033[1;33mshellcheck not installed -- NOT CHECKED (paru -S shellcheck)\033[0m\n'
    return 2
  fi
  local out="" outb=""
  # the ci runners and the commit wall were outside this for as long as it
  # existed: a shellcheck error planted in ci/xos-ci was never seen, because
  # lint only scanned the files someone happened to list. they are first-party
  # bash that decides whether a push is accepted -- scan them.
  # the bash tier is held at WARNING, not just error: it reached zero warnings
  # on 2026-10-03 (an unused variable, an array/string name clash, two ls|grep,
  # a masked return value) and a ratchet is the only thing that keeps a zero.
  # the ash tier below stays at error -- shellcheck has no busybox-ash dialect,
  # so `local`, `read -s` and RANDOM are warnings there by design, not defects
  # (G35 parses every one of those scripts under the ash that actually ships).
  outb=$(shellcheck -S warning -x build.sh build/*.sh selftest.sh overlay/usr/share/udhcpc/default.script \
                    ci/xos-repro ci/xos-ci-full ci/xos-ci-status githooks/pre-commit githooks/pre-push; echo)
  out+=$(shellcheck init learn/learn; echo)
  out+=$(shellcheck -s sh learn/lib/* overlay/etc/shrc; echo)
  # the arsenal tree was never shellchecked though it is the security-tooling
  # half of the codebase: the school driver, its libs, the xexec doorway and the
  # provisioning scripts. PARITY/rekeys are data, not scripts, and live outside
  # arsenal/lib so this glob does not reach them.
  out+=$(shellcheck -s sh arsenal/learn arsenal/arsenal arsenal/xexec arsenal/qr arsenal/push arsenal/*.sh arsenal/lib/*; echo)
  printf '%s\n' "$outb" "$out"
  # info/style are noise until they aren't; the bash tier fails on any warning,
  # the ash tier only on error-severity, so a bump in shellcheck's own defaults
  # cannot silently red the tree on a class it never held before.
  # a listed file that is gone is no finding at all to the text match below --
  # the tool prints openBinaryFile and the file drops out of the ratchet.
  if printf '%s' "$outb$out" | has 'openBinaryFile'; then
    printf '  \033[1;31mshellcheck could not open a listed file -- renamed or removed? fix the list\033[0m\n'
    return 1
  fi
  if printf '%s' "$outb" | has '(error):' || printf '%s' "$outb" | has '(warning):'; then
    printf '  \033[1;31mshellcheck found warnings in the bash tier (held at zero)\033[0m\n'
    return 1
  fi
  if printf '%s' "$out" | has '(error):'; then
    printf '  \033[1;31mshellcheck found errors\033[0m\n'
    return 1
  fi
  printf '  \033[1;32mshellcheck clean (bash tier: no warnings; ash tier: no errors)\033[0m\n'
  return 0
}

libparity() {
  # the engine libs arsenal COPIES from the fort must not silently drift. p3
  # cannot source the signed fort (the signing boundary), so lib/cards lib/coach
  # lib/ctx lib/grade lib/ui are duplicated by hand -- and a fix that lands in
  # one copy and not the other is exactly how two ui fixes and the whole SRS
  # read-side went missing from arsenal for a release. every shared basename
  # (learn/lib INTERSECT arsenal/lib, discovered here so a future lib is covered
  # for free) must be byte-identical, EXCEPT the pairs pinned in
  # arsenal/lib/PARITY -- and a pinned pair is checked by hash on BOTH sides, so
  # the pin cannot be quieted by editing one file to match the other, or both
  # without re-pinning. reads only committed files: buildless by construction.
  # the pin file (arsenal/PARITY) lives top-level, not under arsenal/lib, so the
  # script-parse and shellcheck globs never try to read its data rows as shell.
  say "engine-lib parity (learn/lib <-> arsenal/lib)"
  local f lh ah pin="arsenal/PARITY" bad=0 want_l want_a
  for f in $(comm -12 <(ls learn/lib 2>/dev/null | sort) <(ls arsenal/lib 2>/dev/null | sort)); do
    [ -f "learn/lib/$f" ] && [ -f "arsenal/lib/$f" ] || continue
    lh=$(sha256sum < "learn/lib/$f" | cut -d' ' -f1)
    ah=$(sha256sum < "arsenal/lib/$f" | cut -d' ' -f1)
    if [ "$lh" = "$ah" ]; then
      # a stale pin (the files agree again) is a soft note, so the allowlist
      # cleans itself rather than accumulating dead rows.
      grep -q "^lib/${f}[[:space:]]" "$pin" 2>/dev/null \
        && printf '  \033[1;33mnote\033[0m lib/%s matches -- its PARITY row is stale, remove it\n' "$f"
      continue
    fi
    want_l=$(awk -v p="lib/$f" '$1==p && $2=="learn"   {print $3}' "$pin" 2>/dev/null)
    want_a=$(awk -v p="lib/$f" '$1==p && $2=="arsenal" {print $3}' "$pin" 2>/dev/null)
    if [ "$want_l" = "$lh" ] && [ "$want_a" = "$ah" ]; then
      printf '  lib/%s: pinned divergence ok\n' "$f"
    else
      printf '  \033[1;31mlib/%s DIVERGED and is not pinned\033[0m (learn=%.8s arsenal=%.8s)\n' "$f" "$lh" "$ah" >&2
      printf '    port the change to both copies, or add a reviewed pin to %s\n' "$pin" >&2
      bad=1
    fi
  done
  [ "$bad" = 0 ] && printf '  \033[1;32mshared engine libs in parity\033[0m\n'
  return $bad
}

# xexecproof -- the carried executor, behaving, not just parsing. xexec is the
# only way carried code runs on the stick (p3 is noexec), and until this it was
# parse-checked and shellchecked and never once run by anything: the seal, the
# teardown, the tree entry check were claims. a user namespace gives an
# unprivileged host root-enough to mount a tmpfs, which is all xexec needs, so
# every behaviour runs here: a staged binary executes; the surface refuses a
# write once sealed; a child the tool leaves behind does not keep the surface
# mounted; an entry that escapes the tree is refused. no userns -> SKIP, named.
xexecproof() {
  say "xexec: run, seal, tear down, refuse an escaping entry"
  [ -x ./busybox ] || { printf '  skipped: no built busybox to stage (./build.sh busybox first)\n'; return 0; }
  unshare -rm true 2>/dev/null \
    || { printf '  \033[1;33mskipped: no user namespaces on this host -- xexec behaviour unverified here\033[0m\n'; return 0; }
  local out bad=0
  # the probe the staged busybox runs: find its own surface in /proc/mounts and
  # try to write to it. a file, not a quoted one-liner -- three quoting layers
  # deep is where a probe stops meaning what it says.
  local t; t=$(mktemp -d) || return 1
  cat > "$t/seal.sh" <<'EOF'
d=$(grep -o ' [^ ]*/\.xexec\.[^ ]* ' /proc/mounts | tail -1 | tr -d ' ')
[ -n "$d" ] && [ -d "$d" ] || { echo SEAL-NOSURFACE; exit 0; }
touch "$d/new" 2>/dev/null && echo SEAL-WRITABLE || echo SEAL-OK
EOF
  out=$(unshare -rm sh -c '
    cd "$1" || exit 9
    sh arsenal/xexec ./busybox echo RUN-OK 2>&1
    sh arsenal/xexec ./busybox sh "$2/seal.sh" 2>&1
    sh arsenal/xexec ./busybox sh -c "sleep 15 >/dev/null 2>&1 & exit 0" 2>&1
    echo "MOUNTS-LEFT $(grep -c /.xexec. /proc/mounts)"
    mkdir -p "$2/tree/bin"; cp ./busybox "$2/tree/bin/"
    sh arsenal/xexec -t "$2/tree" ../../bin/sh 2>&1 | grep -q "plain path inside" && echo ESCAPE-REFUSED || echo ESCAPE-ALLOWED
    : > "$2/sib"   # one level up and REAL, so only the path rule can refuse it
    sh arsenal/xexec -t "$2/tree" ../sib 2>&1 | grep -q "plain path inside" && echo ESCAPE1-REFUSED || echo ESCAPE1-ALLOWED
    sh arsenal/xexec -t "$2/tree" bin/busybox echo TREE-OK 2>&1' _ "$PWD" "$t" 2>&1)
  rm -rf "$t"
  for want in RUN-OK SEAL-OK "MOUNTS-LEFT 0" ESCAPE-REFUSED ESCAPE1-REFUSED TREE-OK; do
    printf '%s\n' "$out" | grep -qxF -- "$want" || { bad=1; printf '    xexec: expected "%s", did not see it\n' "$want" >&2; }
  done
  printf '%s\n' "$out" | grep -qE 'SEAL-WRITABLE|SEAL-NOSURFACE|ESCAPE1?-ALLOWED|WARNING' && bad=1
  if [ "$bad" = 0 ]; then printf '  xexec runs, seals, tears down and refuses an escaping entry\n'; return 0; fi
  printf '  \033[1;31mxexec misbehaved:\033[0m\n%s\n' "$(printf '%s\n' "$out" | sed 's/^/    /')" >&2
  return 1
}

# learnship -- every $ROOT/<name> the learn engine reads is a name rootfs()
# ships to /usr/share/learn. otherwise the stick opens it as nothing (2>/dev/null)
# while the dev host, where every grader runs, has it: acts (the level groupings
# the climb is narrated by) and syn (the labels every page carries) were exactly
# that for months. the floor is derived from the engine's own text, so a file
# the engine starts reading fails here until rootfs() ships it. two dev-only
# exceptions, named: compose (a build-time ledger, G63) and learn itself (lint
# greps its own source for stray escapes); no verb on the stick reads either.
learnship() {
  say "learn ships what the engine reads"
  local lref lship f lmiss=""
  lref=$(grep -ohE '\$\{?ROOT\}?/[A-Za-z0-9_.-]+' learn/learn learn/lib/* 2>/dev/null | sed -E 's/^\$\{?ROOT\}?\///' | sort -u)
  lship=$(fnbody rootfs | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
            | grep -E '^[[:space:]]*cp ' | grep -F 'root/usr/share/learn/' | grep -oE 'learn/[A-Za-z0-9_.-]+' | sed 's|^learn/||' | sort -u)
  [ -n "$lref" ] && [ -n "$lship" ] || { echo "  FAIL: could not read the engine's references or rootfs()'s learn copies" >&2; return 1; }
  for f in $lref; do
    case "$f" in compose|learn) continue ;; esac
    printf '%s\n' "$lship" | grep -qxF -- "$f" || lmiss="$lmiss $f"
  done
  if [ -z "$lmiss" ]; then printf '  %s names read by the engine, all shipped\n' "$(printf '%s\n' "$lref" | grep -c .)"; return 0; fi
  printf '  \033[1;31mthe learn engine reads $ROOT/{%s } but rootfs() never ships it\033[0m\n' "$lmiss" >&2
  return 1
}

# schoolship -- both arsenal installers ship every file the school reads. the
# stick's populate() once copied the libs, levels and pools but never ref/ or
# rekeys, so on the stick every Tab panel said "no reference" while install.sh
# (off-stick, where it was tested) shipped them -- and nothing compared the two.
# the list is read off arsenal/learn itself (the libs its source loop names)
# plus the corpus it opens, then each installer is run into a scratch home and
# every item must land non-empty. buildless: install.sh gets a stand-in
# busybox, populate() no tool dir, so neither needs a build or the network.
schoolship() {
  say "arsenal installers ship the whole school (stick + standalone)"
  local t libs items it bad=0
  t=$(mktemp -d) || return 1
  libs=$(sed -n 's/^for _l in \(.*\); do$/\1/p' arsenal/learn | head -1)
  [ -n "$libs" ] || { echo "  FAIL: cannot read the lib list off arsenal/learn" >&2; rm -rf "$t"; return 1; }
  items="learn phrases rekeys syntax levels pools ref"
  for it in $libs; do items="$items lib/$it"; done
  # the stick: populate() into a scratch p3
  mkdir -p "$t/p3"
  SELF="$PWD/arsenal" ARSENAL="$t/none" bash -c 'set -eu; . arsenal/provision-lib.sh; populate "$1"' _ "$t/p3" >/dev/null 2>&1 \
    || { echo "  FAIL: provision-lib.sh populate errored" >&2; bad=1; }
  # off-stick: install.sh from a scratch copy of the tree, into a scratch home
  mkdir -p "$t/src/learn" "$t/home"
  cp -r arsenal "$t/src/arsenal"; cp learn/syntax "$t/src/learn/syntax"
  # the stand-in installs one applet, ash, as the host's sh: enough for the
  # installer's own does-it-run check, and nothing a card would grade by.
  printf '#!/bin/sh\n[ "$1" = --install ] && ln -sf "$(command -v sh)" "$3/ash"\nexit 0\n' > "$t/src/busybox"
  chmod +x "$t/src/busybox"
  HOME="$t/home" XDG_DATA_HOME="$t/home/share" sh "$t/src/arsenal/install.sh" >/dev/null 2>&1 \
    || { echo "  FAIL: arsenal/install.sh errored" >&2; bad=1; }
  # landed = a non-empty file, or a directory with something in it
  _landed() { if [ -d "$1" ]; then [ -n "$(ls -A "$1" 2>/dev/null)" ]; else [ -s "$1" ]; fi; }
  for it in $items; do
    _landed "$t/p3/tools/$it" || { echo "  FAIL: the stick (provision-lib.sh) does not ship $it" >&2; bad=1; }
    _landed "$t/home/share/xos-arsenal/$it" || { echo "  FAIL: install.sh does not ship $it" >&2; bad=1; }
  done
  rm -rf "$t"
  [ "$bad" = 0 ] && printf '  \033[1;32mboth installers ship: %s\033[0m\n' "$items"
  return $bad
}

# outdated -- is any pinned dependency behind its upstream? this ONLY LOOKS: it
# never changes a byte, never touches the stick. runs on your own box (needs the
# network). xos does not auto-update -- on purpose (immutable signed image) --
# so this is how you find out WHEN to rebuild, and `bump` below makes the change
# a 9-year-old can do. only STABLE releases count: after reading a project's own
# git tags we keep pure numeric versions, which drops rc/devel/beta tags.
outdated() {
  say "is anything behind?  -- this only LOOKS, it never changes your stick"
  local behind=0
  _chk() { # friendly-name  current-version  git-repo  tag-refspec(''=all)  sed(tag -> version)
    local name=$1 cur=$2 repo=$3 refspec=$4 latest top
    latest=$(timeout 25 git ls-remote --tags --refs "$repo" ${refspec:+"$refspec"} 2>/dev/null \
             | sed 's#.*/##' | eval "$5" | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)
    if [ -z "$latest" ]; then printf '  %-12s %-13s  ?  could not reach upstream -- check by hand\n' "$name" "$cur"; return; fi
    top=$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)
    if [ "$top" = "$cur" ]; then
      printf '  %-12s %-13s  up to date\n' "$name" "$cur"
    else
      printf '  \033[1;33m%-12s %-13s  BEHIND\033[0m -- newest is %s   \033[1mfix: ./build.sh bump %s %s\033[0m\n' "$name" "$cur" "$latest" "$name" "$latest"
      behind=$((behind + 1))
    fi
  }
  # kernel: stay on your own series (6.18.x) -- a .z bump is the security one; a
  # whole new series is a deliberate move, not a "you're behind".
  _chk kernel       "$KVER"   https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "v${KVER%.*}.*" "sed 's/^v//'"
  _chk busybox      "$BBVER"  https://git.busybox.net/busybox                    '' "tr '_' '.'"
  _chk cryptsetup   "$CSVER"  https://gitlab.com/cryptsetup/cryptsetup           '' "sed -n 's/^v//p'"
  _chk util-linux   "$UTLVER" https://github.com/util-linux/util-linux           '' "sed -n 's/^v//p'"
  _chk lvm2         "$LVMVER" https://github.com/lvmteam/lvm2                     '' "sed -n 's/^v//p'"
  _chk dropbear     "$DBVER"  https://github.com/mkj/dropbear                    '' "sed -n 's/^DROPBEAR_//p'"
  _chk wireguard    "$WGTVER" https://github.com/WireGuard/wireguard-tools       '' "sed -n 's/^v//p'"
  # odd version style (a date suffix) or a deliberately quiet project -- the
  # tag filter cannot judge these, so name them for a human. sources: SOURCES.md.
  printf '  \033[2mby hand (odd version or a quiet project): bearssl %s  popt %s  json-c %s  ii %s  abduco %s\033[0m\n' \
    "$BSSLVER" "$POPTVER" "$JSONCVER" "$IIVER" "$ABDVER"
  echo
  if [ "$behind" -eq 0 ]; then
    printf '  \033[1;32meverything checkable is current -- nothing to do.\033[0m\n'
  else
    printf '  \033[1;33m%d behind.\033[0m to update one: run its \033[1mfix:\033[0m line, then \033[1m./build.sh all\033[0m, then flash the stick.\n' "$behind"
  fi
  printf '  \033[2mxos never updates itself. nothing changed just now.\033[0m\n'
  return 0
}

# bump -- take one dependency to a new version, SAFELY, in one command. for a
# maintainer-signed dep it downloads the new tarball AND its signature, VERIFIES
# that signature against the same committed key the build trusts, and only then
# changes anything: the version, the pinned hash (sources.sha256) and the stored
# signature (sigs/). if the signature does not verify, NOTHING changes -- a fake
# or tampered version is refused before it can be pinned. an unsigned (TOFU) dep
# is pinned from what TLS delivered, said out loud. after this, `./build.sh all`
# rebuilds. usage: ./build.sh bump <name> <version>   e.g. bump cryptsetup 2.8.8
# the reversible, network-free heart of bump: retarget the version pin and the
# sources.sha256 hash line, and NOTHING else. factored out so G66 can prove, on a
# scratch copy, that a bump edits exactly those two lines and that bumping back to
# the old version restores the files byte-for-byte. operates on build.sh +
# sources.sha256 by default; BUMP_BUILD / BUMP_SRC point it at scratch copies.
_bump_apply() { # $1=const $2=old $3=new $4=pre $5=newhash $6=tb
  local const=$1 old=$2 new=$3 pre=$4 newhash=$5 tb=$6
  local B=${BUMP_BUILD:-build.sh} S=${BUMP_SRC:-sources.sha256}
  sed -i "s|^$const=\"\${$const:-$old}\"|$const=\"\${$const:-$new}\"|" "$B"
  grep -q "^$const=\"\${$const:-$new}\"" "$B" || return 1
  # drop the old line for this dep -- match the FILENAME field literally (a regex
  # on a short prefix like "ii" could hit the wrong row), keying on "${pre}-" /
  # "${pre}." exactly, whatever whitespace separates the hash from the name.
  awk -v p="$pre" 'BEGIN{lp=length(p)} {fn=$2; pfx=substr(fn,1,lp); nx=substr(fn,lp+1,1)} (pfx==p && (nx=="-"||nx==".")){next} {print}' "$S" > "$S.bump" && mv "$S.bump" "$S"
  printf '%s  %s\n' "$newhash" "$tb" >> "$S"
}

bump() {
  local name=$1 new=$2 const old signed=0 url key fpr tb pre
  # per-dep: constant, tarball URL, whether/where its maintainer signs. the three
  # kernel.org-signed ones + busybox are verified; the rest are trust-on-first-use
  # (SOURCES.md says which), pinned from TLS with a warning.
  case "$name" in
    kernel)     const=KVER;   pre=linux;         url="https://cdn.kernel.org/pub/linux/kernel/v${new%%.*}.x/linux-$new.tar.xz";                        key=sigs/linux-release-key.asc;      fpr=$LNX_FPR; signed=xz ;;
    cryptsetup) const=CSVER;  pre=cryptsetup;    url="https://cdn.kernel.org/pub/linux/utils/cryptsetup/v${new%.*}/cryptsetup-$new.tar.xz";   key=sigs/cryptsetup-release-key.asc; fpr=$CS_FPR;  signed=xz ;;
    util-linux) const=UTLVER; pre=util-linux;    url="https://cdn.kernel.org/pub/linux/utils/util-linux/v${new%.*}/util-linux-$new.tar.xz";   key=sigs/util-linux-release-key.asc; fpr=$UTL_FPR; signed=xz ;;
    busybox)    const=BBVER;  pre=busybox;       url="https://busybox.net/downloads/busybox-$new.tar.bz2";                                    key=sigs/busybox-release-key.asc;    fpr=$BB_FPR;  signed=raw ;;
    lvm2)       const=LVMVER; pre=LVM2;          url="https://sourceware.org/pub/lvm2/LVM2.$new.tgz";       signed=0 ;;
    dropbear)   const=DBVER;  pre=dropbear;      url="https://matt.ucc.asn.au/dropbear/releases/dropbear-$new.tar.bz2"; signed=0 ;;
    wireguard|wireguard-tools) const=WGTVER; pre=wireguard-tools; url="https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-$new.tar.gz"; signed=0 ;;
    json-c)     const=JSONCVER; pre=json-c;      url="https://github.com/json-c/json-c/archive/refs/tags/json-c-$new.tar.gz"; signed=0 ;;
    popt)       const=POPTVER;  pre=popt;        url="https://github.com/rpm-software-management/popt/releases/download/popt-$new-release/popt-$new.tar.gz"; signed=0 ;;
    ii)         const=IIVER;    pre=ii;          url="https://dl.suckless.org/tools/ii-$new.tar.gz"; signed=0 ;;
    abduco)     const=ABDVER;   pre=abduco;      url="https://www.brain-dump.org/projects/abduco/abduco-$new.tar.gz"; signed=0 ;;
    bearssl)    const=BSSLVER;  pre=bearssl;     url="https://bearssl.org/bearssl-$new.tar.gz"; signed=0 ;;
    *) echo "bump: don't know '$name'. try: ./build.sh outdated  (it names each one)" >&2; return 1 ;;
  esac
  [ -n "$new" ] || { echo "bump: give the new version too, e.g. ./build.sh bump cryptsetup 2.8.8" >&2; return 1; }
  old=$(sed -n "s/^$const=\"\${$const:-\(.*\)}\"/\1/p" build.sh | head -1)
  [ -n "$old" ] || { echo "bump: could not find $const in build.sh" >&2; return 1; }
  [ "$old" = "$new" ] && { echo "$name is already pinned at $new -- nothing to do."; return 0; }
  command -v curl >/dev/null 2>&1 || { echo "bump: needs curl" >&2; return 1; }
  mkdir -p "$XOS_CACHE" sigs
  tb=$(basename "$url")
  say "bump $name $old -> $new  (verify first, change nothing until it passes)"
  echo "  downloading $tb ..."
  curl -fsSL --retry 2 -o "$XOS_CACHE/$tb" "$url" || { echo "bump: could not download $url" >&2; return 1; }

  if [ "$signed" != 0 ]; then
    # the maintainer signs the UNCOMPRESSED tar (kernel.org) or the archive as
    # published (busybox). fetch the signature and verify with the SAME committed
    # key + fingerprint the build uses -- reusing sigver, so this is exactly the
    # build's own check, run early. nothing is pinned unless it returns clean.
    local signurl="${url%.tar.xz}.tar.sign"; [ "$signed" = raw ] && signurl="$url.sig"
    local signdst="sigs/$tb.NEW"; [ "$signed" = xz ] && signdst="sigs/${tb%.xz}.sign.NEW"
    echo "  downloading + verifying the maintainer signature ..."
    curl -fsSL --retry 2 -o "$signdst" "$signurl" || { rm -f "$XOS_CACHE/$tb" "$signdst"; echo "bump: could not download the signature ($signurl) -- NOT pinned" >&2; return 1; }
    if ! XOS_STRICT=1 sigver "$tb" "$signdst" "$key" "$fpr" "$([ "$signed" = xz ] && echo xz)"; then
      rm -f "$XOS_CACHE/$tb" "$signdst"
      echo "bump: signature did NOT verify -- $name $new is refused, nothing changed" >&2; return 1
    fi
  else
    printf '  \033[1;33mno maintainer signature for %s -- pinning what TLS delivered (trust-on-first-use).\n  confirm it is the real upstream before you ship.\033[0m\n' "$name"
  fi

  # verified (or TOFU-accepted): NOW commit the two content pins together --
  # the version and the sources.sha256 hash line. the surgery is factored into
  # _bump_apply so G66 can prove it edits exactly those lines and reverses clean.
  local newhash; newhash=$(sha256sum "$XOS_CACHE/$tb" | cut -d' ' -f1)
  _bump_apply "$const" "$old" "$new" "$pre" "$newhash" "$tb" \
    || { echo "bump: pin surgery failed -- nothing committed" >&2; return 1; }
  if [ "$signed" = xz ]; then
    rm -f "sigs/${pre}-$old.tar.sign"; mv "sigs/${tb%.xz}.sign.NEW" "sigs/${tb%.xz}.sign"
  elif [ "$signed" = raw ]; then
    rm -f "sigs/${pre}-$old.tar.bz2.sig"; mv "sigs/$tb.NEW" "sigs/$tb.sig"
  fi
  echo "  pinned: $const=$new, sources.sha256 ($newhash), $([ "$signed" != 0 ] && echo 'signature stored' || echo 'no sig (TOFU)')"
  echo "next:  ./build.sh all   then flash the stick.   to undo:  ./build.sh bump $name $old"
}

# ci_reconcile ROSTER RAN SKIPPED -- every rostered check ran or said why it
# did not, and nothing ran that the roster does not name (a new check must be
# rostered to count). a function of its own so the rule is provable in a
# harness without a four-minute ci run.
ci_reconcile() {
  local roster=$1 ran=$2 skipped=$3 c nran=0 nskip=0 lost="" stray="" rc=0
  for c in $roster; do
    case " $ran " in *" $c "*) nran=$((nran + 1)); continue ;; esac
    case " $skipped " in *" $c "*) nskip=$((nskip + 1)); continue ;; esac
    lost="$lost $c"
  done
  for c in $ran $skipped; do
    case " $roster " in *" $c "*) ;; *) stray="$stray $c" ;; esac
  done
  [ -z "$lost" ]  || { printf '  \033[1;31mrostered checks that neither ran nor skipped:%s\033[0m\n' "$lost" >&2; rc=1; }
  [ -z "$stray" ] || { printf '  \033[1;31mchecks ran that the roster does not name:%s\033[0m\n' "$stray" >&2; rc=1; }
  # shellcheck disable=SC2086
  printf '  %d checks rostered: %d ran, %d skipped%s\n' "$(echo $roster | wc -w)" "$nran" "$nskip" \
    "$([ -n "$skipped" ] && printf ' (%s)' "$(echo $skipped)")"
  return $rc
}

ci() {
  # the checks that need neither the signing key nor a full image build, in one
  # command a self-hosted runner, a timer, or the pre-push hook can call. the
  # signed image gates and the qemu self-test are ./build.sh gates and
  # ./selftest.sh -- those need the key and belong in a manual or tagged tier.
  # this is the cheap-to-run, expensive-to-inherit half: a script that will not
  # parse, a shellcheck error, a corpus authoring defect. no network, no root.
  say "ci -- buildless checks (no key, no image)"
  local rc=0 f chk bb f48py
  # the run-roster. gates() reconciles what ran against its roster; ci() had
  # no such thing, so a check whose guard was false ([ -d arsenal/levels ] on a
  # partial tree, a missing Dockerfile) simply never appeared, and nothing said
  # so. every check now registers by name as it runs (cic) or as it is skipped
  # (cis, with the reason, in yellow); the summary reconciles both against this
  # list. a rostered name that did neither is a FAIL -- the check vanished.
  local CI_ROSTER="provenance shellcheck parse pyparse dockerfile trust
    learn-ledger learn-corpus arsenal-selftest arsenal-ledger arsenal-order xexec
    one-q tool-cards lock-roster ref-pages libparity schoolship learnship
    pin-source readme-counts keyseal"
  CI_ROSTER=$(echo $CI_ROSTER)   # one line, single spaces: the matches below are word-bounded by spaces
  local CI_RAN="" CI_SKIPPED=""
  cic() { CI_RAN="$CI_RAN $1"; }
  cis() { CI_SKIPPED="$CI_SKIPPED $1"; printf '  \033[1;33mSKIP\033[0m %s -- %s\n' "$1" "$2"; }
  # provenance first: it is the cheapest check here and the one that says
  # whose tree this is. unverified is not a failure -- a stranger on a shallow
  # clone, or the repro container with no openssh, must still be able to run ci.
  cic provenance; vouch || [ "$?" -eq 2 ] || rc=1
  cic keyseal; keysealproof || rc=1
  # a red CI tier on THIS machine is not a defect of this tree, so it is not a
  # failure here -- but a push from a box whose timers are red should not go
  # out blind to it. one yellow line per red tier, from the per-machine logs.
  if [ -x ci/xos-ci-status ]; then
    local red; red=$(XOS_CI_NOKERNEL=1 ci/xos-ci-status 2>/dev/null | grep -E '^[a-z]+ +(FAIL|\?\?\?\?) ' || true)
    [ -z "$red" ] || printf '\033[1;33m  warn: a CI tier on this machine is red (ci/xos-ci-status):\033[0m\n%s\n' "$(printf '%s\n' "$red" | sed 's/^/    /')"
  fi
  # a check that could not run is not a check that passed. G13 may SKIP
  # because forcing it would prove nothing; shellcheck's absence proves
  # nothing either way and is one package away, so ci refuses rather than
  # printing "buildless checks pass" over an unlinted tree.
  local lrc=0; cic shellcheck; lint || lrc=$?
  case $lrc in
    0) ;;
    2) printf '  \033[1;31mci needs shellcheck -- it cannot certify what it did not run\033[0m\n' >&2; rc=1 ;;
    *) rc=1 ;;
  esac
  # parse every first-party script under the shell its shebang names -- the
  # same coverage as gates G35/G38/G48, but runnable before anything is built.
  # type -P, not command -v: build.sh defines a busybox() build function, and
  # command -v would return THAT (and the parse loop would build busybox instead
  # of parsing). -P forces a PATH lookup for the real binary.
  bb=./busybox; [ -x "$bb" ] || bb=$(type -P busybox 2>/dev/null || true)
  say "parsing every first-party script"
  cic parse
  for f in build.sh build/*.sh selftest.sh init learn/learn learn/lib/* \
           overlay/usr/share/udhcpc/default.script overlay/etc/shrc githooks/pre-commit githooks/pre-push \
           learn/install.sh learn/push learn/wrapper ci/xos-* \
           arsenal/*.sh arsenal/push arsenal/wrapper arsenal/arsenal arsenal/xexec arsenal/qr \
           arsenal/learn arsenal/lib/*; do
    [ -f "$f" ] || continue
    # ci/xos-* also matches the systemd units and the tier README; those are
    # not scripts and `sh -n` on one is a confusing failure, not a finding.
    case "$f" in *.service|*.timer|*.md) continue ;; esac
    case "$(head -1 "$f")" in
      *bash) chk="bash -n" ;;
      *)     [ -n "$bb" ] && chk="$bb ash -n" || chk="sh -n" ;;
    esac
    $chk "$f" 2>/dev/null || { printf '  \033[1;31mparse FAIL\033[0m %s\n' "$f" >&2; rc=1; }
  done
  [ "$rc" -eq 0 ] && printf '  every script parses\n'
  # atlas, view, chart and the canvas.py engine are python, not shell -- ash
  # -n would reject them for the wrong reason, so they get the interpreter's
  # own syntax check, same as gates() G48.
  cic pyparse
  for f48py in arsenal/atlas arsenal/view arsenal/chart arsenal/canvas.py; do
    [ -f "$f48py" ] || continue
    python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$f48py" \
      || { printf '  \033[1;31mparse FAIL\033[0m %s\n' "$f48py" >&2; rc=1; }
  done
  # the reproducible-build toolchain is only reproducible if repro/Dockerfile
  # pins its inputs by content: a base image by digest (never a moving tag) and
  # a frozen Arch archive day (never the live mirror). crepro rests on both, so
  # a tag or a live-mirror slip silently breaks reproducibility -- catch it here.
  if [ -f repro/Dockerfile ]; then
    say "repro toolchain pinned"
    cic dockerfile
    local dok=1
    grep -qE '^FROM[[:space:]]+\S+@sha256:[0-9a-f]{64}' repro/Dockerfile \
      || { printf '  \033[1;31mFROM is not pinned by digest\033[0m\n' >&2; dok=0; rc=1; }
    grep -qE '^ARG ALA=[0-9]{4}/[0-9]{2}/[0-9]{2}$' repro/Dockerfile \
      || { printf '  \033[1;31mALA is not a frozen YYYY/MM/DD day\033[0m\n' >&2; dok=0; rc=1; }
    toolver || { dok=0; rc=1; }
    [ "$dok" -eq 1 ] && printf '  base pinned by digest, packages frozen to one ALA day\n'
  else
    cis dockerfile "no repro/Dockerfile in this tree"
  fi
  # the trust surface. buildless by construction -- it reads committed files
  # and nothing else -- and the class of regression it catches (a new host
  # tool, a new source, a new container package with nobody accounting for it)
  # is exactly the kind you want named on the push, not six days later.
  say "trust surface"
  cic trust; trustver || rc=1
  # the learn authoring ledger: pure static analysis, no busybox needed. it is
  # advisory by design (see lib/lint) -- printed so drift shows in the ci log,
  # never a hard fail, so it cannot breed filler.
  if [ -d learn/ref ]; then
    say "learn authoring ledger"; cic learn-ledger
    LEARN_ROOT="$PWD/learn" ./learn/learn lint 2>&1 || true
  else
    cis learn-ledger "no learn/ref"
  fi
  # order and coverage, on the other hand, ARE hard -- and they belong here
  # rather than only in the weekly signed tier, because neither needs a built
  # image: both read the committed corpus and ref pages and nothing else. a
  # question that uses a command before any level introduces it, or a flag
  # that is neither taught nor retired, is a defect you want named on the push
  # that made it, not six days later.
  if [ -d learn/ref ] && [ -n "$bb" ]; then
    say "learn corpus order and coverage"
    cic learn-corpus
    local cv_out cv_rc=0
    LEARN_ROOT="$PWD/learn" "$bb" ash learn/learn order || rc=1
    # captured rather than piped: a pipe hands back the exit status of the
    # last stage, so `coverage | sed` reports sed's success and an untaught
    # flag would have sailed past the check that exists to catch it.
    cv_out=$(LEARN_ROOT="$PWD/learn" "$bb" ash learn/learn coverage -q 2>&1) || cv_rc=1
    printf '%s\n' "$cv_out" | sed -n '3,5p'
    [ "$cv_rc" -eq 0 ] || { printf '%s\n' "$cv_out" >&2; rc=1; }
  else
    cis learn-corpus "no learn/ref or no busybox to run the engine"
  fi
  # the graded arsenal school, the same static net G25 gives base learn: render
  # every card, grade each card's own answer, and hold unique-boss / >=5-per-boss.
  # arsenal rides p3 off-image and its tools stage on the stick, so a lean ci host
  # has only some of them -- selftest_graded notes+skips a card whose carried tool
  # is absent here (the stick, with every tool staged, runs them all at provision).
  # so a broken engine, a duplicate boss or a card that cannot grade its own answer
  # is caught on the push, while a merely-absent tool is not mistaken for a defect.
  if [ -d arsenal/levels ] && [ -n "$bb" ]; then
    say "arsenal school selftest"
    cic arsenal-selftest
    # the answers' PATH: an applet dir built from the fort busybox, so a card is
    # graded against the commands the stick has -- not the host's gnu set, which
    # hid the rabin2 stick-only failure. with no built busybox (a fresh clone),
    # the jail falls back to the host PATH and says so.
    local abb=""
    if [ -x ./busybox ]; then
      abb=$(mktemp -d) && ./busybox --install -s "$abb" 2>/dev/null || abb=""
      # the stick has /bin/busybox itself too (cards call `busybox true`)
      [ -n "$abb" ] && ln -sf "$PWD/busybox" "$abb/busybox"
      [ -n "$abb" ] && printf '  answers run on the fort busybox applets, nothing else on PATH\n'
    fi
    # captured, not piped: a pipe returns grep's status, so a real selftest
    # failure would sail past (the same trap the learn coverage block names).
    local as_out as_rc=0
    as_out=$(ARSENAL_BB="$abb" ARSENAL_ROOT="$PWD/arsenal" NO_COLOR=1 "$bb" ash arsenal/learn selftest 2>&1) || as_rc=1
    printf '%s\n' "$as_out" | grep -vE '^note ' >&2 || true
    [ "$as_rc" -eq 0 ] || rc=1
    # the authoring ledger: advisory like learn's (never gated -- a hard rule on
    # wording breeds filler), printed so single-phrasing/same-words drift shows.
    say "arsenal authoring ledger"
    cic arsenal-ledger
    ARSENAL_ROOT="$PWD/arsenal" "$bb" ash arsenal/learn lint 2>&1 || true
    # order: a mission may only lean on a tool an earlier (or this) mission has
    # taught -- the base school's G27, which the arsenal school never had. a HARD
    # gate (not advisory like the ledger): a card reaching for a not-yet-taught
    # tool is a dead end for the learner, the exact defect G27 forbids base-side.
    say "arsenal missions teach before they use"
    cic arsenal-order
    local ao_out ao_rc=0
    ao_out=$(ARSENAL_ROOT="$PWD/arsenal" NO_COLOR=1 "$bb" ash arsenal/learn order 2>&1) || ao_rc=1
    printf '  %s\n' "$ao_out"
    [ "$ao_rc" -eq 0 ] || rc=1
    [ -n "$abb" ] && rm -rf "$abb"
  else
    cis arsenal-selftest "no arsenal/levels or no busybox to run the engine"
    cis arsenal-ledger "same"; cis arsenal-order "same"
  fi
  # the userns probe decides ran-vs-skipped HERE: xexecproof's own skip
  # returns 0, so registering first reported an unexercised xexec as ran.
  if ! [ -x ./busybox ]; then cis xexec "no built busybox to stage (./build.sh busybox first)"
  elif ! unshare -rm true 2>/dev/null; then cis xexec "no user namespaces on this host -- behaviour unverified"
  else cic xexec; xexecproof || rc=1; fi
  # one q: per card, across every corpus that becomes SRS cards. the card key
  # is the q: template, stored one tab-separated row per card; a second q: line
  # gives held_keys (which reads only the first) a different key than blk_load
  # (which reads them all), so the card would never register as held -- the same
  # grade-time-vs-read-time split as the review bug. forbid it at the source.
  say "one q: per card"
  cic one-q
  local q2
  q2=$(awk '
    FNR==1{ blk=0; q=0 }
    /^---$/{ blk++; q=0; next }
    /^q: /{ q++; if(q==2) printf "  %s block %d has a second q:\n", FILENAME, blk }
  ' learn/levels/* learn/scenarios/* learn/chains arsenal/levels/* 2>/dev/null)
  if [ -n "$q2" ]; then
    printf '  \033[1;31mmultiple q: lines in one block\033[0m\n%s\n' "$q2" >&2; rc=1
  else
    printf '  every card has exactly one q:\n'
  fi
  # every carried FIELD tool is drilled by at least one card -- the curriculum's
  # promise ("learn the whole toolkit") made a build gate, the same completeness
  # G24/G26 hold base learn to. the stick's OWN presentation utilities render
  # maps/charts/images/qr codes: you use them, you do not drill them, so they are
  # exempt by name -- and a sixth one added later fails this until someone says so.
  if [ -f arsenal/arsenal-catalog ] && [ -d arsenal/levels ]; then
    say "every field tool has a card"
    cic tool-cards
    local _cov_miss
    _cov_miss=$(comm -23 \
      <(grep -E '^[a-z]' arsenal/arsenal-catalog | cut -f1 | sort -u) \
      <( { grep -h '^teach:' arsenal/levels/* 2>/dev/null | sed 's/^teach: *//'
           grep -h '^a:'     arsenal/levels/* 2>/dev/null | sed 's/^a: *//' | awk '{print $1}'
           grep -h '^tools:'  arsenal/levels/* 2>/dev/null | sed 's/^tools: *//' | tr ' ' '\n'
         } | sort -u ) \
      | grep -vwE 'atlas|chart|view|qr|qrencode' || true)   # grep exits 1 when it filters all out (the pass case); set -e must not see it
    if [ -n "$_cov_miss" ]; then
      printf '  \033[1;31mcarried tool with no card\033[0m (add one, or exempt it if it is a utility): %s\n' "$(echo $_cov_miss)" >&2; rc=1
    else
      printf '  every field tool is drilled\n'
    fi
  else
    cis tool-cards "no arsenal catalog or levels"
  fi
  # arsenal.lock attests the BUILD OUTPUT; its sha drifts per build (build-ids),
  # so nothing can gate the hash -- but the SET of rows must still track what is
  # carried. a tool pinned, built and catalogued yet missing from the lock ships
  # unattested, which is exactly how qrencode slipped in with no gate to catch
  # it. hold the roster both ways: every catalogued compiled tool has a lock row,
  # every lock row is catalogued. the four presentation WRAPPERS
  # (atlas/chart/qr/view) ship as arsenal/ scripts, not compiled binaries, so
  # they carry no lock row; qrencode IS the real binary the `qr` wrapper drives,
  # so it does. file.mgc is file's magic db, attested beside it, not a tool.
  if [ -f arsenal/arsenal-catalog ] && [ -f arsenal/arsenal.lock ]; then
    say "arsenal.lock attests every carried tool"
    cic lock-roster
    local _lk_cat _lk_lock _lk_a _lk_b
    _lk_cat=$(grep -E '^[a-z]' arsenal/arsenal-catalog | cut -f1 | grep -vxE 'atlas|chart|qr|view' | sort -u)
    _lk_lock=$(grep -vE '^#|^[[:space:]]*$' arsenal/arsenal.lock | awk '{print $1}' | grep -vx 'file.mgc' | sort -u)
    _lk_a=$(comm -23 <(printf '%s\n' "$_lk_cat") <(printf '%s\n' "$_lk_lock") || true)
    _lk_b=$(comm -13 <(printf '%s\n' "$_lk_cat") <(printf '%s\n' "$_lk_lock") || true)
    if [ -n "$_lk_a" ]; then
      printf '  \033[1;31mcatalogued but not in arsenal.lock\033[0m (built but unattested): %s\n' "$(echo $_lk_a)" >&2; rc=1
    fi
    if [ -n "$_lk_b" ]; then
      printf '  \033[1;31min arsenal.lock but not catalogued\033[0m (attesting a tool nothing lists): %s\n' "$(echo $_lk_b)" >&2; rc=1
    fi
    [ -z "$_lk_a$_lk_b" ] && printf '  every carried tool is attested in arsenal.lock\n'
  else
    cis lock-roster "no arsenal catalog or lock"
  fi
  # every card's ref: names a real reference page, and every page names a tool a
  # card drills -- the Tab panel and `arsenal learn ref` both read these, so a
  # ref: with no page is a dead panel and an orphan page is a claim nothing uses.
  if [ -d arsenal/ref ] && [ -d arsenal/levels ]; then
    say "arsenal reference pages cover the cards"
    cic ref-pages
    local _rf_refs _rf_have _rf_miss _rf_orphan
    _rf_refs=$( { grep -h '^ref:' arsenal/levels/* 2>/dev/null | sed 's/^ref: *//'
                  grep -h '^teach:' arsenal/levels/* 2>/dev/null | sed 's/^teach: *//'; } \
                | grep -E '^[a-z]' | sort -u )
    _rf_have=$(ls arsenal/ref 2>/dev/null | sort -u)
    _rf_miss=$(comm -23 <(printf '%s\n' "$_rf_refs") <(printf '%s\n' "$_rf_have") || true)
    _rf_orphan=$(comm -13 <(printf '%s\n' "$_rf_refs") <(printf '%s\n' "$_rf_have") || true)
    if [ -n "$_rf_miss" ]; then
      printf '  \033[1;31mcard ref: with no page\033[0m: %s\n' "$(echo $_rf_miss)" >&2; rc=1
    fi
    if [ -n "$_rf_orphan" ]; then
      printf '  \033[1;31mreference page no card names\033[0m (remove it or point a ref: at it): %s\n' "$(echo $_rf_orphan)" >&2; rc=1
    fi
    [ -z "$_rf_miss$_rf_orphan" ] && printf '  every ref: has a page, every page a card\n'
  else
    cis ref-pages "no arsenal/ref or levels"
  fi
  # the copied engine libs must still match the fort's -- the one gate that
  # stops a fix landing in one tree and not the other (the drift this session found).
  if [ -d arsenal/lib ] && [ -d learn/lib ]; then cic libparity; libparity || rc=1
  else cis libparity "no arsenal/lib or learn/lib"; fi
  if [ -x arsenal/learn ]; then cic schoolship; schoolship || rc=1
  else cis schoolship "no arsenal/learn"; fi
  # the README states counts the reader trusts -- the command surface, the level
  # and question totals. nothing checked them, so they drifted release after
  # release (202 vs 203 ref pages, 894 vs 963 questions). re-derive the three
  # that are exact file-or-corpus facts and make the prose match. the applet
  # count is left out here: it is `busybox --list` on the BUILT binary, which a
  # buildless runner may not have, and a host busybox has a different set.
  cic learnship; learnship || rc=1
  # the pin is a claim about COMMITTED source; refuse to let a HEAD that moved
  # an image-affecting path travel with a pin taken from an older one. buildless:
  # it compares tree ids, not bytes -- the byte check is crepro, which is where
  # this used to be caught, weekly, after the push.
  if [ -f image.sha256 ] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    say "image pin is taken from this source"
    cic pin-source
    local want_src have_src pin_at
    want_src=$(awk '$1=="source"{print $2}' image.sha256)
    have_src=$(srcpin)
    if [ -z "$want_src" ]; then
      printf '  \033[1;31mimage.sha256 has no source line -- truncated pin, run ./build.sh cpin\033[0m\n' >&2; rc=1
    elif [ "$want_src" != "$have_src" ]; then
      pin_at=$(git log -1 --format=%h -- image.sha256 2>/dev/null)
      printf '  \033[1;31mimage.sha256 was pinned at %s; image-affecting source moved since:\033[0m\n' "${pin_at:-?}" >&2
      # shellcheck disable=SC2086
      [ -n "$pin_at" ] && git diff --stat "$pin_at..HEAD" -- $IMAGE_SRC 2>/dev/null | sed 's/^/    /' >&2
      printf '    the committed pin describes bytes this source no longer builds.\n' >&2
      printf '    ./build.sh cpin, then commit image.sha256 (alone).\n' >&2
      rc=1
    else
      printf '  source digest %s... matches the pin\n' "${have_src:0:16}"
    fi
    srcpin_cover || { printf '  \033[1;31mIMAGE_SRC is missing an input rootfs() ships -- the staleness check above has a blind spot\033[0m\n' >&2; rc=1; }
  else
    cis pin-source "no image.sha256 or not a git tree"
  fi
  if [ -f README.md ] && [ -d learn/ref ] && [ -d learn/levels ]; then
    say "README counts match the tree"
    cic readme-counts
    local rc_cmd rc_lvl rc_q claim_cmd claim_lvl claim_q
    rc_cmd=$(find learn/ref -mindepth 1 -maxdepth 1 -type f | grep -c .)
    rc_lvl=$(find learn/levels -mindepth 1 -maxdepth 1 -type f | grep -c .)
    # the question total the way learn lint counts it (the authoritative source
    # the README number is meant to equal)
    rc_q=$(LEARN_ROOT="$PWD/learn" NO_COLOR=1 "${bb:-busybox}" ash learn/learn lint 2>/dev/null \
             | grep -oE '[0-9]+ questions' | head -1 | awk '{print $1}' || true)
    # || true: under pipefail a reworded README made grep exit 1 and set -e
    # ended ci() mid-check with no word; an empty claim is reported below.
    claim_cmd=$(grep -oE 'the [0-9]+ commands' README.md | grep -oE '[0-9]+' | head -1 || true)
    claim_lvl=$(grep -oE '[0-9]+ levels' README.md | grep -oE '[0-9]+' | head -1 || true)
    claim_q=$(grep -oE '[0-9]+ questions' README.md | grep -oE '[0-9]+' | head -1 || true)
    local cnt_bad=0
    [ "$claim_cmd" = "$rc_cmd" ] || { printf '  \033[1;31mREADME says %s commands, the tree has %s ref pages\033[0m\n' "${claim_cmd:-?}" "$rc_cmd" >&2; cnt_bad=1; }
    [ "$claim_lvl" = "$rc_lvl" ] || { printf '  \033[1;31mREADME says %s levels, the tree has %s\033[0m\n' "${claim_lvl:-?}" "$rc_lvl" >&2; cnt_bad=1; }
    # an empty count is a broken lint, not a pass: skipping the check on it
    # let the README number go unchecked whenever lint stopped printing it.
    [ -n "$rc_q" ] && [ "$claim_q" = "$rc_q" ] || { printf '  \033[1;31mREADME says %s questions, learn lint counts %s\033[0m\n' "${claim_q:-?}" "${rc_q:-nothing}" >&2; cnt_bad=1; }
    if [ "$cnt_bad" -eq 0 ]; then printf '  %s commands, %s levels, %s questions -- README matches\n' "$rc_cmd" "$rc_lvl" "${rc_q:-?}"; else rc=1; fi
  else
    cis readme-counts "no README or learn corpus"
  fi
  ci_reconcile "$CI_ROSTER" "$CI_RAN" "$CI_SKIPPED" || rc=1
  [ "$rc" -eq 0 ] && printf '\033[1;32m  ci: buildless checks pass\033[0m\n' \
                  || printf '\033[1;31m  ci: FAILED\033[0m\n'
  return $rc
}

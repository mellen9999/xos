#!/bin/bash
# build/components.sh -- the components -- kernel, busybox, dropbear, cryptsetup, wireguard, tlstunnel, ii, abduco -- each from a pinned tarball, musl static-pie
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# ────────────────────────────────────────────────────────────────────────────
# components -- each built from a pinned tarball, musl static-pie
# ────────────────────────────────────────────────────────────────────────────
kernel() {
  say "building kernel $KVER"
  local d="src/linux-$KVER"
  make -C "$d" tinyconfig
  # kernel.config now has two classes of line: `CONFIG_X=y` (must be on) and
  # `CONFIG_X=n` (must be off). split them -- feeding a `=n` line to --enable
  # would turn hardening-disable requests into enables.
  local enables disables
  # `=y\s*$`: a trailing space on a line used to drop that option from both
  # the enable pass AND the gate, silently. whitespace is not a config change.
  enables=$(grep -oP '^CONFIG_[A-Z0-9_]+(?==y\s*$)' kernel.config)
  disables=$(grep -oP '^CONFIG_[A-Z0-9_]+(?==n\s*$)' kernel.config)
  # olddefconfig silently drops any option whose deps are unmet, so enable to a
  # fixpoint (a parent enabled on pass N unlocks its children on pass N+1) and
  # then GATE on it -- a kernel quietly missing squashfs still "builds fine".
  # disables run each pass too: olddefconfig can re-select a choice default
  # (e.g. the lockdown FORCE_NONE member) that an earlier pass turned off.
  for _pass in 1 2 3; do
    while read -r opt; do
      [ -n "$opt" ] && "$d/scripts/config" --file "$d/.config" --enable "$opt"
    done <<< "$enables"
    while read -r opt; do
      [ -n "$opt" ] && "$d/scripts/config" --file "$d/.config" --disable "$opt"
    done <<< "$disables"
    make -C "$d" olddefconfig >/dev/null
  done
  local kmiss=() present=()
  while read -r opt; do
    [ -n "$opt" ] || continue
    grep -q "^$opt=y" "$d/.config" || kmiss+=("$opt")
  done <<< "$enables"
  # a `=n` opt that is present as =y is a hardening request that silently lost
  while read -r opt; do
    [ -n "$opt" ] || continue
    grep -q "^$opt=y" "$d/.config" && present+=("$opt")
  done <<< "$disables"
  if [ "${#kmiss[@]}" -gt 0 ]; then
    echo "FAIL: kernel options requested but not enabled: ${kmiss[*]}" >&2
    return 1
  fi
  if [ "${#present[@]}" -gt 0 ]; then
    echo "FAIL: kernel options requested off but still enabled: ${present[*]}" >&2
    return 1
  fi
  grep -q '^CONFIG_MODULES=y' "$d/.config" && { echo "FAIL: module loader enabled" >&2; return 1; }
  echo 0 > "$d/.version"
  make -C "$d" -j"$JOBS" bzImage
  cp "$d/arch/x86/boot/bzImage" bzImage
  # bind the binary to the config it was built from. G14 checks .config, not
  # bzImage, so a kernel built days before kernel.config changed passed every
  # gate while failing the boot-time asserts -- the config said lockdown and
  # no-vsyscall, the running kernel disagreed, and nothing in the build noticed.
  # two digests: the expanded config (what was really compiled) and our source
  # kernel.config (the only one a gate can recompute without rebuilding).
  {
    sha256sum < "$d/.config"   | awk '{print "expanded " $1}'
    sha256sum < kernel.config  | awk '{print "source   " $1}'
  } > bzImage.config.sha256
}

bbset() {
  local d="$1" opt="$2" val="$3"
  sed -i "/^CONFIG_$opt=/d;/^# CONFIG_$opt is not set\$/d" "$d/.config"
  if [ "$val" = y ]; then
    echo "CONFIG_$opt=y" >> "$d/.config"
  else
    echo "# CONFIG_$opt is not set" >> "$d/.config"
  fi
}

headers() {
  say "installing kernel headers into sysroot"
  local d="src/linux-$KVER"
  rm -rf sysroot
  make -C "$d" headers_install INSTALL_HDR_PATH="$PWD/sysroot" >/dev/null
  printf '  sysroot/include: %s headers\n' "$(find sysroot/include -name '*.h' | wc -l)"
}

busybox() {
  say "building busybox $BBVER (${BBMODE:-trim})"
  [ -d sysroot/include/linux ] || headers
  local d="src/busybox-$BBVER"
  patch_tree "$d" patches/busybox || return 1
  make -C "$d" defconfig >/dev/null

  # static-PIE: plain -static is an ASLR downgrade (fixed load address), so we
  # drive it through EXTRA flags instead of CONFIG_STATIC, which would inject a
  # conflicting -static. G3 verifies the result is ET_DYN.
  bbset "$d" STATIC n
  bbset "$d" PIE n
  for off in TC PAM FEATURE_WTMP FEATURE_UTMP; do bbset "$d" "$off" n; done
  sed -i '/^CONFIG_EXTRA_CFLAGS=/d;/^CONFIG_EXTRA_LDFLAGS=/d' "$d/.config"
  echo "CONFIG_EXTRA_CFLAGS=\"$XCF\"" >> "$d/.config"
  echo 'CONFIG_EXTRA_LDFLAGS=""' >> "$d/.config"

  if [ "${BBMODE:-trim}" = trim ]; then
    local all keep; all=$(mktemp)
    grep -o '^CONFIG_[A-Z0-9_]*=y' "$d/.config" | sed 's/^CONFIG_//;s/=y$//' > "$all"
    keep=$( { grep -v '^[[:space:]]*#' busybox.config.applets
              sed 's/#.*//' busybox.config.features
            } | tr ' ' '\n' | grep -v '^$' | tr 'a-z' 'A-Z' | sort -u)
    while read -r sym; do
      case "$sym" in
        STATIC|*FEATURE*|*PLATFORM*|*LFS*|DESKTOP|LONG_OPTS|SHOW_USAGE|*_PREFIX*|INSTALL_*|*_APPLET_*) continue ;;
      esac
      grep -qx "$sym" <<< "$keep" || bbset "$d" "$sym" n
    done < "$all"
    rm -f "$all"
  fi

  # keeping a symbol out of the trim list only means trim will not turn it OFF;
  # it says nothing about defconfig having it ON. assert it instead of hoping.
  local feat
  for feat in $(sed 's/#.*//' busybox.config.features); do bbset "$d" "$feat" y; done

  # `yes |` takes SIGPIPE when make exits; pipefail would turn that into exit 141
  # and silently abort before compiling. this bit us twice.
  yes '' | make -C "$d" oldconfig >/dev/null 2>&1 || true

  rm -f "$d/busybox"
  local specs="$PWD/musl-static-pie.specs"
  [ -f "$specs" ] || { echo "FAIL: $specs missing" >&2; return 1; }
  local cc="gcc -specs=$specs"
  make -C "$d" -j"$JOBS" CC="$cc" HOSTCC=gcc
  [ -f "$d/busybox" ] || { echo "busybox build failed" >&2; return 1; }
  strip "$d/busybox"
  cp "$d/busybox" busybox
  # form gates can pass on a binary that segfaults -- so prove it executes
  ./busybox true 2>/dev/null || { echo "FAIL: built busybox does not run" >&2; return 1; }
  # oldconfig can silently drop a symbol whose dependencies were trimmed away.
  # a feature that vanishes here is exactly the quiet shrink this repo exists to
  # catch, so read it back out of the config we just compiled.
  local bbmiss=""
  for feat in $(sed 's/#.*//' busybox.config.features); do
    grep -qx "CONFIG_$feat=y" "$d/.config" || bbmiss="$bbmiss $feat"
  done
  [ -z "$bbmiss" ] || { echo "FAIL: busybox dropped requested features:$bbmiss" >&2; return 1; }
  printf '  busybox binary: %d bytes (musl static-pie, runs)\n' "$(stat -c%s busybox)"
}

ta() {
  say "compiling trust anchors"
  local d="src/bearssl-$BSSLVER"
  [ -x "$d/build/brssl" ] || { echo "FAIL: brssl missing, run tls first" >&2; return 1; }
  local pems; pems=$(find trust -name '*.pem' | sort)
  [ -n "$pems" ] || { echo "FAIL: trust/ is empty -- refusing to build a client that trusts nothing" >&2; return 1; }
  # shellcheck disable=SC2086
  "$d/build/brssl" ta $pems > ta.h || return 1
  local n; n=$(grep -oE 'TAs_NUM[[:space:]]+[0-9]+' ta.h | grep -oE '[0-9]+$')
  [ "${n:-0}" -gt 0 ] || { echo "FAIL: ta.h has no anchors" >&2; return 1; }
  printf '  %s trust anchor(s) compiled in:\n' "$n"
  local f; for f in $pems; do printf '    %s\n' "$(openssl x509 -in "$f" -noout -subject | sed 's/^subject=//')"; done
}

tls() {
  say "building bearssl + tlstunnel"
  local d="src/bearssl-$BSSLVER" specs="$PWD/musl-static-pie.specs"
  # from clean every time: make does not track CFLAGS, so a library left from
  # an earlier run would keep its old flags and nothing downstream could tell.
  make -C "$d" clean >/dev/null 2>&1
  make -C "$d" -j"$JOBS" CC="gcc -specs=$specs" CFLAGS="-W -Wall $XCF" \
      build/libbearssl.a build/brssl >/dev/null 2>&1
  [ -f "$d/build/libbearssl.a" ] && [ -x "$d/build/brssl" ] \
    || { echo "FAIL: bearssl did not build" >&2; return 1; }
  ta || return 1
  # shellcheck disable=SC2086
  gcc -specs="$specs" $XCF \
    -I"$d/inc" -I. -o tlstunnel tlstunnel.c "$d/build/libbearssl.a" || return 1
  { ./tlstunnel 2>&1 || true; } | has usage || { echo "FAIL: tlstunnel does not run" >&2; return 1; }
  printf '  tlstunnel: %d bytes\n' "$(stat -c%s tlstunnel)"
}

wg_() {
  say "building wireguard-tools (wg, musl static-pie)"
  local d="src/wireguard-tools-$WGTVER/src" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: wireguard-tools source missing, run fetch" >&2; return 1; }
  make -C "$d" clean >/dev/null 2>&1 || true
  # RUNSTATEDIR and the bundled uapi headers are normally added by the
  # makefile's own CFLAGS; supplying ours drops both, so put them back. the
  # bundled linux/wireguard.h goes FIRST: wg is written against the newest
  # netlink attributes and only sends the ones the operator's conf uses, so
  # it must see its own header, never an older one in the kernel sysroot.
  make -C "$d" CC="gcc -specs=$specs" \
    CFLAGS="-isystem $PWD/$d/uapi/linux $XCF -DRUNSTATEDIR='\"/run\"'" \
    LDFLAGS="" WITH_BASHCOMPLETION=no WITH_WGQUICK=no WITH_SYSTEMDUNITS=no wg >/dev/null 2>&1
  [ -f "$d/wg" ] || { echo "FAIL: wg did not build" >&2; return 1; }
  strip "$d/wg"; cp "$d/wg" wg
  { ./wg --version 2>&1 || true; } | has 'wireguard-tools' \
    || { echo "FAIL: built wg does not run" >&2; return 1; }
  printf '  wg: %d bytes\n' "$(stat -c%s wg)"
}

dropbear_() {
  say "building dropbear $DBVER (ssh, pubkey-only, musl static-pie)"
  local d="src/dropbear-$DBVER" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: dropbear source missing, run fetch" >&2; return 1; }
  [ -f dropbear.localoptions.h ] || { echo "FAIL: dropbear.localoptions.h missing" >&2; return 1; }
  # our hardening (no password auth, ed25519 only) as a tracked overlay, so the
  # security-relevant deltas from upstream defaults show up in a diff.
  cp dropbear.localoptions.h "$d/src/localoptions.h"
  # every knob the header sets must still be a knob upstream knows. a dropbear
  # bump that renames DROPBEAR_SVR_PASSWORD_AUTH would turn our #define into a
  # no-op and ship password auth on the one listening service -- green. the
  # busybox build reads its features back out of .config for the same reason.
  local knob unknown=""
  for knob in $(sed -n 's/^#define \(DROPBEAR_[A-Z0-9_]*\).*/\1/p' dropbear.localoptions.h); do
    grep -q "^#define $knob\b" "$d/src/default_options.h" || unknown="$unknown $knob"
  done
  [ -z "$unknown" ] || { echo "FAIL: dropbear.localoptions.h sets knobs upstream $DBVER no longer has:$unknown" >&2; return 1; }
  ( cd "$d" && ./configure --disable-zlib --disable-lastlog --disable-utmp \
      --disable-utmpx --disable-wtmp --disable-wtmpx --disable-pututline \
      --disable-pututxline \
      CC="gcc -specs=$specs" CFLAGS="$XCF" \
      >/dev/null 2>&1 ) || { echo "FAIL: dropbear configure failed" >&2; return 1; }
  # do NOT pass STATIC=1 -- it injects a plain -static that fights the specs
  # file's -static-pie and produces a fixed-load-address (ASLR-off) binary.
  # the artifact goes first: an existence check after a failed make otherwise
  # passes on whatever the previous run left behind.
  rm -f "$d/dropbearmulti"
  make -C "$d" PROGRAMS="dropbear dbclient dropbearkey" MULTI=1 >/dev/null 2>&1
  [ -f "$d/dropbearmulti" ] || { echo "FAIL: dropbear did not build" >&2; return 1; }
  strip "$d/dropbearmulti"; cp "$d/dropbearmulti" dropbearmulti
  { ./dropbearmulti dropbear -V 2>&1 || true; } | has 'Dropbear' \
    || { echo "FAIL: built dropbear does not run" >&2; return 1; }
  printf '  dropbearmulti: %d bytes\n' "$(stat -c%s dropbearmulti)"
}

cryptsetup_() {
  say "building cryptsetup $CSVER + its four libraries (musl static-pie)"
  local specs="$PWD/musl-static-pie.specs" root="$PWD"
  # XCF carries -ffile-prefix-map: json-c bakes __FILE__ into assert strings,
  # which put the absolute build path inside the shipped cryptsetup -- two
  # clean clones built different bytes and reproducibility quietly broke.
  local cc="gcc -specs=$specs" cf="$XCF"
  local dep="$root/src/cs-dep"
  rm -rf "$dep"; mkdir -p "$dep/lib" "$dep/include/json-c" "$dep/include/uuid"

  # pkg-config on the BUILD HOST will happily answer for the host's shared
  # libraries -- it pulled in -ludev and broke the static link. point it at an
  # empty directory so only what we built here can be found.
  mkdir -p "$dep/nopc"
  export PKG_CONFIG_LIBDIR="$dep/nopc" PKG_CONFIG_PATH="$dep/nopc"

  # libdevmapper: the dm ioctl wrapper. only the library is wanted -- lvm2's
  # own dmsetup tool wants libblkid and is not built.
  # every artifact is removed before its build: the existence checks below
  # must prove THIS run built it, not that some earlier run did.
  local d="src/LVM2.$LVMVER"
  rm -f "$d/libdm/ioctl/libdevmapper.a"
  ( cd "$d" && ./configure --enable-static_link --disable-selinux --disable-udev_sync \
      --disable-udev_rules --disable-readline --disable-nls --disable-shared \
      --with-cache=none --with-thin=none --with-vdo=none --with-writecache=none \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -C libdm >/dev/null 2>&1 ) || true
  [ -f "$d/libdm/ioctl/libdevmapper.a" ] || { echo "FAIL: libdevmapper did not build" >&2; return 1; }
  cp "$d/libdm/ioctl/libdevmapper.a" "$dep/lib/"
  cp "$d/libdm/libdevmapper.h" "$dep/include/"

  d="src/popt-$POPTVER"
  rm -f "$d/src/libpopt.la" "$d/src/.libs/libpopt.a"   # libtool: the .la is the target
  ( cd "$d" && ./configure --disable-shared --enable-static --disable-nls \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/src/.libs/libpopt.a" ] || { echo "FAIL: popt did not build" >&2; return 1; }
  cp "$d/src/.libs/libpopt.a" "$dep/lib/"; cp "$d/src/popt.h" "$dep/include/"

  d="src/json-c-json-c-$JSONCVER"
  rm -f "$d/b/libjson-c.a"
  ( cd "$d" && cmake -S . -B b -DCMAKE_C_COMPILER=gcc -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="-specs=$specs $cf" -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
      -DDISABLE_WERROR=ON -DBUILD_TESTING=OFF -DBUILD_APPS=OFF >/dev/null 2>&1 \
    && cmake --build b -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/b/libjson-c.a" ] || { echo "FAIL: json-c did not build" >&2; return 1; }
  cp "$d/b/libjson-c.a" "$dep/lib/"; cp "$d"/*.h "$d"/b/*.h "$dep/include/json-c/" 2>/dev/null

  d="src/util-linux-$UTLVER"
  rm -f "$d/libuuid.la" "$d/.libs/libuuid.a"
  ( cd "$d" && ./configure --disable-all-programs --enable-libuuid --disable-shared \
      --enable-static --without-systemd --without-udev --disable-nls --disable-asciidoc \
      CC="$cc" CFLAGS="$cf" >/dev/null 2>&1 && make -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/.libs/libuuid.a" ] || { echo "FAIL: libuuid did not build" >&2; return 1; }
  cp "$d/.libs/libuuid.a" "$dep/lib/"; cp "$d/libuuid/src/uuid.h" "$dep/include/uuid/"

  d="src/cryptsetup-$CSVER"
  rm -f "$d/cryptsetup.static"
  ( cd "$d" && ./configure --disable-shared --enable-static --enable-static-cryptsetup \
      --with-crypto_backend=kernel --disable-ssh-token --disable-external-tokens \
      --disable-selinux --disable-nls --disable-blkid --disable-udev \
      --disable-veritysetup --disable-integritysetup --disable-asciidoc \
      --disable-hw-opal \
      CC="$cc" CFLAGS="$cf -I$dep/include" LDFLAGS="-L$dep/lib" \
      DEVMAPPER_CFLAGS="-I$dep/include" DEVMAPPER_LIBS="-L$dep/lib -ldevmapper" \
      JSON_C_CFLAGS="-I$dep/include/json-c" JSON_C_LIBS="-L$dep/lib -ljson-c" \
      UUID_CFLAGS="-I$dep/include" UUID_LIBS="-L$dep/lib -luuid" \
      POPT_LIBS="-L$dep/lib -lpopt" >/dev/null 2>&1 \
    && make -j"$JOBS" >/dev/null 2>&1 ) || true
  [ -f "$d/cryptsetup.static" ] || { echo "FAIL: cryptsetup did not build" >&2; return 1; }
  cp "$d/cryptsetup.static" cryptsetup; strip cryptsetup
  unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH

  # form gates pass on a binary that segfaults, and this one must also have the
  # KERNEL_CAPI backend -- an openssl-linked build would be a silent dependency.
  { ./cryptsetup --version 2>&1 || true; } | has 'KERNEL_CAPI' \
    || { echo "FAIL: cryptsetup missing or not using the kernel crypto backend" >&2; return 1; }
  printf '  cryptsetup: %d bytes\n' "$(stat -c%s cryptsetup)"
}

abduco() {
  say "building abduco $ABDVER (session detach, musl static-pie)"
  local d="src/abduco-$ABDVER" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: abduco source missing, run fetch" >&2; return 1; }
  # upstream defaults to running dvtm, which this system does not ship. the
  # override is a tracked file so the change shows up in a diff.
  [ -f abduco.config.h ] || { echo "FAIL: abduco.config.h missing" >&2; return 1; }
  cp abduco.config.h "$d/config.h"
  rm -f "$d/abduco"
  # -lutil for forkpty(). musl keeps forkpty in libc and ships an empty
  # libutil.a for compatibility, so this resolves and costs nothing.
  # shellcheck disable=SC2086
  gcc -specs="$specs" $XCF \
    -std=c99 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 \
    -DVERSION="\"$ABDVER\"" -DNDEBUG -I"$d" \
    -o abduco "$d/abduco.c" -lutil || return 1
  strip abduco
  # form gates pass on a binary that segfaults, so prove it executes
  { ./abduco 2>&1 || true; } | has 'Active sessions' \
    || { echo "FAIL: built abduco does not run" >&2; return 1; }
  printf '  abduco: %d bytes\n' "$(stat -c%s abduco)"
}

ii_() {
  say "building ii $IIVER (irc, musl static-pie)"
  local d="src/ii-$IIVER" specs="$PWD/musl-static-pie.specs"
  [ -d "$d" ] || { echo "FAIL: ii source missing, run fetch" >&2; return 1; }
  make -C "$d" clean >/dev/null 2>&1 || true
  make -C "$d" CC="gcc -specs=$specs" \
    CFLAGS="$XCF" LDFLAGS="" >/dev/null 2>&1
  [ -f "$d/ii" ] || { echo "FAIL: ii did not build" >&2; return 1; }
  strip "$d/ii"; cp "$d/ii" ii
  # ii exits non-zero when printing usage, and pipefail would read that as a
  # build failure, so the producer is neutralised as well as the consumer.
  { ./ii 2>&1 || true; } | has usage || { echo "FAIL: built ii does not run" >&2; return 1; }
  printf '  ii: %d bytes\n' "$(stat -c%s ii)"
}

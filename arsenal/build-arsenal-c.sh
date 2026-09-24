#!/bin/sh
# build-arsenal-c.sh -- static musl C tools for ~/tools/, built in Alpine.
#
# static musl C means hand-linking every dep, so we build inside Alpine (musl-
# native) where the -dev/-static libs are one apk away, then take the static
# binary out. it runs on any linux (no libc on the host), same as the Go set.
# --network host because docker's bridge cannot reach the alpine CDN on this
# machine's wireguard/firewalled network.
#
# needs: docker. output: appends binaries to ./arsenal/ (lock via build-arsenal
# regen, or by hand). builds masscan + tcpdump + socat + nmap + links + mutool +
# frotz + whois + hydra + john + jq + rg + zstd + ddrescue + strace + testdisk +
# photorec + smartctl + file + mandoc + minisign + dvtm + rsync, all static (rg
# is static-PIE, see its block; nmap is C++, its block documents the
# static-musl fix). the recovery/forensics/triage flank: read a .zst, image a
# dying disk, trace a binary, rebuild a partition table, carve files back, read
# a drive's SMART health, identify an unknown blob. `file` also emits file.mgc
# (its magic db), which provision drops at $HOME/.magic.mgc for libmagic to
# auto-discover. minisign/dvtm/rsync are the field-ops trio: sign/verify a
# transfer, split panes with no tmux server, sync/backup over ssh.
# NOTE: masscan + tcpdump + nmap + radare2 embed a build-id/timestamp, so their
# arsenal.lock sha drifts per build (size is stable) -- a point-in-time
# attestation. links + mutool are
# bit-reproducible. masscan needs linux-headers (netlink) -- in the apk set below.
#
# INTEGRITY: every source is pinned in arsenal.pins and checked BEFORE it builds
# -- a tarball by sha256, a git repo by commit. that file is the input anchor;
# arsenal.lock stays the post-build output attestation. the pins are mounted at
# /pins inside the container; fetch()/clone_pinned() below refuse a source that
# is not in them or does not match. G47 fails the whole build if a fetch here
# ever names a tool the pins file does not.
set -eu
OUT="${1:-arsenal}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)  # absolute: -v below must not double-prefix $PWD
SELF=$(cd "$(dirname "$0")" && pwd)                            # holds arsenal.pins
[ -f "$SELF/arsenal.pins" ] || { echo "no arsenal.pins beside $0 -- refusing to build unpinned" >&2; exit 1; }
command -v docker >/dev/null || { echo "no docker" >&2; exit 1; }

docker run --rm -i --network host -v "$OUT":/out -v "$SELF/arsenal.pins":/pins:ro alpine:3.20 sh -e <<'INNER'
apk add --no-cache build-base git wget tar libpcap-dev linux-headers \
  zlib-dev zlib-static openssl-dev openssl-libs-static bzip2-static \
  ncurses-dev ncurses-static pkgconf perl autoconf automake libtool cargo \
  file lzip xz linux-headers e2fsprogs-dev e2fsprogs-static util-linux-dev \
  rustup fontconfig-dev fontconfig-static freetype-dev freetype-static \
  expat-static libpng-static brotli-static xz-static xz-dev musl-dev \
  meson ninja cmake libsodium-dev libsodium-static >/dev/null 2>&1
log() { echo "[c-build] $*"; }

# ---- integrity: read the pins, verify before build ------------------------
PINS=/pins
pin() { awk -v n="$1" -v k="$2" '$1==n && $2==k {print $(f=="ref"?3:4)}' f="$3" "$PINS"; }

# fetch NAME OUTFILE -- download the pinned url to OUTFILE and verify its sha256
# before anyone extracts it. the wayback machine holds the SAME url's bytes, so
# it is a safe fallback: the digest, not the host, is what this trusts.
fetch() {
  n="$1"; out="$2"
  url=$(pin "$n" url ref); want=$(pin "$n" url sha)
  [ -n "$url" ] && [ -n "$want" ] || { echo "$n: no url pin in arsenal.pins" >&2; return 1; }
  wget -qO "$out" "$url" \
    || wget -qO "$out" "https://web.archive.org/web/2999id_/$url" \
    || { echo "$n: $url unreachable (tried wayback too)" >&2; return 1; }
  have=$(sha256sum < "$out" | cut -d' ' -f1)
  [ "$want" = "$have" ] || { echo "$n: sha256 mismatch -- refusing to build" >&2
                             echo "   want $want" >&2; echo "   got  $have" >&2; return 1; }
  log "$n: sha256 ok"
}

# clone_pinned NAME DEST -- clone the pinned repo and check out the pinned
# commit exactly, asserting HEAD is that commit. defeats a re-pointed tag and a
# moved branch head alike; github serves a fetch-by-sha so no full history is
# pulled. no source here builds until its commit is the one the pin names.
clone_pinned() {
  n="$1"; dest="$2"
  repo=$(pin "$n" git ref); commit=$(pin "$n" git commit)
  [ -n "$repo" ] && [ -n "$commit" ] || { echo "$n: no git pin in arsenal.pins" >&2; return 1; }
  git init -q "$dest"
  ( cd "$dest"
    git config advice.detachedHead false
    git remote add origin "$repo"
    git fetch -q --depth 1 origin "$commit" 2>/dev/null || git fetch -q origin
    git checkout -q "$commit"
    [ "$(git rev-parse HEAD)" = "$commit" ] ) \
    || { echo "$n: commit $commit not checked out -- refusing to build" >&2; return 1; }
  log "$n: commit $commit ok"
}

# links 2.30 -- the reader. text-mode (no X/fb): a zim is served by kiwix-serve
# on localhost and reads perfectly as text, so the graphics libs (and their
# static-link fight) are not paid for. https works: openssl-libs-static is
# linked, so it also fetches over TLS when a network is up.
# WHY THIS IS AN ARSENAL TOOL, NOT A ROOTFS COMPONENT: a browser is capability,
# and xos's rule is that capability rides p3 (carried), never the signed image.
# putting links in build.sh would widen the verity-checked trust surface for no
# reason -- the fort must stay a fort. see README.md.
( set -e; log links
  mkdir -p /s && fetch links /s/links.tar.bz2 && tar xj -C /s -f /s/links.tar.bz2
  cd /s/links-2.30
  # graphics off keeps the dep set to zlib+ssl, both of which apk ships as .a;
  # -static then links clean where a graphics build would drag in libpng/jpeg.
  # env vars must PREFIX configure -- links' configure reads CFLAGS=... as a
  # positional host triplet otherwise ("can only configure for one host").
  CFLAGS="-O2" LDFLAGS="-static" ./configure --with-ssl --without-x --without-fb \
    --without-directfb --without-svgalib >/s/links.log 2>&1
  make -j"$(nproc)" >>/s/links.log 2>&1
  file links | grep -q "statically linked" || { echo "not static"; tail -5 /s/links.log; exit 1; }
  ./links -version | head -1
  strip links                       # -s equivalent: smaller binary, same behaviour
  cp links /out/links ) || log "links FAILED"

# masscan 1.3.2 -- self-contained, static
( set -e; log masscan
  clone_pinned masscan /s/m
  make -C /s/m -j"$(nproc)" CFLAGS="-O2 -static" LDFLAGS="-static" >/s/m.log 2>&1
  file /s/m/bin/masscan | grep -q "statically linked" || { echo "not static"; exit 1; }
  cp /s/m/bin/masscan /out/masscan ) || log "masscan FAILED"

# tcpdump 4.99.5 -- apk's libpcap-dev already ships libpcap.a, so just link -static
( set -e; log tcpdump
  mkdir -p /s && fetch tcpdump /s/tcpdump.tgz && tar xz -C /s -f /s/tcpdump.tgz
  cd /s/tcpdump-4.99.5 && ./configure >/s/td.log 2>&1 && make -j"$(nproc)" LDFLAGS="-static" >>/s/td.log 2>&1
  file tcpdump | grep -q "statically linked" || { echo "not static"; exit 1; }
  cp tcpdump /out/tcpdump ) || log "tcpdump FAILED"

# socat 1.8.0.3 -- the swiss-army relay: the pivot/tunnel half alongside chisel.
# openssl-libs-static is already in the apk set, so OPENSSL addresses (socat's
# tls) compile in; --disable-readline drops the one interactive-only dep that
# would otherwise drag ncurses into the static link for no field value.
# dest-unreach.org serves a cert for another domain, so the pin is over http --
# the sha256 is the anchor, exactly as build.sh get() argues.
( set -e; log socat
  mkdir -p /s && fetch socat /s/socat.tgz && tar xz -C /s -f /s/socat.tgz
  cd /s/socat-1.8.0.3
  ./configure --disable-readline CFLAGS="-O2 -static" LDFLAGS="-static" >/s/socat.log 2>&1
  make -j"$(nproc)" >>/s/socat.log 2>&1
  file socat | grep -q "statically linked" || { echo "not static"; tail -20 /s/socat.log; exit 1; }
  strip socat
  cp socat /out/socat ) || log "socat FAILED"

# mupdf/mutool 1.24.10 -- the PDF reader for xos. `mutool draw -F txt` turns any
# pdf (the survival floor: where-there-is-no-doctor, FM 21-76, every datasheet on
# the knowledge stick) into text for busybox `less`, or `-F html` for links. it
# bundles its own freetype/mujs/jbig2dec/openjpeg, so -static links clean with no
# system libs. big (~40MB) because it carries a full pdf+font+js stack -- the only
# thing that reads a pdf on a browserless box, and the stick has room.
( set -e; log mutool
  mkdir -p /s && fetch mupdf m.tgz && tar xz -C /s -f m.tgz
  cd /s/mupdf-1.24.10-source
  # no explicit target: the default build emits build/release/mutool linked
  # against the bundled thirdparty libs. HAVE_X11/GLUT=no drops the GUI viewer.
  make -j"$(nproc)" HAVE_X11=no HAVE_GLUT=no USE_SYSTEM_LIBS=no     XCFLAGS="-O2" LDFLAGS="-static" build=release >/s/mutool.log 2>&1
  file build/release/mutool | grep -q "statically linked" || { echo "not static"; tail -5 /s/mutool.log; exit 1; }
  build/release/mutool draw -F txt -o /dev/null docsrc/manual/*.pdf 2>/dev/null || true
  strip build/release/mutool
  cp build/release/mutool /out/mutool ) || log "mutool FAILED"

# frotz (dfrotz) -- dumb-terminal z-machine interpreter. WHY: morale is a supply,
# and interactive fiction is the one game genre a text-only box runs natively --
# one ~200KB binary plays the entire if/ story library carried on the knowledge
# stick (zork, anchorhead, spider-and-web). "dumb" = pure stdout, so it needs no
# curses and runs even on a busybox console. capability -> p3, same rule as links.
# frotz ships no release tag, so the pin is a commit -- it was cloning an
# unpinned HEAD before, new code on every build with nothing recording which.
( set -e; log frotz
  clone_pinned frotz /s/frotz
  cd /s/frotz
  # -fcommon: frotz's dumb port keeps tentative defs (f_setup, do_more_prompts)
  # in a shared header; gcc>=10 defaults -fno-common and multiply-defines them.
  make dfrotz CFLAGS="-O2 -static -fcommon" LDFLAGS="-static" PKG_CONFIG=false >/s/frotz.log 2>&1
  file dfrotz | grep -q "statically linked" || { echo "not static"; tail -12 /s/frotz.log; exit 1; }
  strip dfrotz; cp dfrotz /out/frotz ) || log "frotz FAILED"

# whois 5.6.6 (rfc1036/marco d'itri) -- one of the few genuinely missing
# basics; busybox ships no whois applet. IDN support autodetects via
# pkg-config; libidn2-dev is deliberately not in the apk set above so it
# drops out clean instead of fighting a static link (an explicit
# HAVE_LIBIDN=0 make var is refused outright -- see the Makefile).
( set -e; log whois
  clone_pinned whois /s/whois
  cd /s/whois
  make CFLAGS="-O2 -static" LDFLAGS="-static" >>/s/whois.log 2>&1
  file whois | grep -q "statically linked" || { echo "not static"; tail -20 /s/whois.log; exit 1; }
  strip whois
  cp whois /out/whois ) || log "whois FAILED"

# hydra 9.5 -- online service login brute-forcer, the credential-attack half
# of the gap alongside john below (offline hashes). LIBS pins -lssl -lcrypto
# explicitly: configure's own static-link probe for -lssl fails without it
# even though openssl-libs-static is installed.
( set -e; log hydra
  clone_pinned hydra /s/hydra
  cd /s/hydra
  ./configure >>/s/hydra.log 2>&1 || true
  make CFLAGS="-O2 -static" LDFLAGS="-static" -j"$(nproc)" >>/s/hydra.log 2>&1
  file hydra | grep -q "statically linked" || { echo "not static"; tail -30 /s/hydra.log; exit 1; }
  strip hydra
  cp hydra /out/hydra ) || log "hydra FAILED"

# john (bleeding-jumbo, pinned to a commit -- upstream tags no releases off
# this branch, so commit-pin is the sqlmap pattern, not the version-tag one).
# offline hash cracker, the other half of the credential-attack gap.
# --disable-openmp: no GPU/multi-core win worth the dep on this hardware.
# needs linux-headers (yescrypt's mman.h) and the same LIBS= fix as hydra.
# ships as a TREE, not a lone binary, same as python: john.conf and the
# *2john extractor scripts/binaries sit next to the john binary and are found
# by relative path, not compiled in, so xexec's `-t DIR john` mode carries the
# whole thing. dropped from the tree: *.chr (incremental-mode charsets,
# 40MB, a mode this kit's dictionary+rules workflow doesn't use) and
# password.lst (redundant with the staged rockyou.txt/SecLists).
( set -e; log john
  clone_pinned john /s/john
  cd /s/john/src
  ./configure --disable-openmp CFLAGS="-O2 -static" LDFLAGS="-static" \
    LIBS="-lssl -lcrypto" >>/s/john.log 2>&1
  make -sj"$(nproc)" >>/s/john.log 2>&1
  file ../run/john | grep -q "statically linked" || { echo "not static"; tail -50 /s/john.log; exit 1; }
  strip ../run/john
  cd ../run && rm -rf ./*.chr password.lst bip-0039 base64conv unshadow unafs undrop
  mkdir -p /out/john && cp -a . /out/john/ ) || log "john FAILED"

# jq 1.7.1 -- every other tool here (nuclei/httpx/dnsx/subfinder) emits JSON
# and there was nothing on-box to parse it. --with-oniguruma=builtin: jq
# vendors its own copy as a submodule, so no oniguruma-dev/-static apk needed.
# -all-static must go on the MAKE line, not configure's: configure's own
# compiler probe is a raw gcc invocation that doesn't understand a libtool
# flag, but the actual `jq` link happens through the libtool CCLD wrapper,
# which does. LDFLAGS="-static" at configure time is still needed so that
# probe itself passes.
( set -e; log jq
  clone_pinned jq /s/jq
  cd /s/jq
  git submodule update --init >>/s/jq.log 2>&1
  autoreconf -fi >>/s/jq.log 2>&1
  ./configure --disable-maintainer-mode --disable-shared --with-oniguruma=builtin \
    CFLAGS="-O2" LDFLAGS="-static" >>/s/jq.log 2>&1
  make -j"$(nproc)" LDFLAGS="-all-static" >>/s/jq.log 2>&1
  file jq | grep -q "statically linked" || { echo "not static"; tail -60 /s/jq.log; exit 1; }
  strip jq
  cp jq /out/jq ) || log "jq FAILED"

# ripgrep 14.1.1 -- fast search over the already-staged corpora (exploit-db,
# man-pages, rfc-bundle, wordlists) and over loot. rust+musl with crt-static
# is inherently static-PIE, not fully static (no amount of RUSTFLAGS moves
# it off PIE on this target) -- same category as the carried kiwix release,
# so it's checked the same way build-kiwix.sh does: no INTERP segment, not
# a `file` string match.
( set -e; log ripgrep
  clone_pinned rg /s/rg
  cd /s/rg
  RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --locked >>/s/rg.log 2>&1
  readelf -l target/release/rg 2>/dev/null | grep -q INTERP \
    && { echo "dynamically linked (has INTERP)"; tail -30 /s/rg.log; exit 1; }
  strip target/release/rg
  cp target/release/rg /out/rg ) || log "ripgrep FAILED"

# nmap 7.95 -- host/service/version/OS detection + NSE, the scanner masscan
# can't be. C++, and the static-musl link was the long-standing blocker; the
# real fix turned out to be prerequisites, not a per-lib link pass:
#   - bundled libpcre regenerates aclocal.m4 on build, so automake/autoconf/
#     libtool must be present (they're in the apk set above) or `make` dies at
#     aclocal-1.16 long before any link.
#   - every object -fno-pie -fno-PIC + LDFLAGS="-static -no-pie" defeats
#     Alpine's PIE-default toolchain (a PIE object in a -static link throws
#     R_X86_64_32 / __TMC_END__).
#   - system static libs via --with-{libz,openssl,libpcap}=/usr; the bundled
#     zlib otherwise insists on a libz.so that -static can't link.
# with those, a plain parallel `make` emits a static nmap -- no serial pass.
( set -e; log nmap
  mkdir -p /s && fetch nmap /s/nmap.tar.bz2 && tar xj -C /s -f /s/nmap.tar.bz2
  cd /s/nmap-7.95
  F="-O2 -fno-pie -fno-PIC"
  ./configure --without-zenmap --without-ndiff --without-nping --without-libssh2 \
    --with-libz=/usr --with-openssl=/usr --with-libpcap=/usr \
    CC=gcc CXX=g++ CFLAGS="$F" CXXFLAGS="$F" LDFLAGS="-static -no-pie" >/s/nmap.log 2>&1
  make -j"$(nproc)" >>/s/nmap.log 2>&1
  file nmap | grep -q "statically linked" || { echo "not static"; tail -30 /s/nmap.log; exit 1; }
  strip nmap
  cp nmap /out/nmap ) || log "nmap FAILED"

# ---- recovery / forensics / triage: the flank the offense set left open -----

# zstd 1.5.6 -- the modern compressor. more and more images, firmware dumps and
# package payloads land as .zst, which nothing else on the stick reads; the one
# binary is also unzstd and zstdcat by argv0. optional zlib/lzma/lz4 support is
# turned OFF so the static link stays clean and the binary decodes .zst alone.
( set -e; log zstd
  mkdir -p /s && fetch zstd /s/zstd.tgz && tar xz -C /s -f /s/zstd.tgz
  cd /s/zstd-1.5.6
  make -j"$(nproc)" -C programs zstd HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 \
    CFLAGS="-O2" LDFLAGS="-static" >/s/zstd.log 2>&1
  file programs/zstd | grep -q "statically linked" || { echo "not static"; tail -5 /s/zstd.log; exit 1; }
  programs/zstd --version
  strip programs/zstd
  cp programs/zstd /out/zstd ) || log "zstd FAILED"

# ddrescue 1.28 -- the tool for a dying disk: it images what still reads, logs
# the bad ranges to a mapfile, and resumes, so a failing drive is copied in one
# careful pass instead of hammered. the disk-blind fort reaches media only over
# usb, which is exactly where a recovery job starts. GNU ships .tar.lz, so lzip
# unpacks it; the configure is GNU's own script, not autotools.
( set -e; log ddrescue
  mkdir -p /s && fetch ddrescue /s/ddrescue.tar.lz && lzip -dc /s/ddrescue.tar.lz | tar x -C /s
  cd /s/ddrescue-1.28
  ./configure CXXFLAGS="-O2 -static" >/s/ddrescue.log 2>&1
  make -j"$(nproc)" >>/s/ddrescue.log 2>&1
  file ddrescue | grep -q "statically linked" || { echo "not static"; tail -8 /s/ddrescue.log; exit 1; }
  ./ddrescue --version | head -1
  strip ddrescue
  cp ddrescue /out/ddrescue ) || log "ddrescue FAILED"

# strace 6.13 -- syscall trace: watch what an unknown or misbehaving binary
# actually does -- files it opens, connects it makes, why it exits -- the
# dynamic-analysis half the deferred gdb leaves open, and the fastest triage of
# a foreign binary short of a debugger. --enable-mpers=no drops the 32-bit
# personality shim that fights a static link on x86_64.
( set -e; log strace
  mkdir -p /s && fetch strace /s/strace.tar.xz && tar xJ -C /s -f /s/strace.tar.xz
  cd /s/strace-6.13
  ./configure --enable-mpers=no LDFLAGS="-static" >/s/strace.log 2>&1
  make -j"$(nproc)" >>/s/strace.log 2>&1
  file src/strace | grep -q "statically linked" || { echo "not static"; tail -8 /s/strace.log; exit 1; }
  ./src/strace -V | head -1
  strip src/strace
  cp src/strace /out/strace ) || log "strace FAILED"

# testdisk + photorec 7.2 -- the recovery pair: testdisk rebuilds a lost or
# corrupt partition table and its boot sectors, photorec carves files back off
# a formatted or damaged filesystem by signature. exactly the job that starts
# once ddrescue has imaged the failing disk over usb. ntfs/jpeg/ewf/reiser
# support is dropped so the static link needs only ncurses + e2fsprogs (both
# .a in the apk set); the tui still runs over a serial console.
( set -e; log testdisk
  mkdir -p /s && fetch testdisk /s/td.tar.bz2 && tar xj -C /s -f /s/td.tar.bz2
  cd /s/testdisk-7.2
  ./configure --without-ntfs --without-ntfs3g --without-jpeg --without-ewf --without-reiserfs \
    CFLAGS="-O2" LDFLAGS="-static" >/s/td.log 2>&1
  make -j"$(nproc)" >>/s/td.log 2>&1
  for b in testdisk photorec; do
    file "src/$b" | grep -q "statically linked" || { echo "$b not static"; tail -12 /s/td.log; exit 1; }
    strip "src/$b"; cp "src/$b" "/out/$b"
  done
  ./src/testdisk /version 2>&1 | head -1 || true ) || log "testdisk FAILED"

# smartctl 7.4 -- SMART health for a disk reached over the usb-sata/nvme adapter:
# reallocated sectors, pending sectors, self-test log -- whether a drive is dying
# before you trust or wipe it. smartd (the daemon) is not built; a field kit reads
# health on demand, it does not run a monitor. the nvme-devicescan probe is off so
# the static link does not want libnvme.
( set -e; log smartctl
  mkdir -p /s && fetch smartmontools /s/sm.tgz && tar xz -C /s -f /s/sm.tgz
  cd /s/smartmontools-7.4
  ./configure --without-libcap-ng --without-libsystemd --without-selinux --without-nvme-devicescan \
    CXXFLAGS="-O2" LDFLAGS="-static" >/s/sm.log 2>&1
  make -j"$(nproc)" smartctl >>/s/sm.log 2>&1
  file smartctl | grep -q "statically linked" || { echo "not static"; tail -12 /s/sm.log; exit 1; }
  ./smartctl --version | head -1
  strip smartctl
  cp smartctl /out/smartctl ) || log "smartctl FAILED"

# file 5.46 -- identify an unknown blob by content: the one forensics staple the
# arsenal lacked, where strings only shows text. ships two artifacts: the static
# binary and its compiled magic database (file.mgc, ~10MB). provision drops the
# db at $HOME/.magic.mgc, which libmagic auto-discovers with no env or wrapper --
# verified. decompression (zlib/bz2/xz/zstd) is off so the static link stays lean:
# file names the outer type, and the carried zstd/gunzip/xz open it to re-file.
# NOTE: file uses libtool, which drops a plain -static, so the executable link
# needs -all-static (libtool's own flag) to come out static.
( set -e; log file
  mkdir -p /s && fetch file /s/file.tgz && tar xz -C /s -f /s/file.tgz
  cd /s/file-5.46
  ./configure --disable-shared --enable-static --disable-libseccomp \
    --disable-zlib --disable-bzlib --disable-xzlib --disable-zstdlib --disable-lzlib \
    CFLAGS="-O2" >/s/file.log 2>&1
  make -j"$(nproc)" LDFLAGS="-all-static" >>/s/file.log 2>&1
  file src/file | grep -q "statically linked" || { echo "not static"; file src/file; tail -8 /s/file.log; exit 1; }
  MAGIC=magic/magic.mgc ./src/file src/file | grep -q ELF || { echo "magic db not working"; exit 1; }
  strip src/file
  cp src/file /out/file
  cp magic/magic.mgc /out/file.mgc ) || log "file FAILED"

# mandoc 1.14.6 -- the man-page reader. build-docs stages the linux man-pages
# corpus onto XOS-KNOW, but nothing rendered it: busybox has no man applet and
# troff source is not reading material. mandoc renders man(7)/mdoc(7) to a plain
# terminal with no roff and no dep but zlib (so .gz pages open too). `mandoc
# PAGE` prints one page; build-docs' own usage line points at it now. AN ARSENAL
# TOOL, NOT A ROOTFS ONE: a reader is capability, and capability rides p3 -- the
# man-pages payload rides XOS-KNOW beside it, both off the signed fort.
# NOTE: the build embeds a BuildID, so the arsenal.lock sha drifts per build
# (size stable) -- a point-in-time attestation, like masscan/nmap/radare2.
( set -e; log mandoc
  mkdir -p /s && fetch mandoc /s/mandoc.tgz && tar xz -C /s -f /s/mandoc.tgz
  cd /s/mandoc-1.14.6
  { echo 'PREFIX=/usr'; echo 'CFLAGS="-O2 -static"'; echo 'LDFLAGS="-static"'; echo 'LDADD="-lz"'; } > configure.local
  ./configure >/s/mandoc.log 2>&1
  make -j"$(nproc)" mandoc >>/s/mandoc.log 2>&1
  file mandoc | grep -q "statically linked" || { echo "not static"; tail -12 /s/mandoc.log; exit 1; }
  ./mandoc -T ascii mandoc.1 | grep -q . || { echo "mandoc renders nothing"; exit 1; }
  strip mandoc
  cp mandoc /out/mandoc ) || log "mandoc FAILED"

# ---- field ops: sign/verify, sync, multiplexed terminal --------------------

# minisign 0.12 -- field signature sign/verify (jedisct1, ed25519 via libsodium).
# verifies a release tarball or a backup image against a detached .minisig
# without gpg's whole trust model; the :crypto chain below pairs it with age.
# cmake's own BUILD_STATIC_EXECUTABLES flips pkg_check_modules to the .a in
# libsodium-static and forces LINK_SEARCH_{START,END}_STATIC -- no manual
# link-flag surgery needed, unlike the rest of this file.
( set -e; log minisign
  clone_pinned minisign /s/minisign
  cd /s/minisign
  mkdir build && cd build
  cmake -D BUILD_STATIC_EXECUTABLES=1 -D CMAKE_BUILD_TYPE=MinSizeRel .. >/s/minisign.log 2>&1
  make -j"$(nproc)" >>/s/minisign.log 2>&1
  file minisign | grep -q "statically linked" || { echo "not static"; tail -20 /s/minisign.log; exit 1; }
  ./minisign -v | head -1
  strip minisign
  cp minisign /out/minisign ) || log "minisign FAILED"

# dvtm 0.15 -- suckless terminal multiplexer: split panes with no tmux server,
# no config file, no dependency beyond ncurses -- a shell running abduco (the
# existing detach layer) gains real panes for it. LDFLAGS goes into config.mk
# rather than the make command line: dvtm's own CFLAGS already carries a
# shell-quoted -DVERSION="0.15" that a CLI override would re-escape and break
# (the compiler then sees VERSION as a bare float literal, not a string).
( set -e; log dvtm
  clone_pinned dvtm /s/dvtm
  cd /s/dvtm
  sed -i 's/^LDFLAGS += /LDFLAGS += -static /' config.mk
  make -j"$(nproc)" >/s/dvtm.log 2>&1
  file dvtm | grep -q "statically linked" || { echo "not static"; tail -20 /s/dvtm.log; exit 1; }
  strip dvtm
  cp dvtm /out/dvtm ) || log "dvtm FAILED"

# rsync 3.5.1 -- sync/backup over ssh, resumable and delta-transferring: the
# one thing scp/socat can't do is skip what already matches on the far end.
# optional deps are all disabled rather than fought static: openssl/xxhash/
# zstd/lz4 buy modern checksum/compression choices this kit doesn't need, and
# idn needs libidn2 (deliberately absent, same call as whois above); dropping
# all five leaves rsync's own bundled zlib+popt as the only libs, both already
# static-clean. --disable-md2man drops the python3-only manpage build.
( set -e; log rsync
  mkdir -p /s && fetch rsync /s/rsync.tgz && tar xz -C /s -f /s/rsync.tgz
  cd /s/rsync-3.5.1
  ./configure --disable-openssl --disable-xxhash --disable-zstd --disable-lz4 \
    --disable-idn --disable-md2man --with-included-popt \
    CFLAGS="-O2 -static" LDFLAGS="-static" >/s/rsync.log 2>&1
  make -j"$(nproc)" >>/s/rsync.log 2>&1
  file rsync | grep -q "statically linked" || { echo "not static"; tail -20 /s/rsync.log; exit 1; }
  ./rsync --version | head -1
  strip rsync
  cp rsync /out/rsync ) || log "rsync FAILED"

# qrencode 4.1.1 -- airgap egress: a wg config, a pubkey or any small file as a
# scannable QR on the console, read off by a phone camera with NO network
# between the two machines at all -- the one transfer path xos can offer when
# even a usb stick is a bridge you do not want to cross. `arsenal/qr` is the
# wrapper (plain busybox ash, not python -- this binary needs no interpreter
# tree, so requiring one would be a self-inflicted dependency).
# --without-png, NOT --without-tools: xos only ever renders to a terminal
# (-t UTF8/ANSIUTF8/ASCII), so the PNG encoder and its libpng dependency are
# dead weight -- but --without-tools disables BUILD_TOOLS entirely, which is
# the qrencode CLI itself; passing it would build a static libqrencode.a and
# no qrencode binary at all. read configure.ac before trusting a flag's name.
( set -e; log qrencode
  clone_pinned qrencode /s/qrencode
  cd /s/qrencode
  ./autogen.sh >/s/qrencode.log 2>&1
  ./configure --disable-shared --enable-static --without-png \
    CFLAGS="-O2" LDFLAGS="-static" >>/s/qrencode.log 2>&1
  make -j"$(nproc)" LDFLAGS="-all-static" >>/s/qrencode.log 2>&1
  file qrencode | grep -q "statically linked" || { echo "not static"; tail -40 /s/qrencode.log; exit 1; }
  ./qrencode -t ASCII "xos" | grep -q '#' || { echo "qrencode renders nothing"; exit 1; }
  strip qrencode
  cp qrencode /out/qrencode ) || log "qrencode FAILED"

# binwalk 3.1.0 -- firmware carving: scan a blob for embedded filesystems,
# bootloaders, compressed streams and keys, and map where each begins. the v3
# rewrite is rust. two knots, both handled here:
#   * it uses std::path::absolute (rust >= 1.79); alpine 3.20 ships 1.78, so this
#     block installs a current stable toolchain via rustup rather than bump the
#     base image out from under every other tool.
#   * a plain crt-static in RUSTFLAGS makes proc-macros fail to build on a musl
#     host; naming --target x86_64-unknown-linux-musl explicitly splits host
#     (proc-macro) from target (crt-static) codegen and it links clean.
# it pulls fontconfig/freetype (its entropy-graph png), so those .a's + expat/
# png/brotli are in the apk set and PKG_CONFIG_ALL_STATIC forces static libs.
# comes out static-pie (self-contained, no interpreter), same class as rg.
( set -e; log binwalk
  mkdir -p /s; rustup-init -y --default-toolchain stable --profile minimal >/s/rustup.log 2>&1
  . "$HOME/.cargo/env"
  clone_pinned binwalk /s/bw
  cd /s/bw
  PKG_CONFIG_ALL_STATIC=1 PKG_CONFIG_ALLOW_SYSTEM_LIBS=1 \
  RUSTFLAGS="-C target-feature=+crt-static" \
    cargo build --release --locked --target x86_64-unknown-linux-musl >/s/bw.log 2>&1
  B=target/x86_64-unknown-linux-musl/release/binwalk
  readelf -l "$B" | grep -q INTERP && { echo "not static (has interp)"; exit 1; }
  "$B" --version | head -1
  strip "$B"; cp "$B" /out/binwalk ) || log "binwalk FAILED"

# cc -- a C compiler carried on the stick. xos ships no compiler by design (the
# fort's contract), so this rides p3: capability by carry, never a fort change.
# tcc is the whole toolchain in one static binary -- its own preprocessor,
# assembler and linker -- so it needs no binutils (whose as/ld will not link
# static-musl: LDFLAGS never threads into their executable link, the same wall
# the repo's gdb note records). alongside it we carry a musl sysroot (libc.a +
# crt + headers, from this pinned alpine's musl-dev) and two wrappers:
#   cc   -- tcc, self-contained; supplies crt/libc on the link (tcc finds crt via
#           a compiled prefix, not -L, so the link step names them explicitly)
#   cpp  -- tcc -E, the standalone preprocessor
# run on the stick through xexec's tree mode: sh ~/tools/xexec -t ~/tools/cc cc x.c -o x
# NOTE (cproc/qbe): the oasis compiler builds static fine and compiles end-to-end
# WITH a preprocessor+as+ld, but it drives an external as/ld -- i.e. binutils,
# which hits the static wall above. tcc supersedes it here (one binary, no wall).
( set -e; log cc
  clone_pinned tcc /s/tcc
  cd /s/tcc
  ./configure --prefix=/opt/xcc --enable-static --config-bcheck=no --config-backtrace=no \
    --extra-cflags="-static -O2" --extra-ldflags="-static" >/s/tcc.log 2>&1
  make -j"$(nproc)" >>/s/tcc.log 2>&1
  readelf -l tcc | grep -q INTERP && { echo "tcc not static"; exit 1; }
  strip tcc; make install >/dev/null 2>&1
  mkdir -p /out/cc/tcc /out/cc/sysroot/lib /out/cc/sysroot/include
  cp tcc /out/cc/tcc-bin
  cp -a /opt/xcc/lib/tcc/. /out/cc/tcc/
  # the musl sysroot: static libc + startup objects + headers, from the pinned base
  for f in libc.a crt1.o crti.o crtn.o Scrt1.o rcrt1.o; do
    [ -f "/usr/lib/$f" ] && cp -a "/usr/lib/$f" /out/cc/sysroot/lib/
  done
  cp -a /usr/include/. /out/cc/sysroot/include/
  # the wrappers (printf, not a heredoc -- keep this block one flat level)
  { printf '%s\n' '#!/bin/sh' \
    'D=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' \
    'T="$D/tcc-bin"; S="$D/sysroot"' \
    'case " $* " in' \
    '  *" -c "*|*" -E "*|*" -S "*) exec "$T" -B"$D/tcc" -I"$S/include" "$@" ;;' \
    'esac' \
    'exec "$T" -B"$D/tcc" -I"$S/include" -nostdlib -static "$S/lib/crt1.o" "$S/lib/crti.o" "$@" -L"$S/lib" -lc "$S/lib/crtn.o"' \
  ; } > /out/cc/cc
  { printf '%s\n' '#!/bin/sh' \
    'D=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' \
    'exec "$D/tcc-bin" -B"$D/tcc" -E "$@"' \
  ; } > /out/cc/cpp
  chmod +x /out/cc/cc /out/cc/cpp
  "/out/cc/tcc-bin" -v 2>&1 | head -1 ) || log "cc FAILED"

# radare2 -- the reversing kit the arsenal lacked (no r2, no gdb). one static
# multicall blob (r2blob: r2/rabin2/radiff2/rax2/... by argv0) that disassembles,
# analyses and hex-edits a binary offline. the static-musl fight is precise: r2's
# own libs already link static via -Dstatic_runtime, but (a) the vendored sdb
# subproject builds a *shared* .so, so a GLOBAL -static poisons that link (crt1
# wants main), and (b) the r2blob.static target links r2 static yet leaves libc
# dynamic. so we DON'T pass -static globally -- we patch ONLY the r2blob.static
# executable to link -static, leaving the sdb .so untouched. that gives one fully
# static blob and covers the deferred-gdb reversing gap (r2 has its own debugger).
( set -e; log radare2
  clone_pinned radare2 /s/r2
  cd /s/r2
  # surgical: give ONLY the r2blob.static executable a fully-static link (libc too)
  sed -i "s#executable('r2blob.static', 'r2blob.c',#executable('r2blob.static', 'r2blob.c',\n  link_args: ['-static', '-no-pie'],#" binr/blob/meson.build
  meson setup build --buildtype=release --default-library=static \
    -Dstatic_runtime=true -Dblob=true -Db_pie=false \
    -Dc_args="-fno-pie -fno-PIC" >/s/r2.log 2>&1
  ninja -C build binr/blob/r2blob.static >>/s/r2.log 2>&1
  B=build/binr/blob/r2blob.static
  readelf -l "$B" | grep -q INTERP && { echo "r2blob not static"; exit 1; }
  strip "$B"; cp "$B" /out/radare2
  "/out/radare2" -v 2>&1 | head -1 ) || log "radare2 FAILED"

# gdb -- DEFERRED (static link). 15.2 configures and compiles clean in Alpine
# (gmp/mpfr .a live in gmp-dev/mpfr-dev, not a -static package), but the final
# `gdb` executable links dynamic-PIE against ld-musl even with LDFLAGS="-static
# -no-pie" at configure and --with-static-standard-libraries: gdb's own gdb/
# Makefile does not thread LDFLAGS into the executable link, so -static never
# reaches it. the fix is a per-subdir relink pass (make -C gdb ... LDFLAGS=
# "-static -no-pie") after the build, deferred. low priority: a headless field
# kit rarely runs an interactive C debugger, and the crash-triage floor is
# covered by strings + the carried python.
#
# tshark -- DEFERRED (glib/static). wireshark 4.4.8's cmake finds every static
# dep in Alpine (glib-static, pcre2-dev, c-ares-static, libgcrypt-static,
# libpcap-dev, libffi, libintl.a), but a global CMAKE_EXE_LINKER_FLAGS="-static"
# breaks cmake's own feature probes -- the libpcap check links a -static test
# that fails ("pcap_lib_version - not found" -> "need libpcap 0.8 or later")
# before the build starts. static wireshark needs the probes run dynamic and
# only tshark's final link forced static, which its cmake doesn't cleanly
# support. deferred; tcpdump covers capture on-box.
#
# nethack -- DEFERRED (roguelike, would be the morale S-tier). two blockers, both
# solvable in a follow-up pass:
#   1. build: passing CFLAGS="...-static" wholesale clobbers nethack's own
#      -I../include, so src/*.c can't find config.h. the fix is to edit
#      sys/unix/hints/linux to APPEND '-static' to LFLAGS + '-fcommon' to CFLAGS
#      (nethack 3.6.x is pre -fno-common too) rather than overriding on the cli.
#   2. runtime: nethack needs a WRITABLE HACKDIR (saves/bones/record); p3 and the
#      xexec tmpfs are read-only, so a launch must point HACKDIR at exFAT, e.g.
#      HACKDIR=/run/media/$USER/XOS-KNOW/games/nethack ~/tools/xexec nethack
# frotz + the if/ story library already give xos a native game library; nethack
# is the next add, not a blocker.


echo "[c-build] built: $(ls /out | grep -E '^(masscan|tcpdump|socat|nmap|links|mutool|frotz|whois|hydra|john|jq|rg|zstd|ddrescue|strace|testdisk|photorec|smartctl|file|mandoc|minisign|dvtm|rsync|binwalk)$' | tr '\n' ' ')"
INNER
echo "arsenal now: $(ls "$OUT" | tr '\n' ' ')"
# fail LOUD, not open: a build that produced none of its four binaries used to
# exit 0 with an empty arsenal (the $PWD/$OUT double-prefix bug did exactly this).
# a builder that ships nothing must fail, not shrink -- the same rule as rootfs().
# john ships as a tree (john/john inside), not a lone file -- checked with -e.
built=0
for b in masscan tcpdump socat nmap links mutool frotz whois hydra jq rg minisign dvtm rsync; do [ -f "$OUT/$b" ] && built=$((built+1)); done
[ -f "$OUT/john/john" ] && built=$((built+1))
[ "$built" -ge 1 ] || { echo "FAIL: build-arsenal-c produced no binaries" >&2; exit 1; }
echo "note: refresh arsenal/arsenal.lock after (sha256 + sizes)."

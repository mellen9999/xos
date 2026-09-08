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
# regen, or by hand). builds masscan + tcpdump + links + mutool, all static.
# NOTE: masscan + tcpdump embed a build-id, so their arsenal.lock sha drifts per
# build (size is stable) -- a point-in-time attestation. links + mutool are
# bit-reproducible. masscan needs linux-headers (netlink) -- in the apk set below.
#
# nmap is NOT built here: nmap 7.95 is C++ and its static-musl link fights
# Alpine's PIE-default toolchain. progress made (phase-2b picks up here):
#   - compile every object -fno-pie -fno-PIC (kills the initial R_X86_64_32 /
#     __TMC_END__ against a PIE-compiled object)
#   - point configure at the SYSTEM static libz (--with-libz=/usr): the bundled
#     zlib insists on building libz.so, which -static cannot link ("undefined
#     reference to main" from crt1 linking a .so)
#   - keep bundled pcre2 (builds a .a, fine); 7.95 needs pcre2 not legacy pcre
# with those, configure + most objects build, but the final parallel link still
# does not emit a static binary -- the remaining fix is a serial per-lib flag
# pass to pin the last offending object. masscan covers fast scanning until then.
set -eu
OUT="${1:-arsenal}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)  # absolute: -v below must not double-prefix $PWD
command -v docker >/dev/null || { echo "no docker" >&2; exit 1; }

docker run --rm -i --network host -v "$OUT":/out alpine:3.20 sh -e <<'INNER'
apk add --no-cache build-base git wget tar libpcap-dev linux-headers \
  zlib-dev zlib-static openssl-dev openssl-libs-static bzip2-static >/dev/null 2>&1
log() { echo "[c-build] $*"; }

# links 2.30 -- the reader. text-mode (no X/fb): a zim is served by kiwix-serve
# on localhost and reads perfectly as text, so the graphics libs (and their
# static-link fight) are not paid for. https works: openssl-libs-static is
# linked, so it also fetches over TLS when a network is up.
# WHY THIS IS AN ARSENAL TOOL, NOT A ROOTFS COMPONENT: a browser is capability,
# and xos's rule is that capability rides p3 (carried), never the signed image.
# putting links in build.sh would widen the verity-checked trust surface for no
# reason -- the fort must stay a fort. see field/README.md.
( set -e; log links
  mkdir -p /s && wget -qO- http://links.twibright.com/download/links-2.30.tar.bz2 | tar xj -C /s
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
  git clone --depth 1 -b 1.3.2 https://github.com/robertdavidgraham/masscan /s/m >/dev/null 2>&1
  make -C /s/m -j"$(nproc)" CFLAGS="-O2 -static" LDFLAGS="-static" >/s/m.log 2>&1
  file /s/m/bin/masscan | grep -q "statically linked" || { echo "not static"; exit 1; }
  cp /s/m/bin/masscan /out/masscan ) || log "masscan FAILED"

# tcpdump 4.99.5 -- apk's libpcap-dev already ships libpcap.a, so just link -static
( set -e; log tcpdump
  wget -qO- https://www.tcpdump.org/release/tcpdump-4.99.5.tar.gz | tar xz -C /s
  cd /s/tcpdump-4.99.5 && ./configure >/s/td.log 2>&1 && make -j"$(nproc)" LDFLAGS="-static" >>/s/td.log 2>&1
  file tcpdump | grep -q "statically linked" || { echo "not static"; exit 1; }
  cp tcpdump /out/tcpdump ) || log "tcpdump FAILED"

# mupdf/mutool 1.24.10 -- the PDF reader for xos. `mutool draw -F txt` turns any
# pdf (the survival floor: where-there-is-no-doctor, FM 21-76, every datasheet on
# the knowledge stick) into text for busybox `less`, or `-F html` for links. it
# bundles its own freetype/mujs/jbig2dec/openjpeg, so -static links clean with no
# system libs. big (~40MB) because it carries a full pdf+font+js stack -- the only
# thing that reads a pdf on a browserless box, and the stick has room.
( set -e; log mutool
  wget -qO m.tgz https://github.com/ArtifexSoftware/mupdf-downloads/releases/download/1.24.10/mupdf-1.24.10-source.tar.gz     || wget -qO m.tgz "https://web.archive.org/web/2999id_/https://mupdf.com/downloads/archive/mupdf-1.24.10-source.tar.gz"
  mkdir -p /s && tar xz -C /s -f m.tgz
  cd /s/mupdf-1.24.10-source
  # no explicit target: the default build emits build/release/mutool linked
  # against the bundled thirdparty libs. HAVE_X11/GLUT=no drops the GUI viewer.
  make -j"$(nproc)" HAVE_X11=no HAVE_GLUT=no USE_SYSTEM_LIBS=no     XCFLAGS="-O2" LDFLAGS="-static" build=release >/s/mutool.log 2>&1
  file build/release/mutool | grep -q "statically linked" || { echo "not static"; tail -5 /s/mutool.log; exit 1; }
  build/release/mutool draw -F txt -o /dev/null docsrc/manual/*.pdf 2>/dev/null || true
  strip build/release/mutool
  cp build/release/mutool /out/mutool ) || log "mutool FAILED"

echo "[c-build] built: $(ls /out | grep -E '^(masscan|tcpdump|links|mutool)$' | tr '\n' ' ')"
INNER
echo "arsenal now: $(ls "$OUT" | tr '\n' ' ')"
# fail LOUD, not open: a build that produced none of its four binaries used to
# exit 0 with an empty arsenal (the $PWD/$OUT double-prefix bug did exactly this).
# a builder that ships nothing must fail, not shrink -- the same rule as rootfs().
built=0
for b in masscan tcpdump links mutool; do [ -f "$OUT/$b" ] && built=$((built+1)); done
[ "$built" -ge 1 ] || { echo "FAIL: build-arsenal-c produced no binaries" >&2; exit 1; }
echo "note: refresh field/arsenal.lock after (sha256 + sizes)."

# ── nmap phase-2b: resume here ────────────────────────────────────────────────
# the recipe below gets 7.95 through configure and every object; it FAILS only at
# the final static link (see the note up top). uncomment inside the docker block
# and finish the per-lib flag pass. deps to apk add: openssl-dev
# openssl-libs-static zlib-static zlib-dev libpcap-dev linux-headers.
#
#   wget -qO- https://nmap.org/dist/nmap-7.95.tar.bz2 | tar xj && cd nmap-7.95
#   F="-O2 -fno-pie -fno-PIC"
#   ./configure --without-zenmap --without-ndiff --without-nping --without-libssh2 \
#     --with-libz=/usr --with-openssl=/usr --with-libpcap=/usr \
#     CC=gcc CXX=g++ CFLAGS="$F" CXXFLAGS="$F" LDFLAGS="-static -no-pie"
#   make -j"$(nproc)"        # <-- last object still won't link static; make serial
#   file nmap | grep -q "statically linked" && cp nmap /out/nmap

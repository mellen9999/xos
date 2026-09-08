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
# regen, or by hand). builds masscan + tcpdump, both verified static.
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
OUT="${1:-arsenal}"; mkdir -p "$OUT"
command -v docker >/dev/null || { echo "no docker" >&2; exit 1; }

docker run --rm --network host -v "$PWD/$OUT":/out alpine:3.20 sh -e <<'INNER'
apk add --no-cache build-base git wget tar libpcap-dev >/dev/null 2>&1
log() { echo "[c-build] $*"; }

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

echo "[c-build] built: $(ls /out | grep -E '^(masscan|tcpdump)$' | tr '\n' ' ')"
INNER
echo "arsenal now: $(ls "$OUT" | tr '\n' ' ')"
echo "note: refresh field/arsenal.lock after (sha256 + sizes)."

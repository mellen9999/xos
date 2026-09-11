#!/bin/sh
# build-arsenal.sh -- produce the static Go field tools for ~/tools/ on p3.
#
# Go with CGO disabled emits a fully static amd64 binary with zero musl fuss,
# so the modern recon/pivot ecosystem drops onto xos as-is. this builds a
# curated set into a staging dir and writes arsenal.lock: tool, resolved
# version, size, sha256 -- the arsenal's own attestation, in xos's spirit
# (reproducible + hashed). copy the staging dir to the stick's ~/tools/.
#
# needs: go (paru -S go / pacman -S go). network, to fetch modules once.
# nothing here is offensive on its own; these are the same tools every blue
# and red team ships. keep it lean -- every binary is weight.
set -eu

OUT="${1:-arsenal}"                 # staging dir (copy to p3 ~/tools/)
LOCK="$(dirname "$0")/arsenal.lock"
command -v go >/dev/null || { echo "build-arsenal: no go -- 'paru -S go' first" >&2; exit 1; }

# tool = module path @ version. PINNED for a reproducible arsenal -- bump a
# version here and the lock records the new build. all CGO-free / pure Go
# (verified: naabu, tshark and friends need libpcap/CGO and are NOT here).
set -- \
  "ffuf=github.com/ffuf/ffuf/v2@v2.2.1" \
  "httpx=github.com/projectdiscovery/httpx/cmd/httpx@v1.12.0" \
  "nuclei=github.com/projectdiscovery/nuclei/v3/cmd/nuclei@v3.11.1" \
  "subfinder=github.com/projectdiscovery/subfinder/v2/cmd/subfinder@v2.16.0" \
  "dnsx=github.com/projectdiscovery/dnsx/cmd/dnsx@v1.3.1" \
  "gobuster=github.com/OJ/gobuster/v3@v3.8.2" \
  "chisel=github.com/jpillora/chisel@v1.12.1" \
  "pspy=github.com/dominicbreuker/pspy@v1.2.1"

mkdir -p "$OUT"
BIN="$(mktemp -d)"; NEWLOCK="$(mktemp)"
trap 'rm -rf "$BIN"; rm -f "$NEWLOCK"' EXIT
export CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS=-trimpath GOBIN="$BIN"

# the lock is shared: build-arsenal-c.sh and build-python.sh also record their
# tools in it. preserve THEIR lines (and the header) so a Go rebuild refreshes
# only the Go set instead of wiping the whole attestation.
gonames="ffuf httpx nuclei subfinder dnsx gobuster chisel pspy"
gore=$(printf '%s' "$gonames" | tr ' ' '|')
carry=""
[ -f "$LOCK" ] && carry=$(grep -Ev "^($gore)[[:space:]]" "$LOCK" 2>/dev/null | grep -Ev '^[[:space:]]*#' || true)

# built into a scratch file, not $LOCK directly: a go install failure partway
# through the loop must leave the real lock untouched. writing straight into
# $LOCK would truncate it before this point and, under set -eu, exit before
# the carry-forward below ever ran -- silently losing every C/python/sqlmap
# attestation line on the very next successful build.
printf '# arsenal.lock -- Go set refreshed %s\n# tool  source  bytes  sha256\n' \
  "$(date -u +%Y-%m-%dT%H:%MZ)" > "$NEWLOCK"

for spec in "$@"; do
  name=${spec%%=*}; mod=${spec#*=}
  echo "building $name ($mod) ..."
  # -s -w strips symbol + DWARF tables: smaller binary, same behaviour.
  go install -ldflags '-s -w' "$mod"
  # the installed binary is named for its package; find it and normalise.
  src="$BIN/$(ls "$BIN")"; [ -f "$BIN/$name" ] && src="$BIN/$name"
  # resolve what version actually got built (module graph, last matching line).
  ver=$(go version -m "$src" 2>/dev/null | awk '$1=="mod"{print $3; exit}')
  cp "$src" "$OUT/$name"; rm -f "$src"
  sz=$(stat -c%s "$OUT/$name"); sh=$(sha256sum < "$OUT/$name" | cut -d' ' -f1)
  printf '%-12s %s@%s  %s  %s\n' "$name" "${mod%@*}" "${ver:-?}" "$sz" "$sh" >> "$NEWLOCK"
done

# re-attach the C/python/sqlmap lines a prior run of the other scripts recorded.
[ -n "$carry" ] && printf '%s\n' "$carry" >> "$NEWLOCK"
mv "$NEWLOCK" "$LOCK"

echo
echo "== arsenal built into $OUT/ =="
column -t "$LOCK" 2>/dev/null | sed 's/^/  /' || sed 's/^/  /' "$LOCK"
tot=$(du -sh "$OUT" | cut -f1); echo "  total: $tot"
echo "  copy to the stick: cp $OUT/* /path/to/p3/tools/   (run via: sh ~/tools/xexec ~/tools/<tool>)"

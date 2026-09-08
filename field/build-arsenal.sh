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

# tool = module path @ version. @latest on first run; pin from arsenal.lock
# after, for a reproducible arsenal. all CGO-free / pure Go (verified: naabu,
# tshark and friends need libpcap/CGO and are NOT here).
set -- \
  "ffuf=github.com/ffuf/ffuf/v2@latest" \
  "httpx=github.com/projectdiscovery/httpx/cmd/httpx@latest" \
  "nuclei=github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest" \
  "subfinder=github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" \
  "dnsx=github.com/projectdiscovery/dnsx/cmd/dnsx@latest" \
  "gobuster=github.com/OJ/gobuster/v3@latest" \
  "chisel=github.com/jpillora/chisel@latest"

mkdir -p "$OUT"
BIN="$(mktemp -d)"; trap 'rm -rf "$BIN"' EXIT
export CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS=-trimpath GOBIN="$BIN"

: > "$LOCK"
printf '# arsenal.lock -- built %s\n# tool  module@version  bytes  sha256\n' \
  "$(date -u +%Y-%m-%dT%H:%MZ)" >> "$LOCK"

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
  printf '%-12s %s@%s  %s  %s\n' "$name" "${mod%@*}" "${ver:-?}" "$sz" "$sh" >> "$LOCK"
done

echo
echo "== arsenal built into $OUT/ =="
column -t "$LOCK" 2>/dev/null | sed 's/^/  /' || sed 's/^/  /' "$LOCK"
tot=$(du -sh "$OUT" | cut -f1); echo "  total: $tot"
echo "  copy to the stick: cp $OUT/* /path/to/p3/tools/   (run via: sh ~/tools/xexec ~/tools/<tool>)"

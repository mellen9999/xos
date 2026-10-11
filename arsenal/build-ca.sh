#!/bin/sh
# build-ca.sh -- carry a CA trust store for the TLS tools on p3.
#
# the signed root ships no CA bundle (it has no business trusting the public
# web), but the carried tools do: python's statically-linked OpenSSL (sqlmap,
# impacket) looks for /etc/ssl/cert.pem, finds nothing, and every HTTPS/LDAPS
# verify fails -- leaving --insecure as the only way through, which is broken
# AND a footgun. so the trust store rides the arsenal, like any other carried
# capability, and xexec points SSL_CERT_FILE at it. the Go tools carry their
# own roots and don't need this.
#
# the bundle is the Mozilla root set as redistributed by curl.se (the same
# source distro ca-certificates packages use), PINNED to one dated release:
# the download is verified against CA_SHA and the build fails loud if upstream
# has rotated it, so a refresh is a deliberate pin bump, never a silent change.
#
# needs: curl + network, to fetch the bundle once. copy $OUT/cacert.pem to the
# stick's ~/tools/ (provision does this); the lock row is refreshed in place.
set -eu

# the pinned release. bump BOTH together, then commit the refreshed lock row.
CA_URL="https://curl.se/ca/cacert.pem"
CA_DATE="2026-09-25"
CA_SHA="a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505"

OUT="${1:-arsenal}"                 # staging dir (copy to p3 ~/tools/)
LOCK="$(dirname "$0")/arsenal.lock"
command -v curl >/dev/null || { echo "build-ca: no curl -- 'paru -S curl' first" >&2; exit 1; }

mkdir -p "$OUT"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
echo "fetching the Mozilla CA bundle ($CA_DATE) ..."
curl -fsS -o "$TMP" "$CA_URL" || { echo "build-ca: download failed from $CA_URL" >&2; exit 1; }

got=$(sha256sum < "$TMP" | cut -d' ' -f1)
if [ "$got" != "$CA_SHA" ]; then
  echo "build-ca: the bundle at $CA_URL has changed." >&2
  echo "  pinned CA_SHA: $CA_SHA" >&2
  echo "  downloaded:    $got" >&2
  echo "  upstream rotates this file as roots change -- review the new bundle, then" >&2
  echo "  bump CA_DATE + CA_SHA in build-ca.sh and re-run to refresh the lock." >&2
  exit 1
fi

cp "$TMP" "$OUT/cacert.pem"
bytes=$(wc -c < "$OUT/cacert.pem" | tr -d ' ')
row=$(printf '%-11s %s  %s  %s' cacert.pem "curl.se/cacert.pem@$CA_DATE(mozilla-roots)" "$bytes" "$CA_SHA")
if [ -f "$LOCK" ] && grep -qE '^cacert\.pem[[:space:]]' "$LOCK"; then
  awk -v r="$row" '/^cacert\.pem[[:space:]]/{print r; next}{print}' "$LOCK" > "$LOCK.new" && mv "$LOCK.new" "$LOCK"
elif [ -f "$LOCK" ]; then
  printf '%s\n' "$row" >> "$LOCK"
fi
echo "built: $OUT/cacert.pem ($bytes bytes, $(grep -c '^-----BEGIN CERTIFICATE-----' "$OUT/cacert.pem") roots)"

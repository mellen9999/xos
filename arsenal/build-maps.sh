#!/bin/sh
# build-maps.sh -- stage the offline vector atlas onto the XOS-KNOW stick.
# xos is text-first with a serial vt320: zero pixels, pre-unicode on the
# lowest tier. a raster map tile is dead weight there. a VECTOR map is not --
# `atlas` rasterizes these lines onto a character grid itself, at whatever
# tier the terminal actually has (braille down to plain '#', see arsenal/atlas)
# so the same payload serves a 256-colour ssh session and a real serial line.
#
# WHY NATURAL EARTH: public domain (no licence column needed, unlike books.lock),
# small (coastline + borders + rivers + lakes + named places, not full detail
# topography), and it ships two zoom resolutions so a world view and a
# country-level view both look right instead of one looking empty or the
# other looking like a smear.
#
# WHERE: maps/ on the XOS-KNOW stick, same reasoning as books/ and games/if --
# knowledge payload, never needs exec, mounted read-only, does not touch the
# loot space on p3.
#
# TRUST: Natural Earth publishes no signature, so each layer is pinned by
# sha256 here and verified before it is staged -- the same trust-on-first-use
# tier as books.lock and games.lock. A mismatch fails that layer loud and
# stages nothing for it; the others still land.
#
# needs: curl or wget, sha256sum, gzip.
# output: ./maps/ + maps.lock committed next to this script.
set -eu
OUT="${1:-maps}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

# pinned at nvkelso/natural-earth-vector tag v5.1.2 -- public domain (Natural
# Earth places no restriction on use; CC0-equivalent by the project's own terms).
# name<TAB>on-stick file<TAB>url<TAB>sha256<TAB>licence<TAB>one-line what
MAPS="
110m-coastline	ne_110m_coastline.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_110m_coastline.geojson	851f581ff5ffb844deed8ae1a9ce22e3c4bb3d74fa342cadb5d8e39b41ae7c3c	public-domain	world coastline, zoomed-out floor
110m-countries	ne_110m_admin_0_countries.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_110m_admin_0_countries.geojson	6866c877d39cba9c357620878839b336d569f8c662d3cfab4cb1dbe2d39c977f	public-domain	country borders, zoomed-out floor
110m-rivers	ne_110m_rivers_lake_centerlines.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_110m_rivers_lake_centerlines.geojson	55aa4497405afc07cdc931b7fbe062c4d6693ba2a550c0d24899953f5d507c8d	public-domain	rivers + lake centerlines, zoomed-out floor
110m-lakes	ne_110m_lakes.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_110m_lakes.geojson	eb02ecc86c82004fccbf979058bfabbbd6c2d07968c7844d38eb1c9152d2ffc9	public-domain	lake outlines, zoomed-out floor
110m-places	ne_110m_populated_places.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_110m_populated_places.geojson	a86028b083182b68c7620fc6e1a8a47ee547cb9cd2fb62ccbb78bea786440899	public-domain	named places for search, zoomed-out set
50m-coastline	ne_50m_coastline.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_coastline.geojson	271f1c4c1908312bac6b29d158ea1356544beafc129f260005300913aa5ea283	public-domain	world coastline, zoomed-in detail
50m-countries	ne_50m_admin_0_countries.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_admin_0_countries.geojson	3e458fc036ad0a66411f2c1e6cac49c5d7bfb81cb1123bc513b22511a2b7fdeb	public-domain	country borders, zoomed-in detail
50m-rivers	ne_50m_rivers_lake_centerlines.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_rivers_lake_centerlines.geojson	f286e0ce978fde999ca2d7a78c764be08542e19b63cded52b05c12d5173ccc51	public-domain	rivers + lake centerlines, zoomed-in detail
50m-lakes	ne_50m_lakes.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_lakes.geojson	d350b75978b26fe839b797c2c529b2fb8f47fb3983c03f4964e36d5df9378a52	public-domain	lake outlines, zoomed-in detail
50m-places	ne_50m_populated_places.geojson	https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_populated_places.geojson	da4662b7bbfeb897d02f228c5839131dce27acff5717630f91ccff4f67828ee7	public-domain	named places for search, zoomed-in set
"

fetch() { # url dest -- curl if present, else wget; non-zero on either
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 120 -o "$2" "$1"
  else wget -q -O "$2" "$1"; fi
}

# a served error page is the failure this catches: 200 with the wrong bytes.
# the sha pin would catch it too, but naming WHAT arrived turns "sha mismatch"
# into "that url is now a login wall".
shaped() { [ "$(dd if="$1" bs=1 count=1 2>/dev/null)" = '{' ]; }  # geojson opens on '{'

printf '%s\n' "$MAPS" | while IFS='	' read -r name file url sha lic what; do
  [ -n "$name" ] || continue
  raw="$OUT/$file"; gz="$raw.gz"
  if [ -f "$gz" ] && gzip -dc "$gz" 2>/dev/null | sha256sum | cut -d' ' -f1 | grep -qx "$sha"; then
    echo "  $name: already staged and verified"
    continue
  fi
  if ! fetch "$url" "$raw.tmp"; then
    echo "  $name: FETCH FAILED ($url)" >&2; rm -f "$raw.tmp"; echo x >>"$OUT/.fail"; continue
  fi
  got=$(sha256sum "$raw.tmp" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    echo "  $name: SHA MISMATCH -- got $got, want $sha" >&2
    shaped "$raw.tmp" || echo "  $name: and the bytes are not geojson either -- check the url by hand" >&2
    rm -f "$raw.tmp"; echo x >>"$OUT/.fail"; continue
  fi
  # gzip after the pin is verified: the sha is over the bytes Natural Earth
  # actually published, never over a derivative this script produced.
  gzip -9 -c "$raw.tmp" > "$gz.tmp" && mv -f "$gz.tmp" "$gz" && rm -f "$raw.tmp"
  echo "  $name -> maps/$file.gz  ($(du -h "$gz" | cut -f1), $lic)"
done
[ -f "$OUT/.fail" ] && { FAILED=1; rm -f "$OUT/.fail"; }

# the lock, one line per layer actually staged -- books.lock's shape: it too
# carries a licence column, even though every row here is the same value,
# because the field is what a future non-public-domain layer would need and
# a column added under pressure later is a column nobody checks retroactively.
LOCK="$HERE/maps.lock"
{
  printf '# maps.lock -- vector atlas staged %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
  printf '# natural earth v5.1.2, public domain -- give it away, sell it, whatever\n'
  printf '# name  licence  sha256  size  source\n'
  printf '%s\n' "$MAPS" | while IFS='	' read -r name file url sha lic what; do
    [ -n "$name" ] || continue
    f="$OUT/$file.gz"; [ -f "$f" ] || continue
    printf '%s  %s  %s  %s  %s\n' "$name" "$lic" "$sha" "$(du -h "$f" | cut -f1)" \
      "$(printf '%s' "$url" | sed -e 's#^https://##')"
  done
} > "$LOCK"

echo
echo "== vector atlas staged into $OUT/ =="
ls -1 "$OUT" 2>/dev/null | sed 's/^/  /'
echo "  total: $(du -sh "$OUT" | cut -f1)"
echo "lock:  $LOCK"
echo "read:  atlas   (arsenal/atlas -- tier-aware, works down to a plain vt320)"
[ "$FAILED" -eq 0 ] || { echo "one or more layers failed -- see above" >&2; exit 1; }

# provision-lib.sh -- populate H with the arsenal layout. sourced by
# provision.sh, where H is the mounted p3. nothing in selftest.sh reaches
# arsenal/ at all: the whole tree is provisioning, not the signed image.
populate() {
  H="$1"
  mkdir -p "$H/tools" "$H/wordlists" "$H/docs" "$H/loot"
  install -m 0755 "${SELF:-$(dirname "$0")}/xexec" "$H/tools/xexec"
  # the discoverability surface: a generic lister + its descriptions. both ride
  # p3 (capability), so the signed image never changes when the arsenal does.
  install -m 0755 "${SELF:-$(dirname "$0")}/arsenal" "$H/tools/arsenal"
  install -m 0644 "${SELF:-$(dirname "$0")}/arsenal-catalog" "$H/tools/arsenal-catalog"
  if [ -d "$ARSENAL" ] && ls "$ARSENAL"/* >/dev/null 2>&1; then
    for f in "$ARSENAL"/*; do
      b=$(basename "$f")
      if [ "$b" = arsenal.lock ]; then
        install -m 0644 "$f" "$H/tools/arsenal.lock"     # the attestation travels
        continue
      fi
      if [ -d "$f" ]; then
        rm -rf "$H/tools/$b"; cp -a "$f" "$H/tools/$b"   # a tree: python/, sqlmap/
      else
        install -m 0755 "$f" "$H/tools/$b"               # a flat static binary
      fi
    done
  else
    echo "  note: no arsenal at $ARSENAL -- run arsenal/build-arsenal.sh first"
  fi
  # the lock files travel like arsenal.lock does: they live beside the build
  # scripts (arsenal/), not inside the staging dir the caller points to.
  if [ -n "${XOS_WORDLISTS:-}" ] && [ -d "$XOS_WORDLISTS" ]; then
    cp -rf "$XOS_WORDLISTS/." "$H/wordlists/"
    wl="${SELF:-$(dirname "$0")}/wordlists.lock"
    [ -f "$wl" ] && install -m 0644 "$wl" "$H/wordlists/wordlists.lock"
  fi
  if [ -n "${XOS_DOCS:-}" ] && [ -d "$XOS_DOCS" ]; then
    cp -rf "$XOS_DOCS/." "$H/docs/"
    dl="${SELF:-$(dirname "$0")}/docs.lock"
    [ -f "$dl" ] && install -m 0644 "$dl" "$H/docs/docs.lock"
  fi
  chmod 700 "$H"; sync
  echo "  tools:     $(ls "$H/tools" 2>/dev/null | tr '\n' ' ')"
  echo "  list them: sh $H/tools/arsenal"
  echo "  wordlists: $(du -sh "$H/wordlists" 2>/dev/null | cut -f1)"
  echo "  docs:      $(du -sh "$H/docs" 2>/dev/null | cut -f1)"
}

# provision-lib.sh -- populate H with the field-kit layout. sourced by
# provision.sh, where H is the mounted p3. nothing in selftest.sh reaches
# field/ at all: the whole tree is provisioning, not the signed image.
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
    echo "  note: no arsenal at $ARSENAL -- run field/build-arsenal.sh first"
  fi
  [ -n "${XOS_WORDLISTS:-}" ] && [ -d "$XOS_WORDLISTS" ] && cp -rf "$XOS_WORDLISTS/." "$H/wordlists/"
  [ -n "${XOS_DOCS:-}" ] && [ -d "$XOS_DOCS" ] && cp -rf "$XOS_DOCS/." "$H/docs/"
  chmod 700 "$H"; sync
  echo "  tools:     $(ls "$H/tools" 2>/dev/null | tr '\n' ' ')"
  echo "  list them: sh $H/tools/arsenal"
  echo "  wordlists: $(du -sh "$H/wordlists" 2>/dev/null | cut -f1)"
  echo "  docs:      $(du -sh "$H/docs" 2>/dev/null | cut -f1)"
}

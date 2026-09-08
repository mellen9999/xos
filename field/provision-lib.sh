# provision-lib.sh -- populate H with the field-kit layout. sourced by
# provision.sh (H = the mounted p3) and by the test harness (H = a temp dir).
populate() {
  H="$1"
  mkdir -p "$H/tools" "$H/wordlists" "$H/docs" "$H/loot"
  install -m 0755 "${SELF:-$(dirname "$0")}/xexec" "$H/tools/xexec"
  if [ -d "$ARSENAL" ] && ls "$ARSENAL"/* >/dev/null 2>&1; then
    for f in "$ARSENAL"/*; do
      b=$(basename "$f"); [ "$b" = arsenal.lock ] && continue
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
  echo "  wordlists: $(du -sh "$H/wordlists" 2>/dev/null | cut -f1)"
  echo "  docs:      $(du -sh "$H/docs" 2>/dev/null | cut -f1)"
}

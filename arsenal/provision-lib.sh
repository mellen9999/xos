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
  install -m 0644 "${SELF:-$(dirname "$0")}/arsenal-playbook" "$H/tools/arsenal-playbook"  # the how-to
  # the character renderers: first-party python, ship like arsenal/xexec/learn
  # do -- source, not a build-arsenal.sh artifact -- so they are installed
  # here, not pulled from $ARSENAL below. canvas.py is the shared engine
  # atlas and view both import; it has to land beside them or neither runs.
  install -m 0755 "${SELF:-$(dirname "$0")}/atlas" "$H/tools/atlas"
  install -m 0755 "${SELF:-$(dirname "$0")}/view" "$H/tools/view"
  install -m 0644 "${SELF:-$(dirname "$0")}/canvas.py" "$H/tools/canvas.py"
  install -m 0755 "${SELF:-$(dirname "$0")}/chart" "$H/tools/chart"
  # qr: plain ash, ships the same way -- qrencode itself is a build-arsenal-c.sh
  # artifact and lands beside it through the $ARSENAL loop below, same as any
  # other flat static binary.
  install -m 0755 "${SELF:-$(dirname "$0")}/qr" "$H/tools/qr"
  # the graded school (arsenal learn): the engine + its libs, pools, phrases and
  # levels. reads them relative to its own dir, so all under $H/tools.
  S="${SELF:-$(dirname "$0")}"
  install -m 0755 "$S/learn" "$H/tools/learn"                                                # the graded, from-zero school
  install -m 0644 "$S/phrases" "$H/tools/phrases"
  mkdir -p "$H/tools/lib" "$H/tools/pools" "$H/tools/levels"
  for f in "$S"/lib/*;    do install -m 0644 "$f" "$H/tools/lib/$(basename "$f")"; done
  for f in "$S"/pools/*;  do install -m 0644 "$f" "$H/tools/pools/$(basename "$f")"; done
  for f in "$S"/levels/*; do install -m 0644 "$f" "$H/tools/levels/$(basename "$f")"; done
  if [ -d "$ARSENAL" ] && ls "$ARSENAL"/* >/dev/null 2>&1; then
    for f in "$ARSENAL"/*; do
      b=$(basename "$f")
      if [ "$b" = arsenal.lock ]; then
        install -m 0644 "$f" "$H/tools/arsenal.lock"     # the attestation travels
        continue
      fi
      if [ "$b" = file.mgc ]; then
        install -m 0644 "$f" "$H/.magic.mgc"             # libmagic auto-discovers $HOME/.magic.mgc
        continue
      fi
      if [ "$b" = links ]; then
        # the association that opens a picture in the served zim/html as
        # characters instead of a dead link -- checked against links 2.30's
        # own config parser (default.c type_rd/parse_config_file), see
        # arsenal/links.cfg. the directory really is .links, not .links2 --
        # confirmed against get_home() in the same source, and against a
        # real build: it loaded this file and wrote the association back out
        # byte-identical. falls through below to install the binary itself,
        # same as any other flat static tool.
        mkdir -p "$H/.links"
        install -m 0644 "${SELF:-$(dirname "$0")}/links.cfg" "$H/.links/links.cfg"
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

# provision-lib.sh -- populate H with the arsenal layout. sourced by
# provision.sh, where H is the mounted p3. nothing in selftest.sh reaches
# arsenal/ at all: the whole tree is provisioning, not the signed image.

# which build script produces a given lock row -- named in the refusal so the
# fix is the command to run, not a hunt.
_lk_script() {
  case "$1" in
    ffuf|httpx|nuclei|subfinder|dnsx|gobuster|chisel|pspy|ligolo-proxy|ligolo-agent|age)
      echo build-arsenal.sh ;;
    python|sqlmap|impacket) echo build-python.sh ;;
    kiwix-serve|kiwix-search) echo build-kiwix.sh ;;
    terminfo) echo build-terminfo.sh ;;
    *) echo build-arsenal-c.sh ;;   # the musl-static C set, cc and john
  esac
}

# lock_check DIR -- refuse to ship a staging that does not match its own
# arsenal.lock. a build runs in a cw worktree and rewrites the lock there, but
# the binaries it makes die with the worktree; the main checkout then keeps old
# binaries beside a newer lock. provisioning that silently copies the mismatch
# puts tools on the stick that no attestation describes. so prove every row
# before the first byte is written: flat binaries by sha256, the terminfo tree
# by its combined hash, and the trees whose lock hash is a source digest (cc,
# john, python, sqlmap, impacket) by presence -- their output sha is not
# reproducible from the staged files, only their inputs were pinned.
lock_check() {
  _lk_dir="$1"; _lk_lock="$_lk_dir/arsenal.lock"
  [ -f "$_lk_lock" ] || { echo "  FAIL: no arsenal.lock in $_lk_dir -- cannot verify the staging" >&2; return 1; }
  _lk_miss=""; _lk_drift=""; _lk_scripts=""
  while read -r _n _src _bytes _sha; do
    case "$_n" in ''|'#'*) continue ;; esac
    case "$_n" in
      cc)       [ -d "$_lk_dir/cc" ]         || _lk_miss="$_lk_miss $_n"; continue ;;
      john)     [ -f "$_lk_dir/john/john" ]  || _lk_miss="$_lk_miss $_n"; continue ;;
      python|impacket) [ -d "$_lk_dir/python" ] || _lk_miss="$_lk_miss $_n"; continue ;;
      sqlmap)   [ -d "$_lk_dir/sqlmap" ]     || _lk_miss="$_lk_miss $_n"; continue ;;
      terminfo)
        if [ ! -d "$_lk_dir/terminfo" ]; then _lk_miss="$_lk_miss $_n"
        else
          _h=$(cd "$_lk_dir" && find terminfo -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
          [ "$_h" = "$_sha" ] || _lk_drift="$_lk_drift $_n"
        fi
        continue ;;
    esac
    # a flat binary (file.mgc included): must exist and hash to its row.
    if [ ! -f "$_lk_dir/$_n" ]; then _lk_miss="$_lk_miss $_n"
    else
      _h=$(sha256sum < "$_lk_dir/$_n" | cut -d' ' -f1)
      [ "$_h" = "$_sha" ] || _lk_drift="$_lk_drift $_n"
    fi
  done < "$_lk_lock"
  [ -z "$_lk_miss$_lk_drift" ] && return 0
  echo "  FAIL: the arsenal staging in $_lk_dir does not match its arsenal.lock." >&2
  [ -n "$_lk_miss" ]  && echo "    attested but not staged:$_lk_miss" >&2
  [ -n "$_lk_drift" ] && echo "    staged but the bytes differ from the lock:$_lk_drift" >&2
  for _n in $_lk_miss $_lk_drift; do _lk_scripts="$_lk_scripts $(_lk_script "$_n")"; done
  # deliberate split: one script name per line so sort -u can dedupe them.
  # shellcheck disable=SC2086
  _lk_scripts=$(printf '%s\n' $_lk_scripts | sort -u | tr '\n' ' ')
  echo "    rebuild then copy the output into $_lk_dir -- run in arsenal/:$_lk_scripts" >&2
  echo "    (a build in a worktree must be copied back to the main checkout, or the two drift)" >&2
  return 1
}

populate() {
  H="$1"
  # verify the tool staging against its own lock BEFORE writing anything, so a
  # mismatch refuses with an empty p3 rather than a half-populated one.
  if [ -d "$ARSENAL" ] && ls "$ARSENAL"/* >/dev/null 2>&1; then
    lock_check "$ARSENAL" || return 1
  fi
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
  # the graded school (arsenal learn): the engine + its libs, pools, phrases,
  # levels, the reference pages its Tab panel opens, the rekeys ledger its SRS
  # rehome reads, and the fort's shell-grammar table the panel glosses (one
  # source, learn/syntax). reads them relative to its own dir, so all under
  # $H/tools. the same set install.sh ships off-stick; build.sh ci holds the
  # two to it.
  S="${SELF:-$(dirname "$0")}"
  install -m 0755 "$S/learn" "$H/tools/learn"                                                # the graded, from-zero school
  install -m 0644 "$S/phrases" "$H/tools/phrases"
  install -m 0644 "$S/rekeys" "$H/tools/rekeys"
  install -m 0644 "$S/../learn/syntax" "$H/tools/syntax"
  mkdir -p "$H/tools/lib" "$H/tools/pools" "$H/tools/levels" "$H/tools/ref"
  for f in "$S"/lib/*;    do install -m 0644 "$f" "$H/tools/lib/$(basename "$f")"; done
  for f in "$S"/pools/*;  do install -m 0644 "$f" "$H/tools/pools/$(basename "$f")"; done
  for f in "$S"/levels/*; do install -m 0644 "$f" "$H/tools/levels/$(basename "$f")"; done
  for f in "$S"/ref/*;    do install -m 0644 "$f" "$H/tools/ref/$(basename "$f")"; done
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

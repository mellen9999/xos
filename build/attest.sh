#!/bin/bash
# build/attest.sh -- attestation: the chain, its signatures, minting one, re-deriving one
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# verify the chain. reads only attest/, needs no gpg, no docker, no build.
# prints the HEAD hash -- sha256 of the last line's bytes -- which is the one
# short string that commits to the entire history.
verify_log() {
  local f="$ATTEST/log" n=0 seq mh link expect="$ZERO" want line
  [ -f "$f" ] || { echo "FAIL: $f is missing -- there is nothing to verify" >&2; return 1; }
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    read -r seq mh link <<< "$line"
    n=$((n + 1))
    printf -v want '%04d' "$n"
    [ "$seq" = "$want" ] || {
      echo "FAIL: $f line $n: sequence is $seq, expected $want -- a line was inserted or removed" >&2
      return 1; }
    [ "$link" = "$expect" ] || {
      echo "FAIL: $f $seq: link does not match the previous line" >&2
      printf '  recorded %s\n  computed %s\n' "$link" "$expect" >&2
      printf '  the history was rewritten after this entry was written.\n' >&2
      return 1; }
    [ -f "$ATTEST/$seq.manifest" ] || {
      echo "FAIL: $f $seq: attest/$seq.manifest is missing" >&2; return 1; }
    local have; have=$(h256 "$ATTEST/$seq.manifest")
    [ "$have" = "$mh" ] || {
      echo "FAIL: $f $seq: the manifest does not match the digest the log binds" >&2
      printf '  log  %s\n  file %s\n' "$mh" "$have" >&2
      printf '  the manifest was replaced while the log was left alone.\n' >&2
      return 1; }
    # the next link is taken over THESE bytes plus the newline read() stripped.
    expect=$(printf '%s\n' "$line" | sha256sum | awk '{print $1}')
  done < "$f"
  [ "$n" -gt 0 ] || { echo "FAIL: $f holds no entries -- an empty log is not a verified one" >&2; return 1; }
  # $expect is now the hash of the last line: the head.
  printf '  chain intact: %d entr%s, head %s\n' "$n" "$([ "$n" -eq 1 ] && echo y || echo ies)" "$expect"
  # the one defence in this design against a split view: a history that is
  # internally consistent but shown only to you. if you were told the head out
  # of band -- a release announcement, a mirror, an older clone -- pin it here.
  if [ -n "${XOS_EXPECT_HEAD:-}" ]; then
    [ "${XOS_EXPECT_HEAD}" = "$expect" ] || {
      echo "FAIL: chain head is not the one you were told to expect" >&2
      printf '  expected %s\n  found    %s\n' "$XOS_EXPECT_HEAD" "$expect" >&2
      printf '  this is what a split view looks like: a consistent history that is\n' >&2
      printf '  not the history everyone else is being shown.\n' >&2
      return 1; }
    printf '  head matches XOS_EXPECT_HEAD\n'
  fi
}

# G57's engine. a detector that cannot fail is not a detector, so this builds a
# SYNTHETIC three-entry chain in a throwaway directory, proves verify_log
# accepts it, then applies one rewrite per way a history can be tampered with
# and proves it refuses each. three entries, not however many attest/ happens
# to hold, so the test means the same thing on the first release and the
# hundredth. never touches attest/.
log_selftest() {
  local t rc=0 i seq mh link
  t=$(mktemp -d) || return 1
  _mkchain() {
    local i seq mh link="$ZERO" line
    : > "$t/log"
    for i in 1 2 3; do
      printf -v seq '%04d' "$i"
      printf 'synthetic %s\n' "$seq" > "$t/$seq.manifest"
      mh=$(h256 "$t/$seq.manifest")
      line="$seq  $mh  $link"
      printf '%s\n' "$line" >> "$t/log"
      link=$(printf '%s\n' "$line" | sha256sum | awk '{print $1}')
    done
  }
  _refuses() { # $1 what was done
    ( ATTEST="$t"; verify_log ) >/dev/null 2>&1 \
      && { printf '    a rewritten chain was ACCEPTED: %s\n' "$1" >&2; rc=1; }
  }
  _mkchain
  ( ATTEST="$t"; verify_log ) >/dev/null 2>&1 \
    || { printf '    verify_log rejects a chain it built itself\n' >&2; rc=1; }
  # 1. flip one digit of a link
  _mkchain; sed -i '3s/\(  [0-9a-f]\)\([0-9a-f]\{63\}\)$/x\2/' "$t/log"; _refuses "a link digit was changed"
  # 2. swap two entries
  _mkchain; { sed -n '2p' "$t/log"; sed -n '1p' "$t/log"; sed -n '3p' "$t/log"; } > "$t/log.x"
  mv "$t/log.x" "$t/log"; _refuses "two entries were swapped"
  # 3. delete a middle entry
  _mkchain; sed -i '2d' "$t/log"; _refuses "a middle entry was deleted"
  # 4. replace a manifest and leave the log alone
  _mkchain; printf 'tampered\n' > "$t/0002.manifest"; _refuses "a manifest was replaced under its log line"
  rm -rf "$t"
  return $rc
}

# every manifest carries a signature by a PINNED release key.
#
# gpg is HARD-REQUIRED here, unlike sigver(): there, a missing gpg still leaves
# the sha256 pin binding the tarball, so skipping is honest. here the signature
# IS the anchor -- skipping would turn the headline claim into a no-op that
# prints green.
verify_sigs() {
  local gh m fpr rc=0 n=0 st sr ok
  command -v gpg >/dev/null 2>&1 || {
    echo "FAIL: verify needs gpg -- the signature is the only thing anchoring these" >&2
    echo "  claims to a person. there is no digest pin behind it to fall back on." >&2
    return 1; }
  [ -f "$ATTEST/release-key.asc" ] || { echo "FAIL: $ATTEST/release-key.asc is missing" >&2; return 1; }
  gh=$(mktemp -d) || return 1
  gpg -q --homedir "$gh" --import "$ATTEST/release-key.asc" 2>/dev/null
  # the committed pubkey is a convenience copy, never the anchor: check that it
  # IS one of the pinned keys before trusting a single signature it makes.
  ok=0
  for fpr in $RELEASE_FPRS; do
    gpg --homedir "$gh" --list-keys --with-colons 2>/dev/null \
      | awk -F: '/^fpr/{print $10}' | grep -qx "$fpr" && ok=1
  done
  [ "$ok" -eq 1 ] || {
    rm -rf "$gh"
    echo "FAIL: $ATTEST/release-key.asc is not a key this build.sh pins" >&2
    echo "  a swapped pubkey cannot buy itself trust by being in the repo." >&2
    return 1; }
  for m in "$ATTEST"/[0-9]*.manifest; do
    [ -f "$m" ] || continue
    n=$((n + 1))
    [ -f "$m.asc" ] || { echo "FAIL: $m carries no signature" >&2; rc=1; continue; }
    st=$(gpg --homedir "$gh" --status-fd 1 --verify "$m.asc" "$m" 2>/dev/null || true)
    sr=0; printf '%s\n' "$st" | sigok "$(printf '%s\n' "$RELEASE_FPRS" | head -1)" || sr=$?
    if [ "$sr" -ne 0 ]; then
      # a rotated key: try every pinned fingerprint before calling it bad.
      for fpr in $RELEASE_FPRS; do
        sr=0; printf '%s\n' "$st" | sigok "$fpr" || sr=$?
        [ "$sr" -eq 0 ] && break
      done
    fi
    case "$sr" in
      0) ;;
      3) echo "FAIL: ${m##*/} is signed by a REVOKED release key -- the private half is" >&2
         echo "  presumed stolen. do not act on this attestation." >&2; rc=1 ;;
      2) echo "FAIL: ${m##*/} is signed by an expired release key -- the release key is" >&2
         echo "  pinned without an expiry on purpose; an expiring one means something changed." >&2; rc=1 ;;
      *) echo "FAIL: ${m##*/} is not signed by any pinned release key" >&2; rc=1 ;;
    esac
  done
  rm -rf "$gh"
  [ "$n" -gt 0 ] || { echo "FAIL: there are no manifests to check" >&2; return 1; }
  [ "$rc" -eq 0 ] && printf '  %d manifest(s) signed by a pinned release key\n' "$n"
  return $rc
}

# read one key out of a manifest. first word is the key, '#' lines are inert --
# the same idiom image.sha256 and sources.sha256 already use.
mkey() { awk -v k="$2" '$1==k{print $2}' "$1"; }

# mint the next attestation for committed HEAD and append it to the chain.
attest() {
  say "attesting the bytes this commit builds"
  command -v gpg >/dev/null 2>&1 || { echo "FAIL: attest needs gpg to sign" >&2; return 1; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "FAIL: attest needs a git repo -- it attests a commit" >&2; return 1; }
  [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] || {
    echo "FAIL: tracked files are modified -- an attestation is a claim about COMMITTED" >&2
    echo "  source. commit first, then attest." >&2
    git status --porcelain --untracked-files=no >&2
    return 1; }
  mkdir -p "$ATTEST"
  local commit seq n=0 line prevline=""
  commit=$(git rev-parse HEAD)
  # one attestation per commit: a second one for the same tree is either a
  # mistake or someone re-signing history, and both want a human.
  local m
  for m in "$ATTEST"/[0-9]*.manifest; do
    [ -f "$m" ] || continue
    n=$((n + 1))
    [ "$(mkey "$m" commit)" = "$commit" ] && {
      echo "FAIL: ${m##*/} already attests $commit" >&2; return 1; }
  done
  # the chain must be sound BEFORE anything is appended to it.
  if [ "$n" -gt 0 ]; then verify_log >/dev/null || return 1; fi
  printf -v seq '%04d' "$((n + 1))"

  # four artifact digests come from the committed pin, not from a fresh build:
  # image.sha256 is what crepro re-derives, so copying it here keeps ONE source
  # of truth. a stale pin is caught by verify, which rebuilds and compares.
  local k v
  for k in image squashfs roothash kernel toolchain; do
    v=$(awk -v k="$k" '$1==k{print $2}' image.sha256)
    [ -n "$v" ] || { echo "FAIL: image.sha256 has no '$k' line -- run ./build.sh cpin first" >&2; return 1; }
  done
  local base ala
  base=$(sed -n 's/^FROM[[:space:]]\+[^@]*@\(sha256:[0-9a-f]\{64\}\).*/\1/p' repro/Dockerfile | head -1)
  ala=$(sed -n 's/^ARG ALA=\(.*\)$/\1/p' repro/Dockerfile | head -1)
  [ -n "$base" ] && [ -n "$ala" ] || {
    echo "FAIL: repro/Dockerfile does not pin a base digest and an ALA day" >&2; return 1; }

  local mf="$ATTEST/$seq.manifest"
  { echo "# an xos release attestation. every value below is re-derived by"
    echo "# ./build.sh verify, EXCEPT the lines marked CLAIMED at the bottom."
    echo "# first word is the key; '#' lines are inert."
    printf 'release    %s\n' "$seq"
    printf 'commit     %s\n' "$commit"
    printf 'date       %s\n' "$(date -u +%Y-%m-%d)"
    printf 'signer     %s\n' "$(printf '%s\n' "$RELEASE_FPRS" | head -1)"
    printf 'epoch      %s\n' "$SOURCE_DATE_EPOCH"
    echo "# the toolchain, by content. duplicated from repro/Dockerfile on purpose:"
    echo "# verify cross-checks the two, so the redundancy is checked, not decorative."
    printf 'base       %s\n' "$base"
    printf 'ala        %s\n' "$ala"
    echo "# digests of committed files, not copies of them: one source of truth,"
    echo "# and the digest is what binds it."
    printf 'dockerfile %s\n' "$(h256 repro/Dockerfile)"
    printf 'sources    %s\n' "$(h256 sources.sha256)"
    printf 'blobs      %s\n' "$(h256 blobs.sha256)"
    printf 'kconfig    %s\n' "$(h256 kernel.config)"
    printf 'fsmanifest %s\n' "$(h256 manifest)"
    echo "# the artifacts. verify rebuilds a clean clone in the pinned container"
    echo "# and compares all four."
    for k in image squashfs roothash kernel toolchain; do
      printf '%-10s %s\n' "$k" "$(awk -v kk="$k" '$1==kk{print $2}' image.sha256)"
    done
    echo "# the gate/section COUNTS below are re-derived by verify from the tree at"
    echo "# this commit -- structural, so checked, not claimed. what verify still"
    echo "# cannot do is re-run the qemu suite or the gate sweep to prove they PASS;"
    echo "# that needs the signing key and a boot, and is never asserted here."
    printf 'claimed-gates    %s\n' "$(roster_of . | sort -u | grep -c .)"
    printf 'claimed-sections %s\n' "$(sed -n 's/^EXPECTED_SECTIONS=\([0-9][0-9]*\).*/\1/p' selftest.sh | head -1)"
  } > "$mf"

  gpg --armor --detach-sign --local-user "$(printf '%s\n' "$RELEASE_FPRS" | head -1)" \
      --output "$mf.asc" "$mf" 2>/dev/null \
    || { rm -f "$mf" "$mf.asc"; echo "FAIL: could not sign $seq.manifest with the pinned release key" >&2; return 1; }

  # the log line. the link is taken over the PREVIOUS line's bytes + newline.
  local link="$ZERO"
  if [ "$n" -gt 0 ]; then
    prevline=$(grep -v '^#' "$ATTEST/log" | grep -v '^$' | tail -1)
    link=$(printf '%s\n' "$prevline" | sha256sum | awk '{print $1}')
  else
    { echo "# append-only hash chain. SEQ  MANIFEST-SHA256  LINK, where LINK is the"
      echo "# sha256 of the previous line's bytes including its newline (the first is"
      echo "# 64 zeros). comment lines are not part of the chain. rewriting any entry"
      echo "# breaks every link after it -- see docs/attestation.md for what that does"
      echo "# and, just as importantly, what it does not, defend against."
    } > "$ATTEST/log"
  fi
  printf '%s  %s  %s\n' "$seq" "$(h256 "$mf")" "$link" >> "$ATTEST/log"

  # export the pubkey next to the claims it signs, if it is not already there.
  gpg --armor --export "$(printf '%s\n' "$RELEASE_FPRS" | head -1)" > "$ATTEST/release-key.asc"

  verify_log || return 1
  verify_sigs || return 1
  say "attested $seq -- commit, then publish the head hash with the release"
  cat "$mf"
}

# ./build.sh verify [ref] -- the one command a stranger runs.
#
# needs docker, git and gpg. no signing key, no qemu, no root, no KVM, no Arch,
# no host toolchain: everything that decides the verdict happens either in
# attest/ or inside the pinned container.
verify() {
  local ref="${1:-HEAD}" rc=0
  say "verifying xos -- chain, signatures, then a byte-for-byte rebuild"
  local need
  for need in docker git gpg; do
    command -v "$need" >/dev/null 2>&1 \
      || { echo "FAIL: verify needs $need" >&2; return 1; }
  done

  say "1/4  the attestation chain"
  verify_log || return 1
  say "2/4  the signatures"
  verify_sigs || return 1

  say "3/4  the manifest for $ref"
  local commit m found=""
  commit=$(git rev-parse "$ref" 2>/dev/null) \
    || { echo "FAIL: $ref is not a commit in this repo" >&2; return 1; }
  for m in "$ATTEST"/[0-9]*.manifest; do
    [ -f "$m" ] || continue
    [ "$(mkey "$m" commit)" = "$commit" ] && { found="$m"; break; }
  done
  [ -n "$found" ] || {
    echo "FAIL: no attestation covers $commit" >&2
    printf '  attested commits, newest last:\n' >&2
    for m in "$ATTEST"/[0-9]*.manifest; do
      [ -f "$m" ] || continue
      printf '    %s  %s  %s\n' "$(mkey "$m" release)" "$(mkey "$m" date)" "$(mkey "$m" commit)" >&2
    done
    printf '  verify one of those, or ask the author to attest this one.\n' >&2
    return 1; }
  printf '  %s attests %s\n' "${found##*/}" "$commit"

  # cross-check the manifest against the tree AT THAT COMMIT. these are the
  # values verify can settle without building anything.
  local s2 k want
  s2=$(snap) || { echo "FAIL: could not clone this repo" >&2; return 1; }
  # -B, not a bare checkout: a detached HEAD makes repro()'s inner
  # `git clone --depth 1 file://` produce an EMPTY tree, and the rebuild then
  # fails for a reason that has nothing to do with the bytes.
  git -C "$s2/tree" checkout -q -B verify "$commit" \
    || { rm -rf "$s2"; echo "FAIL: could not check out $commit" >&2; return 1; }

  local bad=0
  chk() { # $1 manifest key  $2 value from the tree
    want=$(mkey "$found" "$1")
    [ -n "$want" ] || { printf '    %-11s not in the manifest\n' "$1" >&2; bad=1; return; }
    [ "$want" = "$2" ] && return
    printf '    %-11s manifest %s\n                tree     %s\n' "$1" "$want" "$2" >&2; bad=1
  }
  chk dockerfile "$(h256 "$s2/tree/repro/Dockerfile")"
  chk sources    "$(h256 "$s2/tree/sources.sha256")"
  chk blobs      "$(h256 "$s2/tree/blobs.sha256")"
  chk kconfig    "$(h256 "$s2/tree/kernel.config")"
  chk fsmanifest "$(h256 "$s2/tree/manifest")"
  chk base "$(sed -n 's/^FROM[[:space:]]\+[^@]*@\(sha256:[0-9a-f]\{64\}\).*/\1/p' "$s2/tree/repro/Dockerfile" | head -1)"
  chk ala  "$(sed -n 's/^ARG ALA=\(.*\)$/\1/p' "$s2/tree/repro/Dockerfile" | head -1)"
  chk epoch "$(sed -n 's/^export SOURCE_DATE_EPOCH=\([0-9]*\).*/\1/p' "$s2/tree/build.sh" | head -1)"
  # the gate and section COUNTS are structural -- derivable from the tree at
  # this commit without running a single gate or booting qemu. so verify settles
  # them here, the same way it settles a digest; only whether they PASS stays out
  # of reach (that needs the key'd build and the qemu suite).
  chk claimed-gates    "$(roster_of "$s2/tree" | sort -u | grep -c .)"
  chk claimed-sections "$(sed -n 's/^EXPECTED_SECTIONS=\([0-9][0-9]*\).*/\1/p' "$s2/tree/selftest.sh" | head -1)"
  for k in image squashfs roothash kernel toolchain; do
    chk "$k" "$(awk -v kk="$k" '$1==kk{print $2}' "$s2/tree/image.sha256")"
  done
  if [ "$bad" -ne 0 ]; then
    rm -rf "$s2"
    echo "FAIL: the signed manifest does not describe the tree at $commit" >&2
    return 1
  fi
  printf '  manifest matches the tree at that commit\n'

  say "4/4  rebuilding it, byte for byte, in the pinned container"
  printf '  this takes 20-40 minutes and downloads about a gigabyte the first\n'
  printf '  time. nothing is wrong if it is quiet -- it is compiling a kernel.\n'
  in_toolchain "$s2/tree" ./build.sh repro || rc=1
  desnap "$s2"
  if [ "$rc" -ne 0 ]; then
    printf '\n\033[1;31m  NOT VERIFIED\033[0m -- %s did not rebuild to the bytes it is signed for\n' "$commit" >&2
    return 1
  fi
  printf '\n\033[1;32m  VERIFIED\033[0m -- %s\n' "$commit"
  printf '  signed by %s\n' "$(mkey "$found" signer)"
  printf '  and it rebuilds, byte for byte, from source you can read.\n\n'
  printf '  what this does NOT say: see docs/attestation.md. a signature is not a\n'
  printf '  proof the author is honest, and a reproducible build is not a proof the\n'
  printf '  source is safe. it says these bytes came from this source, and who said so.\n'
}

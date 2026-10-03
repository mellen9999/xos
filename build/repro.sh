#!/bin/bash
# build/repro.sh -- reproducibility: vouch, repro, the pinned container (cpin, crepro)
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# build_all -- the whole pipeline, front to back. a real function (not just a
# case arm) so other commands (stick_install on a clean tree) can call it too.
# repro -- the claim, actually tested. G13 compares THIS tree's artifacts to
# the committed pin, which proves the pin was taken from this tree and nothing
# more. this clones committed HEAD into a scratch dir, builds it from scratch
# with its own hands (pinned sources re-verified on extraction, same pinned
# clock), and compares the result against the SAME committed pin. no signing:
# the pin covers xos.img and rootfs.squashfs, both born before any key is
# touched, so a clean clone needs no passphrase and mints no keys. tarballs
# are already in the shared XOS_CACHE, so the clone builds off the network;
# get() re-checks their digests, so a poisoned copy still fails loudly. only meaningful on the
# toolchain the pin was taken with -- same rule G13 already enforces.
# the reproducible path: every stage that mints xos.img + rootfs.squashfs, and
# nothing past verity (no keys, no signed uki, no stick -- so no passphrase).
# ONE list, shared by repro() (clone + compare) and cpin/crepro (in-container),
# so the sequence can never drift between "what we pin" and "what we verify".
build_repro() {
  deps repro; fetch; kernel; headers; busybox; tls; ii_; abduco
  cryptsetup_; wg_; dropbear_; rootfs; verity
}

# ────────────────────────────────────────────────────────────────────────────
# reproducibility -- a clean clone, built and compared to the pin
# ────────────────────────────────────────────────────────────────────────────
# ────────────────────────────────────────────────────────────────────────────
# provenance -- WHOSE source this is, which reproducibility never answers
# ────────────────────────────────────────────────────────────────────────────
# crepro proves source -> bytes. it has no opinion about who wrote the source,
# so whoever takes the publishing account can push a tree that reproduces
# perfectly and every other check stays green. vouch is the other half: every
# commit since SIGN_EPOCH carries an ssh signature from the key pinned by
# SIGN_FPR here and by public key in `signers`.
#
# 0 ok, 1 FAIL, 2 unverified -- repro()'s convention. 2 is never a green pass:
# a check that cannot run here must not read as one that ran and passed.
vouch() {
  say "provenance -- every commit since the epoch signed by the pinned key"
  local fps nfp bad tip

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf '  \033[1;33munverified\033[0m -- not a git work tree. an unpacked tarball\n' >&2
    printf '  carries no signatures; clone the repo if you want to check them.\n' >&2
    return 2; }

  # the repro container ships git but not openssh, so this is the normal state
  # inside it -- say so instead of failing, and check on the host.
  command -v ssh-keygen >/dev/null 2>&1 || {
    printf '  \033[1;33munverified\033[0m -- no ssh-keygen here, so no signature was\n' >&2
    printf '  checked. run ./build.sh vouch on the host.\n' >&2
    return 2; }

  [ -s signers ] || {
    printf '  \033[1;31mFAIL\033[0m: signers is missing or empty -- the key pin is gone.\n' >&2
    return 1; }

  # the double pin, the same shape as sigs/ + *_FPR: the key blob lives in
  # `signers`, its fingerprint is a constant in this file. a swapped pubkey
  # cannot satisfy both. a quietly ADDED second signer is how this gets
  # ruined, so an unpinned extra key is a failure, not a warning.
  fps=$(grep -v '^[[:space:]]*#' signers | awk 'NF{print $3" "$4}' | while read -r blob
        do printf '%s\n' "$blob" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'; done)
  nfp=$(printf '%s\n' "$fps" | grep -c . || true)
  if [ "${nfp:-0}" -ne 1 ]; then
    printf '  \033[1;31mFAIL\033[0m: signers must pin exactly one key, it names %s.\n' "${nfp:-0}" >&2
    return 1
  fi
  if [ "$fps" != "$SIGN_FPR" ]; then
    printf '  \033[1;31mFAIL\033[0m: the key in signers is not the pinned one.\n' >&2
    printf '    pinned (build.sh): %s\n' "$SIGN_FPR" >&2
    printf '    signers:           %s\n' "$fps" >&2
    return 1
  fi

  # HEAD first: it is the one commit a shallow clone can always check.
  if ! git -c gpg.ssh.allowedSignersFile=signers verify-commit HEAD >/dev/null 2>&1; then
    printf '  \033[1;31mFAIL\033[0m: HEAD is not signed by the pinned key.\n' >&2
    return 1
  fi

  # the epoch bounds the claim. every commit before it is unsigned and always
  # will be -- a signature cannot be added to an object without changing its
  # hash, and rewriting that history would invalidate every digest anyone
  # already holds. see SOURCES.md, "this tree's own commits".
  if ! git cat-file -e "$SIGN_EPOCH^{commit}" 2>/dev/null; then
    printf '  \033[1;33munverified\033[0m -- HEAD is signed by the pinned key, but this\n' >&2
    printf '  clone is too shallow to hold the epoch, so the chain back to it was\n' >&2
    printf '  not walked. clone without --depth to check it.\n' >&2
    return 2
  fi
  if ! git merge-base --is-ancestor "$SIGN_EPOCH" HEAD 2>/dev/null; then
    printf '  \033[1;31mFAIL\033[0m: the epoch is not an ancestor of HEAD -- this history\n' >&2
    printf '  was rewritten out from under the pin.\n' >&2
    return 1
  fi

  bad=$(git -c gpg.ssh.allowedSignersFile=signers \
          log --format='%G? %h %s' "$SIGN_EPOCH~1..HEAD" 2>/dev/null | grep -vc '^G ' || true)
  if [ "${bad:-0}" -ne 0 ]; then
    printf '  \033[1;31mFAIL\033[0m: %s commit(s) since the epoch are not signed by the\n' "$bad" >&2
    printf '  pinned key:\n' >&2
    git -c gpg.ssh.allowedSignersFile=signers \
        log --format='%G? %h %s' "$SIGN_EPOCH~1..HEAD" 2>/dev/null | grep -v '^G ' | head -10 >&2
    return 1
  fi

  tip=$(git rev-list --count "$SIGN_EPOCH~1..HEAD" 2>/dev/null)
  printf '  \033[1;32mvouched\033[0m -- %s commit(s) since the epoch, every one signed by\n' "$tip"
  printf '  %s\n' "$SIGN_FPR"
  printf '  compare that fingerprint against a copy you did NOT get from this clone --\n'
  printf '  it is a pin, not an identity (SOURCES.md, "this tree'"'"'s own commits").\n'

  # HEAD's signature covers HEAD, not the tree you are about to build.
  if ! git diff --quiet HEAD -- 2>/dev/null; then
    printf '  \033[1;33mnote\033[0m -- tracked files are modified, so what builds here is not\n' >&2
    printf '  what was signed.\n' >&2
    return 2
  fi
  return 0
}

repro() {
  say "independent rebuild -- clone committed HEAD, build, compare to the pin"
  local d want_tc have_tc
  # fail fast, and honestly: reproducibility is verifiable only on the toolchain
  # the pin was taken with. on any other gcc/squashfs-tools/systemd the bytes
  # differ for innocent reasons, so a rebuild here would build for an hour and
  # then cry "NOT REPRODUCIBLE" about nothing -- the exact wolf G13 stopped
  # crying. so check the toolchain FIRST and skip the build if it differs.
  want_tc=$(awk '$1=="toolchain"{print $2}' image.sha256 2>/dev/null)
  have_tc=$(toolchain)
  if [ -n "$want_tc" ] && [ "$want_tc" != "$have_tc" ]; then
    printf '  \033[1;33munverified\033[0m -- this toolchain is not the one the pin was\n' >&2
    printf '  taken with, so a byte difference would prove nothing. run\n' >&2
    printf '  ./build.sh crepro to verify inside the pinned toolchain container\n' >&2
    printf '  (see G13, repro/Dockerfile, SOURCES.md). skipping the build.\n' >&2
    return 2
  fi
  d=$(mktemp -d /tmp/xos-repro.XXXXXX) || return 1
  git clone -q --depth 1 "file://$PWD" "$d/tree" || { rm -rf "$d"; return 1; }
  if ! ( cd "$d/tree" && ./build.sh build_repro ) > "$d/build.log" 2>&1
  then
    echo "FAIL: the clean-clone build itself failed -- tail of the log:" >&2
    tail -5 "$d/build.log" >&2
    rm -rf "$d"; return 1
  fi
  # compare BEFORE deleting: cmp_pin reads the files. the old code hashed
  # into variables first and could afford to rm early -- and on a mismatch it
  # deleted the build log, which is exactly what a stranger needs to report.
  if cmp_pin "$d/tree"; then
    rm -rf "$d"
    printf '  \033[1;32mreproduced\033[0m -- a stranger cloning this repo builds these exact bytes\n'
  else
    printf '  \033[1;31mNOT REPRODUCIBLE\033[0m -- clean clone built different bytes than the pin\n' >&2
    printf '  build log kept: %s/build.log\n' "$d" >&2
    return 1
  fi
}

# clone committed HEAD into a throwaway NORMAL repo and echo its path. a git
# worktree's .git is a FILE pointing at the main repo outside any bind mount, so
# a container cannot read it; a plain clone carries a self-contained .git, and
# clones only what is committed -- the same "committed source only" claim repro
# and pin already rest on. caller removes the dir.
snap() {
  local s; s=$(mktemp -d /tmp/xos-snap.XXXXXX) || return 1
  git clone -q "$PWD" "$s/tree" >/dev/null 2>&1 || { rm -rf "$s"; return 1; }
  printf '%s\n' "$s"
}

# remove a snapshot. the container builds as root, so the tree it leaves is
# root-owned and a plain `rm` by the calling user cannot touch it -- remove it
# from inside the same image (as root), then drop the now-empty dir.
desnap() {
  [ -n "$1" ] && [ -d "$1" ] || return 0
  # same content tag in_toolchain built; the bare $CTAG may not exist at all
  # now that images are tagged by Dockerfile content.
  local tag="$CTAG"
  [ -f "$1/tree/repro/Dockerfile" ] \
    && tag="$CTAG:$(sha256sum < "$1/tree/repro/Dockerfile" | cut -c1-12)"
  docker run --rm -v "$1:/s" "$tag" rm -rf /s/tree 2>/dev/null || true
  rm -rf "$1" 2>/dev/null || true
}

# build the pinned toolchain image, then run "$@" inside it with $1 mounted at
# /src. --network=host on both: the build pulls ALA packages and the run fetches
# pinned sources, and docker's default DNS cannot reach a host systemd-resolved
# stub. the sources stay pinned+signed, so host networking changes nothing the
# digests do not still decide.
in_toolchain() {
  local src="$1"; shift
  command -v docker >/dev/null 2>&1 \
    || { echo "FAIL: this needs docker -- the pinned toolchain runs in a container" >&2; return 1; }
  # build the container from the SNAPSHOT's Dockerfile, not this checkout's.
  # for cpin/crepro the two are the same tree so it never showed, but the
  # moment anything verifies an older commit, the caller's Dockerfile would
  # silently decide the toolchain -- an old claim checked against today's
  # compiler, passing. that is a false pass, which is the one failure class
  # this repo cannot tolerate.
  [ -f "$src/repro/Dockerfile" ] || { echo "FAIL: $src/repro/Dockerfile missing" >&2; return 1; }
  # and tag by the Dockerfile's content, so two commits with different
  # toolchains cannot clobber each other's image behind one fixed tag.
  local tag; tag="$CTAG:$(sha256sum < "$src/repro/Dockerfile" | cut -c1-12)"
  say "building the pinned toolchain container ($tag)"
  docker build --network=host -q -t "$tag" -f "$src/repro/Dockerfile" "$src/repro" >/dev/null \
    || { echo "FAIL: could not build the toolchain container" >&2; return 1; }
  docker run --rm --network=host -e XOS_STRICT=1 -v "$src:/src" -w /src "$tag" "$@"
}

# take the canonical pin INSIDE the pinned toolchain, so image.sha256's toolchain
# line is the container's -- the only fingerprint a stranger can match. builds in
# a snapshot, copies just the pin back out. review and commit the image.sha256.
cpin() {
  say "taking the pin inside the pinned toolchain"
  local s; s=$(snap) || { echo "FAIL: could not snapshot committed HEAD" >&2; return 1; }
  if in_toolchain "$s/tree" sh -euc './build.sh build_repro && ./build.sh pin'; then
    cp -f "$s/tree/image.sha256" image.sha256
    desnap "$s"
    say "pin taken in-container -- review and commit image.sha256"
    cat image.sha256
  else
    desnap "$s"; echo "FAIL: in-container pin failed" >&2; return 1
  fi
}

# verify: a clean clone, built inside the pinned toolchain, reproduces the
# committed pin. the check a stranger runs -- no key, no host toolchain, only
# docker. repro() runs unchanged inside; have_tc now equals the container's
# want_tc, so the comparison actually fires instead of skipping.
crepro() {
  say "reproducing inside the pinned toolchain -- clean clone, build, compare"
  # who wrote it, before what it builds: the host has ssh-keygen and the full
  # history, the container has neither. a tree that fails rung one is not worth
  # an hour of rebuild.
  vouch || [ "$?" -eq 2 ] || return 1
  local s rc=0; s=$(snap) || { echo "FAIL: could not snapshot committed HEAD" >&2; return 1; }
  in_toolchain "$s/tree" ./build.sh repro || rc=$?
  desnap "$s"; return $rc
}

#!/bin/bash
# build/gates.sh -- the gates -- every claim this repo makes, checked before it ships (G1..G67; the roster is the comment above gates())
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# gate roster -- every G-number that exists, in one place, so a silently
# dropped gate is visible instead of hiding in a diff. most run in gates()
# below; G8 runs in fetch(), G9 lives in githooks/pre-commit (not this
# script). a trailing * marks a gate rostered here but not expected to run
# in gates().
#
# this block is DATA: gates() reads it back (roster_of), so the expected
# count is derived from it and can never drift from it again. the hand-kept
# 48 went stale the day G51 landed, and every gates run since died crying
# "truncated" about a run that was complete -- while that early return sat
# in front of the bad check and masked GATES FAILED behind it.
#   G1  image <= IMAGE_MAX
#   G2  no dynamic loader (no INTERP segment on any ELF)
#   G3  every ELF is PIE
#   G4  no setuid/setgid files
#   G5  no world-writable files
#   G6  cmdline root hash matches the built tree
#   G7  kernel has no module loader
#   G8* every source pinned + verified before extraction; six upstreams
#       also matched to committed maintainer signatures    (fetch())
#   G9* no build artifacts/keys committed                  (githooks/pre-commit)
#   G10 build clock pinned (busybox banner matches SOURCE_DATE_EPOCH)
#   G11 no plaintext private key on disk
#   G12 image has every manifest entry
#   G13 image matches the committed digest (reproducibility)
#   G14 kernel honours the hardening config
#   G15 cmdline carries every hardening param
#   G16 no executable stack
#   G17 stick.img coherent with the pinned artifacts
#   G18 no firmware blobs in image
#   G19 UKI + image <= IMAGE_MAX (the binding size gate)
#   G20 shipped image is not revoked
#   G21 revocation digest matches the signature
#   G22 stack protector present in every shipped ELF
#   G23 exactly one shell (busybox ash)
#   G24 learn corpus covers the shipped surface exactly
#   G25 learn selftest passes under the built busybox
#   G26 curriculum covers the surface -- commands and flags (nothing untaught)
#   G27 levels only use commands already taught, in order
#   G28 bzImage was built from the on-disk kernel.config
#   G29 challenge track holds its shape
#   G30 clock floor is fresh, not stale
#   G31 no test flags on the production cmdline
#   G32 fingerprint wordlist holds its shape (256 unique words)
#   G33 init remote-access arg-building, run through the real ash
#   G34 signed UKI's embedded roothash matches the tree
#   G35 first-party scripts parse under the shipped ash
#   G36 learn reaches its prompt on a silent terminal, under that ash
#   G37 the between-cards pause takes one keypress and gives the tty back
#   G38 build.sh, build/*.sh and selftest.sh parse under bash
#   G39 both destructive disk paths go through the shared guard
#   G40 the respawn backoff counts and sleeps as written
#   G41 a flashed stick yields a p3 that fills the device
#   G42 a revocation is shipped in a form real firmware can enroll
#   G43 an update preserves p3 -- its entry and its bytes
#   G44 a planted digest cannot buy a pass from the revocation check
#   G45 a source signed by an expired or revoked key is refused
#   G46 every carried patch is in the tree, and its effect is in the binary
#   G47 every arsenal source is pinned before build, no fetch bypasses it
#   G48 the remaining first-party scripts parse (the commit hook, arsenal, ci)
#   G49 the install entry point writes only through the guarded disk paths
#   G50 every level's teaching brief fits one 80x25 screen
#   G51 a failed command at the real prompt reaches learn, and only a name
#   G52 every commit since the epoch is signed by the pinned key
#   G53 the maintainer signatures were actually checked, not skipped
#   G54 selftest.sh counts the sections it actually has
#   G55 the attestation chain is intact
#   G56 every attestation is signed by a pinned release key
#   G57 a rewritten attestation log is refused (the detector can fail)
#   G58 the signed image still checks its host blobs before wrapping them
#   G59 the container toolchain is pinned by bytes, not by an archive day
#   G60 the trust manifest accounts for everything in the tree
#   G61 every carried book is pinned by sha256 and carries a licence
#   G62 every row of learn/bashisms is a construct this shell really lacks
#   G63 the levels ask you to put two commands together, and keep asking
#   G64 clone is guarded and proves the spare is a faithful copy
#   G65 every carried map layer is pinned by sha256 and licensed public-domain
#   G66 bump edits exactly the two pins it should and reverses byte-clean
#   G67 no private key in the shipped image (root/ = the squashfs, 1:1)
# ────────────────────────────────────────────────────────────────────────────
# the gates -- every claim this repo makes, checked before it ships
# ────────────────────────────────────────────────────────────────────────────
gates() {
  say "gates"
  local bad=0 ran=0 skipped=0 saw="" skipped_names=""
  # the roster above is the list, and this reads it back: an unstarred
  # G-number is one this run must emit, so the count follows from the roster
  # instead of being retyped beside it and left to rot.
  local roster EXPECTED_GATES
  roster=$(roster_of . | sort -u)
  EXPECTED_GATES=$(printf '%s\n' "$roster" | grep -c . || true)
  # a gate is ok, FAIL, or SKIP. SKIP is for a check that cannot run here and
  # whose result would be meaningless if forced -- G13 on a foreign toolchain.
  # it is counted (so the truncation guard still holds) and reported, but it
  # is never a green pass: reporting it as ok is how "unverified" became
  # indistinguishable from "verified" for as long as that line existed.
  g() { printf '  %-42s %s\n' "$1" "$2"; ran=$((ran+1)); saw="$saw ${1%% *}"
        LASTGATE=${1%% *}
        case "$2" in ok) ;; SKIP) skipped=$((skipped+1)); skipped_names="$skipped_names ${1%% *}" ;; *) bad=1 ;; esac; }
  # the roster check at the end of this function is supposed to catch a gate
  # that dies mid-run -- but it is INSIDE the function that died, so it never
  # ran, and G62 aborting looked like a build that simply stopped talking. the
  # trap says which gate was the last to report, which is the one after it that
  # died. cleared before the roster check, so an honest `return 1` down there
  # does not trip it.
  trap 'printf "\033[1;31m  the gate run died right after %s -- that gate aborted under set -e\033[0m\n" "${LASTGATE:-none}" >&2' ERR

  local sz; sz=$(stat -c%s xos.img)
  g "G1 image <= $IMAGE_MAX ($sz)" "$([ "$sz" -le "$IMAGE_MAX" ] && echo ok || echo FAIL)"

  # the ELF gates. `for f in $elfs` word-split paths and an empty root/ made
  # every counter 0 -> ok, so: read paths line by line, and count the ELFs so
  # an empty tree is a FAIL instead of a vacuous pass.
  local elfs interp exec_type n_elf=0 rwe_stack=0 ssp_miss=0 f
  elfs=$(find root -type f -exec sh -c 'head -c4 "$1" | grep -q ELF && echo "$1"' _ {} \; 2>/dev/null)
  interp=0; exec_type=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n_elf=$((n_elf+1))
    readelf -l "$f" 2>/dev/null | has INTERP && interp=$((interp+1))
    readelf -h "$f" 2>/dev/null | has 'Type:.*EXEC' && exec_type=$((exec_type+1))
    # GNU_STACK marked RWE = executable stack (the noexecstack link flag failed).
    # this one IS kernel-enforced, unlike RELRO in a static-pie binary. the
    # flags are the second-to-last column -- the last is the alignment, and
    # reading it made this gate unable to fail for as long as it existed.
    readelf -lW "$f" 2>/dev/null | awk '/GNU_STACK/{print $(NF-1)}' | has RWE && rwe_stack=$((rwe_stack+1))
    # G22 -- the stack protector claim. a protected function loads the canary
    # from the TLS slot (%fs:0x28 on x86_64) in its prologue; a binary with no
    # such load anywhere was compiled without -fstack-protector. musl prints
    # no message on a canary failure (it just crashes), so the code is the
    # only evidence there is.
    [ "$(objdump -d "$f" 2>/dev/null | grep -c '%fs:0x28')" -gt 0 ] || ssp_miss=$((ssp_miss+1))
  done <<< "$elfs"
  # the executable-stack detector must be able to say RWE at all: link a
  # deliberately bad object and ask. a detector that cannot fail is not one.
  local g16d; g16d=$(mktemp -d)
  printf 'int main(void){return 0;}\n' > "$g16d/x.c"
  local g16_self=FAIL
  if gcc -o "$g16d/x" "$g16d/x.c" -z execstack 2>/dev/null \
     && readelf -lW "$g16d/x" | awk '/GNU_STACK/{print $(NF-1)}' | has RWE; then g16_self=ok; fi
  rm -rf "$g16d"
  g "G2 no dynamic loader ($interp with INTERP, $n_elf ELF)" "$([ "$interp" -eq 0 ] && [ "$n_elf" -gt 0 ] && echo ok || echo FAIL)"
  g "G3 all ELF are PIE ($exec_type non-PIE)"    "$([ "$exec_type" -eq 0 ] && [ "$n_elf" -gt 0 ] && echo ok || echo FAIL)"
  g "G16 no executable stack ($rwe_stack RWE, detector $g16_self)" \
    "$([ "$rwe_stack" -eq 0 ] && [ "$n_elf" -gt 0 ] && [ "$g16_self" = ok ] && echo ok || echo FAIL)"
  g "G22 stack protector in every ELF ($ssp_miss without)" "$([ "$ssp_miss" -eq 0 ] && [ "$n_elf" -gt 0 ] && echo ok || echo FAIL)"

  local suid ww
  suid=$(find root -type f \( -perm -4000 -o -perm -2000 \) | wc -l)
  ww=$(find root -type f -perm -0002 | wc -l)
  g "G4 no setuid/setgid ($suid)"      "$([ "$suid" -eq 0 ] && echo ok || echo FAIL)"
  g "G5 no world-writable ($ww)"       "$([ "$ww" -eq 0 ] && echo ok || echo FAIL)"

  local want have
  want=$(cat verity.roothash)
  have=$(grep -oE 'sha256 [0-9a-f]{64}' cmdline.txt | awk '{print $2}')
  g "G6 cmdline root hash matches tree" "$([ "$want" = "$have" ] && echo ok || echo FAIL)"

  # a full reproducibility check needs two builds; this asserts the mechanism
  # that makes it possible is still in place, which is cheap and catches drift.
  local pinned; pinned=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%d 2>/dev/null)
  g "G10 build clock pinned ($pinned)" \
    "$(strings busybox 2>/dev/null | has "BusyBox v.*$pinned" && echo ok || echo FAIL)"

  # by CONTENT, the way the pre-commit hook does it: a key is a file that says
  # PRIVATE KEY inside, wherever it sits and whatever it is called. the old
  # check was `keys/*.key` -- one directory, one extension -- so a decrypted
  # copy left at the tree root during debugging passed as 0. src/ and root/
  # are upstream and image trees (dropbear ships test keys); .git is history.
  #
  # the pattern used to be `BEGIN (RSA |EC |OPENSSH |ENCRYPTED |)PRIVATE KEY`,
  # which had two defects. it missed DSA and, more to the point, armored
  # OpenPGP secret keys -- and this repo now HOLDS one: the release signing
  # key, the single key whose leak lets someone forge attestations. and its
  # alternation ended in an EMPTY branch, which GNU grep accepts and ugrep and
  # some BSD greps reject as a regex error -- on such a host the detector
  # errored, its stderr went to /dev/null, the count came back 0 and the gate
  # reported ok. a detector that ERRORS must go red, never green, so its stderr
  # is captured and checked now instead of discarded.
  # NOTE: the redirection is a literal `2>"$perr"`, never `${perr:+2>"$perr"}`.
  # bash does not perform redirection that arrives from a parameter expansion --
  # it hands grep the string `2>/tmp/...` as a FILENAME, and the gate then fails
  # on "no such file" for a tree that is perfectly clean. that bug lived in this
  # very check for about twenty minutes.
  local plain plain_rc=0 perr
  perr=$(mktemp)
  plain=$(grep -rlE "$KEYPAT" . \
            --exclude-dir=src --exclude-dir=root --exclude-dir=.git --exclude-dir=sysroot \
            --exclude-dir=.worktrees 2>"$perr" | grep -c . || true)
  if [ -s "$perr" ]; then
    plain_rc=1
    printf '    the private-key detector wrote to stderr -- it may not have run:\n' >&2
    sed 's/^/      /' "$perr" >&2
  fi
  rm -f "$perr"
  # both walls have to carry the SAME pattern. they are in different files by
  # necessity (the hook cannot source this script -- sourcing it runs its
  # dispatch), so nothing but this line stops one of them being fixed alone,
  # which is exactly what happened: the hook learned about PGP keys and the
  # gate did not.
  grep -qF -- "$KEYPAT" githooks/pre-commit \
    || { plain_rc=1; printf '    githooks/pre-commit does not carry the same private-key pattern\n' >&2
         printf '    as this gate -- one wall was fixed and the other was not\n' >&2; }
  g "G11 no plaintext private key on disk ($plain)" \
    "$([ "$plain" -eq 0 ] && [ "$plain_rc" -eq 0 ] && echo ok || echo FAIL)"

  # G67 -- the tree that actually SHIPS, scanned. G11 sweeps the repo but
  # EXCLUDES root/ (build output; its wall is the commit hook, which only sees
  # git-tracked files, and root/ is gitignored). so nothing looked at root/ --
  # which mksquashfs packs 1:1 into the verity-covered image -- and a private
  # key baked in (a mis-set XOS_SSH_KEY, a stray dropped file) would ride the
  # signed root, attested and all. "no secrets in the image" (threat-model.md)
  # was prose nothing checked. scan it with the same marker, same stderr-is-red
  # discipline as G11. NOT a generic high-entropy sweep: the trust-anchor PEMs
  # and the static binaries would drown it in false positives; a PRIVATE KEY
  # PEM block is the concrete, bulletproof target.
  local imgk=0 imgerr
  imgerr=$(mktemp)
  if [ -d root ]; then
    imgk=$(grep -rlE "$KEYPAT" root 2>"$imgerr" | grep -c . || true)
  else
    imgk=1; printf '    root/ is absent -- the image staging tree did not build\n' >&2
  fi
  if [ -s "$imgerr" ]; then
    imgk=1
    printf '    the image key-scan wrote to stderr -- it may not have run:\n' >&2
    sed 's/^/      /' "$imgerr" >&2
  fi
  rm -f "$imgerr"
  g "G67 no private key in the shipped image ($imgk)" \
    "$([ "$imgk" -eq 0 ] && echo ok || echo FAIL)"

  # G12 -- the image contains everything the manifest declares. component
  # copies were `[ -f x ] && cp x`, so a component that failed to build made
  # the image smaller and every other gate still went green.
  local listing missing=0 want_n=0 p
  listing=$(unsquashfs -l rootfs.squashfs 2>/dev/null | sed 's|^squashfs-root/||')
  while read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    want_n=$((want_n+1))
    if [ "$(printf '%s\n' "$listing" | grep -cFx -- "$p" || true)" = 0 ]; then
      missing=$((missing+1)); printf '    missing from image: %s\n' "$p" >&2
    fi
  done < manifest
  g "G12 image has all $want_n manifest entries ($missing missing)" \
    "$([ "$missing" -eq 0 ] && [ "$want_n" -gt 0 ] && echo ok || echo FAIL)"

  # G13 -- the artifact matches the digest committed alongside the source.
  # this is the whole point of a pinned clock, salt and uuid: without it,
  # "reproducible" is a claim in a README that nothing ever checks.
  if [ -f image.sha256 ]; then
    # only the toolchain values are read here; cmp_pin reads the four
    # artifact digests itself, from the one place they are parsed.
    local want_tc have_tc
    want_tc=$(awk '$1=="toolchain"{print $2}'  image.sha256)
    have_tc=$(toolchain)
    # a pin with no toolchain line is a TRUNCATED pin, not a foreign host. it
    # can never equal the real fingerprint, so the SKIP below would fire every
    # run and G13 would quietly stop comparing digests forever. repro() has
    # guarded this since it was written; this gate never did.
    if [ -z "$want_tc" ] || ! grep -q '^source ' image.sha256; then
      g "G13 image digest pinned" FAIL
      printf '    image.sha256 has no toolchain or source line -- truncated pin, run ./build.sh cpin\n' >&2
    elif [ "$want_tc" != "$have_tc" ]; then
      g "G13 reproducible (needs the pinned toolchain)" SKIP
      printf '    this gcc/squashfs-tools is not the one the pin was taken with,\n' >&2
      printf '    so a byte mismatch here would prove nothing. rebuild is unverified.\n' >&2
    else
      # all four values, via the comparator repro() also uses, so the two can
      # never again disagree about what "reproduced" means.
      local g13=ok; cmp_pin . || g13=FAIL
      g "G13 image matches committed digest" "$g13"
      # the remedy, because it is nearly always this one and `all && pin` can
      # never reach it: the gates run at the END of `all`, so a stale pin fails
      # the run that would have refreshed it. pin cannot move inside `all`
      # either -- taken before the gates it would satisfy G13 by construction
      # and stop meaning anything.
      [ "$g13" = ok ] || printf '    if this build is the one you meant: ./build.sh pin\n' >&2
    fi
  else
    g "G13 image digest pinned" FAIL
    printf '    no image.sha256 -- run ./build.sh pin\n' >&2
  fi

  # G20 -- never ship an image we have revoked. one `revoke` on the wrong file
  # and the next boot is refused by our own firmware, with a secure boot error
  # that looks like an attack rather than a typo.
  local cur="" rev=0
  if [ -f xos-signed.efi ]; then
    cur=$(python3 pehash.py xos-signed.efi 2>/dev/null || true)
    [ -n "$cur" ] && rev=$(grep -c "^$cur" revoked || true)
  fi
  g "G20 shipped image is not revoked" \
    "$([ -n "$cur" ] && [ "$rev" = 0 ] && echo ok || echo FAIL)"
  [ -n "$cur" ] || printf '    no xos-signed.efi to check -- run ./build.sh uki\n' >&2

  # G21 -- the revocation hash function agrees with the signature it revokes.
  # dbx matches an authenticode digest, not sha256sum of the file; if pehash.py
  # computed the wrong number every dbx entry would match nothing, revoke
  # nothing, and look exactly like revocation that works.
  g "G21 revocation digest matches signature" \
    "$([ -n "$cur" ] && python3 pehash.py --verify xos-signed.efi >/dev/null 2>&1 && echo ok || echo FAIL)"

  # G44 -- G21 is only worth its line if it cannot be lied to. --verify used to
  # look for its own digest anywhere in the PKCS#7 blob, and everything in there
  # beyond the signed content comes from the image and is signed by nobody. so an
  # image could carry a planted copy of a wrong digest, pass, and hand `revoke` a
  # dbx entry that matches nothing while looking exactly like one that works.
  # this replays that forgery byte for byte and demands a refusal.
  local g44=ok
  if [ -f xos-signed.efi ]; then
    # -B: this is the one python invocation that imports pehash as a module, and
    # a stray __pycache__ would leave the tree dirty -- which `pin` refuses.
    PYTHONDONTWRITEBYTECODE=1 python3 -B - xos-signed.efi <<'G44EOF' >&2 || g44=FAIL
import os, shutil, struct, sys, tempfile, pehash

src = sys.argv[1]
b = bytearray(open(src, "rb").read())
pe = struct.unpack_from("<I", b, 0x3C)[0]
opt = pe + 24
dd = opt + (96 if struct.unpack_from("<H", b, opt)[0] == 0x10B else 112)
cert_dd = dd + 32
off, size = struct.unpack_from("<II", b, cert_dd)
if not size:
    sys.exit("    the signed image carries no signature")

d = tempfile.mkdtemp(prefix="xos-g44-")
f = os.path.join(d, "forged.efi")
try:
    if pehash.verify(src) != pehash.pe_hash(src):
        sys.exit("    --verify does not return the digest it checked")

    # flip one hashed byte: the image no longer hashes to what sbsign signed
    b[off // 2] ^= 0xFF
    open(f, "wb").write(b)
    wrong = pehash.pe_hash(f)

    # now plant that wrong digest in the certificate blob -- space the image owns
    # and nobody signs. the cert-table entry is an excluded region and the tail
    # boundary moves with the blob, so the hashed spans do not shift by a byte.
    struct.pack_into("<I", b, cert_dd + 4, size + 32)
    b += bytes.fromhex(wrong)
    open(f, "wb").write(b)

    # if either of these slips the forgery is not a forgery and the gate is theatre
    if pehash.pe_hash(f) != wrong:
        sys.exit("    planting the digest moved the hash -- the gate proves nothing")
    _, o2, s2 = pehash._regions(bytes(b))
    if bytes.fromhex(wrong) not in bytes(b[o2 + 8:o2 + s2]):
        sys.exit("    the wrong digest is not in the blob a substring check reads")

    try:
        pehash.verify(f)
    except ValueError:
        pass                      # the only acceptable outcome
    else:
        sys.exit("    a planted digest passed --verify -- dbx would revoke nothing")
finally:
    shutil.rmtree(d, ignore_errors=True)
G44EOF
  else
    g44=FAIL; printf '    no xos-signed.efi to forge against\n' >&2
  fi
  g "G44 a planted digest cannot pass revocation" "$g44"

  g "G7 kernel has no module loader" \
    "$([ -f "src/linux-$KVER/.config" ] && ! grep -q '^CONFIG_MODULES=y' "src/linux-$KVER/.config" && echo ok || echo FAIL)"

  # G14 -- the built kernel actually honours the config contract. kernel() checks
  # this at build time; re-checking here catches a stale prebuilt .config that
  # was never rebuilt after kernel.config changed.
  local kc="src/linux-$KVER/.config" k_miss=0 k_bad=0 k_want=0 opt
  if [ -f "$kc" ] && [ -s kernel.config ]; then
    while read -r opt; do
      [ -n "$opt" ] || continue
      k_want=$((k_want+1))
      grep -q "^$opt=y" "$kc" || { k_miss=$((k_miss+1)); printf '    config not enabled: %s\n' "$opt" >&2; }
    done < <(grep -oP '^CONFIG_[A-Z0-9_]+(?==y\s*$)' kernel.config)
    while read -r opt; do
      [ -n "$opt" ] || continue
      k_want=$((k_want+1))
      grep -q "^$opt=y" "$kc" && { k_bad=$((k_bad+1)); printf '    config still on: %s\n' "$opt" >&2; }
    done < <(grep -oP '^CONFIG_[A-Z0-9_]+(?==n\s*$)' kernel.config)
    # a kernel.config that parses to nothing is a contract with no clauses
    [ "$k_want" -gt 0 ] || { k_miss=$((k_miss+1)); printf '    kernel.config declares no options\n' >&2; }
    # CONFIG_EXTRA_FIRMWARE bakes a vendor blob straight into bzImage, which
    # G18 (squashfs only) cannot see. it is a string option, so the =n leak
    # scan above skips it -- assert its absence explicitly.
    grep -q '^CONFIG_EXTRA_FIRMWARE="..*"' "$kc" \
      && { k_bad=$((k_bad+1)); printf '    firmware blob embedded in kernel: CONFIG_EXTRA_FIRMWARE\n' >&2; }
    g "G14 kernel hardening config ($k_miss off, $k_bad leaked)" \
      "$([ "$k_miss" -eq 0 ] && [ "$k_bad" -eq 0 ] && echo ok || echo FAIL)"
  else
    g "G14 kernel hardening config" FAIL
    printf '    no %s\n' "$kc" >&2
  fi

  # G15 -- the tamper-proof hardening lives on the cmdline (inside the UKI
  # signature). assert every param that must be there is.
  local c15=0 want15
  # console=ttyS0,19200 is in this list because the serial terminal is a promise
  # the README makes and nothing was holding it: drop it from the cmdline and the
  # hardware terminal goes dark from the first kernel message, with every gate
  # still green. the baud is part of it -- a vt320 receives garbage above 19200.
  for want15 in 'panic_on_corruption' 'oops=panic' 'panic=-1' 'page_alloc.shuffle=1' 'random.trust_cpu=1' 'xos.epoch=' 'dm-mod.waitfor=PARTUUID=' 'console=ttyS0,19200'; do
    grep -qF "$want15" cmdline.txt || { c15=$((c15+1)); printf '    cmdline missing: %s\n' "$want15" >&2; }
  done
  # ...and assert NO param is present that would neuter the compiled-in
  # hardening at boot. G15 checked only for presence; a runtime override like
  # mitigations=off or init_on_free=0 keeps every config gate green while
  # switching the protection off, and the cmdline is signed, so it must be
  # caught here before it ships inside the signature.
  local c15b=0 deny15
  # this is a denylist, which is only ever as complete as the list. it is
  # tolerable ONLY because cmdline.txt is a fixed printf template in verity()
  # with no per-boot or per-install input -- the one variable token is $testflag
  # (G31). so this guards an EDITED template landing in a signed commit, not a
  # typo'd boot param. keep the obvious hardening-off spellings covered; the
  # alternate spellings (pti=off vs nopti, spectre_v2=off vs the per-bug knobs)
  # each neuter a compiled-in mitigation from a signed cmdline just the same.
  for deny15 in 'mitigations=off' 'mitigations=auto,nosmt' 'init_on_alloc=0' 'init_on_free=0' 'nokaslr' 'kaslr.disable' 'lockdown=none' 'lockdown=integrity' 'nosmep' 'nosmap' 'nopti' 'pti=off' 'spectre_v2=off' 'spectre_v2_user=off' 'spec_store_bypass_disable=off' 'l1tf=off' 'mds=off' 'tsx_async_abort=off' 'retbleed=off' 'srbds=off' 'gather_data_sampling=off' 'reg_file_data_sampling=off' 'no_hash_pointers' 'page_alloc.shuffle=0' 'random.trust_cpu=0' 'slab_nomerge=0' 'noexec=off' 'nosmt=force_off'; do
    grep -qF "$deny15" cmdline.txt && { c15b=$((c15b+1)); printf '    cmdline FORBIDDEN: %s\n' "$deny15" >&2; }
  done
  g "G15 cmdline hardening params ($c15 missing, $c15b forbidden)" \
    "$([ "$c15" -eq 0 ] && [ "$c15b" -eq 0 ] && echo ok || echo FAIL)"

  # G18 -- no firmware blobs in the image. r8169 pulls in FW_LOADER; if a blob
  # ever gets shipped it is unverified-by-vendor content on a verified system.
  local fw fw_list
  fw_list=$(unsquashfs -l rootfs.squashfs 2>/dev/null) || fw_list=""
  fw=$(printf '%s\n' "$fw_list" | grep -c 'squashfs-root/lib/firmware' || true)
  g "G18 no firmware blobs in image ($fw)" "$([ -n "$fw_list" ] && [ "${fw:-0}" -eq 0 ] && echo ok || echo FAIL)"

  # G32 -- the fingerprint wordlist. init indexes it 1..256 by roothash byte;
  # a short, duplicated, or malformed list makes two images share words or
  # prints empty ones, silently -- exactly the quiet shrink gates exist for.
  local wl=overlay/usr/share/xos/words wl_n wl_u wl_bad
  wl_n=$(grep -c . "$wl" 2>/dev/null || true)
  wl_u=$(sort -u "$wl" 2>/dev/null | grep -c . || true)
  wl_bad=$(grep -cvE '^[a-z]+$' "$wl" 2>/dev/null || true)
  g "G32 fingerprint wordlist ($wl_n words, $((wl_n - wl_u)) dup, $wl_bad malformed)" \
    "$([ "${wl_n:-0}" -eq 256 ] && [ "${wl_u:-0}" -eq 256 ] && [ "${wl_bad:-1}" -eq 0 ] && echo ok || echo FAIL)"

  # G33 -- init's remote-access arg-building, exercised through the SAME busybox
  # ash the image runs. the wg-address parse and its two consumers (the route
  # keeps the CIDR, the ssh bind takes the bare address) are the exact lines a
  # prior fix inverted -- $wgip carried the CIDR into `dropbear -p`, and neither
  # the gates nor the boot self-test caught it, because the real state_open()
  # / wg block never runs in the harness (it needs a partitioned LUKS stick and
  # an interactive passphrase). this runs init's own parse bytes and asserts the
  # split; the structural checks pin the two consumers and the partition scan so
  # a future edit that swaps them fails here instead of on a stick in the field.
  local g33=ok bb33 wgp33 t33 got33
  t33=$(mktemp -d)
  bb33=./busybox; [ -x "$bb33" ] || bb33=$(command -v busybox 2>/dev/null)
  wgp33=$(sed -n '/^[[:space:]]*wgcidr=/,/^[[:space:]]*case /p' init)
  _wg33() {   # $1 = Address value ('' for none), $2 = expected "wgcidr|wgip"
    if [ -n "$1" ]; then printf 'Address = %s\n' "$1" > "$t33/wg0.conf"; else : > "$t33/wg0.conf"; fi
    got33=$(STATE_DIR="$t33" "$bb33" ash -c "$wgp33"'; printf "%s|%s" "$wgcidr" "$wgip"' 2>/dev/null)
    [ "$got33" = "$2" ] || { g33=FAIL; printf '    wg-parse %s -> %s (want %s)\n' "${1:-none}" "$got33" "$2" >&2; }
  }
  _wg33 "10.9.0.2/32" "10.9.0.2/32|10.9.0.2"
  _wg33 "10.9.0.1/24" "10.9.0.1/24|10.9.0.1"
  _wg33 "10.9.0.5"    "10.9.0.5/24|10.9.0.5"
  _wg33 ""            "|"
  # the signed-cmdline reader, same treatment: a key in FIRST position used to
  # come back empty (`[ ^]` was a bracket set, not an anchor), and xos.epoch --
  # the clock floor -- is read through it.
  local cg33 cl33
  cg33=$(grep '^cmdline_get()' init)
  for cl33 in 'xos.epoch=7 a=1|7' 'a=1 xos.epoch=7|7' 'a=1 xos.epoch=7 b=2|7' 'a=1 xos.epochs=9|'; do
    got33=$(CMDLINE="${cl33%|*}" "$bb33" ash -c "$cg33"'; cmdline_get xos.epoch' 2>/dev/null)
    [ "$got33" = "${cl33#*|}" ] || { g33=FAIL; printf '    cmdline_get on "%s" -> "%s" (want "%s")\n' "${cl33%|*}" "$got33" "${cl33#*|}" >&2; }
  done
  rm -rf "$t33"
  grep -q 'ip addr add "\$wgcidr" dev wg0' init          || { g33=FAIL; printf '    wg route no longer uses $wgcidr\n' >&2; }
  grep -q 'dropbear .*-p "\$wgip:22"' init               || { g33=FAIL; printf '    ssh bind no longer uses bare $wgip\n' >&2; }
  grep -q 'for p in /sys/class/block/\*/partition' init  || { g33=FAIL; printf '    state_open no longer scans */partition\n' >&2; }
  grep -q 'for dev in \$cands' init                      || { g33=FAIL; printf '    state_open no longer tries every candidate\n' >&2; }
  grep -q 'wg setconf wg0 /tmp/wgset.conf' init          || { g33=FAIL; printf '    setconf fed the raw conf -- Address= lines make strict wg error out\n' >&2; }
  g "G33 init remote-access logic (real ash)" "$g33"

  # G34 -- the signed UKI's EMBEDDED roothash must match the tree. G6 pins
  # cmdline.txt (a file) to verity.roothash (a file), and G17 pins the ESP to
  # xos-signed.efi -- but nothing pinned what is INSIDE the signed efi to
  # either. a uki step that fails (locked keys) while verity and stick succeed
  # leaves a stale signed efi beside a fresh image, every gate green, and a
  # stick that panics at the verity mount on real hardware. seen happen.
  # `|| true`: under `set -o pipefail` a missing xos-signed.efi makes strings
  # exit 1, the assignment fails, and set -e takes the WHOLE gate run down here
  # -- every gate after this one never ran and never said so, which is the one
  # failure mode a gate wall cannot have. a missing artifact is this gate's
  # FAIL to report, not the run's death.
  local g34_have
  g34_have=$( { strings xos-signed.efi 2>/dev/null || true; } \
    | grep -o 'sha256 [0-9a-f]\{64\}' | head -1 | cut -d' ' -f2 || true)
  g "G34 signed UKI embeds the tree's roothash" \
    "$([ -n "$g34_have" ] && [ "$g34_have" = "$(cat verity.roothash)" ] && echo ok || echo FAIL)"

  # G35 -- every first-party script parses under the ash that ships. shellcheck
  # is host-optional (lint()); this is not: a script the shipped shell cannot
  # even parse is a boot- or lease-time failure no other gate can see, because
  # init and the dhcp hook only ever run on the stick.
  local g35=ok bb35 f35 e35
  # absolute, not ./busybox: G51 forks a pty whose child chdirs into a temp
  # HOME before it execs this, and a relative path does not survive that --
  # it failed with ENOENT, inside a heredoc whose output goes to /dev/null,
  # so the gate simply read FAIL with nothing to say why. type -P already
  # returns an absolute path, so both branches agree.
  bb35=$PWD/busybox; [ -x "$bb35" ] || bb35=$(type -P busybox 2>/dev/null)
  for f35 in init learn/learn learn/lib/* overlay/usr/share/udhcpc/default.script overlay/etc/shrc; do
    e35=$("$bb35" ash -n "$f35" 2>&1) \
      || { g35=FAIL; printf '    %s does not parse: %s\n' "$f35" "$e35" >&2; }
  done
  # /etc/shrc is the first file every interactive shell on the stick sources:
  # a syntax error in it is a broken prompt on every console, at once, with the
  # build green. its source (overlay/etc/shrc) is in the list above; this is
  # the shipped copy, parsed again so a copy that was not made is not a pass.
  if [ -f root/etc/shrc ]; then
    e35=$("$bb35" ash -n root/etc/shrc 2>&1) \
      || { g35=FAIL; printf '    root/etc/shrc does not parse: %s\n' "$e35" >&2; }
  fi
  g "G35 first-party scripts parse under shipped ash" "$g35"

  # G38 -- build.sh and selftest.sh parse. G35 covers what ships; these two
  # never ship, and until now nothing looked at them at all. that matters most
  # for usb() and addstate(): no test calls them, so a syntax error in either
  # is invisible until the moment someone flashes a real disk with it. bash,
  # not ash -- these are the two files that are allowed to be bash.
  local g38=ok f38 e38
  for f38 in build.sh build/*.sh selftest.sh; do
    e38=$(bash -n "$f38" 2>&1) \
      || { g38=FAIL; printf '    %s does not parse: %s\n' "$f38" "$e38" >&2; }
  done
  g "G38 build scripts parse under bash" "$g38"

  # G48 -- the scripts G35 and G38 do not name: the commit hook, the arsenal
  # builders, the on-stick helpers (arsenal, xexec, the learn installers), the
  # graded arsenal school (arsenal/learn + its lib/*, which ride p3 off-image so
  # nothing else parse-checks them), and the two CI runners. the hook is the
  # sharp one -- it IS gate G9, and a syntax
  # error in it makes git skip it silently, so the guard would wave through the
  # artifacts and keys it exists to stop. the runners are the same shape of
  # danger one level out: they are what runs every other gate unattended, and a
  # syntax error in one surfaces only when the timer fires, into a journal that
  # on a busy box does not keep a day. each script is parsed under the shell its
  # shebang names: bash for the hook, the shipped ash for the rest (a stricter
  # POSIX check that also catches a bashism smuggled into a #!/bin/sh file).
  local g48=ok f48 e48 chk48 f48py
  for f48 in githooks/pre-commit learn/install.sh learn/push learn/wrapper \
             arsenal/*.sh arsenal/push arsenal/wrapper arsenal/arsenal arsenal/xexec arsenal/qr \
             arsenal/learn arsenal/lib/* \
             ci/lib.sh ci/xos-repro ci/xos-ci-full ci/xos-ci-status; do
    [ -f "$f48" ] || continue
    case "$(head -1 "$f48")" in *bash) chk48="bash -n" ;; *) chk48="$bb35 ash -n" ;; esac
    e48=$($chk48 "$f48" 2>&1) \
      || { g48=FAIL; printf '    %s does not parse: %s\n' "$f48" "$e48" >&2; }
  done
  # build-arsenal-c.sh wraps a busybox-ash build in a quoted heredoc; the outer
  # parse never looks inside it, so parse the INNER block on its own under ash.
  if [ -f arsenal/build-arsenal-c.sh ]; then
    e48=$(awk "/<<'INNER'/{f=1;next} /^INNER\$/{f=0} f" arsenal/build-arsenal-c.sh \
          | "$bb35" ash -n /dev/stdin 2>&1) \
      || { g48=FAIL; printf '    build-arsenal-c.sh INNER block does not parse: %s\n' "$e48" >&2; }
  fi
  # arsenal/atlas, arsenal/view, arsenal/chart and the canvas.py engine they
  # all import are the first-party scripts in this list that are not shell --
  # ash -n on a python file would reject it for the wrong reason (a bashism
  # check on a language it does not even apply to), so they get the
  # interpreter's own syntax check instead.
  for f48py in arsenal/atlas arsenal/view arsenal/chart arsenal/canvas.py; do
    [ -f "$f48py" ] || continue
    e48=$(python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$f48py" 2>&1) \
      || { g48=FAIL; printf '    %s does not parse: %s\n' "$f48py" "$e48" >&2; }
  done
  g "G48 remaining first-party scripts parse" "$g48"

  # G39 -- the only two functions here that write to a raw block device must
  # both go through the shared guard. they were near-identical copies, which is
  # how a guard gets fixed in one and forgotten in the other; one implementation
  # is only worth anything if nothing can quietly stop calling it.
  local g39=ok fn39 body39 need39
  for fn39 in usb addstate; do
    body39=$(fnbody "$fn39")
    for need39 in guard_removable confirm_model; do
      printf '%s' "$body39" | has "$need39 \"" \
        || { g39=FAIL; printf '    %s() no longer calls %s\n' "$fn39" "$need39" >&2; }
    done
  done
  g "G39 destructive disk paths share one guard" "$g39"

  # G49 -- stick_install() is the command a user actually runs (./build.sh
  # install), yet no test can call it: it demands a real removable disk. so
  # nothing watched what it does, and what it does is decide where the bytes
  # go. it must never grow a raw write of its own -- every byte reaches the
  # disk through usb() or addstate(), the two paths G39 proves are guarded by
  # guard_removable + confirm_model. a dd or sfdisk inlined here would write
  # around both guards, past the model confirmation, onto whatever /dev the
  # detection picked. so: it calls the guarded delegates, and holds no
  # block-write primitive itself.
  local g49=ok body49
  body49=$(fnbody stick_install)
  if [ -z "$body49" ]; then
    g49=FAIL; printf '    stick_install() not found\n' >&2
  else
    for need49 in detect_removable 'usb "' 'addstate "'; do
      printf '%s' "$body49" | has "$need49" \
        || { g49=FAIL; printf '    stick_install no longer calls %s\n' "$need49" >&2; }
    done
    # a raw write here bypasses usb()/addstate() and their guards entirely.
    printf '%s' "$body49" | grep -nE '(^|[^[:alnum:]_])(dd|sfdisk|wipefs|mkfs\.[a-z0-9]+|blockdev|partprobe)[[:space:]]|luksFormat|of=/dev|>[[:space:]]*"?/dev/' \
      | grep -v '#' >&2 \
      && { g49=FAIL; printf '    stick_install writes a raw device directly -- must go through usb()/addstate()\n' >&2; }
  fi
  g "G49 install writes only through the guarded paths" "$g49"

  # G64 -- clone() images a stick onto a spare, so it writes a raw device and
  # must be guarded like the others: guard_removable + confirm_model on the DST,
  # nothing raw around them. no test can hand it a removable disk, so the static
  # half mirrors G39/G49 and the live half runs its two factored helpers on
  # image files -- clone_precheck's refusals, and range_hash telling a faithful
  # copy from a one-byte corruption. proven to go red if either helper is broken.
  local g64=ok body64
  body64=$(fnbody clone)
  if [ -z "$body64" ]; then
    g64=FAIL; printf '    clone() not found\n' >&2
  else
    for need64 in 'guard_removable "' 'confirm_model "' clone_precheck range_hash; do
      printf '%s' "$body64" | has "$need64" \
        || { g64=FAIL; printf '    clone() no longer calls %s\n' "$need64" >&2; }
    done
  fi
  clone_precheck /dev/x /dev/x 100 100 2>/dev/null && { g64=FAIL; printf '    clone_precheck accepted src==dst\n' >&2; }
  clone_precheck a b 200 100 2>/dev/null && { g64=FAIL; printf '    clone_precheck accepted a too-small dst\n' >&2; }
  clone_precheck a b 100 200 2>/dev/null || { g64=FAIL; printf '    clone_precheck refused a valid pair\n' >&2; }
  local t64; t64=$(mktemp -d)
  head -c 1048576 /dev/zero | tr '\0' 'A' > "$t64/src"; cp "$t64/src" "$t64/dst"
  [ "$(range_hash "$t64/src" 1048576)" = "$(range_hash "$t64/dst" 1048576)" ] \
    || { g64=FAIL; printf '    range_hash called a faithful copy different\n' >&2; }
  printf 'B' | dd of="$t64/dst" bs=1 seek=1000 count=1 conv=notrunc status=none 2>/dev/null
  [ "$(range_hash "$t64/src" 1048576)" != "$(range_hash "$t64/dst" 1048576)" ] \
    || { g64=FAIL; printf '    range_hash missed a one-byte corruption\n' >&2; }
  rm -rf "$t64"
  g "G64 clone is guarded and its copy-is-faithful check works" "$g64"

  # G40 -- the respawn backoff, run for real. it is written once now, but the
  # dropbear copy it replaced was never reached by any boot, healthy or not, so
  # the arithmetic had no coverage whatsoever. sleep is shadowed by a stub, so
  # the 30-second branch is observable without waiting 30 seconds.
  # each case is "starting _fail : seconds the payload ran : want _fail : want sleep".
  local g40=ok rw40 out40 c40 f40 r40 wf40 ws40
  rw40=$(sed -n '/^respawn_wait()/,/^}/p' init)
  for c40 in 0:1:1:1 3:1:4:1 4:1:5:30 4:9:0:1 7:5:0:1 5:1:6:30; do
    f40=$(printf '%s' "$c40" | cut -d: -f1); r40=$(printf '%s' "$c40" | cut -d: -f2)
    wf40=$(printf '%s' "$c40" | cut -d: -f3); ws40=$(printf '%s' "$c40" | cut -d: -f4)
    out40=$("$bb35" ash -c "sleep() { printf 'slept=%s ' \"\$1\"; }
$rw40
_fail=$f40
respawn_wait $r40
printf 'fail=%s' \"\$_fail\"" 2>&1)
    [ "$out40" = "slept=$ws40 fail=$wf40" ] \
      || { g40=FAIL; printf '    respawn_wait: _fail=%s ran=%ss -> [%s] (want [slept=%s fail=%s])\n' \
             "$f40" "$r40" "$out40" "$ws40" "$wf40" >&2; }
  done
  g "G40 respawn backoff counts and sleeps as written" "$g40"

  # G41 -- flashing the stick must leave a device whose free space can actually
  # become p3. no test could call usb()/addstate() (they demand a real removable
  # disk), and both of the bugs this catches shipped for exactly that reason:
  # dd left the backup GPT describing the IMAGE, so sfdisk saw 0 B free
  # on a 16 GB stick, and the type was written as gdisk's 8309, which sfdisk
  # rejects outright -- addstate had never once produced a p3. a sparse file is
  # enough: sfdisk does the same arithmetic on a file as on a block device.
  # 1 GiB, not 16: /tmp is tmpfs on this host, so a 16 GB scratch file is 16 GB
  # of RAM competing with the qemu boots the self-test runs. the property under
  # test is "p3 fills whatever device it is given", and a device 15x the image
  # proves that as well as one 240x it. the assertions are stated as "everything
  # past the image, less the backup GPT" for the same reason -- exact, and
  # indifferent to how big the stick is.
  local g41=ok f41 free41 p3sz41 p2sz41 want41 dev41=$((1024 * 1024 * 1024 / 512))
  if [ -f stick.img ]; then
    want41=$(( dev41 - STATE_START_S - 2048 ))
    f41=$(mktemp -u /tmp/xos-g41.XXXXXX.img)
    truncate -s $((dev41 * 512)) "$f41" 2>/dev/null && dd if=stick.img of="$f41" bs=1M conv=notrunc status=none 2>/dev/null
    sfdisk --relocate gpt-bak-std "$f41" >/dev/null 2>&1
    free41=$(sfdisk -F "$f41" 2>/dev/null | awk '/^ *[0-9]+ /{print $3; exit}')
    # every sector past the image must be free once the backup GPT is at the end
    [ "${free41:-0}" -ge "$want41" ] \
      || { g41=FAIL; printf '    only %s of %s sectors free after relocate -- the backup GPT still describes the image\n' "${free41:-0}" "$want41" >&2; }
    # p2 is the same sectors in every version or p3's start is not a constant,
    # and then no update can preserve it. this is the layout claim itself.
    p2sz41=$(partx -g -o SECTORS -n 2:2 "$f41" 2>/dev/null | tr -d ' ')
    [ "${p2sz41:-0}" -eq "$ROOT_SIZE_S" ] \
      || { g41=FAIL; printf '    p2 is %s sectors, not the fixed %s -- p3 would move with the image\n' "${p2sz41:-0}" "$ROOT_SIZE_S" >&2; }
    sfdisk --no-reread -a "$f41" >/dev/null 2>&1 <<G41EOF
start=$STATE_START_S, type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
G41EOF
    p3sz41=$(partx -g -o SECTORS -n 3:3 "$f41" 2>/dev/null | tr -d ' ')
    [ "${p3sz41:-0}" -ge "$want41" ] \
      || { g41=FAIL; printf '    p3 is %s of %s sectors -- addstate cannot fill the stick\n' "${p3sz41:-0}" "$want41" >&2; }
    rm -f "$f41"
  else
    g41=FAIL; printf '    no stick.img to flash\n' >&2
  fi
  g "G41 a flashed stick yields a p3 that fills the device" "$g41"

  # G42 -- a revocation that only reaches the qemu varstore is not a revocation.
  # dbx() wrote nothing else for as long as revoke has existed, so `./build.sh
  # revoke` passed every gate, went green in the harness, and left the machine
  # it was meant to protect completely unchanged. if anything is revoked, the
  # stick must carry the enrollable list beside the keys.
  local g42=ok nrev42
  # grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` used to
  # append a second line and the gate label came out as "(0\n0".
  nrev42=$(grep -cE '^[0-9a-f]{64}' revoked 2>/dev/null || true); nrev42=${nrev42:-0}
  if [ "${nrev42:-0}" -eq 0 ]; then
    # nothing revoked -> the enroll-onto-stick path is UNEXERCISED, not proven.
    # green ok here would count an untested production path as passing; SKIP is
    # the honest verdict (A11 proves the firmware side when something is revoked).
    g "G42 revocation shipped enrollably (nothing revoked)" SKIP
  else
    [ -s dbxauth/dbx.auth ] \
      || { g42=FAIL; printf '    %s revoked but no dbxauth/dbx.auth -- run ./build.sh dbx\n' "$nrev42" >&2; }
    [ -f stick.img ] && { mdir -i stick.img@@$((1024 * 1024)) ::/xos-keys 2>/dev/null | has 'dbx.auth' \
      || { g42=FAIL; printf '    the stick does not carry /xos-keys/dbx.auth -- revocation would hold in qemu only\n' >&2; }; }
    g "G42 revocation shipped enrollably ($nrev42 revoked)" "$g42"
  fi

  # G43 -- an update must not be a factory reset. `usb` writes stick.img over the
  # whole front of the device, GPT included, so the new two-partition table
  # forgets p3 even though the flash never reaches a single one of its bytes.
  # that is verified behaviour, not a theory: dd was proven to orphan p3. the fix
  # is the fixed layout (p3 begins where stick.img ends) plus tail_parts, and
  # this gate runs the real function over a scratch device through a whole
  # flash -> addstate -> REflash cycle, then checks the entry AND the data.
  local g43=ok f43 dev43=$((1024 * 1024 * 1024 / 512)) sz43 before43 after43 mark43 gone43
  if [ -f stick.img ]; then
    sz43=$(stat -c%s stick.img)
    f43=$(mktemp -u /tmp/xos-g43.XXXXXX.img)
    truncate -s $((dev43 * 512)) "$f43" 2>/dev/null \
      && dd if=stick.img of="$f43" bs=1M conv=notrunc status=none 2>/dev/null
    sfdisk --relocate gpt-bak-std "$f43" >/dev/null 2>&1
    sfdisk --no-reread -a "$f43" >/dev/null 2>&1 <<G43EOF
start=$STATE_START_S, type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
G43EOF
    # a byte pattern where p3's luks header would be, so "preserved" has to mean
    # the data too and not merely a partition entry pointing at rubble.
    printf 'XOS-G43-STATE' | dd of="$f43" bs=512 seek="$STATE_START_S" conv=notrunc status=none 2>/dev/null
    before43=$(tail_parts "$f43" "$sz43" keep)
    [ -n "$before43" ] \
      || { g43=FAIL; printf '    p3 is not past the flashed region -- an update would write over it\n' >&2; }
    [ -z "$(tail_parts "$f43" "$sz43" lose)" ] \
      || { g43=FAIL; printf '    p3 starts INSIDE the region a flash writes\n' >&2; }
    # the update, byte for byte what usb() does to the device
    dd if=stick.img of="$f43" bs=1M conv=notrunc status=none 2>/dev/null
    gone43=$(tail_parts "$f43" "$sz43" keep)
    [ -z "$gone43" ] \
      || { g43=FAIL; printf '    the reflash did not drop p3 at all -- this gate is proving nothing\n' >&2; }
    sfdisk --relocate gpt-bak-std "$f43" >/dev/null 2>&1
    printf '%s\n' "$before43" | sfdisk --no-reread -a "$f43" >/dev/null 2>&1 || true
    after43=$(tail_parts "$f43" "$sz43" keep)
    [ -n "$after43" ] && [ "$after43" = "$before43" ] \
      || { g43=FAIL; printf '    p3 entry did not come back identical\n      was: %s\n      now: %s\n' "$before43" "$after43" >&2; }
    mark43=$(dd if="$f43" bs=512 skip="$STATE_START_S" count=1 status=none 2>/dev/null | head -c 13 || true)
    [ "$mark43" = "XOS-G43-STATE" ] \
      || { g43=FAIL; printf '    the flash wrote over p3 data -- stick.img reaches past sector %s\n' "$STATE_START_S" >&2; }
    # the other direction: a stick from the OLD layout, p3 sitting where the
    # image now writes. usb() must SEE that, not discover it afterwards.
    rm -f "$f43"; f43=$(mktemp -u /tmp/xos-g43b.XXXXXX.img)
    truncate -s $((dev43 * 512)) "$f43" 2>/dev/null \
      && dd if=stick.img of="$f43" bs=1M conv=notrunc status=none 2>/dev/null
    sfdisk --relocate gpt-bak-std "$f43" >/dev/null 2>&1
    sfdisk --no-reread -a "$f43" >/dev/null 2>&1 <<G43OLD
start=$(( ROOT_START_S + ROOT_SIZE_S )), type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
G43OLD
    # -i: sfdisk dumps uuids upper-case and PU_STATE is written lower-case here,
    # which is exactly why usb() greps case-insensitively too.
    printf '%s' "$(tail_parts "$f43" "$sz43" lose)" | grep -qi "$PU_STATE" \
      || { g43=FAIL; printf '    a p3 inside the flashed region is not reported as at risk -- the refusal cannot fire\n' >&2; }
    [ -z "$(tail_parts "$f43" "$sz43" keep)" ] \
      || { g43=FAIL; printf '    an old-layout p3 was misreported as safe to keep\n' >&2; }
    # and the orphan guard: addstate must not lay a new p3 over a live volume
    # whose entry an older flash threw away. both directions, or it is decoration.
    dd if=/dev/zero of="$f43" bs=512 seek=$(( ROOT_START_S + ROOT_SIZE_S )) count=1 conv=notrunc status=none 2>/dev/null
    luks_at "$f43" $(( ROOT_START_S + ROOT_SIZE_S )) \
      && { g43=FAIL; printf '    luks_at says LUKS on a sector that has none\n' >&2; }
    printf 'LUKS\272\276' | dd of="$f43" bs=512 seek=$(( ROOT_START_S + ROOT_SIZE_S )) conv=notrunc status=none 2>/dev/null
    luks_at "$f43" $(( ROOT_START_S + ROOT_SIZE_S )) \
      || { g43=FAIL; printf '    luks_at misses a real LUKS header -- an orphaned p3 would be written over\n' >&2; }
    rm -f "$f43"
  else
    g43=FAIL; printf '    no stick.img to flash\n' >&2
  fi
  # and the real path has to still use it -- the same reason G39 exists.
  local body43; body43=$(fnbody usb)
  printf '%s' "$body43" | has 'keep_tail=$(tail_parts "$dev" "$img_bytes" keep)' \
    || { g43=FAIL; printf '    usb() no longer saves the partitions past the image\n' >&2; }
  printf '%s' "$body43" | has '"$keep_tail" | sfdisk --no-reread -a "$dev"' \
    || { g43=FAIL; printf '    usb() no longer puts the saved partitions back after the write\n' >&2; }
  printf '%s' "$body43" | has 'grep -qi "\$PU_STATE"' \
    || { g43=FAIL; printf '    usb() no longer refuses a p3 inside the region it writes\n' >&2; }
  printf '%s' "$(fnbody addstate)" | has 'luks_at "\$dev"' \
    || { g43=FAIL; printf '    addstate() no longer checks for an orphaned state volume\n' >&2; }
  g "G43 an update preserves p3, entry and data" "$g43"

  # G45 -- a dead maintainer key must not keep verifying. gpg prints VALIDSIG for
  # an expired key and for a revoked one exactly as it does for a live one, so
  # matching that line alone -- which sigver did -- means a leaked key goes on
  # passing forever, and expiry and revocation are the only things that ever
  # limit that damage. two layers: the verdicts, against recorded status text, so
  # this holds on a host without gpg; then the same verdicts against keys really
  # generated here, so a gpg that renames a status line is caught too.
  local g45=ok r45=0
  local F45=DEADBEEF0000000000000000000000000000CAFE
  r45=0; printf '[GNUPG:] GOODSIG AAAA Some One\n[GNUPG:] VALIDSIG %s x\n' "$F45" | sigok "$F45" || r45=$?
  [ "$r45" = 0 ] || { g45=FAIL; printf '    sigok refuses a good signature (rc %s)\n' "$r45" >&2; }
  r45=0; printf '[GNUPG:] EXPKEYSIG AAAA Some One\n[GNUPG:] KEYEXPIRED 1654819200\n[GNUPG:] VALIDSIG %s x\n' "$F45" | sigok "$F45" || r45=$?
  [ "$r45" = 2 ] || { g45=FAIL; printf '    an expired key is not flagged (rc %s, wanted 2)\n' "$r45" >&2; }
  r45=0; printf '[GNUPG:] REVKEYSIG AAAA Some One\n[GNUPG:] VALIDSIG %s x\n' "$F45" | sigok "$F45" || r45=$?
  [ "$r45" = 3 ] || { g45=FAIL; printf '    a revoked key is not flagged (rc %s, wanted 3)\n' "$r45" >&2; }
  r45=0; printf '[GNUPG:] GOODSIG AAAA Some One\n[GNUPG:] VALIDSIG %s x\n' 0000000000000000000000000000000000000000 | sigok "$F45" || r45=$?
  [ "$r45" = 1 ] || { g45=FAIL; printf '    a signature by an unpinned key is accepted (rc %s)\n' "$r45" >&2; }
  # the uid is free text that travels with the key -- it must not spoof a verdict
  r45=0; printf '[GNUPG:] EXPKEYSIG AAAA GOODSIG Impersonator\n[GNUPG:] VALIDSIG %s x\n' "$F45" | sigok "$F45" || r45=$?
  [ "$r45" = 2 ] || { g45=FAIL; printf '    a user id spoofed the verdict (rc %s, wanted 2)\n' "$r45" >&2; }

  if command -v gpg >/dev/null 2>&1; then
    local h45 fpr45 st45
    for k45 in live expired; do
      h45=$(mktemp -d) || continue
      chmod 700 "$h45"; printf 'payload\n' > "$h45/f"
      # a key made and used two years ago with a one-day life is expired now
      local age45=""; [ "$k45" = expired ] && age45=--faked-system-time=20240101T000000!
      gpg -q --batch --homedir "$h45" --pinentry-mode loopback --passphrase '' $age45 \
        --quick-gen-key 'xos gate <g45@invalid>' default default \
        "$([ "$k45" = expired ] && echo seconds=86400 || echo never)" 2>/dev/null
      gpg -q --batch --homedir "$h45" --pinentry-mode loopback --passphrase '' $age45 \
        --detach-sign -o "$h45/f.sig" "$h45/f" 2>/dev/null
      fpr45=$(gpg --batch --homedir "$h45" --with-colons -k 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
      st45=$(gpg --batch --homedir "$h45" --status-fd 1 --verify "$h45/f.sig" "$h45/f" 2>/dev/null || true)
      r45=0; printf '%s\n' "$st45" | sigok "${fpr45:-none}" || r45=$?
      if [ "$k45" = live ]; then
        [ "$r45" = 0 ] || { g45=FAIL; printf '    real gpg: a live key does not verify (rc %s)\n' "$r45" >&2; }
        # gpg writes a revocation certificate at generation time, so revoking the
        # same key needs no interactive step
        sed 's/^:-----BEGIN/-----BEGIN/' "$h45"/openpgp-revocs.d/*.rev 2>/dev/null \
          | gpg -q --batch --homedir "$h45" --import 2>/dev/null || true
        st45=$(gpg --batch --homedir "$h45" --status-fd 1 --verify "$h45/f.sig" "$h45/f" 2>/dev/null || true)
        r45=0; printf '%s\n' "$st45" | sigok "${fpr45:-none}" || r45=$?
        [ "$r45" = 3 ] || { g45=FAIL; printf '    real gpg: a REVOKED key is not refused (rc %s, wanted 3)\n' "$r45" >&2; }
      else
        [ "$r45" = 2 ] || { g45=FAIL; printf '    real gpg: an EXPIRED key is not flagged (rc %s, wanted 2)\n' "$r45" >&2; }
      fi
      rm -rf "$h45"
    done
  else
    printf '    gpg absent -- the recorded-status verdicts ran, the live-gpg layer did not\n' >&2
  fi

  # and the real path has to still route through it, with revocation inescapable
  local body45; body45=$(fnbody sigver)
  printf '%s' "$body45" | has 'sigok "\$4"' \
    || { g45=FAIL; printf '    sigver() no longer judges the status stream through sigok\n' >&2; }
  printf '%s' "$body45" | has 'REVOKED key' \
    || { g45=FAIL; printf '    sigver() no longer refuses a revoked key outright\n' >&2; }
  local n45; n45=$(fnbody fetch | grep -c 'expired-ok' || true)
  [ "${n45:-0}" -eq 1 ] \
    || { g45=FAIL; printf '    %s source(s) waive key expiry -- exactly 1 (lvm2) is accounted for\n' "${n45:-0}" >&2; }
  # and that waiver has a review-by date that has not passed. checked HERE and
  # not only in sigver, because gates run on every host while fetch runs on a
  # build -- a lapsed waiver should be loud before anyone spends an hour.
  local w45; w45=$(fnbody fetch \
                   | sed -n 's/.*expired-ok:\([0-9-]*\).*/\1/p' | head -1)
  if [ -z "$w45" ]; then
    g45=FAIL; printf '    the expiry waiver carries no review-by date -- a waiver with no end\n' >&2
    printf '    is one nobody looks at again\n' >&2
  elif [ "$(date -u +%Y-%m-%d)" \> "$w45" ]; then
    g45=FAIL; printf '    the expiry waiver lapsed on %s -- re-anchor lvm2 or renew it on purpose\n' "$w45" >&2
  fi
  # the waived source carries a second, live anchor. a waiver plus one dead key
  # is one anchor; a waiver plus a corroborating digest from an independent
  # distributor is two, and this is the line that keeps the second one wired up.
  fnbody fetch | has '^  corrob ' \
    || { g45=FAIL; printf '    fetch() no longer corroborates the expiry-waived source against\n' >&2
         printf '    an independent distributor -- that leaves one dead key holding it up\n' >&2; }
  g "G45 expired or revoked source key refused" "$g45"

  # G53 -- the signature tier has to have RUN. sigver() falls back to "digest
  # pin only" when gpg is absent, announcing it in one printf inside an hour
  # of build log, and G45's live-gpg half above is itself wrapped in a
  # command -v gpg, so on a gpg-less host it prints to stderr and still says
  # ok. a build that checked zero maintainer signatures reported every gate
  # green. the repro container never named gnupg either, which made the
  # canonical reproducible build the likeliest one of all to verify nothing.
  local g53=ok n53
  n53=$(fnbody fetch | grep -c '^  sigver ' || true)
  command -v gpg >/dev/null 2>&1 \
    || { g53=FAIL; printf '    gpg is not installed -- every maintainer signature was skipped, not checked\n' >&2; }
  [ "${n53:-0}" -ge 6 ] \
    || { g53=FAIL; printf '    %s sigver() calls in fetch() -- a signed upstream stopped being checked\n' "${n53:-0}" >&2; }
  g "G53 maintainer signatures were checked ($n53 signed upstreams)" "$g53"

  # G36 -- learn REACHES its first prompt on a terminal that answers nothing.
  # parsing is not running: the unicode probe asks the terminal a question, and
  # a shell whose read ignores VMIN/VTIME waits for a newline the reply never
  # sends. that hung learn before it drew anything, on the shipped ash, while
  # the host's shell honoured the same stty and made it look fine. G35 cannot
  # see it and no test that is not a terminal can either -- so open one, stay
  # silent, and require an exit.
  local g36=FAIL
  python3 - "$bb35" <<'G36' >/dev/null 2>&1 && g36=ok
import os, pty, select, sys, time
bb = sys.argv[1]
env = dict(os.environ, LEARN_ROOT=os.getcwd() + "/learn", TERM="xterm-256color")
env.pop("COLUMNS", None); env.pop("LINES", None)
pid, fd = pty.fork()
if pid == 0:
    os.execve(bb, [bb, "ash", "learn/learn", "ref", "cut"], env)
end = time.time() + 10
while time.time() < end:                  # answer nothing, ever
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: os.read(fd, 65536)           # drain, so a full pty cannot block it
        except OSError: pass
    try:
        if os.waitpid(pid, os.WNOHANG)[0]: sys.exit(0)
    except ChildProcessError: sys.exit(0)
os.kill(pid, 9); sys.exit(1)
G36
  g "G36 learn starts on a terminal that answers nothing" "$g36"

  # G37 -- the between-cards pause takes ONE keypress and gives the terminal
  # back. it reads a bare key under -icanon, the same corner that hung the
  # UTF-8 probe: busybox ash ignores VMIN/VTIME, so a read shaped even slightly
  # wrong blocks for a newline that never comes. every card screen sits behind
  # this, so a hang here is a hang everywhere.
  local g37=FAIL
  python3 - "$bb35" <<'G37' >/dev/null 2>&1 && g37=ok
import os, pty, select, sys, time
bb = sys.argv[1]
env = dict(os.environ, LEARN_ROOT=os.getcwd() + "/learn", TERM="xterm-256color")
sh = 'ROOT="$LEARN_ROOT"; . "$ROOT/lib/ui"; pause_card; echo "RC=$?"'
for key, want in ((b"\r", "RC=0"), (b"q", "RC=2"), (b"\x04", "RC=2")):
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(bb, [bb, "ash", "-c", sh], env)
    time.sleep(1)                          # let the prompt settle, then one key
    os.write(fd, key)
    out, end = b"", time.time() + 10
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: c = os.read(fd, 65536)
            except OSError: break
            if not c: break
            out += c
        try:
            if os.waitpid(pid, os.WNOHANG)[0]: break
        except ChildProcessError: break
    else:
        os.kill(pid, 9); sys.exit(1)       # never returned: it hung
    if want.encode() not in out: sys.exit(1)
sys.exit(0)
G37
  g "G37 the card pause answers one keypress" "$g37"

  # G17 -- stick.img is coherent with the pinned artifacts: right PARTUUIDs, p2
  # byte-equal to xos.img, ESP carries the exact signed UKI.
  if [ -f stick.img ]; then
    local s_ok=1 j esp_uki
    esp_uki=$(mktemp)
    j=$(sfdisk -J stick.img 2>/dev/null || true)
    printf '%s' "$j" | grep -qi "\"$PU_ESP\""  || { s_ok=0; printf '    esp PARTUUID absent\n' >&2; }
    printf '%s' "$j" | grep -qi "\"$PU_ROOT\"" || { s_ok=0; printf '    root PARTUUID absent\n' >&2; }
    cmp -s -n "$(stat -c%s xos.img)" xos.img <(dd if=stick.img bs=1M skip=$((1 + STICK_ESP_MIB)) count=$(( ($(stat -c%s xos.img) + 1048575) / 1048576 )) status=none 2>/dev/null) \
      || { s_ok=0; printf '    p2 region != xos.img\n' >&2; }
    mcopy -o -n -i stick.img@@1M ::/EFI/BOOT/BOOTX64.EFI "$esp_uki" 2>/dev/null \
      && cmp -s xos-signed.efi "$esp_uki" || { s_ok=0; printf '    ESP UKI != xos-signed.efi\n' >&2; }
    rm -f "$esp_uki"
    g "G17 stick.img coherent with artifacts" "$([ "$s_ok" -eq 1 ] && echo ok || echo FAIL)"
  else
    g "G17 stick.img coherent" FAIL
    printf '    no stick.img -- run ./build.sh stick\n' >&2
  fi

  # G19 -- the whole bootable system fits the size claim, not just the disk
  # image. the UKI (kernel + cmdline) lives on the ESP and was never gated.
  if [ -f xos-signed.efi ]; then
    local whole; whole=$(( $(stat -c%s xos-signed.efi) + $(stat -c%s xos.img) ))
    g "G19 UKI + image <= $IMAGE_MAX ($whole)" "$([ "$whole" -le "$IMAGE_MAX" ] && echo ok || echo FAIL)"
  else
    g "G19 UKI + image size" FAIL
    printf '    no xos-signed.efi -- run ./build.sh uki\n' >&2
  fi

  # G23 -- exactly one shell, by construction: every executable in the image
  # is busybox, a busybox link, a dropbearmulti link, or a name in EXTRA_BINS.
  # the old check was a list of six shell NAMES in two directories -- the same
  # blocklist-of-past-mistakes the pre-commit hook explains it stopped using.
  # a shell shipped as /bin/rc, or bash under a local prefix, passed it. an
  # undeclared executable of any kind fails this one.
  local sh_ok=1 undecl=0 x base
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    base=$(basename "$x")
    case "$base" in busybox|dropbearmulti) continue ;; esac
    case " $EXTRA_BINS " in *" $base "*) continue ;; esac
    # a first-party script the manifest declares (init, the dhcp hook)
    grep -qxF -- "${x#root/}" manifest && continue
    if [ -L "$x" ]; then
      # a link is judged by its target: the applet links point at busybox
      # or dropbearmulti; /etc/resolv.conf and /run point into the tmpfs
      # (nothing executable lives there). anything else is an executable
      # under a name nobody declared.
      case "$(readlink "$x")" in busybox|dropbearmulti|/tmp/*) continue ;; esac
    fi
    undecl=$((undecl+1)); printf '    undeclared executable in image: %s\n' "$x" >&2
  done <<< "$(find root \( -type f -o -type l \) -perm -0100 2>/dev/null)"
  [ "$undecl" -eq 0 ] || sh_ok=0
  readlink root/bin/sh 2>/dev/null | grep -qx busybox \
    || { sh_ok=0; printf '    /bin/sh is not busybox\n' >&2; }
  g "G23 exactly one shell ($undecl undeclared executables)" "$([ "$sh_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G24 -- learn documents the system that actually ships, in both directions,
  # and the applet list is what was asked for. the third check closes a real
  # gap: rootfs() symlinks whatever `busybox --list` reports, so an applet
  # dropped by oldconfig (unmet dep, typo) shipped silently -- manifest names
  # only a handful of applets, so G12 never saw it. same silent-shrink failure
  # this repo already learned about with components and with artifact names.
  local c_ok=1 want_ap have_ap miss_ref miss_cmd miss_ap
  want_ap=$(grep -v '^[[:space:]]*#' busybox.config.applets | tr ' ' '\n' | grep -v '^$' | sort -u)
  have_ap=$(./busybox --list 2>/dev/null | sort -u)
  # two names in the config list are not applet names and never appear in
  # --list: CONFIG_TEST1 builds the applet called '[', and 'busybox' is the
  # binary itself. everything else missing is a real silent shrink.
  miss_ap=$(comm -23 <(printf '%s\n' "$want_ap") <(printf '%s\n' "$have_ap") \
    | grep -vxE 'test1|busybox' | grep -c . || true)
  [ "${miss_ap:-0}" -eq 0 ] || { c_ok=0; printf '    %s requested applet(s) did not build\n' "$miss_ap" >&2; }
  # shell builtins are part of the surface but never appear in --list. verify
  # each declared one really IS a builtin of the ash THIS build produced, so the
  # list cannot drift into fiction.
  local builtins bi_bad=0 b
  builtins=$(grep -v '^[[:space:]]*#' learn/builtins | tr ' ' '\n' | grep -v '^$' | sort -u)
  for b in $builtins; do
    printf 'type %s\n' "$b" | ./busybox ash 2>&1 | has builtin \
      || { bi_bad=$((bi_bad + 1)); printf '    %s is not a builtin of the built ash\n' "$b" >&2; }
  done
  [ "$bi_bad" -eq 0 ] || c_ok=0
  # xos's own verbs are part of the surface too -- the one-word ways in (irc,
  # scrub, recon_accept) that are shell functions in /etc/shrc, so they appear
  # in neither --list nor on disk as a file. same rule as the builtins above:
  # each declared verb must really BE a function of the /etc/shrc this build
  # ships, so the list cannot drift into fiction. root/etc/shrc is already on
  # disk here -- G46 below reads it the same way.
  local verbs vb_bad=0 v
  verbs=$(grep -v '^[[:space:]]*#' learn/verbs | tr ' ' '\n' | grep -v '^$' | sort -u)
  for v in $verbs; do
    grep -qE "^$v\(\)" root/etc/shrc 2>/dev/null \
      || { vb_bad=$((vb_bad + 1)); printf '    %s is not a function of the shipped /etc/shrc\n' "$v" >&2; }
  done
  [ "$vb_bad" -eq 0 ] || c_ok=0
  # every shipped command has a ref ...
  # "." is a real builtin and can never be a filename -- that name always means
  # the directory itself -- so its page is stored as "dot" and learn translates.
  refname() { [ "$1" = "." ] && echo dot || echo "$1"; }
  miss_ref=$( { printf '%s\n' "$have_ap"; printf '%s\n' "$builtins"; printf '%s\n' "$verbs"; printf '%s\n' $EXTRA_BINS; } | sort -u | while read -r c; do
      [ -n "$c" ] && [ ! -f "learn/ref/$(refname "$c")" ] && echo "$c"; done | grep -c . || true)
  [ "${miss_ref:-0}" -eq 0 ] || { c_ok=0; printf '    %s shipped command(s) undocumented\n' "$miss_ref" >&2; }
  # ... and every ref is a shipped command
  miss_cmd=$(ls -1 learn/ref 2>/dev/null | sed 's/^dot$/./' | while read -r r; do
      # -F: command names are literals. '[' is a real applet and an invalid regex.
      printf '%s\n' "$have_ap" | grep -qxF "$r" && continue
      printf '%s\n' "$builtins" | grep -qxF "$r" && continue
      printf '%s\n' "$verbs" | grep -qxF "$r" && continue
      case " $EXTRA_BINS " in *" $r "*) continue ;; esac
      echo "$r"; done | grep -c . || true)
  [ "${miss_cmd:-0}" -eq 0 ] || { c_ok=0; printf '    %s ref(s) document nothing shipped\n' "$miss_cmd" >&2; }
  # ... and no page is still the stub seed() leaves for a hand to finish. the
  # seed comment promised this gate would name them; it never did.
  local stubs24
  stubs24=$(grep -lE '^TODO: .*by hand\.$' learn/ref/* 2>/dev/null | sed 's|^learn/ref/||' | tr '\n' ' ')
  [ -z "$stubs24" ] || { c_ok=0; printf '    seeded stub(s) never written by hand: %s\n' "$stubs24" >&2; }
  # ... and every ref still matches the binary's own --help flag for flag.
  # seed() never overwrites a page, so without this a busybox bump that added
  # a flag to an existing applet was invisible to G26 -- the claim that a bump
  # stops the build held only for brand-new applets.
  local rc_out
  rc_out=$(PATH="$PWD/root/bin:$PATH" LEARN_ROOT="$PWD/learn" NO_COLOR=1 ./busybox ash learn/learn refcheck 2>&1) \
    || { c_ok=0; printf '%s\n' "$rc_out" | grep STALE | sed 's/^/    /' >&2; }
  g "G24 learn corpus covers the surface exactly ($(printf '%s' "$rc_out" | sed -n 's/^learn: refcheck: //p' | tail -1))" "$([ "$c_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G25/G26 -- the curriculum checks itself, using the shell that will run it.
  #
  # these used to be two hundred lines of host awk that re-implemented learn's
  # own parser: a second answer checker, a second flag table, a second notion
  # of what "documented" means. two implementations of one rule drift, and the
  # copy that runs at build time is the one nobody exercises by hand.
  #
  # so the build now runs the real thing, under the real busybox, against the
  # real corpus. learn selftest renders every question, feeds each of its own
  # answers back through the grader, and EXECUTES them against the sandbox --
  # so a question that teaches a flag this build compiled out fails here.
  # busybox decides what to be from argv[0], so `busybox -c ...` is not a
  # shell -- it needs a name. give it one that lives for the length of the run.
  # PATH is root/bin and NOTHING ELSE -- the image's own applet links, with no
  # host fallback. two reasons. a command an answer runs would otherwise
  # resolve to the HOST's GNU tools and a busybox flag difference sails
  # through green. and learn's own code is held to the same closed surface the
  # corpus is: it called `fold`, which xos does not ship, and the GNU one on
  # PATH answered for it -- so every gate passed while on the image every
  # level brief printed nothing. a fallback is a place for that to hide.
  local st_out st_ok=1 lsh
  lsh=$(mktemp -d); ln -sf "$PWD/busybox" "$lsh/sh"
  st_out=$(PATH="$PWD/root/bin" LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           ./busybox ash learn/learn selftest 2>&1) || st_ok=0
  printf '%s\n' "$st_out" | grep -v '^learn: ' >&2 || true
  g "G25 $(printf '%s' "$st_out" | sed -n 's/^learn: //p' | tail -1)" \
    "$([ "$st_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G26 -- every documented flag is taught or explicitly retired in learn/skip.
  # this is the gate the whole "we teach everything" claim rests on, and it is
  # only checkable because the program surface is fixed at build time. a
  # busybox bump that adds a flag lands in neither set and stops the build.
  local cv_out cv_ok=1
  cv_out=$(PATH="$PWD/root/bin:$PATH" LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           ./busybox ash learn/learn coverage 2>&1) || cv_ok=0
  local cv_t cv_s cv_u
  cv_t=$(printf '%s\n' "$cv_out" | awk '$1 == "taught"   {print $2}')
  cv_s=$(printf '%s\n' "$cv_out" | awk '$1 == "skipped"  {print $2}')
  cv_u=$(printf '%s\n' "$cv_out" | awk '$1 == "untaught" {print $2}')
  [ "$cv_ok" -eq 1 ] || printf '    %s items are neither taught nor listed in learn/skip\n' "$cv_u" >&2
  g "G26 curriculum covers the surface (${cv_t:-0} taught, ${cv_s:-0} retired, ${cv_u:-?} open)" \
    "$([ "$cv_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G27 -- optimal order, enforced. a level may only use commands that it or an
  # earlier level introduces. learn's own header claims it teaches "in order";
  # this is what stops that being a claim nobody checks. it caught six real
  # violations the first time it ran -- awk and cut used three levels before
  # they were taught, and printf used in four.
  local or_out or_ok=1
  or_out=$(LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           ./busybox ash learn/learn order 2>&1) || or_ok=0
  printf '%s\n' "$or_out" | grep -v '^learn: ' >&2 || true
  g "G27 $(printf '%s' "$or_out" | sed -n 's/^learn: //p' | tail -1)" \
    "$([ "$or_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G62 -- learn/bashisms claims, row by row, that a construct works in bash
  # and does not work here. every other table in the corpus is checkable by
  # running the lesson; this one is not, because the shell it is about is the
  # one thing xos refuses to ship. so the gate runs each row's probe twice --
  # once under the busybox this build just produced, once under the host's
  # bash -- and demands they disagree, in exit status or in output.
  #
  # it is not pedantry. `<<<` was in the first draft of that table on the
  # strength of a comment in learn/syntax saying ash has no here-strings. this
  # ash runs `cat <<< hi` and prints hi. a row asserting otherwise would have
  # told a learner to stop writing a line that works -- which is worse than
  # teaching nothing, and is exactly the class of error no amount of reading
  # catches.
  local bz_bad=0 bz_n=0 bz_l bz_p bz_ao bz_ar bz_bo bz_br
  while IFS=$'\t' read -r bz_l _ bz_p _; do
    case "$bz_l" in ''|'#'*) continue ;; esac
    bz_n=$((bz_n + 1))
    # `x=$(cmd)` takes the status of cmd, so under set -e a probe that FAILS
    # kills the whole gate run -- and failing under this ash is the normal case
    # here, it is what makes a row a bashism. the first row (`for (( ))`) exits
    # 2, so this gate aborted gates() before the roster check could notice and
    # took every gate after it down with it, printing nothing at all. the
    # `&& x=0 || x=$?` form keeps the status without ever being a failed
    # command itself.
    bz_ao=$(PATH="$PWD/root/bin" timeout 5 ./busybox ash -c "$bz_p" </dev/null 2>&1) \
      && bz_ar=0 || bz_ar=$?
    bz_bo=$(timeout 5 bash -c "$bz_p" </dev/null 2>&1) && bz_br=0 || bz_br=$?
    if [ "$bz_ar" = "$bz_br" ] && [ "$bz_ao" = "$bz_bo" ]; then
      printf '    %s: this shell runs it exactly as bash does -- not a bashism\n' "$bz_l" >&2
      bz_bad=$((bz_bad + 1))
    fi
  done < learn/bashisms
  [ "$bz_n" -gt 0 ] || { printf '    learn/bashisms has no rows\n' >&2; bz_bad=$((bz_bad + 1)); }
  g "G62 learn/bashisms rows this shell really lacks ($bz_n checked)" \
    "$([ "$bz_bad" -eq 0 ] && echo ok || echo FAIL)"

  # G63 -- composition, enforced. every command here was taught one at a time
  # and then, almost nowhere, asked for together: nineteen of thirty levels had
  # no answer with a pipe in it, and the one place composition WAS required --
  # the gauntlet -- is locked until every level is held. so the skill the whole
  # thing exists to build was the skill the levels never asked for. learn/compose
  # is the ledger: a floor per level, or an exemption with one of three reasons.
  # the floor is a ratchet, so lowering one is a diff someone has to write.
  local cp_out cp_ok=1
  cp_out=$(LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           ./busybox ash learn/learn compose 2>&1) || cp_ok=0
  printf '%s\n' "$cp_out" | grep -v '^learn: ' >&2 || true
  g "G63 $(printf '%s' "$cp_out" | sed -n 's/^learn: //p' | tail -1)" \
    "$([ "$cp_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G50 -- every level's brief fits the screen it is printed on. the brief is
  # the level's teaching page and it is shown once, full-screen, before the
  # first card: a brief taller than the terminal scrolls its own first
  # paragraph away before the learner reads a word of it.
  #
  # the floor is the SMALLEST screen xos drives, which is the serial line, not
  # the console in front of you: init pins every ttyS/ttyUSB to `rows 24 cols
  # 80` because a serial line reports no window size. 24 rows less the header
  # (3) and the pause (2) is 19 rendered lines at learn's own 76-column wrap.
  # it read 80x25 -- the fbcon -- for as long as this gate existed, so two
  # briefs sat at 20 and scrolled their own first line away on the one
  # terminal the whole mono tier is drawn for. a level with no brief at all is
  # the same failure, earlier.
  #
  # the backticks that mark a literal come out first: they are one byte each in
  # the source and zero columns on the screen -- learn's wrap() skips them -- so
  # counting them here would measure a page the image never draws, and would
  # make marking a paragraph a typographic decision.
  local br_ok=1 br_f br_n br_worst=0
  for br_f in learn/levels/*; do
    br_n=$(sed -n 's/^brief: \{0,1\}//p' "$br_f" | tr -d '`' | fold -s -w 76 | wc -l)
    [ "$br_n" -gt "$br_worst" ] && br_worst=$br_n
    if [ "$br_n" -eq 0 ]; then
      br_ok=0; printf '    %s has no brief\n' "${br_f##*/}" >&2
    elif [ "$br_n" -gt 19 ]; then
      br_ok=0; printf '    %s brief is %s lines, 19 fit an 80x24 serial screen\n' "${br_f##*/}" "$br_n" >&2
    fi
  done
  g "G50 every level brief fits one screen (worst ${br_worst}/19 lines)" \
    "$([ "$br_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G51 -- the loop back from the real prompt. a failed command at /bin/sh is
  # the one thing learn cannot generate for itself, and the only place it is
  # readable is the instant the next prompt is drawn -- which means this whole
  # path depends on a busybox config symbol (ASH_EXPAND_PRMT), a shell
  # function in /etc/shrc, and a terminal. no test that is not a terminal can
  # see any of it: with prompt expansion off, $PS1 is simply printed and the
  # hook never runs, silently, with every other gate still green.
  #
  # it also gates the privacy claim, which is the reason the feature is
  # off by default: a name the image does not teach must never be written.
  # so the session below fails a taught command, a command that does not
  # exist, and something that is nobody's command at all -- and the queue
  # afterwards must hold the first and nothing else.
  local g51=FAIL
  python3 - "$bb35" <<'G51' >/dev/null 2>&1 && g51=ok
import os, pty, select, sys, time
bb = sys.argv[1]
root = os.getcwd()
home = os.path.join(root, "build/g51home")
q = os.path.join(home, ".local/state/learn/fumbles")
os.makedirs(os.path.dirname(q), exist_ok=True)
open(q, "w").close()
env = dict(os.environ, HOME=home, ENV=root + "/root/etc/shrc",
           LEARN_ROOT=root + "/learn", TERM="xterm", PS1="", PS1_CMD="")
env.pop("XDG_STATE_HOME", None); env.pop("HISTFILE", None)
pid, fd = pty.fork()
if pid == 0:
    os.chdir(home)
    os.execve(bb, [bb, "ash", "-i"], env)
lines = b"cut -Z /dev/null\nnosuchcommandatall\nhunter2\ngrep zzz /dev/null\ntrue\nexit\n"
os.write(fd, lines)
end = time.time() + 20
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: os.read(fd, 65536)
        except OSError: break
    try:
        if os.waitpid(pid, os.WNOHANG)[0]: break
    except ChildProcessError: break
else:
    os.kill(pid, 9); sys.exit(1)
got = [l.strip() for l in open(q).read().split("\n") if l.strip()]
sys.exit(0 if got == ["cut"] else 1)
G51
  rm -rf build/g51home
  g "G51 a failed command at the real prompt reaches learn, and only a name" "$g51"

  # G52 -- provenance. vouch() is the whole implementation and this is only the
  # gate caller, so the subcommand a stranger runs and the gate the build runs
  # cannot drift. unverified maps to SKIP, never ok: no ssh-keygen here, or a
  # clone too shallow to hold the epoch, is a check that did not run.
  # `|| rc=$?` and not a bare call: under set -e a non-zero vouch aborts the
  # whole run right here, so the SKIP and FAIL arms below -- and every gate
  # after them -- were unreachable by the only exit codes that select them.
  local g52 g52rc=0; vouch >/dev/null || g52rc=$?
  case "$g52rc" in 0) g52=ok ;; 2) g52=SKIP ;; *) g52=FAIL ;; esac
  g "G52 every commit since the epoch is signed by the pinned key" "$g52"

  # G29 -- the challenge track holds its shape. at least twelve stages, every
  # stage a real chain, the difficulty never falling and ending in the deep
  # end, and no stage claiming a lvl: whose commands the levels have not
  # taught by then. this is what makes "a challenge track that stops getting
  # harder" a build failure instead of a slow disappointment.
  local ch_out ch_ok=1
  ch_out=$(LEARN_ROOT="$PWD/learn" LEARN_SH="$lsh/sh" \
           XDG_STATE_HOME="$lsh/state" HOME="$lsh/home" NO_COLOR=1 \
           PATH="$PWD/root/bin:$PATH" \
           ./busybox ash learn/learn challenge check 2>&1) || ch_ok=0
  printf '%s\n' "$ch_out" | grep -v '^learn: ' >&2 || true
  g "G29 $(printf '%s' "$ch_out" | sed -n 's/^learn: //p' | tail -1)" \
    "$([ "$ch_ok" -eq 1 ] && echo ok || echo FAIL)"

  # not a gate: hint coverage and wording variety are judgment calls, and a
  # hard gate on them would breed filler. printed here so drift is visible.
  LEARN_ROOT="$PWD/learn" ./busybox ash learn/learn lint 2>/dev/null \
    | sed -n 's/^learn: /  /p' || true

  rm -rf "$lsh"

  # G28 -- the bzImage on disk was built from the kernel.config on disk.
  #
  # G14 reads kernel.config and confirms the hardening lines are present. it
  # never looks at the binary, so a bzImage built days before kernel.config
  # last changed passes it while failing the boot-time asserts: the config
  # promised lockdown and no vsyscall page, the running kernel disagreed, and
  # nothing in the build noticed. that cost three red self-test sections and
  # an afternoon chasing them in the wrong place.
  local kb_ok=1 kb_want kb_have kx_want kx_have
  if [ ! -f bzImage ] || [ ! -f bzImage.config.sha256 ]; then
    kb_ok=0; printf '    no bzImage or no config stamp -- run ./build.sh kernel\n' >&2
  else
    kb_want=$(sha256sum < kernel.config | awk '{print $1}')
    kb_have=$(awk '/^source/ {print $2}' bzImage.config.sha256)
    [ "$kb_want" = "$kb_have" ] || {
      kb_ok=0
      printf '    kernel.config has changed since bzImage was built -- rebuild the kernel\n' >&2; }
    # the expanded line is the digest of what was really compiled. it was
    # written and never read: a `scripts/config --enable` on the tree's own
    # .config followed by `make` left kernel.config untouched and this green.
    kx_want=$(sha256sum < "src/linux-$KVER/.config" 2>/dev/null | awk '{print $1}')
    kx_have=$(awk '/^expanded/ {print $2}' bzImage.config.sha256)
    [ -n "$kx_want" ] && [ "$kx_want" = "$kx_have" ] || {
      kb_ok=0
      printf '    the kernel tree .config is not the one bzImage was compiled from -- rebuild the kernel\n' >&2; }
  fi
  g "G28 bzImage was built from this kernel.config" \
    "$([ "$kb_ok" -eq 1 ] && echo ok || echo FAIL)"

  # G30 -- SOURCE_DATE_EPOCH doubles as xos.epoch, the security floor init
  # refuses to boot before. it is a pinned literal (never build-time `date
  # +%s` -- that would break G13 reproducibility), so nothing else stops it
  # going stale and quietly re-opening the window to roll a clock back onto
  # an expired or revoked cert. 90 days is tunable; it just has to be shorter
  # than "nobody noticed".
  local floor_age floor_max=7776000
  floor_age=$(( $(date +%s) - SOURCE_DATE_EPOCH ))
  g "G30 clock floor fresh (epoch $((floor_age / 86400)) days old, max $((floor_max / 86400)))" \
    "$([ "$floor_age" -le "$floor_max" ] && echo ok || echo FAIL)"

  # G31 -- a leaked test build must never pass as production. XOS_TEST=1
  # appends these to cmdline.txt (verity()); selftest.sh restores a clean
  # build afterward, but a hard gate here means that restore is enforced,
  # not just intended.
  local tf=0 tfword
  for tfword in xos.test xos.teststate xos.testwg xos.testtether xos.testclone; do
    grep -qF "$tfword" cmdline.txt && tf=$((tf+1))
  done
  g "G31 no test flags on production cmdline" "$([ "$tf" -eq 0 ] && echo ok || echo FAIL)"

  # G46 -- a carried patch is the easiest thing in this repo to lose: src/ is
  # not in git, the patch applies to a tree nobody reads afterwards, and a
  # stock binary looks exactly like a patched one. it was lost once already,
  # to a patch(1) idempotence check that answered "already applied" about a
  # tree it had never touched. so: every patch is stamped in the tree it
  # belongs to, and the one effect it exists for is proved in the binary and
  # in the shell profile that drives it.
  local g46=ok p pn
  for p in patches/busybox/*.patch; do
    [ -f "$p" ] || continue
    pn=${p##*/}
    [ -f "src/busybox-$BBVER/.xos-patched/$pn" ] \
      || { g46=FAIL; printf '    busybox patch not applied: %s\n' "$pn" >&2; }
  done
  strings busybox 2>/dev/null | has '^PS1_CMD$' \
    || { g46=FAIL; printf '    built busybox does not look up PS1_CMD\n' >&2; }
  grep -q 'PS1_CMD=' root/etc/shrc 2>/dev/null \
    || { g46=FAIL; printf '    /etc/shrc never sets PS1_CMD\n' >&2; }
  # 0002: fdisk's flag list says -t, the spelling its parser takes
  ./busybox fdisk --help 2>&1 | grep -q '^[[:space:]]*-t PARTTYPE' \
    && ! ./busybox fdisk --help 2>&1 | grep -q '^[[:space:]]*-T PARTTYPE' \
    || { g46=FAIL; printf '    built fdisk --help still names -T, a flag it rejects\n' >&2; }
  g "G46 carried patches applied and in effect" "$g46"

  # G47 -- the arsenal is not the signed image, but README calls it "built and
  # pinned", and a pin is only a pin if it is checked BEFORE the build. the
  # arsenal.lock is written AFTER, and drifts per build for the tools that
  # embed a build-id, so it can never gate an input. arsenal.pins can: every
  # C tool build-arsenal-c.sh fetches must resolve to a line in it, and no
  # wget/curl/git-clone may sit outside the two helpers that enforce it -- the
  # same "one guard, nothing bypasses it" shape as G39. socat was fetched over
  # cleartext http with no digest at all before this; frotz cloned an unpinned
  # branch head, new code every build.
  local g47=ok acs=arsenal/build-arsenal-c.sh pins=arsenal/arsenal.pins raw t body
  if [ -f "$acs" ] && [ -f "$pins" ]; then
    body=$(awk '/^fetch\(\) \{/{s=1} /^clone_pinned\(\) \{/{s=1} s&&/^}/{s=0;next} !s' "$acs" \
           | grep -vE '^[[:space:]]*#')
    raw=$(printf '%s\n' "$body" | grep -nE '(^[[:space:]]*|[;&|(][[:space:]]*)(wget|curl)[[:space:]]|git[[:space:]]+clone' || true)
    [ -z "$raw" ] || { g47=FAIL; printf '    fetch outside the pinned helpers:\n%s\n' "$raw" >&2; }
    for t in $(grep -vE '^[[:space:]]*#' "$acs" | grep -oE '(fetch|clone_pinned) [a-z][a-z0-9]*' | awk '{print $2}' | sort -u); do
      grep -qE "^${t}[[:space:]]+(url|git)[[:space:]]" "$pins" \
        || { g47=FAIL; printf '    %s fetched but not pinned in arsenal.pins\n' "$t" >&2; }
    done
  else
    g47=FAIL; printf '    arsenal build script or pins file missing (%s / %s)\n' "$acs" "$pins" >&2
  fi
  g "G47 arsenal sources pinned before build" "$g47"

  # G54 -- selftest.sh keeps the same guard this runner does: a hand-written
  # EXPECTED_SECTIONS it compares its own run against. that number is the one
  # thing in it nothing else checks, and it rots exactly the way EXPECTED_GATES
  # did -- silently, until a truncated run reads as a short but clean one. it
  # cannot derive the number from itself (that would go green on a deleted
  # section, the very thing it exists to catch), so cross-check it from OUT
  # HERE: the declaration against the sections actually written in the file.
  local g54=ok want54 have54
  want54=$(sed -n 's/^EXPECTED_SECTIONS=\([0-9][0-9]*\).*/\1/p' selftest.sh | head -1)
  have54=$(grep -c '^section "A' selftest.sh || true)
  if [ -z "$want54" ]; then
    g54=FAIL; printf '    selftest.sh declares no EXPECTED_SECTIONS\n' >&2
  elif [ "${have54:-0}" -eq 0 ]; then
    g54=FAIL; printf '    selftest.sh has no `section "A...` lines -- the count would be vacuous\n' >&2
  elif [ "$want54" -ne "$have54" ]; then
    g54=FAIL
    printf '    selftest.sh declares %s sections but writes %s\n' "$want54" "$have54" >&2
  fi
  g "G54 selftest section count declared ($have54)" "$g54"

  # G55/G56 -- the published claim, checked the way a stranger checks it. these
  # run the same two functions ./build.sh verify runs, so the repo cannot ship
  # a chain or a signature that its own verifier would reject. output is
  # captured and only shown when something is wrong: a green gate line is the
  # whole report a reader wants here.
  local g55=ok g56=ok out55 out56
  out55=$(verify_log 2>&1) || { g55=FAIL; printf '%s\n' "$out55" >&2; }
  g "G55 attestation chain intact" "$g55"
  out56=$(verify_sigs 2>&1) || { g56=FAIL; printf '%s\n' "$out56" >&2; }
  g "G56 attestations signed by a pinned key" "$g56"

  # G57 -- and the check above is worth nothing if it cannot fail. four
  # rewrites, four refusals, on a synthetic chain.
  local g57=ok
  log_selftest || g57=FAIL
  g "G57 a rewritten chain is refused" "$g57"

  # G58 -- structural, in the G45/G47 mould. blob()/blobver() only help while
  # uki() still calls them, and each is one line someone debugging a fetch
  # would comment out in thirty seconds. so check the SHAPE: blobs.sha256 names
  # the stub AND the package it is cut from, and uki()'s body runs blob, then
  # blobver, before it reaches ukify. checking the digest here instead would be
  # the wrong gate -- gates() runs after the image is already built and signed.
  local g58=ok body58
  body58=$(fnbody uki)
  grep -qE -- "[[:space:]]${STUB##*/}\$" blobs.sha256 2>/dev/null \
    || { g58=FAIL; printf '    the EFI stub is not pinned in blobs.sha256\n' >&2; }
  [ "$(blob_pkg 2>/dev/null | grep -c .)" -eq 1 ] \
    || { g58=FAIL; printf '    blobs.sha256 does not name exactly one package to cut the stub from\n' >&2; }
  # anchored: a commented-out call, or the word appearing in prose, must not
  # satisfy this. it has to be a statement that actually runs.
  printf '%s\n' "$body58" | awk '/^[[:space:]]*blob([[:space:]]|$)/{f=NR} /^[[:space:]]*blobver([[:space:]]|$)/{b=NR} /ukify[[:space:]]/{u=NR} END{exit !(f && b && u && f < b && b < u)}' \
    || { g58=FAIL; printf '    uki() no longer runs blob then blobver before ukify -- the signed\n' >&2
         printf '    image would wrap an unfetched or unchecked blob\n' >&2; }
  g "G58 pinned blobs fetched and checked before they are signed" "$g58"

  # G59 -- the container's packages by content, not by the path they came from.
  local g59=ok
  toolver || g59=FAIL
  g "G59 container toolchain pinned by bytes" "$g59"

  # G60 -- the trust surface, as data, checked against the tree. the same
  # function ci() runs, so a regression is named on the push that caused it.
  local g60=ok
  trustver || g60=FAIL
  g "G60 trust manifest accounts for the tree" "$g60"

  # G61 -- the books payload is the only thing this tree carries that comes
  # with TERMS. a wordlist and a man page have integrity and nothing else to
  # get wrong; a book can be redistributable, non-commercial, no-derivatives,
  # or not redistributable at all, and the difference is invisible in the
  # bytes. so the licence is a field -- and this is what keeps it a field
  # instead of a memory. every title build-books.sh fetches must carry a
  # 64-hex sha256 and a licence from the closed set below; no fetch may bypass
  # the pinned helper (the same rule G47 keeps for tools); and books.lock may
  # not name a sha the script does not pin, which is what a hand-edited
  # attestation looks like. the set is closed on purpose: a licence nobody
  # read is exactly what puts one of these on a stick it may not be on.
  local g61=ok bks=arsenal/build-books.sh blk=arsenal/books.lock b_raw b_body b_bad
  if [ -f "$bks" ]; then
    b_body=$(awk '/^BOOKS="$/{s=1;next} s&&/^"$/{s=0} s' "$bks" | grep -v '^$' || true)
    b_raw=$(awk '/^fetch\(\) \{/{s=1} s&&/^}/{s=0;next} !s' "$bks" \
            | grep -vE '^[[:space:]]*#' \
            | grep -nE '(^[[:space:]]*|[;&|(][[:space:]]*)(wget|curl)[[:space:]]|git[[:space:]]+clone' || true)
    [ -z "$b_raw" ] || { g61=FAIL; printf '    book fetched outside the pinned helper:\n%s\n' "$b_raw" >&2; }
    b_bad=$(printf '%s\n' "$b_body" | awk -F'\t' '
      BEGIN {
        n = split("CC-BY-4.0 CC-BY-SA-3.0 CC-BY-SA-4.0 CC-BY-NC-3.0 CC-BY-NC-4.0 \
                   CC-BY-NC-SA-3.0 CC-BY-NC-SA-4.0 CC-BY-NC-ND-3.0 CC-BY-NC-ND-4.0 \
                   CC0-1.0 MIT Apache-2.0 PSF-2.0 GFDL-1.3", a, /[ \t]+/)
        for (i = 1; i <= n; i++) ok[a[i]] = 1
        rows = 0
      }
      { rows++ }
      NF != 6 { printf "    %s: %d tab-separated fields, want 6\n", $1, NF; next }
      $4 !~ /^[0-9a-f][0-9a-f]*$/ || length($4) != 64 {
        printf "    %s: sha256 is not 64 hex digits\n", $1 }
      !($5 in ok) {
        printf "    %s: licence %s is not in the reviewed set\n", $1, ($5 == "" ? "<empty>" : $5) }
      END { if (rows < 1) print "    build-books.sh lists no books" }')
    [ -z "$b_bad" ] || { g61=FAIL; printf '%s\n' "$b_bad" >&2; }
    # the lock is an attestation of a staging run, so it may be OLDER than the
    # script and shorter than it. it may never be newer in content.
    if [ -f "$blk" ]; then
      b_bad=$(awk -v bks="$bks" '
        BEGIN { while ((getline l < bks) > 0) if (match(l, /\t[0-9a-f]{64}\t/))
                  pinned[substr(l, RSTART + 1, 64)] = 1 }
        /^#/ || /^$/ { next }
        !($3 in pinned) { printf "    books.lock claims %s at a sha build-books.sh does not pin\n", $1 }
      ' "$blk")
      [ -z "$b_bad" ] || { g61=FAIL; printf '%s\n' "$b_bad" >&2; }
    fi
  else
    g61=FAIL; printf '    %s is missing\n' "$bks" >&2
  fi
  g "G61 carried books pinned and licensed" "$g61"

  # G65 -- the same shape as G61, one gate later: the vector atlas is the
  # second payload on the XOS-KNOW stick with a provenance claim to check,
  # even though every layer here carries the same licence. a closed set of
  # one is still a closed set -- the day a non-public-domain layer gets added
  # by habit (copy a books.sh row, change five fields, forget the licence is
  # different this time) is exactly the day this earns its keep.
  local g65=ok mps=arsenal/build-maps.sh mlk=arsenal/maps.lock m_raw m_body m_bad
  if [ -f "$mps" ]; then
    m_body=$(awk '/^MAPS="$/{s=1;next} s&&/^"$/{s=0} s' "$mps" | grep -v '^$' || true)
    m_raw=$(awk '/^fetch\(\) \{/{s=1} s&&/^}/{s=0;next} !s' "$mps" \
            | grep -vE '^[[:space:]]*#' \
            | grep -nE '(^[[:space:]]*|[;&|(][[:space:]]*)(wget|curl)[[:space:]]|git[[:space:]]+clone' || true)
    [ -z "$m_raw" ] || { g65=FAIL; printf '    map layer fetched outside the pinned helper:\n%s\n' "$m_raw" >&2; }
    m_bad=$(printf '%s\n' "$m_body" | awk -F'\t' '
      BEGIN { ok["public-domain"] = 1; rows = 0 }
      { rows++ }
      NF != 6 { printf "    %s: %d tab-separated fields, want 6\n", $1, NF; next }
      $4 !~ /^[0-9a-f][0-9a-f]*$/ || length($4) != 64 {
        printf "    %s: sha256 is not 64 hex digits\n", $1 }
      !($5 in ok) {
        printf "    %s: licence %s is not in the reviewed set\n", $1, ($5 == "" ? "<empty>" : $5) }
      END { if (rows < 1) print "    build-maps.sh lists no layers" }')
    [ -z "$m_bad" ] || { g65=FAIL; printf '%s\n' "$m_bad" >&2; }
    # the lock is an attestation of a staging run, so it may be OLDER than the
    # script and shorter than it. it may never be newer in content.
    if [ -f "$mlk" ]; then
      m_bad=$(awk -v mps="$mps" '
        BEGIN { while ((getline l < mps) > 0) if (match(l, /\t[0-9a-f]{64}\t/))
                  pinned[substr(l, RSTART + 1, 64)] = 1 }
        /^#/ || /^$/ { next }
        !($3 in pinned) { printf "    maps.lock claims %s at a sha build-maps.sh does not pin\n", $1 }
      ' "$mlk")
      [ -z "$m_bad" ] || { g65=FAIL; printf '%s\n' "$m_bad" >&2; }
    fi
  else
    g65=FAIL; printf '    %s is missing\n' "$mps" >&2
  fi
  g "G65 carried maps pinned and licensed" "$g65"

  # G66 -- bump rewrites the two trust-critical pins (the version in build.sh and
  # the hash line in sources.sha256) with in-place surgery; a bug there ships a
  # wrong or misplaced pin silently. prove on a scratch copy that _bump_apply
  # touches EXACTLY the one dep (build.sh changes one line, sources.sha256 swaps
  # one line and leaves every other byte-identical) and that bumping back to the
  # old version restores the same content -- the property that makes the printed
  # `to undo: ./build.sh bump <name> <old>` a real undo. also prove bump verifies
  # the maintainer signature BEFORE it calls the surgery, so a bad signature
  # changes nothing.
  local g66=ok bd ov ot oh
  bd=$(mktemp -d) || { g66=FAIL; printf "    G66: mktemp failed\n" >&2; }
  if [ "$g66" = ok ]; then
    cp build.sh "$bd/b"; cp sources.sha256 "$bd/s"
    ov=$(sed -n 's/^CSVER="${CSVER:-\(.*\)}"/\1/p' build.sh | head -1)
    ot=$(awk '$2 ~ /^cryptsetup[-.]/ {print $2}' sources.sha256 | head -1)
    oh=$(awk '$2 ~ /^cryptsetup[-.]/ {print $1}' sources.sha256 | head -1)
    if [ -z "$ov" ] || [ -z "$ot" ] || [ -z "$oh" ]; then
      g66=FAIL; printf "    G66: could not read the cryptsetup pin/hash to test against\n" >&2
    else
      # forward: bump cryptsetup to a fake version with a fake hash
      BUMP_BUILD="$bd/b" BUMP_SRC="$bd/s" _bump_apply CSVER "$ov" 99.99.99 cryptsetup         0000000000000000000000000000000000000000000000000000000000000000         cryptsetup-99.99.99.tar.xz >/dev/null 2>&1 || { g66=FAIL; printf "    G66: forward _bump_apply failed\n" >&2; }
      # build.sh: exactly one line changed (the CSVER pin), nothing else
      local bdiff; bdiff=$(diff build.sh "$bd/b" | grep -c '^[<>]' || true)
      [ "$bdiff" = 2 ] || { g66=FAIL; printf "    G66: bump changed %s build.sh line-halves, want 2 (one dep)\n" "$bdiff" >&2; }
      grep -q '^CSVER="${CSVER:-99.99.99}"' "$bd/b" || { g66=FAIL; printf "    G66: the version pin was not retargeted\n" >&2; }
      # sources.sha256: only the cryptsetup row moved; every other dep byte-identical
      local sdiff; sdiff=$(diff <(sort sources.sha256) <(sort "$bd/s") | grep -c '^[<>]' || true)
      [ "$sdiff" = 2 ] || { g66=FAIL; printf "    G66: bump changed %s sources.sha256 lines, want 2 (only this dep)\n" "$sdiff" >&2; }
      [ "$(grep -c '  cryptsetup-' "$bd/s")" = 1 ] || { g66=FAIL; printf "    G66: more than one cryptsetup hash line after bump\n" >&2; }
      grep -q '^0\{64\}  cryptsetup-99.99.99.tar.xz$' "$bd/s" || { g66=FAIL; printf "    G66: the new hash line is wrong\n" >&2; }
      # reverse: bump back -- build.sh byte-identical, sources.sha256 same line-set
      BUMP_BUILD="$bd/b" BUMP_SRC="$bd/s" _bump_apply CSVER 99.99.99 "$ov" cryptsetup "$oh" "$ot" >/dev/null 2>&1         || { g66=FAIL; printf "    G66: reverse _bump_apply failed\n" >&2; }
      cmp -s build.sh "$bd/b" || { g66=FAIL; printf "    G66: bump then un-bump did NOT restore build.sh byte-for-byte\n" >&2; }
      diff <(sort sources.sha256) <(sort "$bd/s") >/dev/null 2>&1         || { g66=FAIL; printf "    G66: un-bump did not restore the sources.sha256 line set\n" >&2; }
    fi
    # fail-closed ordering: sigver must be called before the pin surgery, so a
    # bad signature aborts with nothing changed. read it out of the bump body.
    local sline aline; sline=$(fnbody bump | awk '/sigver /{print NR; exit}')
    aline=$(fnbody bump | awk '/_bump_apply /{print NR; exit}')
    { [ -n "$sline" ] && [ -n "$aline" ] && [ "$sline" -lt "$aline" ]; }       || { g66=FAIL; printf "    G66: bump does not verify the signature before committing pins\n" >&2; }
    rm -rf "$bd"
  fi
  g "G66 bump edits exactly the pins and reverses clean" "$g66"

  # a gate that dies mid-run under set -e looked exactly like a passing one,
  # so prove every gate actually executed -- and that the ones that ran are
  # the ones the roster names. the count catches a truncated run and a gate
  # emitted twice; the set difference names WHICH gate went missing, and
  # catches a gate added to the code that never reached the roster, plus one
  # rostered that nothing implements. no integer can see those last two.
  trap - ERR
  local seen missing="" extra="" gi
  seen=$(printf '%s\n' "$saw" | tr ' ' '\n' | grep -v '^$' | sort -u)
  for gi in $roster; do printf '%s\n' "$seen"   | grep -qx "$gi" || missing="$missing $gi"; done
  for gi in $seen;   do printf '%s\n' "$roster" | grep -qx "$gi" || extra="$extra $gi";     done
  # an unparseable roster must be a hard red, never a vacuous zero-of-zero
  # green -- the same floor the ELF sweep keeps with n_elf -gt 0.
  if [ "$EXPECTED_GATES" -eq 0 ] || [ "$ran" -ne "$EXPECTED_GATES" ] \
     || [ -n "$missing" ] || [ -n "$extra" ]; then
    printf '\033[1;31m  %d gates ran, the roster names %d -- the run does not match the roster\033[0m\n' "$ran" "$EXPECTED_GATES"
    [ -z "$missing" ] || printf '\033[1;31m  rostered but did not run:%s\033[0m\n' "$missing"
    [ -z "$extra" ]   || printf '\033[1;31m  ran but not in the roster:%s\033[0m\n' "$extra"
    echo
    return 1
  fi

  echo
  # report the G19 headroom, not G1's. this printed IMAGE_MAX - xos.img, so a
  # green build claimed ~7.7 MB free while the binding gate had ~4.8 MB. the
  # kernel is 82% of the budget; the userland is the small part.
  local whole_sz=$sz
  [ -f xos-signed.efi ] && whole_sz=$(( $(stat -c%s xos-signed.efi) + sz ))
  if [ "$bad" -ne 0 ]; then printf '\033[1;31m  GATES FAILED\033[0m\n\n'; return 1; fi
  # a skipped gate is not a failure, but the summary must not call the run
  # "all green" when one check could not run -- that is the very claim G13's
  # old `ok` made falsely. say the count in yellow so a foreign-toolchain
  # build reads as "verified as far as it can be", never as "reproducible".
  # NAME the skipped gates, never assert one cause: this line used to hardcode
  # "(toolchain differs)", which is G13's reason -- but G52 skips for its own
  # reasons (no ssh-keygen, a shallow clone), and the line then misattributed
  # a provenance gap to the toolchain. each gate already printed its real
  # reason above; the summary points there instead of lying about which.
  if [ "$skipped" -gt 0 ]; then
    printf '\033[1;33m  %d gates green, %d unverified (%s -- reasons above) -- %d bytes on disk, %d of %d used, %d to spare\033[0m\n\n' \
      "$((ran - skipped))" "$skipped" "${skipped_names# }" "$sz" "$whole_sz" "$IMAGE_MAX" "$((IMAGE_MAX - whole_sz))"
  else
    printf '\033[1;32m  all gates green -- %d bytes on disk, %d of %d used, %d to spare\033[0m\n\n' \
      "$sz" "$whole_sz" "$IMAGE_MAX" "$((IMAGE_MAX - whole_sz))"
  fi
  return 0
}

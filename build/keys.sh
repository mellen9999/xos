#!/bin/bash
# build/keys.sh -- secure-boot keys, their seal, and what they sign: the uki, dbx, a second os
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

keys() {
  say "generating xos secure boot keys"
  # idempotent against BOTH states: plaintext keys/db.key (freshly generated)
  # and sealed keys/db.key.enc (seal deletes db.key, so checking only the
  # plaintext made `all` regenerate certs over a sealed key -- old key, new
  # cert, sbverify fails. this was silent because `all` never ran end to end.)
  { [ -f keys/db.key ] || [ -f keys/db.key.enc ]; } && { echo "  already present (delete keys/ to regenerate)"; return 0; }
  # born private: the directory is 0700 and the umask 077 BEFORE any key is
  # written. a chmod after the loop left three plaintext keys world-readable
  # for the length of three keygens.
  mkdir -p keys && chmod 700 keys || return 1
  ( umask 077
    for k in PK KEK db; do
      openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -subj "/CN=xos $k/" -keyout "keys/$k.key" -out "keys/$k.crt" 2>/dev/null || exit 1
      openssl x509 -in "keys/$k.crt" -outform DER -out "keys/$k.der" || exit 1
    done ) || { echo "FAIL: key generation failed" >&2; return 1; }
  echo "  PK/KEK/db written to keys/ (gitignored, xos-only -- never your host's)"
  # loud, because the quiet version of this costs a boot. keys/ is gitignored,
  # so a fresh clone AND every new git worktree starts without one and mints
  # its own here -- and an image signed by a keyset the firmware has never
  # heard of does not boot, with nothing in the build saying why.
  echo "  NOTE: this is a NEW keyset, not the one another clone or worktree holds."
  echo "        an image signed with it boots only on firmware enrolled to it."
  echo "        copy keys/ across first if you meant to sign with an existing one."
}

seal() {
  say "encrypting private keys"
  # fail loud rather than no-op: silently skipping an already-sealed keyset is
  # how you end up believing a new passphrase took effect when it did not.
  if [ ! -f keys/db.key ] && [ -f keys/db.key.enc ]; then
    echo "FAIL: keys are already sealed. use './build.sh reseal' to change the passphrase." >&2
    return 1
  fi
  [ -f keys/db.key ] || { echo "FAIL: no keys/db.key -- run ./build.sh keys first" >&2; return 1; }
  local pass
  if [ -n "${XOS_KEYPASS:-}" ]; then pass="$XOS_KEYPASS"
  else read -rsp "  passphrase for xos signing keys: " pass; echo; fi
  [ -n "$pass" ] || { echo "FAIL: empty passphrase" >&2; return 1; }
  local k
  for k in PK KEK db; do
    [ -f "keys/$k.key" ] || continue
    openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -in "keys/$k.key" -out "keys/$k.key.enc" -pass fd:3 3<<EOF || return 1
$pass
EOF
    shred -u "keys/$k.key" 2>/dev/null || rm -f "keys/$k.key"
  done
  chmod 600 keys/*.enc
  echo "  sealed. plaintext keys removed from disk."
}

reseal() {
  say "changing the signing passphrase"
  unlock || return 1
  local newpass
  if [ -n "${XOS_NEWKEYPASS:-}" ]; then newpass="$XOS_NEWKEYPASS"
  else read -rsp "  NEW passphrase: " newpass; echo; fi
  [ -n "$newpass" ] || { echo "FAIL: empty passphrase" >&2; return 1; }
  # every key is re-encrypted before any is swapped in: one passphrase opens
  # all three, so a failure after PK.key.enc had moved left a set no single
  # passphrase could unlock. the plaintext copies are wiped on every exit path.
  local k ok=0
  for k in PK KEK db; do
    [ -f "$RAMKEYS/$k.key" ] || continue
    openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -in "$RAMKEYS/$k.key" -out "keys/$k.key.enc.new" -pass fd:3 3<<EOF && continue
$newpass
EOF
    ok=1; break
  done
  if [ "$ok" -ne 0 ]; then
    rm -f keys/*.key.enc.new; lock
    echo "FAIL: re-encryption failed -- keys/ untouched, passphrase unchanged" >&2; return 1
  fi
  for k in PK KEK db; do
    [ -f "keys/$k.key.enc.new" ] && mv "keys/$k.key.enc.new" "keys/$k.key.enc"
  done
  chmod 600 keys/*.enc
  lock
  echo "  passphrase changed."
}

# the unlocked key must be the one keys/db.crt attests to. unlock() used to
# early-return on the mere EXISTENCE of $RAMKEYS/db.key, so a stale unlock from
# a different keyset was reused without ever being checked against this tree's
# certificate -- the build would then sign with one key and enroll another.
keymatch() {
  [ -f "$RAMKEYS/db.key" ] && [ -f keys/db.crt ] || return 1
  local a b
  a=$(openssl pkey -in "$RAMKEYS/db.key" -pubout 2>/dev/null) || return 1
  b=$(openssl x509 -in keys/db.crt -noout -pubkey 2>/dev/null) || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}

unlock() {
  keymatch && return 0
  # "nothing lands on disk" (top of file) only holds if tmpfs never spills to a
  # disk-backed swap. zram swap is compressed RAM -- still never disk -- but a
  # swap partition or file could page a decrypted key out. refuse by default so
  # the guarantee is enforced, not assumed; XOS_ALLOW_SWAP=1 is the escape hatch.
  local badswap
  badswap=$(sed '1d' /proc/swaps 2>/dev/null | awk '$1 !~ /^\/dev\/zram/ {print $1}' | tr '\n' ' ')
  if [ -n "${badswap# }" ] && [ "${XOS_ALLOW_SWAP:-0}" != 1 ]; then
    echo "FAIL: disk-backed swap active ($badswap) -- an unlocked key could be paged to disk." >&2
    echo "      'sudo swapoff $badswap' first, or set XOS_ALLOW_SWAP=1 to accept the risk." >&2
    return 1
  fi
  # present but not ours: wipe it rather than sign with it.
  [ -f "$RAMKEYS/db.key" ] && { echo "  cached key does not match keys/db.crt -- re-unlocking"; rm -rf "$RAMKEYS"; }
  [ -f keys/db.key.enc ] || { echo "FAIL: keys/db.key.enc missing -- run ./build.sh keys then seal" >&2; return 1; }
  local pass
  if [ -n "${XOS_KEYPASS:-}" ]; then pass="$XOS_KEYPASS"
  else read -rsp "  passphrase to unlock signing keys: " pass; echo; fi
  mkdir -p "$RAMKEYS"; chmod 700 "$RAMKEYS"
  local k
  for k in PK KEK db; do
    [ -f "keys/$k.key.enc" ] || continue
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
      -in "keys/$k.key.enc" -out "$RAMKEYS/$k.key" -pass fd:3 2>/dev/null 3<<EOF \
      || { rm -rf "$RAMKEYS"; echo "FAIL: wrong passphrase" >&2; return 1; }
$pass
EOF
  done
  chmod 600 "$RAMKEYS"/*.key
  openssl rsa -in "$RAMKEYS/db.key" -noout 2>/dev/null \
    || { rm -rf "$RAMKEYS"; echo "FAIL: decrypted key is not a valid RSA key" >&2; return 1; }
  keymatch \
    || { rm -rf "$RAMKEYS"; echo "FAIL: unlocked db.key does not match keys/db.crt" >&2; return 1; }
  echo "  unlocked into RAM ($RAMKEYS)"
}

ramkeys() { echo "$RAMKEYS"; }

lock() {
  rm -rf "$RAMKEYS"
  echo "  locked -- plaintext keys wiped from RAM"
}

# sign an arbitrary EFI binary in place with the db key. once xos owns secure
# boot, db is an allowlist that no longer trusts the Microsoft/shim chain, so a
# second OS on the same stick (e.g. an alpine live UKI) will not boot unless it
# carries a db signature too. this is the guarded one-shot for that -- same key,
# same unlock path as uki(), never hand-rolled sbsign against the sealed key.
# see docs/carrier.md. does NOT touch the enrolled varstore; it only signs.
sign() {
  local efi="${1:-}"
  [ -n "$efi" ] && [ -f "$efi" ] || { echo "usage: ./build.sh sign IMAGE.efi  (signs in place with keys/db.key)" >&2; return 1; }
  say "signing $efi with the db key"
  [ -f keys/db.crt ] || { echo "FAIL: keys/db.crt missing -- run ./build.sh keys first" >&2; return 1; }
  # already carrying our signature? re-signing would stack a second one; nothing
  # breaks, but say so rather than silently no-op into a confusing double-sig.
  if sbverify --cert keys/db.crt "$efi" >/dev/null 2>&1; then
    echo "  already signed by this db key -- nothing to do"; return 0
  fi
  unlock || return 1
  local out="$efi.signed.$$"
  sbsign --key "$RAMKEYS/db.key" --cert keys/db.crt --output "$out" "$efi" >/dev/null \
    || { echo "FAIL: signing failed" >&2; rm -f "$out"; return 1; }
  sbverify --cert keys/db.crt "$out" >/dev/null 2>&1 \
    || { echo "FAIL: signature does not verify against keys/db.crt" >&2; rm -f "$out"; return 1; }
  mv "$out" "$efi"
  printf '  signed: %s (%d bytes) -- boots under the same enrolled db as xos\n' "$efi" "$(stat -c%s "$efi")"
}

uki() {
  say "building + signing unified kernel image"
  [ -f cmdline.txt ] || { echo "FAIL: run verity first" >&2; return 1; }
  local stub="$STUB"
  # fetch-and-cut from the pinned package, then hard fail HERE, before the stub
  # is wrapped -- not in gates(), which runs after the signed image exists.
  blob || return 1
  [ -f "$stub" ] || { echo "FAIL: systemd-stub missing at $stub" >&2; return 1; }
  blobver || return 1
  grep -q '^CONFIG_EFI_STUB=y' "src/linux-$KVER/.config" || {
    echo "FAIL: kernel lacks EFI_STUB -- firmware cannot load it" >&2; return 1; }

  unlock || return 1
  ukify build --linux=bzImage --cmdline="$(cat cmdline.txt)" --stub="$stub" --output=xos.efi >/dev/null
  sbsign --key "$RAMKEYS/db.key" --cert keys/db.crt --output xos-signed.efi xos.efi >/dev/null \
    || { echo "FAIL: signing failed -- refusing to ship an unsigned image" >&2; rm -f xos-signed.efi; return 1; }
  [ -f xos-signed.efi ] || { echo "FAIL: no signed image produced" >&2; return 1; }
  sbverify --cert keys/db.crt xos-signed.efi >/dev/null 2>&1 || {
    echo "FAIL: signature does not verify" >&2; return 1; }

  mkdir -p esp/EFI/BOOT
  cp xos-signed.efi esp/EFI/BOOT/BOOTX64.EFI

  cp "$OVMF_VARS" ovmf-vars.fd
  # errors here used to go to /dev/null with no status check: enrollment could
  # fail and leave a firmware with NO keys, which does not enforce secure boot
  # at all -- and the build still said it was done.
  virt-fw-vars --input ovmf-vars.fd --output ovmf-vars.fd \
    --set-pk  "$SBGUID" keys/PK.der \
    --add-kek "$SBGUID" keys/KEK.der \
    --add-db  "$SBGUID" keys/db.der >/dev/null 2>&1 \
    || { echo "FAIL: could not enroll keys into ovmf-vars.fd" >&2; return 1; }
  printf '  signed UKI: %d bytes, keys enrolled into ovmf-vars.fd\n' "$(stat -c%s xos-signed.efi)"
  dbx || return 1
}

# a signature says who signed it, never when. an image signed a year ago
# verifies exactly as well as today's, so an attacker who can write the ESP --
# which is plain FAT, by design, because something has to boot -- can put back
# a superseded image with its old kernel and old bugs. dbx is the one link in
# the chain that can refuse it.
dbx() {
  [ -f ovmf-vars.fd ] || { echo "FAIL: no ovmf-vars.fd -- run ./build.sh uki first" >&2; return 1; }
  [ -f revoked ] || { echo "FAIL: revoked missing -- it is tracked; do not delete it" >&2; return 1; }
  local args=() h n=0
  # `|| [ -n "$h" ]`: read returns nonzero on a final line with no newline,
  # and a hand-edited file ending that way would drop exactly one revocation.
  while read -r h rest || [ -n "$h" ]; do
    case "$h" in ''|'#'*) continue ;; esac
    # a malformed line must stop the build. skipping it would silently drop a
    # revocation, and nothing downstream can tell that apart from success.
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] \
      || { echo "FAIL: revoked: not a sha256 hash: $h" >&2; return 1; }
    args+=(--add-dbx-hash "$SBGUID" "$h"); n=$((n+1))
  done < revoked
  if [ "$n" -eq 0 ]; then
    echo "  dbx: nothing revoked yet"
    return 0
  fi
  virt-fw-vars --input ovmf-vars.fd --output ovmf-vars.fd "${args[@]}" >/dev/null 2>&1 \
    || { echo "FAIL: could not enroll dbx into ovmf-vars.fd" >&2; return 1; }

  # ovmf-vars.fd is the QEMU varstore and nothing else. for years that was the
  # only thing revoke() produced, so a revocation held in the test rig and did
  # nothing whatsoever on real hardware -- the one machine it needed to hold on.
  # write the enrollable form too, beside the PK/KEK/db the operator already
  # enrolls from the stick.
  #
  # this .auth carries no KEK signature, so it is accepted in SETUP MODE only --
  # which is exactly the documented order: clear the keys, enroll dbx, db and
  # KEK, and PK last, because enrolling PK is what turns enforcement on. adding
  # a revocation to a machine already in user mode means re-enrolling, and the
  # README says so rather than pretending otherwise.
  rm -rf dbxauth && mkdir -p dbxauth
  virt-fw-vars --input ovmf-vars.fd --output-auth dbxauth >/dev/null 2>&1 \
    && [ -s dbxauth/dbx.auth ] \
    || { echo "FAIL: could not write an enrollable dbx.auth" >&2; return 1; }
  printf '  dbx: %d image(s) revoked -- qemu varstore + dbxauth/dbx.auth (%d bytes)\n' \
    "$n" "$(stat -c%s dbxauth/dbx.auth)"
}

revoke() {
  local img="${1:-}"
  [ -n "$img" ] && [ -f "$img" ] || { echo "usage: ./build.sh revoke IMAGE.efi" >&2; return 1; }
  local h; h=$(python3 pehash.py --verify "$img") \
    || { echo "FAIL: refusing to revoke an image whose digest we cannot confirm" >&2; return 1; }
  if [ "$(grep -c "^$h" revoked || true)" != 0 ]; then
    echo "  already revoked: $h"; return 0
  fi
  # revoking the image you are about to ship bricks the next boot. G14 catches
  # it at build time, but say it here too, while it is still one line to undo.
  if [ -f xos-signed.efi ] && [ "$h" = "$(python3 pehash.py xos-signed.efi)" ]; then
    echo "FAIL: that is the CURRENT signed image -- revoking it would refuse your own boot" >&2
    return 1
  fi
  printf '%s  %s\n' "$h" "revoked $(date -u +%Y-%m-%d) -- $(basename "$img")" >> revoked
  echo "  revoked $h"
  echo "  run ./build.sh uki to re-enroll dbx"
}

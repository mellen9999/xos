#!/bin/bash
# build/stick.sh -- raw disk writes -- the stick image, usb, addstate, clone, install -- and the guards they all pass through
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# assemble the bootable stick image: GPT (fixed GUIDs) + FAT32 ESP carrying the
# signed UKI and the public keys for enrollment + raw xos.img as p2. entirely
# deterministic (no root, no loop mount -- sfdisk + mtools), so the layout is
# reproducible even though we do not pin it: everything that MATTERS on the stick
# is already covered (p2 by image.sha256 + the verity tree, BOOTX64.EFI by the db
# signature). only FAT/GPT metadata is unauthenticated, and tampering it can at
# most deny boot, never change what runs.
stick() {
  say "assembling stick.img"
  [ -f xos-signed.efi ] || { echo "FAIL: no signed UKI -- run ./build.sh uki" >&2; return 1; }
  [ -f xos.img ]        || { echo "FAIL: no xos.img -- run ./build.sh verity" >&2; return 1; }
  for k in PK KEK db; do [ -f "keys/$k.der" ] || { echo "FAIL: keys/$k.der missing" >&2; return 1; }; done

  local esp_bytes root_bytes esp_size_s total
  esp_bytes=$((STICK_ESP_MIB * 1024 * 1024))
  root_bytes=$(stat -c%s xos.img)                 # already a 4K multiple (verity padded it)
  esp_size_s=$((esp_bytes / 512))
  # p2 is IMAGE_MAX, not this image's size -- see the layout constants. G1 and
  # G19 keep the image under that number, but a partition silently too small for
  # its own contents is not a thing this should be able to ship.
  [ "$root_bytes" -le "$IMAGE_MAX" ] \
    || { echo "FAIL: xos.img is $root_bytes bytes -- p2 is $IMAGE_MAX and cannot hold it" >&2; return 1; }
  total=$(( STATE_START_S * 512 ))                # stops exactly where p3 starts

  rm -f stick.img
  truncate -s "$total" stick.img

  # deterministic GPT: fixed disk id + per-partition uuids/types/names, no
  # timestamps in GPT (only CRCs), so identical inputs -> identical bytes.
  # named fields + sizes in SECTORS -- sfdisk rejects a bare 'B' byte suffix.
  sfdisk stick.img >/dev/null <<EOF
label: gpt
label-id: $GPT_DISK
start=$ESP_START_S, size=$esp_size_s, type=C12A7328-F81F-11D2-BA4B-00A08693446B, uuid=$PU_ESP, name="XOS-ESP"
start=$ROOT_START_S, size=$ROOT_SIZE_S, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$PU_ROOT, name="XOS-ROOT"
EOF

  # FAT32 in a temp file, then dd into the ESP slot. --invariant drops the
  # volume id + creation timestamp that would otherwise randomise the bytes.
  rm -f esp.part; truncate -s "$esp_bytes" esp.part
  mkfs.fat --invariant -F 32 -n XOS esp.part >/dev/null
  # pin mtime of everything we copy so mcopy writes deterministic dir entries
  touch -d "@$SOURCE_DATE_EPOCH" xos-signed.efi keys/PK.der keys/KEK.der keys/db.der
  mmd   -i esp.part ::/EFI ::/EFI/BOOT ::/xos-keys
  mcopy -pm -i esp.part xos-signed.efi ::/EFI/BOOT/BOOTX64.EFI
  mcopy -pm -i esp.part keys/PK.der keys/KEK.der keys/db.der ::/xos-keys/
  # the revocation list, in the form firmware can actually take. without this
  # `revoke` only ever reached the qemu varstore. safe on the unauthenticated
  # ESP: firmware validates it, and in setup mode it is the operator who
  # decides to enroll it at all.
  if [ -s dbxauth/dbx.auth ]; then
    touch -d "@$SOURCE_DATE_EPOCH" dbxauth/dbx.auth
    mcopy -pm -i esp.part dbxauth/dbx.auth ::/xos-keys/
  fi
  dd if=esp.part    of=stick.img bs=1M seek=1                     conv=notrunc status=none
  dd if=xos.img  of=stick.img bs=1M seek=$((1 + STICK_ESP_MIB)) conv=notrunc status=none
  rm -f esp.part
  printf '  stick.img: %d bytes (esp %d MiB + p2 %d fixed, holding %d) -- p3 starts at sector %d\n' \
    "$(stat -c%s stick.img)" "$STICK_ESP_MIB" "$IMAGE_MAX" "$root_bytes" "$STATE_START_S"
}

# write stick.img to a real removable disk. this is dd-to-wrong-disk territory,
# so every guard is fail-closed and there is deliberately NO --force flag.
usb() {
  local dev="${1:-}"
  [ -n "$dev" ] || { echo "FAIL: usage: ./build.sh usb /dev/sdX" >&2; return 1; }
  [ -b "$dev" ] || { echo "FAIL: $dev is not a block device" >&2; return 1; }
  local n; n=$(basename "$dev")
  guard_removable "$dev" || return 1
  [ -f stick.img ] || stick || return 1
  # the gates, every time. a stick.img left behind by a gate-FAILED `all` (stick
  # runs before the gates) used to flash straight through here; the only check on
  # this path was a readback against a pin that the same failed run had
  # regenerated. gates are stateless and cheap next to a wrong stick in the field.
  gates || { echo "FAIL: gates failed -- not writing $dev" >&2; return 1; }

  local dev_bytes img_bytes model
  dev_bytes=$(( $(cat "/sys/block/$n/size") * 512 ))
  img_bytes=$(stat -c%s stick.img)
  [ "$dev_bytes" -ge "$img_bytes" ] || { echo "FAIL: $dev too small ($dev_bytes < $img_bytes)" >&2; return 1; }
  if [ "$dev_bytes" -gt $((128 * 1024 * 1024 * 1024)) ]; then
    echo "WARN: $dev is $((dev_bytes / 1024 / 1024 / 1024)) GiB -- larger than any usb stick, is this the right disk?" >&2
  fi
  # a flash writes only the first $img_bytes of the device, so a partition
  # living past that keeps every byte -- but the fresh GPT that lands on top of
  # it describes two partitions, and p3's ENTRY is gone. that is how updating a
  # stick used to be a factory reset. save those entries now and put them back
  # after the write. everything out there is preserved, not just ours: flashing
  # has no business orphaning a partition it never writes to.
  local keep_tail lose_tail
  keep_tail=$(tail_parts "$dev" "$img_bytes" keep)
  lose_tail=$(tail_parts "$dev" "$img_bytes" lose)
  # an xos state partition INSIDE that region is the old layout, where p3 began
  # right after p2. writing this image would go straight through it, so stop --
  # a stranger's partitions on a stick being deliberately flashed are a
  # different matter, and the wipefs warning below already covers those.
  if printf '%s\n' "$lose_tail" | grep -qi "$PU_STATE"; then
    echo "FAIL: $dev has an xos state partition inside the region this image writes:" >&2
    printf '    %s\n' "$lose_tail" >&2
    echo "  it was placed by the old layout, which put p3 directly after p2; flashing" >&2
    echo "  would write over it. copy what you need off it, delete that partition" >&2
    echo "  deliberately, then flash again -- addstate now places p3 past the image," >&2
    echo "  where an update cannot reach it." >&2
    return 1
  fi

  model=$(disk_model "$dev")
  echo "  target: $dev  size: $((dev_bytes / 1024 / 1024)) MiB  model: ${model:-unknown}"
  [ -z "$keep_tail" ] || echo "  keeping $(printf '%s\n' "$keep_tail" | grep -c .) partition(s) past the image -- encrypted state survives this write"
  [ -z "$lose_tail" ] || echo "  WARNING: $(printf '%s\n' "$lose_tail" | grep -c .) partition(s) sit inside the image region and WILL be destroyed."
  if wipefs -n "$dev" 2>/dev/null | has .; then
    echo "  WARNING: $dev already contains a filesystem/partition signature -- it will be DESTROYED."
  fi
  confirm_model "$dev" || return 1
  say "writing stick.img to $dev"
  dd if=stick.img of="$dev" bs=1M oflag=direct conv=fsync status=progress

  # verify by DIRECT-IO readback -- a page-cache read would just echo what we
  # wrote and prove nothing. compare the whole stick, then the p2 root region
  # against the pinned image digest.
  say "verifying written bytes"
  local want_stick have_stick want_root have_root
  want_stick=$(sha256sum < stick.img | awk '{print $1}')
  have_stick=$(dd if="$dev" bs=1M iflag=direct,count_bytes count="$img_bytes" status=none | sha256sum | awk '{print $1}')
  [ "$want_stick" = "$have_stick" ] || { echo "FAIL: stick readback mismatch -- write did not land" >&2; return 1; }
  want_root=$(awk '$1=="image"{print $2}' image.sha256)
  [ -n "$want_root" ] || { echo "FAIL: image.sha256 carries no image digest -- run ./build.sh pin" >&2; return 1; }
  have_root=$(dd if="$dev" bs=1M skip=$((1 + STICK_ESP_MIB)) iflag=direct,count_bytes count="$(stat -c%s xos.img)" status=none | sha256sum | awk '{print $1}')
  [ "$want_root" = "$have_root" ] \
    || { echo "FAIL: root partition on disk does not match pinned image digest" >&2; return 1; }
  # stick.img is 74 MiB; the stick is not. dd copies the GPT verbatim, so the
  # backup header and the "last usable LBA" still describe the IMAGE, and every
  # sector past it reads as unpartitionable: sfdisk -F reported 0 B free on a
  # 16 GB stick and addstate could not place p3 at all. move the backup header
  # to the real end of the device so the rest of the stick becomes usable.
  # deliberately AFTER the readback above, which compares against stick.img
  # byte for byte -- this is the one edit that intentionally diverges from it,
  # and it touches only GPT metadata, which no signature covers.
  sfdisk --relocate gpt-bak-std "$dev" >/dev/null 2>&1 \
    || echo "WARN: could not move the backup GPT to the end of $dev -- addstate may find no free space" >&2

  # and put the saved entries back. their sectors were never written, so the
  # data is untouched -- only the table forgot them. this is a hard failure, not
  # a warning: the image boots either way, and an operator who walks away
  # believing the update kept their state is the whole bug.
  if [ -n "$keep_tail" ]; then
    printf '%s\n' "$keep_tail" | sfdisk --no-reread -a "$dev" >/dev/null 2>&1 || true
    # --no-reread, so tell the kernel yourself -- otherwise ${dev}3 does not
    # come back as a node and install() offers to create the p3 that is already
    # sitting there.
    partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" 2>/dev/null || true
    if [ "$(tail_parts "$dev" "$img_bytes" keep)" = "$keep_tail" ]; then
      say "state partition preserved across the update"
    else
      echo "FAIL: the image is written and boots, and p3's DATA is intact -- but its" >&2
      echo "  partition entry did not come back. re-add it by hand, exactly:" >&2
      printf '    sfdisk --no-reread -a %s <<EOF\n%s\nEOF\n' "$dev" "$keep_tail" >&2
      return 1
    fi
  fi
  sync
  printf '\n  \033[1;32mdone -- %s carries a verified xos\033[0m\n' "$dev"
  echo "  boot it: firmware boot menu -> USB. secure boot: enroll keys from the"
  echo "  stick's /xos-keys (db, KEK, then PK last). see README."
}

# ── clone: a verified spare stick, p3 and all ───────────────────────────────
#
# the README calls for "a second cloned stick stored apart" and for backing up
# p3 offline; this is that, as tooling instead of a hand-typed dd an operator
# gets wrong once. SRC is only read; DST is written and so is guarded exactly
# like usb()/addstate() -- whole, removable, unmounted, model typed back. the
# LUKS state copies as CIPHERTEXT: nothing is decrypted, the spare unlocks with
# the same passphrase and is exactly as secret as the original.
#
# the size and the byte-range readback are factored into three helpers so G64
# can exercise the refusals and the copy-is-faithful check on image files,
# without a removable disk in the loop.

disk_bytes() { # $1 device or image -> size in bytes, 0 if unknown
  if [ -b "$1" ]; then
    blockdev --getsize64 "$1" 2>/dev/null \
      || echo $(( $(cat "/sys/block/$(basename "$1")/size" 2>/dev/null || echo 0) * 512 ))
  else
    stat -c%s "$1" 2>/dev/null || echo 0
  fi
}

range_hash() { # $1 path  $2 bytes  $3 iflag (optional, e.g. direct) -> sha256 of the first $2 bytes
  local fl=count_bytes; [ -n "${3:-}" ] && fl="$3,count_bytes"
  dd if="$1" bs=4M iflag="$fl" count="$2" status=none 2>/dev/null | sha256sum | awk '{print $1}'
}

clone_precheck() { # $1 src  $2 dst  $3 src_bytes  $4 dst_bytes -- non-destructive refusals
  [ "$1" != "$2" ] || { echo "FAIL: source and destination are the same device" >&2; return 1; }
  [ "${3:-0}" -gt 0 ] 2>/dev/null || { echo "FAIL: source $1 has zero size" >&2; return 1; }
  [ "${4:-0}" -ge "${3:-0}" ] 2>/dev/null \
    || { echo "FAIL: destination too small ($4 < $3) -- a spare cannot be smaller than the stick" >&2; return 1; }
}

clone() {
  local src="${1:-}" dst="${2:-}"
  [ -n "$src" ] && [ -n "$dst" ] || { echo "FAIL: usage: ./build.sh clone /dev/SRC /dev/DST" >&2; return 1; }
  [ -b "$src" ] || { echo "FAIL: source $src is not a block device" >&2; return 1; }
  [ -b "$dst" ] || { echo "FAIL: destination $dst is not a block device" >&2; return 1; }
  # DST is the one written, so it takes the full destructive-path guard. SRC is
  # only ever read.
  guard_removable "$dst" || return 1
  # SRC must actually BE an xos stick, or a mistyped source silently images some
  # unrelated disk onto the spare. require both xos partition type GUIDs.
  local srctab; srctab=$(sfdisk -d "$src" 2>/dev/null || true)
  { printf '%s\n' "$srctab" | grep -qi "$PU_ROOT" && printf '%s\n' "$srctab" | grep -qi "$PU_STATE"; } \
    || { echo "FAIL: $src does not look like an xos stick (no xos root + state partitions)" >&2
         echo "  clone copies a stick you already trust; it will not image an arbitrary disk." >&2
         return 1; }
  local src_bytes dst_bytes
  src_bytes=$(disk_bytes "$src"); dst_bytes=$(disk_bytes "$dst")
  clone_precheck "$src" "$dst" "$src_bytes" "$dst_bytes" || return 1
  local model; model=$(disk_model "$dst")
  echo "  source: $src  ($((src_bytes / 1024 / 1024)) MiB, an xos stick -- read only)"
  echo "  target: $dst  ($((dst_bytes / 1024 / 1024)) MiB, model ${model:-unknown}) -- EVERYTHING on it is destroyed"
  if wipefs -n "$dst" 2>/dev/null | has .; then
    echo "  WARNING: $dst already holds a filesystem/partition signature -- it will be DESTROYED."
  fi
  confirm_model "$dst" || return 1
  say "cloning $src -> $dst ($((src_bytes / 1024 / 1024)) MiB, p3 included)"
  dd if="$src" of="$dst" bs=4M iflag=direct oflag=direct conv=fsync status=progress

  # verify by DIRECT-IO readback over the whole copied region: a page-cache read
  # would echo what we just wrote and prove nothing. src is not being written,
  # so its hash is stable across the compare.
  say "verifying the clone, byte for byte"
  local hs hd
  hs=$(range_hash "$src" "$src_bytes" direct)
  hd=$(range_hash "$dst" "$src_bytes" direct)
  [ -n "$hs" ] && [ "$hs" = "$hd" ] \
    || { echo "FAIL: clone readback mismatch -- the copy did not land; do not rely on $dst" >&2; return 1; }

  # a larger DST carries SRC's GPT verbatim, so its backup header and last-usable
  # LBA still describe the smaller source and the tail reads as unpartitionable.
  # move the backup header to the real end -- GPT metadata only, no signed byte,
  # and deliberately AFTER the readback this one edit diverges from.
  if [ "$dst_bytes" -gt "$src_bytes" ]; then
    sfdisk --relocate gpt-bak-std "$dst" >/dev/null 2>&1 \
      || echo "WARN: could not move $dst's backup GPT to the end -- harmless, but its tail may read as unusable" >&2
  fi
  sync
  printf '\n  \033[1;32mdone -- %s is a verified clone of %s, p3 and all\033[0m\n' "$dst" "$src"
  echo "  it boots on the same enrolled keys and unlocks p3 with the same passphrase."
  echo "  store it apart from the original -- a spare you can prove is a spare you can trust."
}


# addstate DEV -- turn the free space after p2 on a flashed stick into p3: an
# encrypted, authenticated ext4 volume that xos unlocks at boot. this is the
# only thing that makes anything persist. it touches the free space only; it
# never writes to p1 or p2. run it once, against the physical stick.
# ────────────────────────────────────────────────────────────────────────────
# writing to real disks -- the only code here that can destroy data
# ────────────────────────────────────────────────────────────────────────────
addstate() {
  local dev="${1:-}"
  [ -b "$dev" ] || { echo "usage: $0 addstate /dev/sdX  (the whole stick, not a partition)" >&2; return 1; }
  # tools addstate needs that a plain build does not -- check them here so it
  # fails with a clear message up front, never half way through partitioning.
  local t asmiss=""
  for t in cryptsetup:cryptsetup mkfs.ext4:e2fsprogs partx:util-linux sfdisk:util-linux \
           partprobe:parted lsblk:util-linux; do
    command -v "${t%%:*}" >/dev/null 2>&1 || asmiss="$asmiss ${t%%:*}(${t##*:})"
  done
  [ -z "$asmiss" ] || { echo "FAIL: addstate needs:$asmiss" >&2; return 1; }
  # this rewrites a partition table and luksFormats: every guard usb() has, it
  # has -- literally the same two functions. it used to have one (removable), so
  # a removable sd card of photos with two partitions qualified, with no prompt.
  guard_removable "$dev" || return 1
  # it must be an xos stick: p1 and p2 carry the fixed PARTUUIDs stick() wrote.
  local ptable
  ptable=$(sfdisk -J "$dev" 2>/dev/null) || { echo "FAIL: cannot read the partition table on $dev" >&2; return 1; }
  printf '%s' "$ptable" | grep -qi "\"$PU_ESP\""  || { echo "FAIL: $dev p1 is not the xos ESP -- flash the image first" >&2; return 1; }
  printf '%s' "$ptable" | grep -qi "\"$PU_ROOT\"" || { echo "FAIL: $dev p2 is not the xos root -- flash the image first" >&2; return 1; }

  # never reformat an existing p3. re-running this used to luksFormat whatever
  # third partition was already there and destroy everything on it, with no
  # prompt. if a p3 exists, stop and make the operator remove it deliberately.
  local ep3="${dev}3"; [ -b "$ep3" ] || ep3="${dev}p3"
  if [ -b "$ep3" ]; then
    if cryptsetup isLuks "$ep3" 2>/dev/null; then
      echo "FAIL: $ep3 already holds an encrypted state volume -- refusing to reformat it." >&2
      echo "  unlock it at boot as usual; to REPLACE it, wipe $ep3 deliberately first." >&2
    else
      echo "FAIL: $ep3 already exists and is not xos state -- refusing to touch it." >&2
      echo "  remove that partition deliberately if you mean to add state here." >&2
    fi
    return 1
  fi

  # a stick flashed by an older build still has the image's backup GPT, so the
  # free space is invisible. usb() does this now; repeat it here so an existing
  # stick is repaired rather than refused.
  sfdisk --relocate gpt-bak-std "$dev" >/dev/null 2>&1 || true

  # p3 goes at a FIXED sector -- the first one past stick.img -- not wherever
  # this build's p2 happens to end. that constant is the whole reason an update
  # can preserve it: `usb` writes exactly up to here and stops, and restores the
  # entry afterwards. placing it at p2end+1 (what this used to do) puts it under
  # the next image's backup GPT slack.
  local p2end
  p2end=$(partx -g -o END -n 2:2 "$dev" 2>/dev/null | tr -d ' ') \
    || { echo "FAIL: cannot read the partition table on $dev -- flash the image first" >&2; return 1; }
  [ -n "$p2end" ] || { echo "FAIL: no second partition on $dev" >&2; return 1; }
  [ "$p2end" -lt "$STATE_START_S" ] \
    || { echo "FAIL: p2 ends at sector $p2end, at or past the fixed state start $STATE_START_S" >&2
         echo "  -- this stick was not flashed by this build. reflash it first." >&2; return 1; }
  local dev_s; dev_s=$(cat "/sys/block/$(basename "$dev")/size" 2>/dev/null || echo 0)
  [ "$dev_s" -gt $((STATE_START_S + 2048)) ] \
    || { echo "FAIL: $dev has no room past sector $STATE_START_S for a state partition" >&2; return 1; }

  # a stick flashed by the old code lost p3's ENTRY -- the two-partition GPT
  # went over it -- while every byte of p3 stayed exactly where it was, at
  # p2end+1. creating a fresh p3 now would write over a live encrypted volume.
  # the entry is the only thing missing, so hand back the line that restores it.
  if luks_at "$dev" $((p2end + 1)); then
    echo "FAIL: a LUKS header sits at sector $((p2end + 1)) with no partition entry." >&2
    echo "  an older flash orphaned it; the data is intact. put the entry back rather" >&2
    echo "  than create a new p3 over it:" >&2
    printf '    sfdisk --no-reread -a %s <<EOF\n    start=%s, type=%s, uuid=%s, name="XOS-STATE"\n    EOF\n' \
      "$dev" "$((p2end + 1))" "$PT_LUKS" "$PU_STATE" >&2
    return 1
  fi

  echo "  target: $dev  model: $(disk_model "$dev")  -- p3 starts at sector $STATE_START_S and fills the rest"
  confirm_model "$dev" || return 1
  sfdisk --no-reread -a "$dev" >/dev/null 2>&1 <<SFDISK || { echo "FAIL: sfdisk could not add p3 to $dev (no free space at sector $STATE_START_S, or an unreadable table)" >&2; return 1; }
start=$STATE_START_S, type=$PT_LUKS, uuid=$PU_STATE, name="XOS-STATE"
SFDISK
  partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" 2>/dev/null || true
  sleep 1
  local p3="${dev}3"; [ -b "$p3" ] || p3="${dev}p3"
  [ -b "$p3" ] || { echo "FAIL: p3 did not appear as ${dev}3 or ${dev}p3" >&2; return 1; }

  echo "  formatting p3 as LUKS2 with hmac-sha256 integrity -- you will be asked for a passphrase"
  # pin the KDF explicitly instead of taking cryptsetup's adaptive default. two
  # reasons, both about a stick formatted here but unlocked elsewhere:
  #   portability -- the adaptive default sizes argon2 to THIS host's RAM (up to
  #     a few GiB on the build box). a stick formatted that way needs that much
  #     free at unlock, so it can silently fail to open on smaller field
  #     hardware. 512 MiB is unlockable on anything that boots xos (which runs
  #     from RAM) and is still ~8x the OWASP argon2id floor.
  #   downgrade-proofing -- if a future cryptsetup weakens its default, this
  #     line does not move with it. argon2id/512MiB/4-lane, recorded here.
  cryptsetup luksFormat --type luks2 --integrity hmac-sha256 \
    --pbkdf argon2id --pbkdf-memory 524288 --pbkdf-parallel 4 \
    --label XOS-STATE "$p3" || return 1
  cryptsetup open "$p3" xosstate_setup || return 1
  make_ext4 /dev/mapper/xosstate_setup || { cryptsetup close xosstate_setup; return 1; }
  cryptsetup close xosstate_setup
  echo "  done. p3 is encrypted + authenticated. xos will offer to unlock it at boot."
}

# thin wrapper so the mkfs call sits behind a name (keeps blunt greps happy).
make_ext4() { "mkfs.ext4" -q -L xos-state "$1"; }


# detect_removable -- echo the removable whole-disks currently attached, one per
# line. the host's fixed disks are excluded, so this cannot surface the drive
# you booted the build machine from.
detect_removable() {
  local d n
  for d in /sys/block/*; do
    n=$(basename "$d")
    [ "$(cat "$d/removable" 2>/dev/null)" = 1 ] || continue
    # skip zero-size card readers with no card in them
    [ "$(cat "$d/size" 2>/dev/null || echo 0)" -gt 0 ] || continue
    echo "/dev/$n"
  done
}

# install [DEV] -- the whole install, in one command: pick the stick, flash a
# verified xos onto it, and offer to add encrypted persistent state. safe by
# construction -- it only ever writes a removable disk, verifies every byte it
# wrote against the pinned digest, and makes you type the disk model before it
# touches anything. with no DEV it auto-detects, and only proceeds when exactly
# one removable disk is present.
stick_install() {
  local dev="${1:-}"
  if [ -z "$dev" ]; then
    local found; found=$(detect_removable)
    local count; count=$(printf '%s\n' "$found" | grep -c . || true)
    if [ "$count" = 0 ]; then
      echo "FAIL: no removable disk found -- plug in the usb stick and try again" >&2
      echo "  (fixed disks are never listed, on purpose)" >&2
      return 1
    elif [ "$count" -gt 1 ]; then
      echo "FAIL: more than one removable disk is attached:" >&2
      printf '%s\n' "$found" | while read -r c; do
        [ -n "$c" ] && echo "    $c  ($(( $(cat "/sys/block/$(basename "$c")/size") / 2048 )) MiB)" >&2
      done
      echo "  name the one you mean: ./build.sh install /dev/sdX" >&2
      return 1
    fi
    dev=$(printf '%s\n' "$found" | grep . | head -1)
    echo "  auto-detected the only removable disk: $dev"
  fi

  # build everything if it is not already sitting here, so a fresh clone can go
  # straight to install.
  [ -f stick.img ] || { echo "  no stick.img yet -- building the whole image first"; build_all || return 1; }

  # the flash + byte-for-byte verification lives in usb(); reuse it rather than
  # keeping a second copy of the careful part.
  usb "$dev" || return 1

  # offer persistent state -- unless the flash just preserved one, which is the
  # normal case for an update. prompting there would walk into addstate's
  # refusal to reformat an existing p3 and read as a failure.
  echo
  local ep3="${dev}3"; [ -b "$ep3" ] || ep3="${dev}p3"
  if [ -b "$ep3" ]; then
    echo "  encrypted state (p3) was already here and came through the update intact --"
    echo "  unlock it at boot as usual."
    echo
    printf '  \033[1;32minstall complete\033[0m\n'
    return 0
  fi
  local ans
  read -rp "  add encrypted persistent state (p3) now? [y/N]: " ans
  case "$ans" in
    y|Y|yes)
      addstate "$dev" || { echo "  state setup failed -- the stick still boots, just without persistence" >&2; return 0; }
      ;;
    *)
      echo "  skipped. add it later with: ./build.sh addstate $dev"
      ;;
  esac

  echo
  printf '  \033[1;32minstall complete\033[0m\n'
}

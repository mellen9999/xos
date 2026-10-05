#!/bin/bash
# build/rootfs.sh -- the image: root filesystem and verity tree
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# ────────────────────────────────────────────────────────────────────────────
# the image -- root filesystem, verity tree, keys, signed UKI, stick
# ────────────────────────────────────────────────────────────────────────────
rootfs() {
  say "building read-only root"
  rm -rf root
  mkdir -p root/bin root/proc root/sys root/dev root/etc root/tmp
  cp busybox root/bin/
  # one binary, many names: busybox reads argv[0] to decide what to be.
  # names come from busybox itself, not our config list -- the two drift
  # (CONFIG_TEST1 is the applet named "["), and a missing applet makes
  # shell tests fail open rather than fail loud.
  local applets; applets=$(mktemp)
  ./busybox --list > "$applets" 2>/dev/null || {
    echo "FAIL: busybox --list unavailable (enable the busybox applet)" >&2; rm -f "$applets"; return 1; }
  [ -s "$applets" ] || { echo "FAIL: empty applet list" >&2; rm -f "$applets"; return 1; }
  while read -r a; do
    ln -sf busybox "root/bin/$a"
  done < "$applets"
  grep -qx '\[' "$applets" || { echo "FAIL: '[' applet missing -- shell tests would fail open" >&2; rm -f "$applets"; return 1; }
  rm -f "$applets"
  # every component is REQUIRED. these were `[ -f x ] && cp x` -- one missing
  # binary silently produced a smaller image that still passed every gate.
  # a build that ships less than it claims must fail, not shrink.
  local b
  for b in ii tlstunnel abduco cryptsetup wg; do
    [ -f "$b" ] || { echo "FAIL: $b not built -- run ./build.sh all" >&2; return 1; }
    cp "$b" "root/bin/$b"
  done
  # dropbear is a multi-call binary like busybox: one file, argv[0] chooses the
  # tool. the ssh server, client and keygen are three names for it.
  [ -f dropbearmulti ] || { echo "FAIL: dropbearmulti not built -- run ./build.sh all" >&2; return 1; }
  cp dropbearmulti root/bin/dropbearmulti
  local dbn
  for dbn in dropbear dbclient dropbearkey; do ln -sf dropbearmulti "root/bin/$dbn"; done

  # learn is this repo's own: an ash script over a plain-text corpus. on a
  # read-only root the filesystem IS the lookup table, so it needs no shell
  # data structures -- which is what lets the one shell be ash.
  [ -x learn/learn ] || { echo "FAIL: learn/learn missing or not executable" >&2; return 1; }
  [ -x tutorial ]    || { echo "FAIL: tutorial missing or not executable" >&2; return 1; }
  local part
  for part in ref lib pools levels scenarios projects c; do
    [ -d "learn/$part" ] || { echo "FAIL: learn/$part missing -- run ./build.sh seed" >&2; return 1; }
  done
  for _f in skip skip-syntax builtins verbs phrases syntax vs bashisms chains migrations rekeys; do
    [ -f "learn/$_f" ] || { echo "FAIL: learn/$_f missing" >&2; return 1; }
  done
  install -m 0755 learn/learn root/bin/learn
  # the front door: the first-boot tutorial. it sources the corpus UI below, so
  # it ships beside learn and is greeted from /etc/shrc on the first shell.
  install -m 0755 tutorial root/bin/tutorial
  mkdir -p root/usr/share/learn
  cp -r learn/ref learn/lib learn/pools learn/levels learn/scenarios learn/projects learn/c root/usr/share/learn/
  # acts (the level groupings the climb is narrated by) and syn (the syntax
  # labels every page carries) were read by the engine and never shipped: on
  # the stick both opened as nothing, 2>/dev/null, while the dev host -- where
  # every grader runs -- had them. ci's "learn ships what the engine reads"
  # check now derives this list's floor from the engine itself.
  cp learn/skip learn/skip-syntax learn/builtins learn/verbs learn/phrases learn/chains \
     learn/syntax learn/vs learn/bashisms learn/migrations learn/rekeys \
     learn/acts learn/syn root/usr/share/learn/
  # the full operator narrative -- boot ledger, refusals, the arsenal, the verbs
  # -- shipped offline so a booted stranger can read what this machine is, not
  # only how each command works. the curriculum is the how; this is the why.
  mkdir -p root/usr/share/doc/xos
  cp README.md root/usr/share/doc/xos/README

  # overlay carries the udhcpc script (without which dhcp silently configures
  # nothing) and the wordlist init turns the roothash into four spoken words.
  # the copy below was once a member of an && list; under `set -e` a failing
  # member of an && list does not abort, so a missing overlay produced a
  # quieter, more broken image instead of stopping. hence the explicit guard.
  [ -d overlay ] || { echo "FAIL: overlay/ missing" >&2; return 1; }
  cp -r overlay/. root/

  cp init root/init
  chmod +x root/init
  echo 'xos' > root/etc/hostname
  # without /etc/passwd, anything calling getpwuid() fails -- ii did exactly that
  # nobody: the uid learn drops to before it runs an answer. root is the only
  # human; this account owns nothing, logs in nowhere, and exists so that
  # plain file permissions -- not a denylist of command names -- are what
  # stand between a learner's typo and the encrypted state partition.
  printf 'root:x:0:0:root:/tmp/home:/bin/sh\nnobody:x:65534:65534:nobody:/:/bin/false\n' > root/etc/passwd
  printf 'root:x:0:\nnobody:x:65534:\n' > root/etc/group
  # ssh: the dir where a baked authorized_keys lives (verity-covered). empty by
  # default. set XOS_SSH_KEY=path/to/key.pub to bake a public key in here so
  # remote login works on first boot without any p3 -- baking it into the
  # verity-covered root means the key itself is attested, not just present.
  mkdir -p root/etc/dropbear
  if [ -n "${XOS_SSH_KEY:-}" ]; then
    [ -f "$XOS_SSH_KEY" ] || { echo "FAIL: XOS_SSH_KEY=$XOS_SSH_KEY not found" >&2; return 1; }
    # this file rides the verity root -- world-readable and attested. it MUST be
    # a public key. a fat-fingered private key here would bake a secret into the
    # signed image (G67 would then fail the build), so reject it now, at the one
    # site that knows the path, naming the file. KEYPAT is the same private-key
    # marker G11/G67 and the commit hook carry.
    if grep -qE "$KEYPAT" "$XOS_SSH_KEY"; then
      echo "FAIL: XOS_SSH_KEY=$XOS_SSH_KEY is a PRIVATE key -- bake the .pub, never the private half" >&2; return 1; fi
    grep -qE '^[^#]*(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp[0-9]+@openssh\.com)[[:space:]]' "$XOS_SSH_KEY" \
      || { echo "FAIL: XOS_SSH_KEY=$XOS_SSH_KEY does not look like an ssh public key (no ssh-ed25519/ssh-rsa/ecdsa/sk- line)" >&2; return 1; }
    install -m 0600 "$XOS_SSH_KEY" root/etc/dropbear/authorized_keys
    # init concatenates this with the p3 key file. a baked key with no final
    # newline fused with the first p3 line into one unparseable key -- and
    # rejected BOTH, locking the image key out. the newline is part of the key.
    sed -i -e '$a\' root/etc/dropbear/authorized_keys
    echo "  baked $XOS_SSH_KEY -> etc/dropbear/authorized_keys"
  fi
  # sourced by every interactive ash (via $ENV). vi editing on by default --
  # the shell has emacs keys too and there is no busybox option to remove them,
  # but nothing here ever leaves vi, so it is vi-only in practice.
  #
  # scrub: flash rots in a drawer, and verity only checks blocks it READS -- a
  # stick can be half-dead and boot fine until the mission needs the bad half.
  # reading every covered byte forces the check now: a rotten block panics the
  # machine on the spot (that is the alarm working), a clean pass means every
  # byte still matches the signed hash tree. a function, not a binary: the
  # command surface (and the learn corpus that must cover it) stays fixed.
  # /etc/shrc ships from overlay/etc/shrc, copied in with the rest of the
  # overlay above. it was a quoted heredoc here until 2026-10-03; a shell file
  # of its own parses, shellchecks and diffs as one, and the gates that read a
  # build.sh function body by its closing brace no longer stop at a brace
  # inside the shrc text (the rootfs() range read ended 250 lines early, and
  # G64's /^clone() {/ matched the on-stick clone before the host one).
  [ -f root/etc/shrc ] || { echo "FAIL: overlay/etc/shrc did not land in root/etc" >&2; return 1; }
  # root is read-only, so resolv.conf must live on the tmpfs udhcpc writes to
  ln -sf /tmp/resolv.conf root/etc/resolv.conf
  # same reason: cryptsetup takes lock files under /run/cryptsetup and refuses
  # to touch a device without them. /run points into the tmpfs init creates.
  ln -sf /tmp/run root/run
  # squashfs-tools >= 4.6 reads SOURCE_DATE_EPOCH itself and clamps every
  # timestamp to it -- and hard-errors if you also pass -mkfs-time, which is
  # how this was caught. -processors 1 keeps block ordering deterministic.
  mksquashfs root rootfs.squashfs -noappend -no-xattrs -all-root -comp gzip -quiet -processors 1
  printf '  rootfs.squashfs: %d bytes (%d files)\n' "$(stat -c%s rootfs.squashfs)" "$(find root -type f -o -type l | wc -l)"
}

verity() {
  say "building verity hash tree"
  cp rootfs.squashfs xos.img
  local data blocks
  data=$(stat -c%s xos.img)
  if [ $((data % 4096)) -ne 0 ]; then
    data=$(( (data / 4096 + 1) * 4096 ))
    truncate -s "$data" xos.img
  fi
  blocks=$((data / 4096))

  # fixed salt AND fixed uuid: the image must be reproducible. a random salt
  # would change the root hash for identical content; a random uuid left the
  # root hash stable and still changed the image bytes on every single build.
  veritysetup format xos.img xos.img \
    --hash-offset="$data" --data-blocks="$blocks" --salt="$SALT" --uuid="$VUUID" > verity.info
  local rh
  rh=$(awk '/Root hash/{print $NF}' verity.info)
  [ ${#rh} -eq 64 ] || { echo "FAIL: no root hash from veritysetup" >&2; return 1; }
  echo "$rh" > verity.roothash

  # veritysetup writes a superblock AT the hash offset, so the hash tree
  # itself starts one block later -- pointing the table at $blocks lands on
  # the superblock and the root mount fails with no verity error at all.
  # xos.test is DEBUG scaffolding, and the cmdline lives INSIDE the UKI
  # signature -- so it must never ship in a production image. selftest.sh
  # rebuilds a test-flavoured UKI for its own runs.
  local testflag=""
  [ "${XOS_TEST:-0}" = 1 ] && testflag=" xos.test xos.teststate xos.testwg"
  # the root is named by PARTUUID, not /dev/vda: on a real machine the stick is
  # /dev/sda|sdb, and dm-init resolves PARTUUID= via early_lookup_bdev. one
  # cmdline, inside one signature, boots qemu and metal alike.
  #
  # dm-mod.waitfor polls (5ms) until the device exists -- usb enumeration takes
  # a second or two, and without this dm-init tries exactly once and the root
  # never appears (a silent hang rootwait cannot fix). there is NO timeout knob
  # in the kernel: an unsupported controller hangs at "waiting for device", visibly.
  #
  # console: serial LAST so it owns /dev/console (harness scrapes serial, output
  # stays byte-identical); tty0 first mirrors printk to a real screen.
  #
  # default dm-verity refuses only the bad block and lets boot continue if
  # nothing essential needed it. panic_on_corruption makes ANY corruption
  # anywhere fatal -- the machine refuses to run at all, which is the point.
  #
  # random.trust_cpu=1: nothing persists here, so the entropy pool starts empty
  # on every boot with no seed file to carry across. the kernel already defaults this
  # to true and dropped the Kconfig symbol, so pinning it on the signed cmdline
  # is how it stays true across a kernel bump. the kernel always MIXES rdrand
  # rather than using it alone -- a backdoored instruction cannot dictate the
  # output, only fail to contribute.
  #
  # oops=panic + panic=-1: any oops becomes a fatal, non-recoverable halt (no
  # boot-and-limp). page_alloc.shuffle=1 activates SHUFFLE_PAGE_ALLOCATOR. the
  # rest of the hardening is compiled in (lockdown, kstack offset, slab), which
  # is stronger than a cmdline flag -- there is no runtime knob left to flip.
  # console=ttyS0,19200: a hardware serial terminal (a vt320 on a com port) tops
  # out at 19200 baud and receives garbage above it, so the early-boot kernel
  # console speaks at a rate it can render. init sets usb-serial lines to match.
  local dev="PARTUUID=$PU_ROOT"
  printf 'dm-mod.waitfor=%s dm-mod.create="vroot,,,ro,0 %d verity 1 %s %s 4096 4096 %d %d sha256 %s %s 1 panic_on_corruption" root=/dev/dm-0 ro rootfstype=squashfs rootwait init=/init oops=panic panic=-1 page_alloc.shuffle=1 random.trust_cpu=1 xos.epoch=%s console=tty0 console=ttyS0,19200%s\n' \
    "$dev" "$((blocks * 8))" "$dev" "$dev" "$blocks" "$((blocks + 1))" "$rh" "$SALT" "$SOURCE_DATE_EPOCH" "$testflag" > cmdline.txt

  printf '  xos.img: %d bytes  root hash: %s
' "$(stat -c%s xos.img)" "$rh"
}

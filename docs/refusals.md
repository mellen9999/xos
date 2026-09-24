# when it refuses

every alarm below is a designed refusal, not a malfunction: xos fails loud and
stops rather than continue quietly, so a message here means the check worked. what
to do, worst first.

**panic: `dm-verity device corrupted`.** a verity-covered byte didn't match the
signed root hash -- the root was altered, or the medium is failing. never safe to
boot this stick again as-is. reflash from source on a machine you trust
(`./build.sh install /dev/sdX`); your p3 survives it. if a fresh flash still panics,
the medium is dying -- replace it. `scrub` reads every covered byte on demand rather
than waiting to hit the bad one.

**the banner speaks the wrong fingerprint words.** different words mean a different
or superseded image; no words at all mean a tampered one that won't verify. don't
unlock p3. compare against the words you wrote down -- if they're wrong this isn't
your current stick, so set it aside and boot the one whose words match.

**`recon: MACHINE ... CHANGED since your last visit`.** the dmi/pci/usb/cpu
inventory differs from your last unlock on this machine -- new hardware, a firmware
change, or a different host wearing the same identity. read the `gone:`/`new:` diff.
expected it (new machine, added a dongle)? run `recon_accept` to make the current
inventory the baseline. didn't? treat the host as suspect and don't unlock p3 -- the
alarm repeats every boot until accepted, so it never clears itself.

**the boot ledger reads lower than you left it** (`boot 44` when you left 47). p3
was rolled back to an older snapshot -- someone restored a previous state partition,
erasing whatever you did since. the current bytes are kept beside the count, not
overwritten. assume p3 isn't what you left; anything written since the rolled-back
boot is gone.

**the machine powers off within seconds of unplugging.** the dead-man switch,
working as designed -- the boot device left the usb bus. plug it back in and boot
again. to run without it (a machine that renumbers usb under load), boot
`xos.notether`.

**LUKS keeps rejecting the passphrase.** three tries, then it gives up. the
passphrase is only ever what you set at `addstate` time -- no recovery and no
backdoor, by design. if it's genuinely lost the state is unrecoverable; reflash and
`addstate` a fresh p3. check you're unlocking the boot stick and not another
encrypted disk that happens to be attached (init prefers the boot stick, but names
what it found).

**wireguard/ssh never come up after unlock.** they start only when p3 holds
`wg0.conf` and an `authorized_keys` (or a baked-in key); a missing or malformed
`wg0.conf` is silent by design -- an attacker holding the stick mustn't learn the
tunnel exists. check the two files at the root of p3 (`/tmp/home`), then re-unlock.
auth attempts land in `/tmp/ssh.log` (tmpfs, gone at reboot).

**a build gate prints `FAIL` / `GATES FAILED`.** the message names the gate and the
mismatch; nothing was flashed. common ones: `G13 ... image matches committed digest
FAIL` after an intentional change means the pin is stale -- `./build.sh pin` if this
build is the one you meant. `G13 reproducible (needs the pinned toolchain) SKIP`
(yellow, not a failure) means this gcc/systemd isn't the one the pin was taken with,
so reproducibility couldn't be checked here.

**the self-test prints `RESTORE FAILED -- the tree may still hold a TEST
uki/stick`.** a `selftest.sh` run was interrupted before it put the production
artifacts back, leaving test-flavoured signed images in the tree. rebuild before
shipping anything: `./build.sh unlock && ./build.sh verity && ./build.sh uki &&
./build.sh stick && ./build.sh lock`. G31 refuses a production cmdline carrying a
test flag, so a real build catches it too.

**`./build.sh repro` says `NOT REPRODUCIBLE`.** a clean clone of HEAD built
different bytes than `image.sha256` on the *same* toolchain -- source and pin
disagree. changed the source? re-pin. didn't? something in the tree isn't what was
committed. `unverified` (yellow) instead means the toolchain differs and nothing was
checked -- run `./build.sh crepro`, which rebuilds inside the pinned toolchain
container where the fingerprint matches by construction, so the comparison actually
fires. if crepro itself says `NOT REPRODUCIBLE`, the committed source and pin
genuinely disagree -- re-pin with `./build.sh cpin` only if you meant to change the
source.

**the arsenal build refuses a source** (`sha256 mismatch` / `commit ... not checked
out`). a pinned tarball or repo no longer matches `arsenal/arsenal.pins` -- upstream
moved a tag, replaced a tarball, or the download was tampered. don't loosen the pin
to make it build. confirm the new artifact is legitimate, then update the pin in
`arsenal/arsenal.pins` in a visible diff.

**`clone` refuses, or its readback fails.** `clone` will not write if the target
is not a whole removable disk, is smaller than the source, or if the source is
not an xos stick (no xos root + state partitions) -- a mistyped source must not
image an unrelated disk onto your spare. after the copy it reads every byte back
under direct i/o; `clone readback mismatch` means the write did not land, so the
spare is not trustworthy -- retry on a different stick or port before relying on
it. the source is only ever read, so it is never at risk.

**an operational failure, not a security alarm.** a few boot messages mean p3 or
its bookkeeping had a problem, not that anything was tampered with, and none stop
the boot: `ledger CORRUPT -- kept as evidence, count restarts` (the boot-count file
didn't parse -- the count resets, the old one is kept to inspect), `ledger FAILED`
and `recon FAILED: could not record the baseline` (a write to p3 didn't land --
the medium is full, failing, or was pulled), `recon FAILED: empty inventory` (the
hardware probe returned nothing), and `note: boot device unknown` (init couldn't
tell which disk it booted, so it won't prefer any for state). each says the state
partition is unreliable this boot -- treat what it holds as suspect until a clean
boot writes it again.

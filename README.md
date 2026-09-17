# xos

an operating system that lives on a usb stick and can prove it hasn't been
altered. plug it in, boot it, and the machine's own disks are never touched --
xos ships no driver that can see them. pull the stick and nothing remains.

every block of the root is covered by a hash tree. the root hash rides the
kernel cmdline, the cmdline rides inside a signed boot image, and the firmware
won't run that image unless it's signed by a key you hold. change one byte and
the kernel refuses the read -- it never reports the tamper after the fact.

## quickstart

    ./build.sh flash          # newbie one-word: build as you, sudo only the flash
    ./build.sh install        # same, but you handle root yourself
    ./build.sh all            # build only
    ./selftest.sh             # adversarial self-test: every tamper must be refused
    ./build.sh boot           # boot the real chain in qemu
    ./build.sh bootusb        # same, through emulated usb

`flash` is the whole thing in one word: plug in only the target stick, run it as
**yourself** (not root), and it builds a signed image, then escalates *just* the
device write under sudo -- so the build never runs as root. it asks twice by
design: your signing passphrase (to sign the image) and your login password
(sudo, to write the disk). `install` does the same build-and-flash but leaves
root to you (run it under sudo, which builds as root too).

both list **removable** disks only, make you type the disk's model back before
they write, read every byte back with direct i/o, and offer to add the encrypted
state partition. name the disk -- `./build.sh flash /dev/sdX` -- when more than
one is attached.

    ./build.sh usb /dev/sdX       write a stick (install wraps this)
    ./build.sh addstate /dev/sdX  add the encrypted state partition
    ./build.sh revoke IMAGE       retire a superseded image
    ./build.sh vouch              check every commit is signed by the pinned key
    ./build.sh repro              rebuild a clean clone, compare to the pin
    ./build.sh crepro             the same, inside the pinned toolchain (docker)
    ./build.sh reseal             change the signing-key passphrase

## the chain

    firmware (secure boot, your enrolled keys)
      verifies -> signed UKI  (kernel + cmdline in one signed PE)
                    carries -> verity root hash + the root's PARTUUID
                                 covers -> every block of a read-only squashfs

one key at the top, complete coverage at the bottom.

a signature says who signed an image, never when -- so an old release stays
bootable forever unless something says otherwise. `revoked` is that something:
the authenticode digest of every image that must never boot again. `revoke`
won't add a digest it can't confirm -- it reads the number sbsign signed out of
the one field that holds it and demands its own match. a digest merely *present*
somewhere in the blob doesn't count: everything past the signed content is the
image's own unsigned space, so that would let an image revoke itself in name only.

`./build.sh dbx` writes it two ways -- into the qemu varstore for the self-test,
and as `/xos-keys/dbx.auth` on the stick, the form real firmware takes. enroll it
in setup mode with the keys, **before** `PK.der` (enrolling PK turns enforcement
on); firmware then refuses the old image exactly where it refuses an unsigned one.
adding a revocation to a machine already enforcing means re-entering setup mode:
the shipped `dbx.auth` carries no KEK signature, and user mode only accepts signed
variable updates. entries are permanent.

## the stick

    p1 ESP 64 MiB   signed UKI + your public keys
    p2      8 MiB   verity root -- the fort. fixed, never sized to the image
    p3     rest     LUKS2 + hmac-sha256, encrypted state

those sectors are identical in every version there will ever be -- which is what
makes an update an update: `./build.sh install /dev/sdX` over a stick you already
use rewrites p1 and p2, stops exactly where p3 begins, and restores p3's partition
entry. it refuses to write at all if it finds anything of yours inside the region
the image covers.

boot from your firmware's boot menu. the root is named by PARTUUID, never
`/dev/sda`, and the kernel waits for that partition -- the same signed image boots
whether the stick enumerates first or third.

the banner prints four words derived from the root hash: `this image is: cobra
drifter payday willow`. write them on the stick. a swapped or superseded stick
speaks different words; a tampered one doesn't speak at all. 32 bits -- enough to
tell your own images apart, not a substitute for the signature.

p3 is opt-in. decline it and nothing survives a reboot; `xos.nostate` makes a
stick that never even looks for one.

## remote access

off by default, switchable on only from the encrypted partition -- an attacker
holding the stick can't see it exists.

the model is dial-OUT. xos connects over wireguard to a machine you control --
its peer -- and the ssh server binds the wireguard address alone. xos never opens
a port on the network it's plugged into: a port scan from that LAN finds nothing.
you reach xos by sshing back down the tunnel.

no wifi driver ships -- a wifi chip needs a firmware blob, and a blob in the image
is a build failure. use usb: an android tether or a usb-ethernet dongle both
enumerate as a wired NIC over xhci and need no firmware. `udhcpc` runs on either.

enable it with two files at the root of p3 (mounts at `/tmp/home`):

    wg0.conf          your private key, the peer's public key + endpoint, Address =
    authorized_keys   the peer's public ssh key -- or bake it into the image
                      with XOS_SSH_KEY=peer.pub ./build.sh all

next unlock, init brings up `wg0`, generates the ssh host key on p3 if absent, and
starts dropbear bound to the tunnel. auth events land in `/tmp/ssh.log` (tmpfs,
gone at reboot). pubkey only -- password auth is compiled out, xos is single-user
root.

wireguard roams, so a changed ip resumes rather than resets, and abduco keeps the
session alive: ssh back in, `abduco -a work`, into what was running.
`dropbearkey`, `dbclient` and `wg` ship for driving it by hand.

## serial terminal

xos drives a real hardware terminal -- a vt320 on the desk -- as a first-class
console. plug it into a com port, or into a usb-serial adapter (ftdi, cp210x,
ch341, pl2303, or a cdc-acm device); both enumerate without a firmware blob.

each serial line gets its own supervised login shell at **19200 8N1, xon/xoff,
80x24, `TERM=vt320`** -- a vt320's own limits, and the rate it can render (above
19200 it receives garbage). the kernel's early-boot console speaks 19200 too, so
a com-wired terminal is legible from the first message, not just once init runs.
the fbcon virtual terminals stay `TERM=linux`; only the serial lines are vt320.

the usb adapter enumerates during boot, so **plug it in before booting**. two
signed-cmdline knobs cover other hardware: `xos.term=vt220`, `xos.baud=9600`.

nothing on screen is utf-8: the banner and `learn` degrade to ascii on a terminal
that reports no utf-8, so box-drawing and colour never reach a glass that can't
render them.

## secure boot

`./build.sh all` generates a platform key (PK), key-exchange key (KEK) and
signing key (db) under `keys/`; the public halves land on the stick under
`/xos-keys/`. the private halves are encrypted with a passphrase it asks for, and
every later build asks again. `keys/` is gitignored.

1. in firmware setup, clear the existing keys / enter setup mode
2. enroll `db.der`, `KEK.der` and (if present) `dbx.auth`, then `PK.der` last --
   enrolling the PK exits setup mode and turns enforcement on

no shim and no MOK: you hold the only key, on purpose.

**danger.** replacing the platform key removes the vendor chain. any other OS on
that machine that relied on the factory keys -- Windows especially -- stops booting
until you restore them, and a few laptops have bricked on non-factory PKs. only do
this on hardware you own and can reflash.

## reproducible

the same source produces the same bytes. `image.sha256` commits the digest this
tree builds, so the signature attests to source you can read. `./build.sh repro`
checks it: a clean clone of HEAD, built and compared to the pin.

a different toolchain yields different bytes for innocent reasons, and a version
string only *describes* one -- so the toolchain is pinned by content.
`repro/Dockerfile` fixes a base image by digest and points pacman at a frozen Arch
archive day; `./build.sh crepro` builds a clean clone inside it and reproduces the
exact `image.sha256` bytes anywhere, needing only docker -- no signing key, no
matching host. off the pinned toolchain the gate records a fingerprint and skips
with a note rather than failing. the pin itself is taken in the container
(`./build.sh cpin`), and its committed bytes match an independent full-Arch host
build -- so the source reproduces across environments, not just one box.

the repo holds recipes, never artifacts: the pre-commit hook refuses any staged
file whose magic says ELF, PE or squashfs, and `build.sh` points `core.hooksPath`
at `githooks/` every run, so a fresh clone is walled from its first build.
`./build.sh ci` is the buildless gate tier -- shellcheck, every first-party script
parsed, the learn authoring ledger, and a check that `repro/Dockerfile` still pins
its base by digest and packages to a frozen archive day -- no key, no image build,
so a runner or a pre-push hook can run it on every push (`XOS_NOVERIFY=1` overrides
for a WIP branch). the building gates and the qemu self-test stay a deliberate
`./build.sh gates` / `./selftest.sh`.

## checking it yourself

none of this asks you to trust whoever built the stick. four rungs, cheapest
first:

    ./build.sh vouch    git + ssh-keygen -- whose source this is
    ./build.sh ci       reads the tree -- no key, no build, no network, no root
    ./build.sh crepro   docker only -- rebuilds a clean clone, compares to the pin
    ./selftest.sh       your own keyset, qemu -- every tamper must be refused

`crepro` reproduces the `image.sha256` bytes from source you can read, on your
machine, with no signing key involved anywhere -- so the digest a signature
attests to is the digest this source makes. but reproducibility has no opinion
about *whose* source it is: whoever takes the publishing account can push a tree
that reproduces perfectly. `vouch` is the other half -- every commit since the
epoch carries an ssh signature from one key, pinned by fingerprint in `build.sh`
and by public key in `signers`, and G52 checks it on every gate run. run it
first; it is the cheapest rung and the only one that answers *who*.

by hand, if you would rather not have `build.sh` vouch for `build.sh`:

    git -c gpg.ssh.allowedSignersFile=signers verify-commit HEAD
    git -c gpg.ssh.allowedSignersFile=signers log --format='%G? %h' | grep -v '^G '

the fingerprint `vouch` prints is worth something only against a copy you did
not get from this clone. what it buys and what it does not is in `SOURCES.md`,
"this tree's own commits".

`selftest.sh` generates its own keys and boots the real chain in a vm before
attacking it, so it proves the chain without trusting the keys that ship. the
signed-image gates in between are `./build.sh gates`.

what all of it is *for* is written down in `docs/threat-model.md` -- what xos
defends against, what it does not, and what the attacker is assumed to be able to
do. a claim not measured against that file is not a claim this tree makes.

## what the build enforces

the build fails, loudly, on any of these. `install` and `usb` run every one
before a byte is written.

- **binaries** -- dynamically linked, non-PIE, executable stack, built without
  the stack protector, setuid, world-writable, or undeclared by `manifest`
- **kernel** -- a module loader, a missing hardening option, a forbidden one, a
  firmware blob, or a driver that could bind sata, nvme or mmc
- **the chain** -- a root hash disagreeing with the filesystem, a cmdline missing
  its hardening params, a stick whose partitions don't match the built artifacts,
  a plaintext signing key on disk, an image listed in `revoked`
- **sources** -- a tarball whose digest misses `sources.sha256`, or (with gpg) one
  missing its maintainer's committed signature and pinned fingerprint, or one
  signed by an expired or revoked key. gpg prints "valid signature" for a dead key
  exactly as for a live one, and expiry is the only thing that stops a leaked key
  signing forever -- so the fingerprint match alone isn't enough. revocation is
  never waivable. lvm2 alone signs with a key it let expire (2022-06-09, still not
  extended anywhere); that waiver is named in `fetch()`, printed yellow every
  build, its fingerprint and digest pinned as ever
- **reproducibility** -- image, filesystem or verity hash off `image.sha256` on the
  pinned toolchain
- **provenance** -- a commit since `SIGN_EPOCH` not signed by the key pinned in
  `build.sh` and `signers`, a second or swapped key in `signers`, or a history
  rewritten so the epoch is no longer an ancestor of HEAD. the pre-push hook
  refuses to publish one; G52 refuses to call a build green with one
- **the shell** -- a second shell parser, a `/bin/sh` that is not busybox ash, or a
  first-party script the shipped ash cannot parse
- **the corpus** -- a shipped command with no `learn` entry or the reverse, a
  question whose answer is not in the reference it cites, a lesson using a command
  no earlier lesson introduced, a documented flag neither taught nor retired in
  `learn/skip`, a reference page out of sync with the binary's own `--help`

the self-test then boots the real chain in a vm and expects every attack to fail:
a flipped root byte, a flipped hash-tree byte, an unsigned kernel, a tampered
signature, a revoked image, a cert outside the trust store -- over both virtio and
emulated usb.

## hardening

who this defends against, what it protects, and where it deliberately gives up is
in `docs/threat-model.md` -- every item below is measured against it.

the kernel is built from `tinyconfig` up, so nothing is on that wasn't asked for.
on: KASLR, stack protector, page-table isolation, the full spectre/meltdown set,
hardened usercopy, slab freelist randomization + hardening, kernel-stack-offset
randomization, lockdown in confidentiality mode. out: /dev/mem, /dev/port, kexec,
hibernation, io_uring, the bpf syscall, ia32 emulation, the fixed vsyscall page.

at runtime the root is read-only and verity-covered; /proc, /sys, /tmp are
nosuid,nodev,noexec; every writable byte lives on tmpfs and is gone at reboot.
memory is zeroed on alloc and free. userland is static-PIE with the stack
protector, stack-clash protection and a non-executable stack. tls trusts exactly
the CAs in `trust/`, compiled into the binary rather than read from a directory, so
the set rides the hash tree.

- **fresh mac every boot** -- no stable link-layer identity for the networks it
  visits. `xos.realmac` opts back in, `xos.nonet` skips the network entirely
- **clock floor** -- `xos.epoch`, the build date pinned in the signed uki, is a
  floor the clock can't fall below. no ntp; init reads the Date header off an https
  response whose chain reaches the compiled-in anchors
- **dead-man switch** -- when the boot device is usb, init watches it and powers
  off within seconds of removal. `xos.notether` opts out
- **machine recon** -- on unlock, init diffs dmi identity, the pci/usb buses and the
  cpu against your last visit to that machine, and prints changes before the first
  console. clear an alarm with `recon_accept`
- **boot ledger** -- p3 counts its own opens and shows the count at unlock. boot 44
  when you left it at 47 means a rollback
- **scrub** -- type `scrub` to read every verity-covered byte now: a rotten block
  panics on the spot, a clean pass means every byte still matches
- **irc** -- type `irc` to reach libera over tls in one word: it brings up the
  tunnel and ii, then a channel is a directory you `tail -f` and an `in` you echo
  to. `irc <nick> <server>` overrides the defaults; a registered nick's password
  rides `IRC_PASS` from the environment, never argv or history

the one attack surface this knowingly accepts: the usb-net drivers (rndis,
cdc-ether) that make tethering work, and the usb-serial drivers (ftdi, cp210x,
ch341, pl2303, cdc-acm) that reach a hardware terminal, parse whatever a
plugged-in device claims to be. reachable only by physically plugging something
in, and none of them can bind a disk.

## when it refuses

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

## the parts

anchors and the case for each part are in `SOURCES.md`.

| part | does |
|---|---|
| linux 6.18 lts, from `tinyconfig` | the kernel -- every driver is opt-in |
| busybox 1.38 | the userland and the one shell (ash) -- 135 applets in one binary |
| bearssl + `tlstunnel.c` | tls, with the trust set compiled in |
| cryptsetup | luks2 + hmac integrity for p3 |
| dropbear | ssh server, client and keygen in one binary -- the one listening service |
| wg | configures the in-kernel wireguard |
| abduco | detach and reattach a session |
| ii | irc, as files in a directory |
| learn | the curriculum |

## the arsenal

capability rides p3 -- an operator key, wireguard home, offline docs, wordlists,
static tools, loot -- from what you carry and plug in, never from widening the
signed fort. every C source is pinned in `arsenal/arsenal.pins` and checked before
it builds (a tarball by sha256, a git repo by commit; gate G47); `arsenal/arsenal.lock`
is the post-build attestation, source + sha256:

| tool | does |
|---|---|
| ffuf | web fuzzer -- brute paths, params, vhosts against a target |
| httpx | fast http prober -- which hosts/ports answer, titles, tech |
| nuclei | template-driven vuln and misconfig scanner |
| subfinder | passive subdomain discovery |
| dnsx | fast dns toolkit -- resolve, bruteforce, record types |
| gobuster | dir/dns/vhost brute-forcer |
| masscan | internet-scale port scanner, fast and stateless |
| nmap | host/service/version/os scan + nse scripting -- what masscan can't |
| tcpdump | packet capture and inspection on the wire |
| chisel | tcp/udp tunnel over http -- pivot through a firewall |
| socat | swiss-army socket relay -- pivot, port-forward, tls-wrap, listen |
| ligolo-proxy / ligolo-agent | reverse-tunnel pivot -- proxy (operator) + agent (target) |
| hydra | online service login brute-forcer (ssh/http/ftp/...) |
| john | offline password hash cracker (bleeding-jumbo, cpu-only) |
| pspy | watch processes/cron without root -- local privesc enumeration |
| links | text-mode browser -- reads served zims and any html/http, no gui |
| mutool | pdf reader -- `draw -F txt` turns a pdf into readable text |
| frotz | z-machine interpreter -- plays the carried interactive-fiction library |
| whois | who registered this domain/ip -- the one basic busybox doesn't ship |
| jq | json parser/filter -- for the json every other tool here emits |
| rg | ripgrep -- fast search over the staged corpora and loot |
| zstd | decompress the .zst images, firmware and payloads nothing else here reads |
| ddrescue | image a dying disk -- copies what reads, logs the bad ranges, resumes |
| strace | trace a binary's syscalls -- files, connections, why it exits |
| testdisk | rebuild a lost or corrupt partition table and its boot sectors |
| photorec | carve files back off a formatted or damaged filesystem by signature |
| smartctl | a drive's SMART health -- is it dying before you trust or wipe it |
| file | identify an unknown blob by content -- where strings only shows text |
| binwalk | scan a firmware blob for embedded filesystems, keys and streams |
| cc | compile C on the stick -- tcc + a musl sysroot, one static toolchain |
| radare2 | reverse a binary offline -- disassemble, analyse, hex-edit (r2/rabin2/rax2) |
| python | full cpython 3.12 -- scripting, a repl, `http.server` |
| sqlmap | automated sql-injection detection and exploitation |
| impacket | windows/ad attack suite -- secretsdump, ntlmrelayx, psexec, kerberos (70 tools, pure-python) |
| kiwix-serve | serves offline zims (wikipedia, survival docs) on localhost |
| kiwix-search | greps the zim corpus without a server |

`sh ~/tools/arsenal` lists every carried tool on the stick itself, one line each,
and cross-checks `arsenal.lock` so an attested-but-missing or present-but-unattested
binary shows up loud instead of hiding. `arsenal <tool>` prints that tool's
canonical recipes and `arsenal chains` the mission workflows (recon, web, crack,
pivot, ad, forensics, reverse) wired end-to-end -- the offline how-to, in
`arsenal-playbook`; the base cli it sits on is taught by `learn`.

a lean static cli kit reaches most of a full kali install without the ~600 packages
and a desktop -- and unlike kali, every byte of it is reproducible and attested:

| area | kali | xos |
|---|---|---|
| net/forensics base | nc, dd, dig, ssh | nc netstat nslookup wget tftp telnet ip arp ping traceroute dbclient wg tlstunnel cryptsetup dd losetup blkid strings tar sha* |
| port/host scan | nmap, masscan | masscan nmap (musl) |
| packet capture | tcpdump, tshark | tcpdump; tshark not built (glib/static) |
| web fuzz/recon | ffuf, gobuster | ffuf gobuster nuclei httpx |
| recon suite | amass, subfinder | subfinder dnsx (go) |
| pivot / tunnel | chisel, socat | chisel socat ligolo (musl+go) |
| brute / crack | hydra, john | hydra john (musl); hashcat out (needs gpu) |
| disk recovery | ddrescue, testdisk | ddrescue testdisk photorec smartctl (musl) |
| reversing | radare2, gdb | radare2 strace file (musl); gdb not built -- r2's own debugger + strings + python cover it |
| exploit framework | metasploit | out (ruby+db) -- carried python covers it |
| python tooling | sqlmap, impacket | carried python 3.12 via xexec -t |
| wireless | aircrack, wifite | out -- no wifi drivers, by design |
| gpu cracking | hashcat | out -- passive/headless |
| gui | burp, wireshark | out -- no gui |

two states behind the gaps: **out** is excluded on principle -- wireless, gpu, gui
and metasploit want drivers, hardware or a runtime xos won't carry, so they are
never coming. **not built** is buildable static-musl but not yet done (gdb, tshark)
-- the current toolset, not a promise of the next one.

## learn

teaches the whole shipped command surface -- the ~180 applets, builtins and binaries
this image contains -- in dependency order. 30 levels, 800-odd questions, generated
not fixed: each rolls its own filenames, values and file contents, and is graded by
*running* what you type as `nobody` in a throwaway sandbox, so `sort -u` and
`sort | uniq` both pass.

tab opens that command's reference under the prompt, tab again takes it away. every
level ends with a named boss -- five questions, thirty seconds each, no hints -- and
the last level is the machine itself.

    learn             resume where you stopped
    learn review      re-ask the weakest cards first
    learn daily       one hard question a day, boss rules, same for everyone
    learn place       climb the curriculum, skip what you already know
    learn challenge   timed chains, one life -- unlocked at the last boss
    learn scenario    narrative missions against the real machine
    learn project     write a program against a spec, graded by running it
    learn shell       a shell in that same sandbox, to try things in
    learn autopsy     read your own shell history, name the drills that fit
    learn fumbles     what you got wrong at the real prompt -- off until you say on

with no argument `learn` names the level it would open and where it picks up
before it opens anything -- restart clears that one level's place and nothing
else, and `n` wipes every ledger for a new game, behind a second confirm.

`learn fumbles on` puts a hook in the prompt: a command that exits nonzero at
`/bin/sh` has its NAME appended to a queue, and the next `learn` brings every card
whose answer runs that command due. a name is written only if this image ships a
reference page for it, so a password, a hostname or a typo is not a name that can
be recorded -- that is the mechanism, not a filter. no argument, path, time or exit
code is stored, ever, and nothing about it is on by default.

`learn/install.sh` puts it on this host as a standalone command -- the corpus and
the tree's own busybox, no stick needed. progress lives under `~/.local/state` and
re-installing never costs you it.

everything shipped is documented and nothing documented is unshipped -- both
directions are build gates, not intentions.

## carrying it

rough split of a 16 GB stick: ~1 GB tools, 1-2 GB wordlists (a SecLists subset --
Discovery/Fuzzing/Passwords -- plus rockyou.txt flat at `~/wordlists/`), 1-2 GB docs
(exploit-db mirror, man-pages, gtfobins, an rfc text bundle), the rest loot.

the knowledge payload is bigger and never needs exec, so it rides a separate exFAT
stick labelled `XOS-KNOW` instead of p3, everything read-only. xos builds the
readers, never the content: kiwix (serve + search) and frotz ship from source, but
the zims are reference payload you populate yourself.

| payload | what | source |
|---|---|---|
| wikipedia | offline zim -- `kiwix-search` from the cli, or `kiwix-serve` + `links` | you supply |
| where-there-is-no-doctor | field medicine when there's no signal and no clinic | you supply |
| ifixit | hardware repair guides for the field | you supply |
| maps | offline map zims | you supply |
| `games/if` | the interactive fiction frotz plays | staged + pinned |

the one payload xos stages is the game library: morale is a supply, and interactive
fiction is the one genre a text-only box runs natively. `arsenal/build-games.sh`
fetches the freeware stories from the IF Archive, verifies each against a sha256 pin
and writes `arsenal/games.lock` -- infocom's zork is still copyright, so you drop
your own copy into `games/if/` by hand.

carried binaries can't run from noexec p3 directly -- `arsenal/xexec` opens a
single-use exec surface: tmpfs mounted exec, the tool copied in, the mount flipped
read-only, torn down on exit. `xexec -t dir entry` stages a whole interpreter tree
instead of one binary -- how carried python runs, since its `.so` extensions need a
dlopen that noexec p3 can't give directly.

a hardware write-protect switch is a per-boot mode: on is vault (stick unalterable,
runs in ram, zero trace, nothing persists), off is work (p3 unlocks read-write, loot
persists).

playbook: attest (clean boot, prove it -- learn 29 / scenario 10), unlock p3, reach
disks over usb only (the host's internal nvme/sata never enumerates, by design), run
tools through xexec, phone home over the wireguard tunnel and ssh back down it.

two things never rebuild from source: your p3 secrets and your signing keys. back
both up offline, apart from the stick and each other -- a fireproof metal plate,
ideally split. everything else -- image, stick, tools -- rebuilds from source. a
write-protect switch has to be confirmed hardware, not a firmware toggle, or vault
mode is fiction. gear beyond the stick: a passive usb<->sata/nvme adapter (reach a
host's internal disk), a usb-a<->usb-c adapter, a second cloned stick stored apart.

provisioning: `build.sh usb /dev/sdX`, `build.sh addstate /dev/sdX`, then optionally
`arsenal/build-wordlists.sh` / `arsenal/build-docs.sh` to stage wordlists/docs (and
`arsenal/build-games.sh` for the if library onto the XOS-KNOW stick), then
`arsenal/provision.sh /dev/sdX3` opens p3 and lays down `tools/` + the arsenal --
write-protect off (work mode) first, since p3 has to be writable. idempotent --
re-run to update.

## limits

- not a general distro -- no package manager, no compiler
- pre-xHCI machines (roughly pre-2012) are out of scope
- no wifi: wired, usb-ethernet or tether, plus wireguard
- iphone tethering needs usbmuxd, which xos does not ship; android works
- don't enroll these keys on hardware whose own secure boot chain you still need

## license

gplv3 -- the scripts, configs and recipes in this repo. see `LICENSE`. a fork
that hardens xos and ships it has to ship its source too, which is the same
property the stick itself claims: you can read what you are running.

a built image is an aggregate, not a relicensing. linux, busybox, cryptsetup and
lvm2 stay under their own terms (gplv2-only, mostly), dropbear and bearssl under
theirs; `SOURCES.md` names every upstream and where it came from. build it
yourself and the question never arises -- hand someone a stick and you are
distributing their work as well as this, on their terms.

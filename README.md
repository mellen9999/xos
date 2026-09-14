# xos

an operating system that lives on a usb stick and can prove it hasn't been
altered. plug it in, boot it, and the machine's own disks are never touched --
xos ships no driver that can see them. pull the stick and nothing remains.

every block of the root is covered by a hash tree. the root hash sits on the
kernel cmdline, the cmdline sits inside a signed boot image, and the firmware
refuses to run that image unless it's signed by a key you hold. change one byte
and the kernel refuses the read rather than reporting it afterwards.

## quickstart

    ./build.sh install        # build, flash a removable disk, verify every byte
    ./build.sh all            # build only
    ./selftest.sh             # adversarial self-test: every tamper must be refused
    ./build.sh boot           # boot the real chain in qemu
    ./build.sh bootusb        # same, through emulated usb

`install` only ever lists **removable** disks, makes you type the disk's model
back before it writes, reads every byte back with direct i/o, and offers to add
the encrypted state partition. name the disk -- `./build.sh install /dev/sdX` --
if more than one removable disk is attached.

    ./build.sh usb /dev/sdX       write a stick (install wraps this)
    ./build.sh addstate /dev/sdX  add the encrypted state partition
    ./build.sh revoke IMAGE       retire a superseded image
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
it lists the authenticode digest of every image that must never boot again.
`revoke` refuses to add a digest it cannot confirm: it reads the number sbsign
signed out of the one field that holds it, and demands its own match. a digest
that is merely *present* somewhere in the signature blob is not good enough --
everything past the signed content is the image's own unsigned space, so that
would let an image get itself revoked in name only.
`./build.sh dbx` writes it two ways -- into the qemu varstore for the
self-test, and as `/xos-keys/dbx.auth` on the stick, which is the form real
firmware takes. enroll it in setup mode alongside the keys, **before** `PK.der`,
since enrolling PK is what turns enforcement on. the firmware then refuses the
old image at exactly the place it refuses an unsigned one.

adding a revocation to a machine already enforcing means going back to setup
mode and enrolling again: the shipped `dbx.auth` carries no KEK signature, and
a machine in user mode only accepts signed variable updates. entries are
permanent.

## the stick

    p1 ESP 64 MiB   signed UKI + your public keys
    p2      8 MiB   verity root -- the fort. fixed, never sized to the image
    p3     rest     LUKS2 + hmac-sha256, encrypted state (~15.9 GB on a 16 GB stick)

those sectors are the same in every version there will ever be, which is what
makes an update an update: `./build.sh install /dev/sdX` over a stick you
already use rewrites p1 and p2, stops exactly where p3 begins, and puts p3's
partition entry back. it refuses to write at all if it finds anything of yours
inside the region the image covers.

boot it from your firmware's boot menu. the root is named by PARTUUID, never
`/dev/sda`, and the kernel waits for that partition -- the same signed image
boots whether the stick enumerates first or third.

the banner prints four words derived from the root hash: `this image is: cobra
drifter payday willow`. write them on the stick. a swapped or superseded stick
speaks different words; a tampered one does not speak at all. four words is 32
bits -- enough to tell your own images apart, not a substitute for the signature.

p3 is opt-in. decline it and nothing survives a reboot; `xos.nostate` makes a
stick that never even looks for one.

## remote access

off by default, and switchable on only from the encrypted partition -- an
attacker holding the stick cannot see that it exists.

the model is dial-OUT. xos connects over wireguard to a machine you control --
its peer -- and the ssh server binds to the wireguard address alone. xos never
opens a port on the network it is plugged into: a port scan from that LAN finds
nothing. you reach xos by sshing back down the tunnel.

no wifi driver ships: a wifi chip needs a firmware blob, and a blob in the image
is a build failure. use usb -- an android phone tethering or a usb-ethernet
dongle both enumerate as a wired NIC over xhci and need no firmware. `udhcpc`
runs on either.

to enable it, put two files at the root of p3 (it mounts at `/tmp/home`):

    wg0.conf          your private key, the peer's public key + endpoint, Address =
    authorized_keys   the peer's public ssh key -- or bake it into the image
                      with XOS_SSH_KEY=peer.pub ./build.sh all

on the next unlock init brings up `wg0`, generates the ssh host key on p3 if it
is not there yet, and starts dropbear bound to the tunnel. auth events land in
`/tmp/ssh.log` -- tmpfs, gone at reboot. pubkey only; password auth is compiled
out and xos is single-user root.

wireguard roams, so a changed ip resumes rather than resets, and abduco keeps
the session alive -- ssh back in, `abduco -a work`, into what was running.
`dropbearkey`, `dbclient` and `wg` ship for driving it by hand.

## secure boot

`./build.sh all` generates a platform key (PK), key-exchange key (KEK) and
signing key (db) under `keys/`; the public halves land on the stick under
`/xos-keys/`. the private halves are encrypted with a passphrase it asks for,
and every later build asks again. `keys/` is gitignored.

1. in firmware setup, clear the existing keys / enter setup mode
2. enroll `db.der`, `KEK.der` and (if present) `dbx.auth`, then `PK.der` last --
   enrolling the PK exits setup mode and turns enforcement on

no shim and no MOK: you hold the only key, on purpose.

**danger.** replacing the platform key removes the vendor chain. any other OS on
that machine that relied on the factory keys -- Windows especially -- stops
booting until you restore them, and a few laptops have bricked on non-factory
PKs. only do this on hardware you own and can reflash.

## reproducible

the same source produces the same bytes. `image.sha256` commits the digest this
tree builds, so the signature attests to source you can read. on a different gcc
the bytes differ for innocent reasons, so the gate records a toolchain
fingerprint and skips with a note rather than failing. `./build.sh repro` checks
from the other side: a clean clone of HEAD, built and compared to the pin.

but a version string only *describes* a toolchain -- a stranger on another
distro still gets different bytes. so the toolchain is pinned by content:
`repro/Dockerfile` fixes a base image by digest and points pacman at a frozen
Arch archive day, and `./build.sh crepro` builds a clean clone inside it and
compares to the pin. it needs only docker -- no signing key, no matching host
toolchain -- and reproduces the exact `image.sha256` bytes anywhere. the pin
itself is taken there too (`./build.sh cpin`), so its toolchain line is the
container's; these committed bytes match an independent full-Arch host build,
so the source reproduces across environments, not just on one box.

the repo holds recipes, never artifacts -- the pre-commit hook refuses any
staged file whose magic says ELF, PE or squashfs. `build.sh` points
`core.hooksPath` at `githooks/` every run, so a fresh clone is walled from its
first build. `./build.sh ci` is the buildless gate tier -- shellcheck, every
first-party script parsed, the learn authoring ledger, and a check that
`repro/Dockerfile` still pins its base by digest and its packages to a frozen
archive day -- with no key and no
image build, so a self-hosted runner or a pre-push hook can run it on every
push (`XOS_NOVERIFY=1` overrides for a WIP branch). the building gates and the
qemu self-test stay a deliberate `./build.sh gates` / `./selftest.sh`.

## what the build enforces

the build fails, loudly, on any of these. `install` and `usb` run every one
before a byte is written.

- **binaries** -- dynamically linked, non-PIE, executable stack, built without
  the stack protector, setuid, world-writable, or undeclared by `manifest`
- **kernel** -- a module loader, a missing hardening option, a forbidden one, a
  firmware blob, or a driver that could bind sata, nvme or mmc
- **the chain** -- a root hash disagreeing with the filesystem, a cmdline
  missing its hardening params, a stick whose partitions don't match the built
  artifacts, a plaintext signing key on disk, an image listed in `revoked`
- **sources** -- a tarball whose digest misses `sources.sha256`, or (with gpg)
  one that misses its maintainer's committed signature and pinned fingerprint,
  or one signed by a key that has expired or been revoked. gpg prints its
  "valid signature" line for a dead key exactly as it does for a live one, and
  expiry is the only thing that ever stops a leaked key signing forever, so the
  fingerprint match is not on its own enough. revocation is never waivable.
  lvm2 is the one source that signs with a key it let expire (2022-06-09, still
  not extended on any keyserver); that waiver is named in `fetch()` and printed
  in yellow on every build, and its fingerprint and digest are pinned as ever
- **reproducibility** -- image, filesystem or verity hash off `image.sha256` on
  the pinned toolchain
- **the shell** -- a second shell parser, a `/bin/sh` that is not busybox ash,
  or a first-party script the shipped ash cannot parse
- **the corpus** -- a shipped command with no `learn` entry or the reverse, a
  question whose answer is not in the reference it cites, a lesson using a
  command no earlier lesson introduced, a documented flag neither taught nor
  retired in `learn/skip`, a reference page out of sync with the binary's own
  `--help`

the self-test then boots the real chain in a vm and expects every attack to
fail: a flipped root byte, a flipped hash-tree byte, an unsigned kernel, a
tampered signature, a revoked image, a cert outside the trust store -- over both
virtio and emulated usb.

## hardening

the kernel is built from `tinyconfig` up, so nothing is on that was not asked
for. on: KASLR, stack protector, page-table isolation, the full
spectre/meltdown set, hardened usercopy, slab freelist randomization and
hardening, kernel-stack-offset randomization, and lockdown in confidentiality
mode compiled in. compiled out: /dev/mem, /dev/port, kexec, hibernation,
io_uring, the bpf syscall, ia32 emulation and the fixed vsyscall page.

at runtime the root is read-only and verity-covered; /proc, /sys and /tmp are
nosuid,nodev,noexec. every writable byte lives on tmpfs and is gone at reboot.
memory is zeroed on both allocation and free. userland is static-PIE with the
stack protector, stack-clash protection and a non-executable stack. tls trusts
exactly the CAs in `trust/`, compiled into the binary rather than read from a
directory, so the set is covered by the hash tree.

- **fresh mac every boot** -- no stable link-layer identity for the networks it
  visits. `xos.realmac` opts back in; `xos.nonet` skips the network entirely
- **clock floor** -- `xos.epoch`, the build date pinned in the signed uki, is a
  floor the clock can never fall below. no ntp; init reads the Date header off
  an https response whose chain reaches the compiled-in anchors
- **dead-man switch** -- when the boot device is on usb, init watches it and
  powers the machine off within seconds of removal. `xos.notether` opts out
- **machine recon** -- on unlock, init diffs dmi identity, the pci and usb
  buses and the cpu against the last visit to that machine, and prints changes
  before the first console. clear an alarm with `recon_accept`
- **boot ledger** -- p3 counts its own opens and shows the count at unlock. a
  stick that says boot 44 when you left it at 47 was rolled back
- **scrub** -- type `scrub` to read every verity-covered byte now; a rotten
  block panics on the spot, a clean pass means every byte still matches

the one attack surface this knowingly accepts: the usb-net drivers (rndis,
cdc-ether) that make tethering work parse whatever a plugged-in device claims
to be. reachable only by physically plugging something in.

## when it refuses

every alarm below is a designed refusal, not a malfunction. the rule is the
same throughout: xos fails loud and stops rather than continuing quietly, so a
message here means the check worked. what to do, in order of how alarming it is.

**the machine panics with `dm-verity device corrupted`.** a verity-covered byte
did not match the signed root hash -- the root filesystem was altered, or the
medium is failing. it is never safe to boot this stick again as-is. reflash from
source on a machine you trust (`./build.sh install /dev/sdX`); your p3 survives a
reflash. if a fresh flash still panics, the flash medium is dying -- replace it.
run `scrub` on a stick you suspect to read every covered byte on demand rather
than waiting to hit the bad one.

**the banner speaks the wrong fingerprint words.** the four words are derived
from the root hash; different words mean a different or superseded image, no
words at all mean a tampered one that will not verify. do not unlock p3 on it.
compare against the words you wrote down; if they are wrong, this is not your
current stick -- set it aside and boot the one whose words match.

**`recon: MACHINE ... CHANGED since your last visit`.** the dmi/pci/usb/cpu
inventory differs from the last time you unlocked on this machine -- new
hardware, a firmware change, or a different host wearing the same identity. read
the `gone:`/`new:` diff. if you expected it (you moved to a new machine, added a
dongle), run `recon_accept` at the shell to make the current inventory the
baseline. if you did not expect it, treat the host as suspect and do not unlock
p3 -- the alarm repeats every boot until accepted, so it never clears itself.

**the boot ledger reads lower than you left it** (`boot 44` when you left 47).
p3 was rolled back to an older snapshot -- someone restored a previous state
partition, which erases whatever you did since. the current bytes are kept
beside the count, not overwritten. assume the p3 contents are not what you left;
anything written since the rolled-back boot is gone.

**the stick powers the machine off within seconds of unplugging.** the dead-man
switch, working as designed -- the boot device left the usb bus. plug it back in
and boot again. to run without it (a machine that renumbers usb under load),
boot with `xos.notether`.

**LUKS unlock keeps saying the passphrase is wrong.** three tries, then it gives
up. the passphrase is only ever what you set at `addstate` time -- there is no
recovery and no backdoor by design. if it is genuinely lost, the state is
unrecoverable; reflash and `addstate` a fresh p3. check you are unlocking the
boot stick and not another encrypted disk that happens to be attached (init
prefers the boot stick, but names what it found).

**wireguard/ssh never come up after unlock.** they start only when p3 holds
`wg0.conf` and an `authorized_keys` (or a baked-in key); a missing or malformed
`wg0.conf` is silent by design (an attacker holding the stick must not learn the
tunnel exists). check the two files at the root of p3 (`/tmp/home`), then re-unlock.
auth attempts land in `/tmp/ssh.log` (tmpfs, gone at reboot).

**a build gate prints `FAIL` / `GATES FAILED`.** the message names the gate and
the mismatch; nothing was flashed. common ones: `G13 ... image matches committed
digest FAIL` after an intentional change means the pin is stale -- `./build.sh
pin` if this build is the one you meant. `G13 reproducible (needs the pinned
toolchain) SKIP` (yellow, not a failure) means this gcc/systemd is not the one
the pin was taken with, so reproducibility could not be checked here.

**the self-test prints `RESTORE FAILED -- the tree may still hold a TEST
uki/stick`.** a `selftest.sh` run was interrupted before it put the production
artifacts back, leaving test-flavoured signed images in the tree. rebuild before
shipping anything: `./build.sh unlock && ./build.sh verity && ./build.sh uki &&
./build.sh stick && ./build.sh lock`. G31 refuses a production cmdline carrying a
test flag, so a real build catches it too.

**`./build.sh repro` says `NOT REPRODUCIBLE`.** a clean clone of HEAD built
different bytes than `image.sha256` on the *same* toolchain -- source and pin
disagree. if you changed the source, re-pin; if you did not, something in the
tree is not what was committed. `unverified` (yellow) instead means the toolchain
differs and nothing was checked -- rebuild on the pinned toolchain to get a real
answer. to get that real answer on any machine, run `./build.sh crepro`: it
rebuilds inside the pinned toolchain container, where the fingerprint matches by
construction, so the comparison actually fires. if crepro itself says
`NOT REPRODUCIBLE`, the committed source and pin genuinely disagree -- re-pin
with `./build.sh cpin` only if you meant to change the source.

**the arsenal build refuses a source** (`sha256 mismatch` / `commit ... not
checked out`). a pinned tarball or repo no longer matches `arsenal/arsenal.pins`
-- upstream moved a tag, replaced a tarball, or the download was tampered. do not
loosen the pin to make it build. confirm the new artifact is legitimate, then
update the pin in `arsenal/arsenal.pins` in a visible diff.

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
static tools, loot -- and comes from what you carry and plug in, never from
widening the signed fort. every C source is pinned in `arsenal/arsenal.pins`
and checked before it builds -- a tarball by sha256, a git repo by commit (gate
G47); `arsenal/arsenal.lock` is the post-build attestation, source + sha256:

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
| ligolo | reverse-tunnel pivot -- proxy (operator) + agent (target) |
| hydra | online service login brute-forcer (ssh/http/ftp/...) |
| john | offline password hash cracker (bleeding-jumbo, cpu-only) |
| pspy | watch processes/cron without root -- local privesc enumeration |
| links | text-mode browser -- reads served zims and any html/http, no gui |
| mutool | pdf reader -- `draw -F txt` turns a pdf into readable text |
| frotz | z-machine interpreter -- plays the carried interactive-fiction library |
| whois | who registered this domain/ip -- the one basic busybox doesn't ship |
| jq | json parser/filter -- for the json every other tool here emits |
| rg | ripgrep -- fast search over the staged corpora and loot |
| python | full cpython 3.12 -- scripting, a repl, `http.server` |
| sqlmap | automated sql-injection detection and exploitation |
| kiwix-serve | serves offline zims (wikipedia, survival docs) on localhost |
| kiwix-search | greps the zim corpus without a server |

`sh ~/tools/arsenal` lists every carried tool on the stick itself, one line
each, and cross-checks `arsenal.lock` so an attested-but-missing or
present-but-unattested binary shows up loud instead of hiding.

a lean static cli kit reaches most of a full kali install without the ~600
packages and a desktop -- and unlike kali, every byte of it is reproducible and
attested:

| area | kali | xos |
|---|---|---|
| net/forensics base | nc, dd, dig, ssh | nc netstat nslookup wget tftp telnet ip arp ping traceroute dbclient wg tlstunnel cryptsetup dd losetup blkid strings tar sha* |
| port/host scan | nmap, masscan | masscan nmap (musl) |
| packet capture | tcpdump, tshark | tcpdump; tshark not built (glib/static) |
| web fuzz/recon | ffuf, gobuster | ffuf gobuster nuclei httpx |
| recon suite | amass, subfinder | subfinder dnsx (go) |
| pivot / tunnel | chisel, socat | chisel socat ligolo (musl+go) |
| brute / crack | hydra, john | hydra john (musl); hashcat out (needs gpu) |
| reversing | radare2, gdb | gdb not built (static link); strings + python cover triage |
| exploit framework | metasploit | out (ruby+db) -- carried python covers it |
| python tooling | sqlmap, impacket | carried python 3.12 via xexec -t |
| wireless | aircrack, wifite | out -- no wifi drivers, by design |
| gpu cracking | hashcat | out -- passive/headless |
| gui | burp, wireshark | out -- no gui |

two states behind the gaps: **out** is excluded on principle -- wireless, gpu,
gui and metasploit want drivers, hardware or a runtime xos won't carry, so they
are never coming. **not built** is buildable static-musl but not yet done (gdb,
tshark) -- a statement of the current toolset, not a promise of the next one.

## learn

teaches the whole shipped command surface -- the ~180 applets, builtins and
binaries this image contains -- in dependency order. 30 levels, 800-odd
questions, generated rather than fixed: each rolls its own filenames, values and
file contents, and is graded by *running* what you type as `nobody` in a
throwaway sandbox, so `sort -u` and `sort | uniq` both pass.

tab opens that command's reference under the prompt, tab again takes it away.
every level ends with a named boss -- five questions, thirty seconds each, no
hints -- and the last level is the machine itself.

    learn             resume where you stopped
    learn review      re-ask the weakest cards first
    learn daily       one hard question a day, boss rules, same for everyone
    learn place       climb the curriculum, skip what you already know
    learn challenge   timed chains, one life -- unlocked at the last boss
    learn scenario    narrative missions against the real machine
    learn autopsy     read your own shell history, name the drills that fit

`learn/install.sh` puts it on this host as a standalone command -- the corpus
and the tree's own busybox, no stick needed. progress lives under
`~/.local/state` and re-installing never costs you it.

everything shipped is documented and nothing documented is unshipped -- both
directions are build gates, not intentions.

## carrying it

rough split of a 16 GB stick: ~1 GB tools, 1-2 GB wordlists (a SecLists subset
-- Discovery/Fuzzing/Passwords -- plus rockyou.txt flat at `~/wordlists/`), 1-2
GB docs (exploit-db mirror, man-pages, gtfobins, an rfc text bundle), the rest
loot.

the knowledge payload is bigger and never needs exec, so it rides a separate
exFAT stick labelled `XOS-KNOW` instead of p3, everything read-only. xos builds
the readers, never the content: kiwix (serve + search) and frotz ship from
source, but the zims are reference payload you populate yourself.

| payload | what | source |
|---|---|---|
| wikipedia | offline zim -- `kiwix-search` from the cli, or `kiwix-serve` + `links` | you supply |
| where-there-is-no-doctor | field medicine when there's no signal and no clinic | you supply |
| ifixit | hardware repair guides for the field | you supply |
| maps | offline map zims | you supply |
| `games/if` | the interactive fiction frotz plays | staged + pinned |

the one payload xos stages is the game library: morale is a supply, and
interactive fiction is the one genre a text-only box runs natively.
`arsenal/build-games.sh` fetches the freeware stories from the IF Archive,
verifies each against a sha256 pin and writes `arsenal/games.lock` -- infocom's
zork is still copyright, so you drop your own copy into `games/if/` by hand.

carried binaries can't run from noexec p3 directly -- `arsenal/xexec` opens a
single-use exec surface: tmpfs mounted exec, the tool copied in, the mount
flipped read-only, torn down on exit. `xexec -t dir entry` stages a whole
interpreter tree instead of one binary, which is how carried python runs -- its
`.so` extensions need dlopen, and noexec p3 can't give that directly.

a hardware write-protect switch is a per-boot mode: on is vault (stick
unalterable, runs in ram, zero trace, nothing persists), off is work (p3 unlocks
read-write, loot persists).

playbook: attest (clean boot, prove it -- learn 29 / scenario 10), unlock p3,
reach disks over usb only (the host's internal nvme/sata never enumerates, by
design), run tools through xexec, phone home over the wireguard tunnel and ssh
back down it.

two things never rebuild from source: your p3 secrets and your signing keys.
back both up offline, apart from the stick and each other -- a fireproof metal
plate, ideally split. everything else -- image, stick, tools -- rebuilds from
source. a write-protect switch has to be confirmed hardware, not a firmware
toggle, or vault mode is fiction. gear beyond the stick: a passive
usb<->sata/nvme adapter (reach a host's internal disk), a usb-a<->usb-c adapter,
a second cloned stick stored apart.

provisioning: `build.sh usb /dev/sdX`, `build.sh addstate /dev/sdX`, then
optionally `arsenal/build-wordlists.sh` / `arsenal/build-docs.sh` to stage
wordlists/docs (and `arsenal/build-games.sh` for the if library onto the
XOS-KNOW stick), then `arsenal/provision.sh /dev/sdX3` opens p3 and lays down
`tools/` + the arsenal -- write-protect off (work mode) first, since p3 has to be
writable. idempotent -- re-run to update.

## limits

- not a general distro -- no package manager, no compiler
- pre-xHCI machines (roughly pre-2012) are out of scope
- no wifi: wired, usb-ethernet or tether, plus wireguard
- iphone tethering needs usbmuxd, which xos does not ship; android works
- don't enroll these keys on hardware whose own secure boot chain you still need

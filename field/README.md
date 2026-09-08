# field kit -- the 16GB BLU stick, in full

The signed root (p1+p2) is the fort: ~8MiB, read-only, verity-checked, blind to
the host's internal disks, ships no way to run code you drop on it. Nothing here
changes that. Everything below is *carried* on the encrypted state partition
(p3) -- data, not part of the signed image -- so the fort's proofs (learn 29-30)
stay literally true while you gain a field kit on top.

The rule, for life: **capability comes from what you carry (p3) and what you
plug in (USB). Never from widening the signed trust surface.**

## the stick, end to end (16GB)

    offset      part   size      what
    0           gap    1 MiB     -
    1 MiB       p1 ESP 64 MiB    signed UKI + enrollment keys (firmware reads it)
    65 MiB      p2     ~8 MiB    verity root: the fort (busybox, learn, wg, ssh, cryptsetup...)
    ~73 MiB     p3     ~15.9 GB  LUKS2 + hmac-sha256, fills the rest -- everything you carry

p3 already grows to fill the device (build.sh addstate). It mounts over `$HOME`,
`nosuid,nodev,noexec`, and is opt-in at boot (skip it and the stick is a
pristine appliance that records nothing).

### where the 16GB actually goes

You do NOT want 16GB of tool binaries -- a curated static arsenal plus a static
python is under 1GB. The gigabytes are wordlists, offline intel, and loot:

    ~/tools/       ~0.5-1 GB   static binaries + xexec (+ optional static python)
    ~/wordlists/   ~1-2 GB     SecLists, rockyou, custom
    ~/docs/        ~1-2 GB     offline: exploit-db mirror, CVE data, man/RFCs, maps
    ~/loot/        ~10+ GB     pulled files, disk images (dd a whole small drive)
    ~/authorized_keys ~/wg0.conf ~/ssh_host_key ~/ledger ~/recon/   (init-owned, tiny)

## running a carried tool -- xexec

p3 is noexec, so a carried binary cannot execute directly (deliberate W^X).
`xexec` opens a single-use exec surface: a tmpfs mounted exec, the tool copied
in, the mount flipped read-only (write-once), the tool run, the whole mount torn
down on exit. A writable+executable area never persists.

    sh ~/tools/xexec ~/tools/nmap -sn 10.0.0.0/24

`sh xexec` bootstraps from noexec p3 because the shell only reads the script;
only the binary it launches needs the exec surface. Root required (mounting is).

## write-protect: the two modes

The BLU stick's hardware write switch is a per-boot mode:

    switch ON   vault   stick provably unalterable; read tools/keys, run in RAM
                        (xexec's surface is tmpfs), zero trace; NO persistence
    switch OFF  work    unlock p3 read-write; save loot, update recon, persist

xexec already works switch-ON (tmpfs is RAM). Full vault mode still needs init
to open p3 read-only on write-protected media and skip its writes (ledger, ssh
host key, recon) -- that is a phase-2 init change. With the switch ON, loot goes
to RAM or an attached USB drive, not the stick. (learn 09 teaches the switch as
what closes the unsigned-metadata gap.)

## do we have "full kali"? -- honest matrix

No, and we do not want to. Kali is ~600 packages + a desktop, most never
touched, none provable. xos carries a lean static CLI kit and reaches most of
the *field* capability. Four ways a tool gets here, easiest first:

- **shipped (fort):** busybox + xos's own binaries -- already yours.
- **Go static:** `CGO_ENABLED=0` yields a static binary with zero musl fuss.
  The whole modern recon/pivot ecosystem drops in as-is. Trivial.
- **musl static-pie C:** builds against the same toolchain the fort uses. Some
  effort per tool, but the heavy hitters port.
- **carried static python** (musl, ~30-50MB, phase 3): unlocks the entire
  Python ecosystem -- the escape hatch for anything not natively static.

    capability          kali                 xos plan
    ----------------    -----------------    --------------------------------
    net/forensics base  nc, dd, dig, ssh     SHIPPED: nc netstat nslookup wget
                                              tftp telnet ip arp ping traceroute
                                              dbclient wg tlstunnel cryptsetup
                                              dd losetup blkid strings tar sha*
    port/host scan      nmap, masscan        masscan BUILT; nmap deferred (musl C++)
    packet capture      tcpdump, tshark      tcpdump BUILT; tshark out (glib)
    web fuzz/recon      ffuf, gobuster       ffuf gobuster nuclei httpx  BUILT
    recon suite         amass, subfinder     subfinder dnsx naabu        (Go)
    pivot / tunnel      chisel, socat        chisel BUILT; ligolo/socat next
    brute / crack       hydra, john          hydra, john (musl); hashcat OUT (GPU)
    reversing           radare2, gdb         radare2 / rizin (musl); gdb hard
    exploit framework   metasploit           OUT (ruby+db) -- use sliver + carried python
    python tooling      sqlmap, impacket     via carried static python  (phase 3)
    wireless            aircrack, wifite     OUT -- no wifi drivers, by design
    gpu cracking        hashcat              OUT -- passive/headless hardware
    gui                 burp, wireshark      OUT -- no GUI

What is permanently out (wireless, GPU, GUI, metasploit-the-framework) is out on
principle -- drivers, hardware, provability -- not for lack of trying. Everything
else is a build-and-carry away, and the strategy scales to near-full CLI parity.

## the field playbook

1. **Attest.** Clean-boot on the host. Prove it: learn 29 / scenario 10 --
   verity root read-only, no module loader, no /dev/mem, host disks invisible.
2. **Unlock.** p3 passphrase (or skip for a zero-trace appliance).
3. **Disk work.** The host's internal NVMe/SATA never enumerates (by design).
   Reach any drive over USB -- a passive keychain USB<->SATA/NVMe adapter turns
   a dead laptop's disk into `/dev/sda`. Image block-level:
   `dd if=/dev/sda of=~/loot/disk.img`, or mount untrusted read-only:
   `mount -o ro,nosuid,nodev,noexec /dev/sda1 /mnt` (learn 21-22).
4. **Run tools.** `sh ~/tools/xexec ~/tools/<tool> ...`.
5. **Phone home.** wireguard `wg0` dials out to the one peer you control; ssh
   over it. xos never listens on the host's network.

## the keychain (lifetime EDC)

Design by failure mode. The insight that orders everything: **only two things
are irreplaceable.** The image, the stick and the tools all rebuild from source
(that is what reproducible builds buy you). The only things you cannot recreate
are your **p3 secrets** (passphrase + encrypted data) and your **signing keys**
(PK/KEK/db -- without them you cannot rebuild a bootable signed stick). So the
lifetime priority is not gear, it is backing those two up offline and apart. The
rest is adapters.

    item                              prevents                              tier
    ------------------------------    ----------------------------------    ---------
    the xos stick (hw write switch)   -- the tool                           core
    USB<->SATA/NVMe adapter (passive) can't see host's internal disk        essential
    USB-A<->USB-C bidir adapter       can't plug into a modern/old host     essential
    metal backup: p3 pass + wg/ssh    lose the ring -> lose your life+home  LIFETIME
      keys, stored OFF the keychain
    2nd cloned stick, stored apart    stick lost / flash rot                resilience
    USB-ethernet dongle               dead NIC / wired offense (no wifi)    field

- get a stick with a **true hardware** write switch (Kanguru FlashBlu30, Netac
  U335 -- confirm it is hardware, not a software toggle), or vault mode is
  fiction.
- the **metal secret backup** is the one thing that must NOT ride the same
  keychain as the stick -- one lost ring should not cost both. a fireproof steel
  plate (cryptosteel-style), ideally a Shamir split across two locations.
- the **signing keys** live on your build machine, backed up offline at home --
  never the keychain. they are how you regenerate a lost stick.
- xos is a payload, not a computer: it still needs any x86-64 UEFI host to run.

Everything here is minimal and timeless on purpose: passive adapters and a metal
plate do not rot, need no firmware, and outlive any single stick.

## building the arsenal

Two build scripts, both writing static amd64 binaries into `./arsenal/`; the
nine currently built are pinned in `field/arsenal.lock` (source@version, size,
sha256 -- the arsenal's own attestation):

    ./field/build-arsenal.sh    # Go set: ffuf httpx nuclei subfinder dnsx
                                #   gobuster chisel   (needs go; CGO-free static)
    ./field/build-arsenal-c.sh  # musl-C: masscan tcpdump   (needs docker+alpine)

built and verified static + running: **ffuf httpx nuclei subfinder dnsx gobuster
chisel masscan tcpdump** (~290MB, they live in `~/.local/share/xos-arsenal/`).

deferred, honestly: **nmap** -- 7.95 is C++ and its static-musl link fights
Alpine's PIE-default toolchain (needs a per-object flag pass; phase-2b). masscan
covers fast scanning until then. next static C: socat, ligolo-ng, john, radare2.
carried static python (sqlmap, impacket, pwntools) is phase 3.

## provisioning a stick

when the BLU arrives, three steps put the whole kit on it:

    sudo ./build.sh usb /dev/sdX          # flash the signed stick
    sudo ./build.sh addstate /dev/sdX     # add encrypted p3 (sets passphrase)
    sudo ./field/provision.sh /dev/sdX3   # open p3, lay down tools/ + arsenal

`provision.sh` opens p3, mounts it, installs `xexec` + everything in
`~/.local/share/xos-arsenal/` into `~/tools/`, and creates `wordlists/ docs/
loot/`. point `XOS_WORDLISTS=` / `XOS_DOCS=` at staging dirs to fill those too.
idempotent -- re-run to update the arsenal on an existing stick.

keep it lean -- every binary is weight; busybox + the fort cover most of a
session, and 16GB is better spent on wordlists, intel, and loot.

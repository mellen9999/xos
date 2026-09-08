# field kit -- what you carry on p3

The signed root (p1+p2) is the fort: minimal, read-only, verity-checked,
blind to the host's internal disks, and it ships no way to run code you drop
on it. Nothing here changes that. Everything in this directory is *carried* on
the encrypted state partition (p3) -- data, not part of the signed image -- so
the fort's proofs (`learn` levels 29-30) stay literally true while you gain a
swiss-army knife on top of them.

The rule, for life: **capability comes from what you carry (p3) and what you
plug in (USB). Never from widening the signed trust surface.**

## p3 layout

p3 is LUKS2 + hmac-sha256, mounts over `$HOME`, `nosuid,nodev,noexec`. init
already owns some paths; the rest are conventions:

    ~/authorized_keys     operator ssh key            (init reads this)
    ~/wg0.conf            wireguard tunnel home        (init brings up wg0)
    ~/ssh_host_key        generated on first unlock    (init)
    ~/ledger              boot-count ledger            (init)
    ~/recon/              per-machine baselines        (init recon)
    ~/tools/              carried static binaries + xexec   (convention)
    ~/docs/              offline reference, maps, manuals  (convention)
    ~/loot/              pulled files, images, notes       (convention)

Put `field/xexec` at `~/tools/xexec` and your static binaries beside it.

## running a carried tool -- xexec

p3 is noexec, so a carried binary cannot be executed directly (that is the
W^X property, and it is deliberate). `xexec` opens a *single-use* exec surface:
a tmpfs mounted exec, the tool copied in, the mount flipped read-only, the tool
run, and the whole surface torn down on exit. A writable-and-executable area
never persists -- between two runs there is none.

    sh ~/tools/xexec ~/tools/nmap -sn 10.0.0.0/24

`sh xexec` bootstraps fine from noexec p3 because the shell only *reads* the
script; only the binary it launches needs the exec surface. Root is required
(mounting needs it) -- the console session is root.

## the field playbook

1. **Attest.** Clean-boot on the host. Prove the machine is what you signed:
   `learn` level 29 / scenario 10 (the sweep) -- verity root read-only, no
   module loader, no /dev/mem, host disks invisible.
2. **Unlock.** Enter the p3 passphrase when prompted. Skip it and the stick is
   a pristine appliance that records nothing.
3. **Disk work.** The host's internal NVMe/SATA never enumerates (by design).
   Reach any drive over USB -- a $10 keychain USB<->SATA/NVMe adapter turns a
   dead laptop's disk into `/dev/sda`. Image it block-level (no FS parser runs):
   `dd if=/dev/sda of=~/loot/disk.img`, or mount read-only and untrusted:
   `mount -o ro,nosuid,nodev,noexec /dev/sda1 /mnt` (levels 21-22).
4. **Run tools.** `sh ~/tools/xexec ~/tools/<tool> ...`.
5. **Phone home.** wireguard `wg0` dials out to the one peer you control; ssh
   over it. xos never listens on the host's network.

## required kit (on the keychain, beside the stick)

- a passive **USB <-> SATA/NVMe adapter** -- this, not a kernel driver, is how
  the stick sees internal disks. Keeps the fort untouchable in situ.

## carried arsenal -- candidates (phase 2: static musl-pie builds)

Nothing offensive lives in the signed image; these are binaries you build
static and drop in `~/tools/`. Candidates worth building for a network/recon/
forensics kit (buildability confirmed per-tool in phase 2):

    nmap tcpdump socat ncat masscan   -- network recon / pivot
    mtr iperf3 ethtool                -- link + path diagnosis
    (forensics is mostly busybox already: dd, losetup, blkid, strings, cmp)

Keep it minimal: every tool is weight on a low-RAM passive box, and busybox +
the fort already cover most of what a field session needs.

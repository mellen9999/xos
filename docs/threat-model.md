# threat model

what xos defends, against whom, and where it deliberately gives up. every
hardening decision is measured against this file, not against paranoia. if a
change doesn't move a line here, it isn't security -- it's decoration, and
decoration is bloat.

`trust.manifest` enumerates everything this file's conclusions rest on -- every
host tool, pinned source, container package, prebuilt blob and trust anchor --
and G60 checks it against the tree on every push. prose that nothing checks is
how the EFI stub stayed unpinned while being honestly described.

## the one sentence

xos is a bootable, tamper-evident, disk-blind usb stick for using a computer you
don't fully trust without leaking into it or letting it leak into you -- and for
proving the stick itself is exactly what its source says.

## who we defend against

listed by how likely they are to actually happen to the person carrying this
stick. effort is spent top-down.

- **the finder / thief / borrower.** the stick is lost, stolen, seized at a
  border, or handed to someone for five minutes. they now hold the physical
  medium. **most likely breach, so it gets the most defense.**
- **the untrusted host.** you boot on a machine you don't own -- a hotel pc, a
  friend's laptop, a lab box. it may be compromised, logging, or hostile.
- **the network you're plugged into.** the LAN wants to scan you, fingerprint
  you, or watch your traffic.
- **the tamperer with a window.** someone had brief physical access to the stick
  and tried to alter it, swap it, or roll it back, then handed it back.
- **whoever takes the publishing account.** github credentials, a session, a
  token. they can push whatever they like, and a reproducible build will
  reproduce it faithfully -- reproducibility answers *what was built*, never
  *whose source it was*. -> every commit since `SIGN_EPOCH` is ssh-signed by a
  key that is not the push key, pinned in `build.sh` and `signers`, checked by
  `./build.sh vouch` and G52 and walled at push.
- **you, six months ago.** the build was wrong: an unsigned tarball, a swapped
  dependency, a key committed to git, a non-reproducible artifact. **self-inflicted
  compromise is the second-most-likely breach and the repo's history proves it.**

## who we do NOT defend against

naming these is the point -- it's what keeps the effort honest.

- **an adversary who can run code on the stick's kernel at boot before verity, or
  reflash your firmware.** if they own the trust root they own you; no amount of
  userland hardening buys it back.
- **a state-level or "super-AI" adversary with unlimited resources aimed
  specifically at you.** if that is your threat model you have already lost, and
  every hour spent on anti-forensics, evasion, or tinfoil layers against them is
  an hour stolen from defending against the finder and the bad build -- the
  threats that are real. we don't build for the apocalypse; we build a correct
  artifact.
- **rubber-hose / coercion.** there is no deniability layer and no hidden volume
  by design. a passphrase you can be forced to give up isn't a defense we pretend
  to offer.
- **the usb-net parsers (rndis, cdc-ether) and usb-serial parsers (ftdi, cp210x,
  ch341, pl2303, cdc-acm).** knowingly accepted attack surface, reachable only by
  physically plugging a device in, and none can bind a disk. documented, not
  defended.
- **the author's own machine while it is signing.** the build host is trusted
  here by definition -- it holds the sealed image key and now the ssh signing
  key too. a key on a compromised host signs whatever it is told. a signature
  proves the key was present, never that the person was.
- **hardware implants / evil-maid firmware below our chain.** recon catches a
  *changed* host; it can't vouch for one that was hostile from the factory.

## what is actually being protected

not "secrets from the NSA." concretely:

1. **the credentials on p3** -- the wireguard key, the ssh keys, the operator
   loot. these walk off when the stick does. → LUKS2, opt-in, no backdoor, remote
   access invisible until unlocked.
2. **the integrity of the running system** -- that the code executing is the code
   the signature attests. → the verity chain, secure boot, revocation.
3. **your non-leakage into the host** -- no writes to its disks, nothing left at
   reboot. → disk-blind kernel, everything-on-tmpfs, dead-man switch.
4. **your non-leakage to the network** -- no stable identity, no open ports. →
   fresh mac, dial-out-only, no listening service on the LAN.
5. **the correctness of the artifact itself** -- that the stick is what its
   source claims. → signed sources, pinned deps, reproducible build, no secrets
   in the image, fail-loud gates.

## the test a change must pass

before any hardening ships, answer:

1. which adversary above does this stop, and are they above or below the "do NOT
   defend" line? below the line → don't build it.
2. which of the five protected things does it protect? none → it's decoration.
3. does it fail loud and safe, or can it break quietly? quiet failure is a bug,
   not a feature.
4. does it cost the finder/bad-build defense to buy defense against someone we've
   already conceded? if so, it's a net loss even if it "adds security."

a change that can't name its adversary and its protected asset doesn't ship.

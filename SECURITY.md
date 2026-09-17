# security

xos claims that a stick can prove it hasn't been altered. that claim is worth
testing, and a hole in it is worth hearing about before anyone else finds it.

## reporting

use github's private advisory form:

    https://github.com/mellen9999/xos/security/advisories/new

not a public issue -- an issue publishes the bug the moment you file it. the
advisory is private, and it opens a private fork to fix it in.

no email, no pgp key, no bounty. one person reads these.

## in scope

the five things `docs/threat-model.md` says are actually protected. a report
that lands on one of these is a real report:

1. **the credentials on p3** -- luks2, opt-in, no backdoor
2. **the integrity of the running system** -- the verity chain, secure boot,
   revocation
3. **non-leakage into the host** -- no writes to its disks, nothing left at
   reboot
4. **non-leakage to the network** -- no stable identity, no open ports
5. **the correctness of the artifact** -- signed sources, pinned deps,
   reproducible build, fail-loud gates

anything that makes a gate pass while the thing it checks is false is in scope
by definition, and is the most interesting report you can send.

## already known -- please don't report these

each of these is documented, deliberate, and not going to change. naming them
here is meant to save you the afternoon.

conceded adversaries (`docs/threat-model.md`, "who we do NOT defend against"):

- code execution on the stick's kernel before verity, or a firmware reflash --
  if they own the trust root they own you
- a state-level adversary aimed specifically at you
- rubber-hose / coercion -- there is no deniability layer and no hidden volume,
  by design
- the usb-net parsers (rndis, cdc-ether) and usb-serial parsers (ftdi, cp210x,
  ch341, pl2303, cdc-acm) -- knowingly accepted, reachable only by plugging
  something in, and none can bind a disk. documented, not defended
- hardware implants or evil-maid firmware below the chain

accepted weaknesses in the supply chain (`SOURCES.md`):

- **lvm2's signing key expired 2022-06-09.** waived on purpose, printed yellow
  on every build, fingerprint and digest still pinned, and gated to exactly one
  waiver by G45 -- a second one fails the build
- **trust-on-first-use pins** -- bearssl, ii, abduco, popt, json-c and
  wireguard-tools publish no signature. the digest pin catches a later
  substitution, not a tarball that was already wrong. named in the tier table
- **the host toolchain is unpinned** -- gcc, binutils, musl's `libc.a` and ovmf
  come from the build host and are fingerprinted by version string, not by
  bytes. "built from source" is true of the applications and false of libc
- **the build host is trusted.** it holds the sealed signing key. that is the
  threat model, not an oversight

## a report that gets acted on fast

- which adversary from `docs/threat-model.md`, and which of the five assets
- how to reproduce it against current `main`
- what you expected the gate or the chain to do instead

if you're not sure whether it's in scope, send it anyway and say so.

## checking it yourself first

none of this needs a key or trust in whoever built the stick:

    ./build.sh ci       reads the tree -- no key, no build, no network, no root
    ./build.sh crepro   docker only -- rebuilds a clean clone, compares to the pin
    ./selftest.sh       your own keyset, qemu -- every tamper must be refused

## testing safely

test your own stick, on your own hardware. don't test against anyone else's
machine, and don't enroll these keys on hardware whose secure boot chain you
still need -- replacing the platform key removes the vendor chain, and a few
laptops have bricked on non-factory PKs.

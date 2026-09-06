# upstream sources and how each pin is anchored

`sources.sha256` pins every tarball by digest, checked before extraction (G8).
But a digest only says "this is the same bytes I saw once" -- what matters is
what that first sighting was anchored to. They are not equal:

| source | anchor | strength |
|---|---|---|
| linux 6.12.108 | sha256sums.asc published by kernel.org, matched byte for byte (downloaded and compared locally -- never transcribed from a summary) | good -- an independent published list |
| busybox 1.38.0 | sha256 published by busybox.net, matched | good -- same |
| bearssl | none available (bearssl.org publishes no .sig/.asc) | **weakest -- trust-on-first-use over TLS only** |
| ii | none available (suckless publishes no .sig/.asc/.sha256) | **weakest -- trust-on-first-use over TLS only** |
| abduco | none available (brain-dump.org publishes no .sig/.asc) | **weakest -- trust-on-first-use over TLS only** |
| cryptsetup 2.8.7 | sha256sums.asc published by kernel.org, matched | good -- an independent published list |
| util-linux 2.42.2 | sha256sums.asc published by kernel.org, matched | good -- same |
| lvm2 2.03.42 | maintainer PGP signature (Marian Csontos), matched against a committed key on every fetch | **best -- signed by the maintainer** |
| popt | none available | **weakest -- trust-on-first-use over TLS only** |
| json-c 0.19 | github release tarball, no signature | **weakest -- trust-on-first-use over TLS only** |
| wireguard-tools 1.0.20260223 | github release tag, no signature | **weakest -- trust-on-first-use over TLS only** |
| dropbear 2026.94 | official release tarball, maintainer PGP signature (Matt Johnston), matched against a committed key on every fetch | **best -- signed by the maintainer** |

Those pins protect against a *later* substitution, not against the tarball
having been wrong when first fetched. That is a real gap and is recorded here
rather than hidden behind a hash that looks as authoritative as the others.

Note what dropping bash cost this table, and what refilled it. bash was the
only entry anchored to a maintainer's PGP signature -- the strongest link here
-- and losing it emptied the "best" tier. lvm2 and dropbear now occupy it: the
upstream detached signatures and the maintainers' public keys are committed in
`sigs/`, the full key fingerprints are pinned as constants in `build.sh`
(`DB_FPR`, `LVM_FPR`), and `sigver()` matches tarball -> signature -> pinned
fingerprint on every fetch. A swapped pubkey file cannot satisfy the
fingerprint pin. Hosts without gpg skip the check loudly; the digest pin (G8)
still holds either way.

How the fingerprints were established (2026-09-05), each via two independent
channels: the signature fetched from the upstream site over TLS, and Arch
Linux's packaging `validpgpkeys` for the same projects. dropbear's key also
matches the one published in its own releases directory.

Adding cryptsetup took this repo from four pinned upstreams to nine in one
step -- the largest single increase in trust surface it has ever taken, and
three of the five newcomers are trust-on-first-use. It buys p3: state that is
encrypted AND authenticated, which is the only way a key can live on this stick
at all. Using the kernel's crypto through AF_ALG is what kept it to five rather
than six; an openssl or gcrypt backend would have been a sixth, and a large one.

wireguard-tools is the remaining remote-access pin without a signature:
git.zx2c4.com publishes no per-release signature, so the github tag stays
trust-on-first-use. dropbear -- the one listening service on the whole system,
so its pin matters more than most -- was moved off the github tag tarball
entirely: the maintainer signs the official release tarball, and a signature
only means something when it covers the artifact you actually build.

`learn` and its corpus are first-party: written in this repo, reviewed in its
diffs, covered by the hash tree like everything else. The reference entries are
generated from the built binaries' own `--help` output rather than transcribed,
so they cannot describe a flag the shipped binary lacks.

## pins move

pinned means pinned to a version, not to a year. the first re-pin (2026-09-06)
moved dropbear eight releases -- past CVE-2025-47203 in the client, CVE-2025-14282
and three further server fixes -- and the kernel sixty-five stable releases,
because "`git pull && ./build.sh all` relinks the whole system when a dependency
gets a CVE" is only true of a tree someone re-pins. two things made the move
cheap: dropbear and lvm2 are anchored to maintainer keys whose fingerprints are
already in `build.sh`, so a new release needs no new trust decision, only a new
`.asc` in `sigs/`; and `dropbear_()` checks every knob in
`dropbear.localoptions.h` against the new `default_options.h`, which is how a
knob that was never a knob (`DROPBEAR_CLI_INTERACT_AUTH`) was caught on the
first build instead of shipping as a silent no-op.

kernel.org signs each tarball (`.tar.sign`, over the uncompressed tar). that
would lift linux, cryptsetup and util-linux to the signed tier; it needs an
`xz -dc | gpg --verify` variant of `sigver()` and three fingerprints
cross-checked on two channels. not done yet -- named here so it is a gap on
the record, not a hash that looks as good as its neighbours.

## the toolchain is host-provided, and unpinned

Every shipped binary is *linked* against musl, but musl is not built from source
here -- `libc.a`, `rcrt1.o`, `crti.o`/`crtn.o` come from the host's
`/usr/lib/musl` (arch's `musl` package) and are covered by no digest in this
repo. The same is true of gcc, binutils, the systemd EFI stub, squashfs-tools,
cryptsetup and the OVMF firmware. So "built from source" is true of the
applications and false of libc and the toolchain.

`toolchain()` fingerprints tool *version strings*, not their bytes, so it
detects an innocent gcc upgrade (which changes the image for legitimate reasons)
but not a compromised compiler that reports the same version. Closing this would
mean a bootstrappable or content-addressed toolchain (Nix/Guix, `mkosi`, a
pinned musl build) -- out of scope for a lab artifact, but named here so the
reproducibility claim is not read as more than it is.

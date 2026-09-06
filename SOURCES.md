# upstream sources and how each pin is anchored

`sources.sha256` pins every tarball by digest, checked before extraction (G8).
But a digest only says "this is the same bytes I saw once" -- what matters is
what that first sighting was anchored to. They are not equal:

| source | anchor | strength |
|---|---|---|
| linux 6.18.49 | maintainer PGP signature (Greg Kroah-Hartman, `.tar.sign` over the uncompressed tar), matched against a committed key on every fetch | **best -- signed by the maintainer** |
| busybox 1.38.0 | maintainer PGP signature (Denys Vlasenko, `.sig` over the `.tar.bz2`), matched against a committed key on every fetch | **best -- signed by the maintainer** (oldest key in the tier: 2006 dsa-1024, sha-1 digest) |
| bearssl | none available (bearssl.org publishes no .sig/.asc) | **weakest -- trust-on-first-use over TLS only** |
| ii | none available (suckless publishes no .sig/.asc/.sha256) | **weakest -- trust-on-first-use over TLS only** |
| abduco | none available (brain-dump.org publishes no .sig/.asc) | **weakest -- trust-on-first-use over TLS only** |
| cryptsetup 2.8.7 | maintainer PGP signature (Milan Broz, `.tar.sign`), matched against a committed key on every fetch | **best -- signed by the maintainer** |
| util-linux 2.42.2 | maintainer PGP signature (Karel Zak, `.tar.sign`), matched against a committed key on every fetch | **best -- signed by the maintainer** |
| lvm2 2.03.42 | maintainer PGP signature (Marian Csontos), matched against a committed key on every fetch | **best -- signed by the maintainer** |
| popt | none available; fetched from fedora's source cache over TLS at a url naming its sha512 (upstream ftp.rpm.org is plain http) | **weakest -- trust-on-first-use over TLS only** |
| json-c 0.19 | github release tarball, no signature | **weakest -- trust-on-first-use over TLS only** |
| wireguard-tools 1.0.20260223 | github release tag, no signature | **weakest -- trust-on-first-use over TLS only** |
| dropbear 2026.94 | official release tarball, maintainer PGP signature (Matt Johnston), matched against a committed key on every fetch | **best -- signed by the maintainer** |

Those pins protect against a *later* substitution, not against the tarball
having been wrong when first fetched. That is a real gap and is recorded here
rather than hidden behind a hash that looks as authoritative as the others.

Note what dropping bash cost this table, and what refilled it. bash was the
only entry anchored to a maintainer's PGP signature -- the strongest link here
-- and losing it emptied the "best" tier. six entries now occupy it: linux,
busybox, cryptsetup, util-linux, lvm2 and dropbear. the upstream detached
signatures and the maintainers' public keys are committed in `sigs/`, the full
key fingerprints are pinned as constants in `build.sh` (`LNX_FPR`, `BB_FPR`,
`CS_FPR`, `UTL_FPR`, `LVM_FPR`, `DB_FPR`), and `sigver()` matches tarball -> signature ->
pinned fingerprint on every fetch. kernel.org signs the uncompressed tar, so
those three are verified through `xz -dc`. A swapped pubkey file cannot
satisfy the fingerprint pin. Hosts without gpg skip the check loudly; the
digest pin (G8) still holds either way.

How the fingerprints were established, each via two independent channels, and
never transcribed from a fetched summary (one such summary invented a kernel
digest once). dropbear and lvm2 (2026-09-05): the signature from the upstream
site over TLS, and Arch Linux's packaging `validpgpkeys`. linux, cryptsetup and
util-linux (2026-09-06): the kernel.org account keyring
(`git.kernel.org/pub/scm/docs/kernel/pgpkeys.git`, cross-signed inside the
kernel web of trust) as the first channel; for the second, kernel.org's own
signature page and WKD for Greg Kroah-Hartman, cryptsetup's FAQ for Milan Broz,
Arch's `validpgpkeys` for Karel Zak. every `.tar.sign` names its issuer
fingerprint, and each matched before anything was pinned. busybox (2026-09-06):
the key busybox.net itself publishes (`~vda/vda_pubkey.gpg`) and Arch's
`validpgpkeys`, with the `.sig` naming the same issuer.

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

the second re-pin (2026-09-06) moved the kernel off 6.12 (end of life
2026-12) to the 6.18 longterm series (fixes to about 2027-12) and lifted linux,
cryptsetup and util-linux to the signed tier in the same step -- a kernel
series change is exactly the moment a signature earns its keep. busybox
followed the same day: its `.sig` covers the `.tar.bz2` as published, so no
decompression step. one caveat, stated rather than hidden: Denys Vlasenko's
key is a 2006 dsa-1024 and the signature digest is sha-1 -- still a maintainer
signature, which beats a bare digest, but the weakest key in the tier and one
a future gpg may refuse by default. if that day comes `sigver()` fails loud,
not open, and the answer is a re-established key -- not `--allow-weak-digest-algos`,
which would admit md5 as well.

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

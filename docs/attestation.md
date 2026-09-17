# attestation

`image.sha256` says what bytes this source builds. it does not say who said so,
or when, and a git remote can rewrite it at will. `attest/` adds those two
halves, in a form someone who has never met the author can check.

```
attest/
  0001.manifest       one release's claim
  0001.manifest.asc   its detached signature, made at that time
  log                 SEQ  MANIFEST-SHA256  LINK -- an append-only hash chain
  release-key.asc     the public half of the signing key
```

## the one command

```sh
git clone https://github.com/mellen9999/xos && cd xos
./build.sh verify
```

it needs **docker, git and gpg**. no signing key, no qemu, no root, no KVM, no
Arch, no host toolchain. it does four things, each of which has to pass:

1. walks the chain and recomputes every link
2. checks every manifest against a release key pinned in `build.sh`
3. finds the manifest for the commit you asked about and re-derives every
   digest in it from the tree at that commit
4. clones that commit into the pinned container, builds it from scratch, and
   compares all four artifact digests

step 4 takes **20-40 minutes** and downloads about a gigabyte the first time.
most of it is compiling a kernel. it is meant to be quiet.

`./build.sh verify <ref>` verifies an older release. `./build.sh verify_log`
and `./build.sh verify_sigs` run the first two steps on their own, in about a
second, with no docker.

## the chain

`LINK` is the sha256 of the previous line's literal bytes *including its
newline*. the first line's link is 64 zeros. comment lines are not part of the
chain. three columns and no more: everything else lives in the manifest that
column two binds, and a second copy of a fact is a second thing that can
disagree.

the **head** is the sha256 of the last line. it is one short string that
commits to the entire history, and it is printed by `verify_log`. every release
announcement should carry it.

```sh
XOS_EXPECT_HEAD=<the head you were told> ./build.sh verify
```

that is the only defence in this design against being shown a history nobody
else is being shown. it costs three lines and you should use it.

## one signature per manifest, not one signed log

a single signed log has to be re-signed on every append, and each re-signing
destroys every earlier signature. whoever holds today's key could then re-sign
a rewritten history and nothing would detect it. per-entry signatures mean each
claim was signed *at the time it was made*, and rewriting one breaks both its
own signature and every link after it.

## the release key

- a separate **ed25519 OpenPGP key**, not the secure-boot `db` key. `keys()`
  mints a PK/KEK/db per clone and CI mints throwaways, so a `db` signature
  proves nothing about who built anything.
- its fingerprint is a pinned literal in `build.sh`, as a **list, newest
  first**, so a rotation appends and every historical signature keeps
  verifying.
- `attest/release-key.asc` is a convenience copy. it is checked *against* the
  pins before a single signature it makes is trusted -- a swapped pubkey cannot
  buy itself trust by sitting in the repo.
- **no expiry date, deliberately.** gpg reports `EXPKEYSIG` for a signature
  made while a key was valid if the key is expired *now*, so an expiry would
  turn the entire historical log red on expiry day and buy nothing: continuity
  already comes from the chain. compromise is handled by publishing the
  revocation certificate, which `sigok()`'s `REVKEYSIG` branch already turns
  red. please do not "fix" this by adding one.

### getting the fingerprint honestly

an in-repo pubkey with an in-repo pinned fingerprint is self-consistent and
**circular on first contact**. break the circle out of band: check the
fingerprint against at least two independent channels -- the author's own
domain (WKD), a DNS TXT record, a GitHub profile, `keys.openpgp.org`, the
release announcement. that is the same standard `SOURCES.md` already applies to
upstream maintainer keys.

**continuity beats first contact.** because the log is chained and its head
appears in each announcement, anyone who saw the fingerprint at *any* earlier
point detects a later swap. what that does not fix: if your very first view of
this repo is attacker-controlled, you get a consistent lie, and no in-repo
mechanism can help you. say so plainly rather than pretend otherwise.

## what this defends against

- **a silent history rewrite.** it needs the remote *and* the key, and it
  breaks every link after the edited entry.
- **a fork, detectably.** anyone holding an older `attest/log` -- a prior
  clone, a mirror, a CI journal, the Wayback Machine -- can *prove* divergence.
- **a coerced retroactive edit.** the same, for the same reason.
- **a compromised build machine**, in combination with step 4: a backdoored
  artifact does not rebuild from the source it is signed for.

## what this does not defend against

- **a stolen key appending honest-looking new entries.** only revocation stops
  that. this is why the revocation certificate exists and why `REVKEYSIG` is
  a hard red.
- **a split view** -- a consistent rewritten history shown to exactly one
  victim. this is what a witness network (Rekor and friends) buys, and taking
  that dependency is deliberately declined. `XOS_EXPECT_HEAD` is the cheap
  mitigation; the CI runner journalling the head it saw on each date is the
  other.
- **the author lying about results that verify cannot re-derive.** the gate
  count and the selftest section count are in the manifest and are labelled
  `CLAIMED, not checked`, because `verify` re-derives digests and cannot re-run
  a qemu suite. run `./build.sh gates` and `./selftest.sh` yourself if you want
  those.
- **a source tree that reproduces perfectly and is malicious anyway.**
  reproducibility says the bytes came from this source. reading the source is
  still your job.

## minting one

```sh
./build.sh attest   # then commit attest/
```

it refuses a dirty tree, refuses a second attestation for a commit that already
has one, and verifies the chain before appending to it. an attestation is
always a claim about an *earlier* commit -- it cannot contain its own digest --
so the entry lands in the commit after the one it covers.

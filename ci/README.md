# ci

unattended CI for xos, in two tiers, each a runner plus a systemd --user timer.
neither needs the production signing key or a human.

- **repro tier** (`xos-ci`, weekly): clones the pushed `main` and runs
  `./build.sh ci` (shellcheck, every script parsed, the learn ledger, the
  Dockerfile-pin check) then `./build.sh crepro` -- a full reproducibility
  rebuild inside the pinned toolchain container. docker only; no host toolchain.
  it runs `./build.sh vouch` first and echoes the fingerprint, so the journal
  records which key signed the tree it rebuilt. CI only ever *verifies*
  signatures and never makes one -- no signing key of any kind reaches a
  runner. neither tier clones shallow: the chain back to the epoch has to
  be walkable or the check reports unverified forever.

- **full tier** (`xos-ci-full`, weekly, staggered): a complete SIGNED build with
  every gate and the qemu self-test. it mints a throwaway keyset sealed with a
  random per-run passphrase (`XOS_KEYPASS`), so the signed path runs with no
  production secret -- CI validates structure and behaviour, which a throwaway
  key satisfies; only a release needs the real one. needs the full host
  toolchain (qemu, ovmf, sbsign, ukify) and KVM/TCG. `G13` SKIPs here (the repro
  tier is where reproducibility is checked).

both run in a throwaway clone; no working tree is touched. only a release, signed
with the real sealed key, still needs a human.

install (systemd --user, survives reboot via linger):

    for u in xos-ci xos-ci-full; do
      install -Dm755 "ci/$u" "$HOME/.local/bin/$u"
      install -Dm644 "ci/$u.service" "$HOME/.config/systemd/user/$u.service"
      install -Dm644 "ci/$u.timer"   "$HOME/.config/systemd/user/$u.timer"
    done
    loginctl enable-linger "$USER"
    systemctl --user daemon-reload
    systemctl --user enable --now xos-ci.timer xos-ci-full.timer

run one now, or read the last run:

    systemctl --user start xos-ci-full.service
    journalctl --user -u xos-ci-full.service -e

needs a non-interactive git remote (an unencrypted deploy key, or an agent).
point either elsewhere with `XOS_CI_REPO=/path` and `XOS_CI_BRANCH=name`.

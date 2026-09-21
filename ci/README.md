# ci

unattended CI for xos, in two tiers, each a runner plus a systemd --user timer.
neither needs the production signing key or a human.

- **repro tier** (`xos-repro`, nightly, guarded): clones the pushed `main` and
  runs `./build.sh vouch`, `./build.sh ci` (shellcheck, every script parsed, the
  learn ledger, the Dockerfile-pin check), `verify_log` + `verify_sigs`, then
  `./build.sh crepro` -- a full reproducibility rebuild inside the pinned
  toolchain container. docker only; no host toolchain.

  `vouch` runs first and echoes the fingerprint, so the journal records which
  key signed the tree it rebuilt. CI only ever *verifies* signatures and never
  makes one -- no signing key of any kind reaches a runner. neither tier clones
  shallow: the chain back to the epoch has to be walkable or the check reports
  unverified forever.

  it checks `git ls-remote` first and exits immediately if nothing was pushed
  since the last pass, so it costs nothing on a quiet day and rebuilds once per
  active one. weekly used to mean a seven-day blind window on the one claim a
  stranger is told to rely on; per-push would queue container rebuilds for
  intermediate commits nobody will ever attest.

  it also prints a `WITNESS` line carrying the chain head it was served. the
  journal then holds a dated record of every head this machine saw, independent
  of the git remote -- the cheapest mitigation for the split-view gap the
  attestation design cannot close from inside the repo:

      grep WITNESS ~/.local/state/xos-ci/witness

- **full tier** (`xos-ci-full`, weekly, staggered): a complete SIGNED build with
  every gate and the qemu self-test. it mints a throwaway keyset sealed with a
  random per-run passphrase (`XOS_KEYPASS`), so the signed path runs with no
  production secret -- CI validates structure and behaviour, which a throwaway
  key satisfies; only a release needs the real one. needs the full host
  toolchain (qemu, ovmf, sbsign, ukify) and KVM/TCG. `G13` SKIPs here (the repro
  tier is where reproducibility is checked).

both run in a throwaway clone; no working tree is touched. only a release, signed
with the real sealed key, still needs a human.

## evidence

the journal is not where a CI record can live. this box keeps
`SystemMaxUse=500M` and is already over it, so the user journal rotates inside a
day -- the full tier failed on 2026-09-17 and three days later there was nothing
left to read, not even which step died. so both runners also append to files
nothing rotates:

    ~/.local/state/xos-ci/xos-repro.log      every repro run, newest last
    ~/.local/state/xos-ci/xos-ci-full.log    every full run
    ~/.local/state/xos-ci/witness            the WITNESS ledger, append-only

`XOS_CI_LOGDIR` moves them. these are per-machine facts and never claims, so
like the repro tier's last-verified head they live outside the repo.

a failing run also shouts, once, on both channels that reach a headless box and
a desktop alike: `logger` and `notify-send -u critical`. a red CI nobody is told
about is a decoration, not a wall.

## when you change a runner

the installed copy in `~/.local/bin` is a COPY, and a copy drifts in silence:
the full tier ran for days on a `--depth 1` clone the repo had already fixed,
and a shallow clone makes `G52` SKIP forever -- the provenance check reporting
"did not run" underneath a green summary. each runner now compares itself
against the `ci/` copy in the tree it just cloned and refuses if they differ, so
**editing a runner means reinstalling it** (the install block above is
idempotent). `G48` parse-checks all three files, so a syntax error in one is
caught by the build rather than by a timer firing into a rotated journal.

install (systemd --user, survives reboot via linger):

    for u in xos-repro xos-ci-full; do
      install -Dm755 "ci/$u" "$HOME/.local/bin/$u"
      install -Dm644 "ci/$u.service" "$HOME/.config/systemd/user/$u.service"
      install -Dm644 "ci/$u.timer"   "$HOME/.config/systemd/user/$u.timer"
    done
    loginctl enable-linger "$USER"
    systemctl --user daemon-reload
    systemctl --user enable --now xos-repro.timer xos-ci-full.timer

the repro tier was called `xos-ci` and ran weekly. if the old unit is still
installed:

    systemctl --user disable --now xos-ci.timer
    rm -f ~/.config/systemd/user/xos-ci.{service,timer} ~/.local/bin/xos-ci

run one now, or read the last run:

    systemctl --user start xos-ci-full.service
    journalctl --user -u xos-ci-full.service -e

needs a non-interactive git remote (an unencrypted deploy key, or an agent).
point either elsewhere with `XOS_CI_REPO=/path` and `XOS_CI_BRANCH=name`.

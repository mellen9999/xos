# ci

unattended CI for xos: the checks that need no signing key, so a timer can run
them. `xos-ci` clones the pushed `main` into a throwaway dir and runs
`./build.sh ci` (shellcheck, every script parsed, the learn ledger, the
Dockerfile-pin check) then `./build.sh crepro` (a full reproducibility rebuild
inside the pinned toolchain container). the key-bound `./build.sh gates` and
`./selftest.sh` stay a human's call.

install (systemd --user, survives reboot via linger):

    install -Dm755 ci/xos-ci ~/.local/bin/xos-ci
    install -Dm644 ci/xos-ci.service ~/.config/systemd/user/xos-ci.service
    install -Dm644 ci/xos-ci.timer   ~/.config/systemd/user/xos-ci.timer
    loginctl enable-linger "$USER"
    systemctl --user daemon-reload
    systemctl --user enable --now xos-ci.timer

run it once now, or read the last run:

    systemctl --user start xos-ci.service
    journalctl --user -u xos-ci.service -e

needs docker and a non-interactive git remote (an unencrypted deploy key, or an
agent). point it elsewhere with `XOS_CI_REPO=/path/to/repo`.

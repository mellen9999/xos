# your first stick, start to finish

one path, in order. every command is meant to be pasted as it stands. a word
in *italics* is explained the first time it appears. nothing here needs you to
have done any of it before.

## what you need

- a linux pc to build on. arch is the easy case; any other distro works with the
  package table in `docs/building.md`.
- one usb stick, 1 GB or more. everything on it will be erased.
- the machine you want to boot it on, with *uefi* firmware (any pc made after
  about 2012). you must be allowed to change its boot settings.

## 1. get the source

    git clone https://github.com/mellen9999/xos
    cd xos
    ./build.sh vouch

`vouch` checks that every commit is signed by the one key this project uses. it
must end in a green line. if it does not, you do not have this project's source
-- stop here.

## 2. name what is missing

    ./build.sh deps

it lists every tool it cannot find and the package that carries it. install
them and run it again until it prints that all host tools are present. on a
distro that is not arch, `docs/building.md` translates the package names.

## 3. build

    ./build.sh all

this downloads the sources (and checks each against its author's signature),
builds the kernel and the userland, assembles the image, and the first time
through makes your *secure-boot keys* -- the keys that will let this image, and
nothing else, boot on your machine.

it then asks for a **passphrase**. this passphrase locks those keys on disk. you
will type it again every time you rebuild. nothing can recover it: lose it and
you make new keys and enroll them again (step 5). a sentence you can remember
beats a short password you cannot.

the build ends with the gates -- every check the project makes about itself --
and prints `GATES PASSED`. if it prints anything else, `docs/refusals.md` says
what the line means and what to do.

## 4. write the stick

plug in the stick. plug in **only** that stick -- no other usb drives. then:

    ./build.sh flash

it lists the removable disks it sees and asks you to **type the disk's model
name back** before it writes a byte. that is the safety: a typo writes nothing.
it asks for your passphrase (to sign the image) and your login password (sudo,
to write the disk). when the write is done it reads the whole stick back and
compares.

it then offers to add the **state partition** -- the encrypted part of the stick
that keeps your files between boots. say yes. it asks for a **second
passphrase**; this one unlocks your files at boot. it is a different secret
from the first and may be shorter: it only guards what is on this stick.

if more than one stick is attached, name the one you mean instead:

    ./build.sh flash /dev/sdX

## 5. tell the machine to trust your key

*secure boot* is the firmware refusing to run anything not signed by a key it
holds. right now it holds the factory keys. you are replacing them with yours.

the four files it needs are on the stick, in the folder `xos-keys`:

| file | what it is |
|---|---|
| `db.der` | the key that signs the image -- the one that matters |
| `KEK.der` | the key allowed to change `db` later |
| `PK.der` | the platform key: owning it means owning the machine's boot policy |
| `dbx.auth` | the list of your own old images that must never boot again (present once you have revoked one) |

**danger, read twice.** replacing the platform key removes the vendor chain.
any other operating system on that machine that relied on the factory keys --
windows especially -- stops booting until you restore them, and a few laptops
have bricked on non-factory keys. only do this on hardware you own and can
reflash.

1. power the machine off. plug the stick in.
2. power on and press the firmware setup key as soon as the logo shows. it is
   one of `F2`, `Del`, `Esc`, `F10` or `F12`; the logo screen usually names it,
   and the model's manual always does.
3. find the secure boot page. it is under *security*, *boot* or *authentication*
   depending on the maker.
4. switch secure boot to **custom** (some call it *setup mode* or *expert key
   management*) and choose **clear all keys** / *delete all secure boot keys*.
5. enroll from file, in this order, browsing to the stick's `xos-keys` folder
   each time: `db.der`, then `KEK.der`, then `dbx.auth` if it exists, then
   `PK.der` **last** -- enrolling the PK is what turns enforcement back on.
6. save and exit.

## 6. boot it

open the boot menu (its key is on the same logo screen -- often `F12`, `F8` or
`Esc`) and pick the stick. you should see, among the first lines:

    this image is: cobra drifter payday willow
    built: 2026-10-03 (UTC)
    tether: yes

the four words are derived from the image itself. **write them on the stick.**
they are the same on every boot of this image and different for any other; a
tampered image never gets as far as printing them.

then:

    unlock persistent state? passphrase (empty to skip):

type the second passphrase from step 4. (press enter instead and nothing you do
this session is kept -- useful on a machine you do not want a trace on.)

you are at a shell, as root. there is nothing else to log in to.

`tether: yes` means the dead-man switch is armed: pull the stick and the
machine powers off within seconds. that is how you leave.

## 7. the first session

    tutorial

three pages that show the shell, the stick and the course. after that:

    learn            # the course, from zero
    learn ref ls     # the reference card for any command, here `ls`
    scrub            # read every byte of the stick back and prove it is still intact

## 8. reach it from elsewhere (optional)

xos never opens a port on the network it is plugged into. instead it dials out
over *wireguard* -- an encrypted tunnel -- to a machine you control, and you ssh
back down that tunnel. two files at the top of the state partition switch it on.
the state partition is your home: once unlocked you are standing in it.

on the stick, make its tunnel key:

    wg genkey > wg.key
    wg pubkey < wg.key          # this is the stick's PUBLIC key -- note it

on the machine you control (the *peer*), make its key the same way, and note
its public key and the address people reach it at. then, on the stick:

    cat > wg0.conf <<'CONF'
    [Interface]
    PrivateKey = <paste the contents of wg.key>
    Address = 10.9.0.2/32

    [Peer]
    PublicKey = <the peer's public key>
    Endpoint = <the peer's address>:51820
    AllowedIPs = 10.9.0.1/32
    PersistentKeepalive = 25
    CONF
    rm wg.key

and the key of the computer you will ssh from -- the contents of its
`~/.ssh/id_ed25519.pub` -- into `authorized_keys`, one key per line.

on the peer, add the stick as a wireguard peer with its public key and
`AllowedIPs = 10.9.0.2/32`, and give the peer's own interface the address
`10.9.0.1/24`. reboot the stick and unlock. the banner now says the tunnel is
up and ssh is listening on it; from the peer:

    ssh root@10.9.0.2

no password is ever accepted -- keys only. an attacker holding the stick cannot
see that remote access exists: both files live inside the encrypted partition.

to bake the ssh key into the image instead, so it is there before any unlock:

    XOS_SSH_KEY=~/.ssh/id_ed25519.pub ./build.sh all

## 9. keeping it current

    ./build.sh outdated              # which pinned upstream has a newer release
    ./build.sh bump kernel 6.18.56   # change one version number, signature-checked
    ./build.sh all                   # rebuild
    ./build.sh install /dev/sdX      # rewrite the stick; your state partition is kept

the sectors are fixed in every version, so an update rewrites the image and
stops exactly where your files begin.

## when something refuses

every refusal is deliberate and every one is in `docs/refusals.md`, worst
first, with the exact line it prints and what to do about it. `./build.sh
help` lists every verb in plain words.

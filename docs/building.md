# building xos on a distro that is not arch

(`./build.sh help` lists every verb, grouped by what it is for. the first-time
path, start to finish, is `docs/first-stick.md`.)

two of the three things you might want to do need **nothing but docker**, and
have never been Arch-bound:

| what | needs | distro |
|---|---|---|
| `./build.sh verify` | docker, git, gpg | any |
| `./build.sh crepro` | docker, git | any |
| `./build.sh all` (build + sign) | the host toolchain below | arch, or the equivalent |
| `./selftest.sh` (the qemu lab) | the above, plus qemu + a secure-boot OVMF pair | arch, debian, fedora |

the pinned toolchain lives in `repro/Dockerfile` -- a base image fixed by
digest and pacman pointed at a frozen Arch archive day. `verify` and `crepro`
run everything inside it, so the distro you are sitting on decides nothing.

## the host toolchain, if you want to build and sign locally

`./build.sh deps` names every missing tool and the Arch package that carries
it. the mapping to other distros:

| tool | arch | debian/ubuntu | fedora |
|---|---|---|---|
| gcc, binutils, make | `gcc binutils make` | `build-essential` | `gcc binutils make` |
| musl (`/usr/lib/musl/lib/rcrt1.o`) | `musl` | `musl-tools` | `musl-gcc` |
| mksquashfs | `squashfs-tools` | `squashfs-tools` | `squashfs-tools` |
| veritysetup | `cryptsetup` | `cryptsetup-bin` | `cryptsetup` |
| sbsign, sbverify | `sbsigntools` | `sbsigntool` | `sbsigntools` |
| ukify, the EFI stub | `systemd` | `systemd-ukify systemd-boot-efi` | `systemd-ukify systemd-boot` |
| virt-fw-vars | `virt-firmware` | `pip install virt-firmware` | `python3-virt-firmware` |
| mcopy, mmd | `mtools` | `mtools` | `mtools` |
| the FAT formatter | `dosfstools` | `dosfstools` | `dosfstools` |
| qemu | `qemu-base` | `qemu-system-x86` | `qemu-system-x86` |
| OVMF | `edk2-ovmf` | `ovmf` | `edk2-ovmf` |
| the rest `deps` checks | `curl tar python openssl cmake flex bison bc pkgconf xz diffutils rsync patch zstd util-linux parted` | `curl tar python3 openssl cmake flex bison bc pkgconf xz-utils diffutils rsync patch zstd util-linux parted` | `curl tar python3 openssl cmake flex bison bc pkgconf xz diffutils rsync patch zstd util-linux parted` |
| not checked by `deps`: `git`, `ssh-keygen` (`vouch`), `sudo` (`flash`) | `git openssh sudo` | `git openssh-client sudo` | `git openssh-clients sudo` |

this table is here rather than inside `deps()` on purpose: a package-name
matrix in the build script is a list of the distros someone has already been
asked about, and it rots the moment nobody is watching. `deps()` names the
*tool*; this names the package, and being wrong here breaks nothing.

## the efi stub is pinned by bytes

`blobs.sha256` pins the exact systemd EFI stub that gets wrapped into the
signed image -- and the arch package it is cut from. `blob()` fetches that
package by name from the arch linux archive (the same frozen archive the
repro toolchain is pinned to), checks its digest, cuts the stub out, checks
that digest too, and parks it under `$XOS_CACHE/blobs/`. nothing reads the
build host's systemd, so a host upgrade can neither move the signed bytes nor
halt the build -- which it did, for two weeks, when the stub still came from
`/usr/lib/systemd/`. the pin says *these exact bytes*; the alternative is a
signed image whose first-running component changed without anyone deciding it
should. re-pin deliberately with `./build.sh blobpin <pkgver>`, in a commit
someone can read. `./build.sh stub` fetches on demand and prints the path.

`verify` and `crepro` never run `uki()`, so none of this touches them.

## OVMF is a matched pair

only the `.secboot` CODE build enforces signatures at all, and its VARS half is
the matching variable store. `build.sh` keeps a table of **pairs** and takes
the first whose both halves exist; `./build.sh ovmf` prints the one it picked.

probing the two halves independently -- which is what a per-distro path guess
amounts to -- can select an enforcing CODE beside a store that does not
enforce. that firmware boots fine and lets the selftest sections whose entire
claim is *"an unsigned or superseded image is refused"* pass an image that
should have been refused. a false pass on exactly the thing under test.

if your distro lays them out somewhere not in the table:

```sh
XOS_OVMF_CODE=/path/OVMF_CODE.secboot.fd \
XOS_OVMF_VARS=/path/OVMF_VARS.fd ./selftest.sh
```

both or neither. half an override is how a mismatched pair gets assembled by
hand, so it is refused.

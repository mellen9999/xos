# building xos on a distro that is not arch

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

this table is here rather than inside `deps()` on purpose: a package-name
matrix in the build script is a list of the distros someone has already been
asked about, and it rots the moment nobody is watching. `deps()` names the
*tool*; this names the package, and being wrong here breaks nothing.

## the efi stub is pinned by bytes

`blobs.sha256` pins the exact systemd EFI stub that gets wrapped into the
signed image. a different distro builds those bytes differently, so
`./build.sh uki` will refuse on one. that is correct: the pin says *these exact
bytes*, and the alternative is a signed image whose first-running component
changed without anyone deciding it should. re-pin deliberately with
`./build.sh blobpin`, in a commit someone can read.

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

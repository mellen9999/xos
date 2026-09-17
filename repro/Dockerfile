# xos reproducible-build toolchain, pinned by content so anyone rebuilds the
# exact bytes ./build.sh pin recorded -- the "toolchain by bytes" a version
# string alone cannot promise. two anchors, and nothing floats between them:
#   1. the base image by digest, never a moving tag
#   2. pacman aimed at a frozen Arch Linux Archive day, never the live mirror
# change either and the toolchain fingerprint moves with it -- which is the point.
# only gcc/binutils/musl/squashfs-tools/veritysetup enter that fingerprint; the
# rest are here so `./build.sh deps repro` passes, and never touch the built
# bytes (every xos binary is musl-static-pie, so the container's own glibc
# cannot leak in). this ships the REPRO toolchain only -- kernel..verity, no
# signing key, no qemu, no ovmf -- which keeps it lean and off the drift-prone
# packages a full boot/sign image would drag in.
FROM archlinux@sha256:b944cc65c5f28665dfd5fdbf5ed2997c88f5bb4a0aefac7ee8a7ef01893e5ed9

# one ALA day freezes every package version. everyone who builds this file pulls
# the same bytes, so the toolchain is reproduced, not merely "latest that worked".
ARG ALA=2026/09/12
RUN printf 'Server=https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' "$ALA" \
      > /etc/pacman.d/mirrorlist \
 && pacman -Syu --noconfirm --needed \
      gcc binutils make curl tar python openssl squashfs-tools cryptsetup \
      cmake flex bison bc pkgconf xz musl git diffutils rsync patch which \
      gnupg \
 && pacman -Scc --noconfirm

WORKDIR /build

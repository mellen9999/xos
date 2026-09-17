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
# ONE list, read by the build below, by ./build.sh toolpin when it re-pins, and
# by G58 and G59 when they check. a second copy is a second thing that can rot.
ARG PKGS="gcc binutils make curl tar python openssl squashfs-tools cryptsetup cmake flex bison bc pkgconf xz musl git diffutils rsync patch which gnupg"
# the archive day says WHERE the packages came from; it does not say which bytes
# arrived. download first, check every named package against toolchain.sha256,
# and only then install -- so the statement this container makes is "the
# compiler is these exact bytes", not "these version strings from this day".
COPY toolchain.sha256 /toolchain.sha256
RUN printf 'Server=https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' "$ALA" \
      > /etc/pacman.d/mirrorlist \
 && pacman -Syuw --noconfirm $PKGS \
 && ( cd /var/cache/pacman/pkg \
      && grep -v '^#' /toolchain.sha256 | sha256sum -c --strict - ) \
 && pacman -Su --noconfirm --needed $PKGS \
 && pacman -Scc --noconfirm \
 && rm -f /toolchain.sha256

WORKDIR /build

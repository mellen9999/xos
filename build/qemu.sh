#!/bin/bash
# build/qemu.sh -- boot the signed image in qemu
# a module of build.sh: sourced by it, never run. it defines functions and
# nothing else; every constant it reads lives in build.sh.

# boot the WHOLE partitioned stick under qemu -- the exact bytes that get dd'd
# to a real disk. OVMF finds BOOTX64.EFI on the stick's own ESP (p1); root is
# resolved by PARTUUID from p2, identically to real hardware. no more fat:esp.
# both boots are the same firmware and the same stick; only the way the disk is
# attached differs, so that is the only thing either one spells out.
# ────────────────────────────────────────────────────────────────────────────
# qemu -- the development rig; the stick is the product
# ────────────────────────────────────────────────────────────────────────────
qboot() { # $@ -- how to attach the disk
  [ -f ovmf-vars.fd ] || { echo "FAIL: run ./build.sh uki first" >&2; return 1; }
  [ -f stick.img ] || stick || return 1
  qemu-system-x86_64 -machine q35,smm=on -m 256 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file=ovmf-vars.fd \
    "$@" \
    -nic user,model=virtio-net-pci \
    -nographic -no-reboot
}

boot() {
  qboot -drive file="${1:-stick.img}",if=virtio,format=raw,readonly=on
}

# same, but attach the stick as an emulated USB mass-storage device on xHCI --
# exercises the real boot path (usb enumeration, dm-mod.waitfor polling, the
# removable-media \EFI\BOOT\BOOTX64.EFI fallback) without any hardware.
bootusb() {
  qboot -device qemu-xhci,id=xhci \
    -drive if=none,id=stick,format=raw,readonly=on,file="${1:-stick.img}" \
    -device usb-storage,bus=xhci.0,drive=stick
}

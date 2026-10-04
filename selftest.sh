#!/bin/bash
# defensive self-test. boots xos in a throwaway qemu vm and asserts its own
# tamper-detection refuses every alteration -- no external target, no secrets,
# no network exploit. each check asserts an EXPECTED FAILURE: the harness fails
# if a tampered image is accepted.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# every temp file of a run -- test sticks, state disks, logs, fifos -- lives in
# a directory of its own. two selftests on one box (the ci timer and a hand
# run, two worktrees) used to share /tmp/xos-a*.img, and restore() in the one
# that finished first removed the other's images mid-round.
XT=$(mktemp -d /tmp/xos-selftest.XXXXXX) || exit 1

has() { local n; n=$(grep -c -- "$1" || true); [ "${n:-0}" -gt 0 ]; }

# these are build.sh's to define. read them out of it rather than keeping
# a second copy that drifts: a harness attacking the stick with the wrong ESP
# size, or enrolling a dbx entry under a different GUID, fails for a reason
# that has nothing to do with the thing under test.
bsh() { local v; v=$(grep -m1 "^$1=" build.sh | cut -d= -f2-)
        [ -n "$v" ] || { echo "cannot read $1 from build.sh" >&2; exit 1; }
        printf '%s' "$v"; }
SBGUID_T=$(bsh SBGUID)
STICK_ESP_MIB=$(bsh STICK_ESP_MIB)
# NOT bsh: OVMF_CODE stopped being a literal when build.sh started resolving a
# matched CODE/VARS pair from a table. bsh greps `^OVMF_CODE=` and takes the
# rest of the line, so it would hand back an unexpanded command substitution
# and qemu would die on a nonsense path -- looking like a broken lab rather
# than a parsing bug. ask build.sh for the resolved path instead.
OVMF_CODE=$(./build.sh ovmf code) || exit 1
pass=0; fail=0; skip=0; sections=0; crit_skip=0
# the gate runner already learned this: a run that dies partway through prints
# a smaller number and looks exactly like a clean one. count the checks that
# actually ran and refuse to report a result if any of them went missing.
EXPECTED_SECTIONS=22
section() { sections=$((sections+1)); echo; echo "$1"; }

# p2 (root) starts after the 1 MiB gap + the ESP. the whole stick is what boots
# on real hardware, so the harness attacks the stick, not the bare xos.img.
ROOT_OFF=$(( (1 + STICK_ESP_MIB) * 1024 * 1024 ))

# production carries no test hook, so build a test-flavoured UKI + stick for this
# run and restore the production ones on the way out.
# unlock once into RAM; every subsequent sign reuses it, and we wipe on exit.
./build.sh unlock || { echo "cannot unlock signing keys"; exit 1; }
# uki rebuilds ovmf-vars.fd from the pristine OVMF template, so restore() also
# discards the throwaway dbx entry A11 enrolls into firmware.
XOS_TEST=1 ./build.sh verity >/dev/null && ./build.sh uki >/dev/null && ./build.sh stick >/dev/null \
	|| { echo "cannot build test uki/stick"; exit 1; }
# restore is the EXIT trap: if it fails partway, the tree can be left holding
# a TEST uki/stick -- xos.test xos.teststate xos.testwg on a cmdline that must
# never ship. that failure must be impossible to miss, so check every step and
# make noise (and a nonzero exit) rather than silently leaving debug scaffolding
# in place for build.sh's own G31 to (hopefully) catch on the next run.
restore() {
	if ! ./build.sh verity >/dev/null 2>&1 || ! ./build.sh uki >/dev/null 2>&1 || ! ./build.sh stick >/dev/null 2>&1; then
		printf '\033[1;31m  RESTORE FAILED -- the tree may still hold a TEST uki/stick (xos.test xos.teststate xos.testwg). rebuild before shipping anything.\033[0m\n' >&2
		./build.sh lock >/dev/null 2>&1
		rm -rf "$XT"
		exit 1
	fi
	./build.sh lock >/dev/null 2>&1
	# a red run keeps its logs and says where: the typed-console rounds in
	# particular cannot be understood from the verdict line alone.
	if [ "${fail:-0}" -gt 0 ]; then
		printf '  logs of this run kept at %s (remove it when read)\n' "$XT" >&2
		find "$XT" -name '*.img' -delete 2>/dev/null
	else
		rm -rf "$XT"
	fi
}
# INT/TERM too: a ctrl-c at minute six of A19 must still put the production
# uki/stick back and discard A11's throwaway dbx entry, or the tree is left
# holding a TEST-flavoured signed image and a firmware store that refuses one.
trap restore EXIT INT TERM
ok()  { printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
# a skip is never silence: it is counted and reported, because "9 passed" with
# a check quietly not evaluated is the exact failure this harness exists to
# catch everywhere else.
skipped() { printf '  \033[1;33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }

# five sections prove the crown jewels -- dbx revocation (A11), the dead-man
# tether (A18), the real typed-passphrase unlock (A19), vault mode (A21) and
# clone (A22). a run that skipped any of them has NOT proven the chain, so
# unlike an ordinary skip it must not read as success at the exit code. this is
# the one place "a skip is never a pass" has to reach the verdict itself. set
# XOS_ALLOW_SKIP=1 to accept a deliberately stub-less dev run.
skipped_crit() { skipped "$1"; crit_skip=$((crit_skip+1)); }

# the signed rounds need the pinned stub and the unlocked db key. signed_ready
# SECTION sets R (the unlocked key dir) and says, once, why a round is not
# evaluated -- a critical skip, since every round that calls this is one of
# the crown jewels. five rounds used to carry this test by hand, one of them
# a different shape.
signed_ready() {
	if ! R=$(./build.sh ramkeys); then
		skipped_crit "no stub or unlocked key -- $1 not evaluated (ramkeys failed)"; return 1
	fi
	[ -n "$stub" ] && [ -f "$stub" ] && [ -f "$R/db.key" ] \
		|| { skipped_crit "no stub or unlocked key -- $1 not evaluated"; return 1; }
}
# mk_uki TAG CMDLINE -- a uki from this tree's kernel and CMDLINE, signed by
# the unlocked db key: $XT/xos-TAG-signed.efi (the unsigned one beside it).
# mk_stick TAG -- stick.img with that uki as its boot loader: $XT/xos-TAG.img.
# the eight test images selftest builds all went through these two commands
# by hand; a build that fails is now a bad line, not a boot that mysteriously
# refuses later.
mk_uki() {
	ukify build --linux=bzImage --cmdline="$2" --stub="$stub" --output="$XT/xos-$1.efi" >/dev/null 2>&1 \
		&& sbsign --key "$R/db.key" --cert keys/db.crt --output "$XT/xos-$1-signed.efi" "$XT/xos-$1.efi" >/dev/null 2>&1 \
		|| bad "could not build and sign the $1 test uki"
}
mk_stick() {
	cp stick.img "$XT/xos-$1.img" \
		&& mcopy -o -i "$XT/xos-$1.img@@1M" "$XT/xos-$1-signed.efi" ::/EFI/BOOT/BOOTX64.EFI \
		|| bad "could not place the $1 test uki on a stick image"
}

# init prints XOS-TEST-END once the whole probe block finished and
# XOS-TEST-DONE once the console supervisor is up too -- the same
# did-everything-run guard this harness already applies to itself
# (EXPECTED_SECTIONS/EXPECTED_GATES), applied to a single boot's output. a
# probe block that dies partway (a hang, a crash) must not look like a clean
# run just because every check that DID print happened to pass. only call
# this for a boot that is expected to reach the end -- never for an
# adversarial boot that is supposed to be refused before it gets there.
assert_complete() {
	if grep -q 'XOS-TEST-END' <<< "$1" && grep -q 'XOS-TEST-DONE' <<< "$1"; then
		ok "$2: probe run reached XOS-TEST-END and XOS-TEST-DONE"
	else
		bad "$2: probe run did not complete (missing END and/or DONE -- truncated)"
	fi
}

# secure-boot firmware with the enrolled keyset, written once. every qemu boot
# below is this plus however it attaches the disk.
QEMU_FW=(
	-global "driver=cfi.pflash01,property=secure,value=on"
	-drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
	-drive "if=pflash,format=raw,unit=1,file=ovmf-vars.fd"
)

# boots the real chain over VIRTIO: firmware -> enrolled key -> signed UKI ->
# verity root resolved by PARTUUID off the stick's p2.
# XOS_PCAP=<file>: also capture everything the guest puts on the wire. the
# only way to prove what the stick SAYS to a LAN, as opposed to what init
# believes it configured.
boot_img() {
	local cap=()
	[ -n "${XOS_PCAP:-}" ] && cap=(-object "filter-dump,id=fd0,netdev=n0,file=$XOS_PCAP")
	timeout 360 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" \
		-drive file="$1",if=virtio,format=raw,readonly=on \
		-nic user,model=virtio-net-pci,id=n0 "${cap[@]}" \
		-nographic -no-reboot < /dev/null 2>&1
}

# for boots the firmware is EXPECTED to refuse: a refused image drops to the
# BDS menu and sits there until timeout 360 expires -- ~18 wasted minutes
# across A3/A4/A11. run qemu detached, poll the log for a verdict either way
# (the refusal string, or XOS-TEST-BEGIN -- the regression these sections
# exist to catch), and kill it the moment one lands. prints the log, so
# callers grep it exactly like boot_img output.
boot_refused() {
	local log=$XT/xos-refused.$$.log t=0 qp
	rm -f "$log"
	timeout 360 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" \
		-drive file="$1",if=virtio,format=raw,readonly=on \
		-nic user,model=virtio-net-pci \
		-nographic -no-reboot < /dev/null > "$log" 2>&1 &
	qp=$!
	while [ "$t" -lt 120 ] && kill -0 "$qp" 2>/dev/null; do
		grep -aqiE 'access denied|security violation|XOS-TEST-BEGIN' "$log" 2>/dev/null && break
		sleep 1; t=$((t+1))
	done
	sleep 2   # let the message finish landing before the kill
	kill "$qp" 2>/dev/null; wait "$qp" 2>/dev/null
	cat "$log"; rm -f "$log"
}

# boot with a second virtio disk attached (becomes /dev/vdb), for the p3 test.
boot_state() {
	local disk="$1"; shift
	timeout 360 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" \
		-drive file="${XOS_STICK:-stick.img}",if=virtio,format=raw,readonly=on \
		-drive file="$disk",if=virtio,format=raw \
		-nic user,model=virtio-net-pci -nographic -no-reboot "$@" < /dev/null 2>&1
}

# boot with the hardware clock forced years into the past. proves the floor.
# XOS_NONIC=1: no network device at all, for the branches that only exist when
# the floored clock has nowhere to ask.
boot_backclock() {
	local nic=(-nic "user,model=virtio-net-pci")
	[ "${XOS_NONIC:-}" = 1 ] && nic=(-nic none)
	timeout 360 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		-rtc base=2010-01-01T00:00:00 \
		"${QEMU_FW[@]}" \
		-drive file="$1",if=virtio,format=raw,readonly=on \
		"${nic[@]}" -nographic -no-reboot < /dev/null 2>&1
}

# the same chain over an emulated xHCI USB mass-storage device -- the real
# hardware path, including usb enumeration and the dm-mod.waitfor poll.
# the stick as an xhci mass-storage device, shared by the two usb boots below.
usb_stick() { printf '%s\n' -device qemu-xhci,id=xhci -drive "if=none,id=stick,format=raw,readonly=on,file=$1" -device usb-storage,bus=xhci.0,drive=stick; }
boot_usb() {
	local usb; mapfile -t usb < <(usb_stick "$1")
	timeout 360 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" "${usb[@]}" \
		-nic user,model=virtio-net-pci \
		-nographic -no-reboot < /dev/null 2>&1
}

# the same chain with a usb-serial adapter also on the bus -- the vt320 path.
# qemu's usb-serial presents as an ftdi ft232 (0403:6001), which ftdi_sio binds
# to a ttyUSB. proves the drivers are compiled in and init lines the tty. the
# chardev is a sink; the proof is the device node + the baud init set on it.
# always-plugged=on on the usb-serial device is load-bearing: qemu defaults it
# to always-plugged=off, and with a null chardev the device is then never
# presented to the guest -- ftdi_sio loads but no ttyUSB ever enumerates, so A20
# fails despite a correct kernel and init. on makes the emulated FT232 enumerate
# like a real dongle. do not drop it.
boot_usbserial() {
	local usb; mapfile -t usb < <(usb_stick "$1")
	timeout 360 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" "${usb[@]}" \
		-chardev null,id=usbtty \
		-device usb-serial,chardev=usbtty,bus=xhci.0,always-plugged=on \
		-nic user,model=virtio-net-pci \
		-nographic -no-reboot < /dev/null 2>&1
}

flip() { python3 -c "import pathlib;p=pathlib.Path('$1');b=bytearray(p.read_bytes());b[$2]^=1;p.write_bytes(bytes(b))"; }

echo
section "A1  flip one byte in the root filesystem -- boot must refuse"
cp stick.img $XT/xos-a1.img
flip $XT/xos-a1.img $((ROOT_OFF + 100000))
out=$(boot_img $XT/xos-a1.img)
# verity detects lazily, when the block is actually read, so the machine may
# execute briefly first. what must be true is that it dies rather than
# continuing -- panic_on_corruption makes that unconditional.
if grep -q 'is corrupted' <<< "$out" && grep -q 'dm-verity device corrupted' <<< "$out"; then
	ok "verity panicked the kernel on one flipped bit"
else
	bad "corrupted image did not panic (verity error present: $(grep -c 'is corrupted' <<< "$out"))"
fi
rm -f $XT/xos-a1.img

echo
section "A2  clean stick -- must boot, and root must be unwritable"
rm -f $XT/xos-a2.pcap
out=$(XOS_PCAP=$XT/xos-a2.pcap boot_img stick.img)
# the kernel's own verdict (arch/x86 setup.c, from boot_params.secure_boot),
# not the efi stub's console line: since 6.18 the stub logs at notice level
# by default and its "UEFI Secure Boot is enabled" info line no longer prints.
grep -q 'Secure boot enabled' <<< "$out" && ok "secure boot was enforcing during the run" || bad "secure boot not enabled"
grep -q 'write-to-root: refused' <<< "$out" && ok "write to / returned EROFS" || bad "root was writable"
# the banner is what an operator reads first: the build date (the version --
# there is no semver) and the tether state. neither line was ever asserted.
grep -qE '^  built: [0-9]{4}-[0-9]{2}-[0-9]{2} \(UTC\)' <<< "$out" \
	&& ok "the banner prints the signed build date" \
	|| bad "no 'built: YYYY-MM-DD' line in the banner (epoch unparsed?)"
grep -qE '^  tether: (yes|no \(not usb\)|off \(xos\.notether\))' <<< "$out" \
	&& ok "the banner states the tether" \
	|| bad "no tether line in the banner"
grep -q 'busybox-runs: yes'      <<< "$out" && ok "userland actually executes"  || bad "userland did not run"
grep -q 'rootfs-type: squashfs' <<< "$out" && ok "root is mounted as squashfs" || bad "root filesystem type is not squashfs"
grep -q 'rootfs-flags: ro'      <<< "$out" && ok "root mount flags include ro" || bad "root not mounted ro"
# the strongest self-statement init makes about itself, checked against
# sources that live OUTSIDE the booted system -- the squashfs on disk and the
# roothash build.sh just wrote for this run -- not anything the image could
# have lied about from the inside. dm-0 exposes xos.img's data region, and
# verity() zero-pads that to a 4096 boundary before hashing it (see build.sh),
# so replicate the same padding here rather than hashing rootfs.squashfs raw --
# otherwise an unaligned squashfs size makes this fail for no real reason.
sqsz=$(stat -c%s rootfs.squashfs)
padsz=$(( (4096 - sqsz % 4096) % 4096 ))
if [ "$padsz" -eq 0 ]; then
	want_digest=$(sha256sum rootfs.squashfs | cut -d' ' -f1)
else
	want_digest=$( { cat rootfs.squashfs; head -c "$padsz" /dev/zero; } | sha256sum | cut -d' ' -f1)
fi
got_digest=$(grep -oP 'rootfs-digest: \K[0-9a-f]+' <<< "$out" | head -1)
[ -n "$got_digest" ] && [ "$got_digest" = "$want_digest" ] \
	&& ok "rootfs-digest (hashed live through dm-verity) matches rootfs.squashfs" \
	|| bad "rootfs-digest mismatch (got ${got_digest:-none}, want $want_digest)"
want_rh=$(cat verity.roothash 2>/dev/null)
got_rh=$(grep -oP 'verity-roothash: \K[0-9a-f]+' <<< "$out" | head -1)
[ -n "$got_rh" ] && [ "$got_rh" = "$want_rh" ] \
	&& ok "verity-roothash on the signed cmdline matches verity.roothash" \
	|| bad "verity-roothash mismatch (got ${got_rh:-none}, want ${want_rh:-none})"
grep -q 'verity-onerror: panic_on_corruption' <<< "$out" \
	&& ok "verity is set to panic on corruption, not merely warn" \
	|| bad "verity onerror is not panic_on_corruption"
# networking: qemu's usermode nic + built-in dhcp server, no real internet needed.
grep -qE 'net-iface-up: [a-z0-9]+' <<< "$out" && ! grep -q 'net-iface-up: none' <<< "$out" \
	&& ok "a network interface came up" \
	|| bad "no network interface came up"
grep -q 'net-has-address: yes' <<< "$out" && ok "dhcp lease obtained" || bad "no ipv4 address"
grep -q 'net-default-route: yes' <<< "$out" && ok "a default route was installed" || bad "no default route"
grep -q 'dhcp-client: running' <<< "$out" && ok "the dhcp client stayed up to renew the lease" || bad "no dhcp client running after boot -- the lease will never renew"
# what the stick SAID on the wire, from the capture, not from init's own
# account. positive control first: a dhcp exchange must be in there at all
# (the magic cookie 63 82 53 63), or "no vendor string" is vacuous.
if [ -s $XT/xos-a2.pcap ] && LC_ALL=C grep -aqF "$(printf '\143\202\123\143')" $XT/xos-a2.pcap; then
	ok "the capture holds the dhcp exchange"
	LC_ALL=C grep -aq 'udhcp' $XT/xos-a2.pcap \
		&& bad "the dhcp request names the stack (udhcp vendor class) to the LAN" \
		|| ok "the dhcp request carries no vendor string"
	LC_ALL=C grep -aqi 'xos' $XT/xos-a2.pcap \
		&& bad "the wire carries the name xos" \
		|| ok "nothing on the wire says xos"
else
	bad "no dhcp exchange captured -- cannot check what the stick says on the wire"
fi
dns_n=$(grep -oP 'net-dns-servers: \K[0-9]+' <<< "$out" | head -1)
[ "${dns_n:-0}" -gt 0 ] && ok "$dns_n dns server(s) from dhcp" || bad "no dns servers from dhcp"
# per-boot mac. qemu's default nic mac (52:54:00:12:34:56) ALREADY has the
# locally-administered bit set, so the bit alone proves nothing -- assert the
# address moved off the hardware one, then that the replacement is well-formed.
mac2=$(grep -oP 'mac-uplink: \K[0-9a-f:]{17}' <<< "$out" | head -1)
grep -q 'mac-randomized: yes' <<< "$out" && ok "uplink mac was randomized away from hardware" || bad "uplink still wears its hardware mac"
[ -n "$mac2" ] && [ "$mac2" != "52:54:00:12:34:56" ] && ok "mac is not the qemu default" || bad "mac is still the qemu default"
b1m=0; [ -n "$mac2" ] && b1m=$((16#${mac2:0:2}))
[ $((b1m & 2)) -ne 0 ] && [ $((b1m & 1)) -eq 0 ] && ok "locally-administered unicast bits correct" || bad "mac bit math wrong"
# fingerprint words, recomputed from the two sources OUTSIDE the booted
# system -- the tree wordlist and the roothash this run just built.
rh18=$(cat verity.roothash); want_fp=""
for i in 0 2 4 6; do want_fp="$want_fp $(sed -n "$((16#${rh18:$i:2} + 1))p" overlay/usr/share/xos/words)"; done
want_fp="${want_fp# }"
grep -qF "fingerprint: $want_fp" <<< "$out" \
	&& ok "fingerprint words derive from the signed roothash ($want_fp)" \
	|| bad "fingerprint mismatch (want: $want_fp)"
grep -q 'tether-armed: no (not usb)' <<< "$out" \
	&& ok "tether stays disarmed on a non-usb boot device" \
	|| bad "tether armed (or errored) on a virtio boot"
assert_complete "$out" "A2 boot"

echo
section "A3  unsigned UKI -- firmware must refuse it"
cp stick.img $XT/xos-a3.img
mcopy -o -i $XT/xos-a3.img@@1M xos.efi ::/EFI/BOOT/BOOTX64.EFI
o3=$(boot_refused $XT/xos-a3.img)
if grep -q XOS-TEST-BEGIN <<< "$o3"; then
	bad "unsigned kernel booted -- secure boot is not enforcing"
else
	grep -qi 'access denied' <<< "$o3" && ok "firmware rejected the unsigned image" \
		|| bad "unsigned image did not boot, but not visibly refused by secure boot"
fi
rm -f $XT/xos-a3.img

echo
section "A4  tamper the signed UKI -- signature must break"
cp xos-signed.efi $XT/xos-a4.efi
flip $XT/xos-a4.efi $(( $(stat -c%s xos-signed.efi) / 2 ))
sbverify --cert keys/db.crt $XT/xos-a4.efi >/dev/null 2>&1 \
	&& bad "tampered UKI still verified" || ok "one flipped bit invalidates the signature"
cp stick.img $XT/xos-a4.img
mcopy -o -i $XT/xos-a4.img@@1M $XT/xos-a4.efi ::/EFI/BOOT/BOOTX64.EFI
o4=$(boot_refused $XT/xos-a4.img)
if grep -q XOS-TEST-BEGIN <<< "$o4"; then
	bad "tampered UKI booted"
else
	# absence of a boot is not a refusal: an empty log (qemu died) looked like one
	grep -qi 'access denied' <<< "$o4" && ok "firmware refused the tampered image" \
		|| bad "tampered image did not boot, but not visibly refused by secure boot"
fi
rm -f $XT/xos-a4.efi $XT/xos-a4.img

echo
section "A5  no dynamic loader to preload into"
if [ ! -d root/bin ]; then
	bad "no root/ tree to inspect -- run ./build.sh rootfs"
elif [ -z "$(find root -name 'ld-musl-*' -o -name 'ld-linux*' 2>/dev/null)" ]; then
	ok "no ld-musl/ld-linux in the image (LD_PRELOAD has nothing to load)"
else
	bad "a dynamic loader is present"
fi
grep -q 'dynamic-loader-present: no' <<< "$out" && ok "confirmed absent from inside the booted system" || bad "loader present at runtime"

echo
section "A6  TLS must refuse a certificate outside our trust anchors"
# host reachability is the proxy for guest reachability: the guest rides
# qemu's user-mode nat, so if the host cannot reach letsencrypt.org over the
# shipped tunnel, neither can init's tls-time. probed once, reused by A15.
net_ok=no
printf 'HEAD / HTTP/1.0\r\nHost: letsencrypt.org\r\nConnection: close\r\n\r\n' \
	| timeout 20 ./tlstunnel - letsencrypt.org 443 2>/dev/null | has 'HTTP/1' && net_ok=yes
if [ "$net_ok" != yes ]; then
	skipped "no network -- A6 not evaluated"
else
	ok "trusted CA: handshake with letsencrypt.org succeeded"
	err=$({ printf 'HEAD / HTTP/1.0\r\nHost: google.com\r\n\r\n' | timeout 20 ./tlstunnel - google.com 443 2>&1 >/dev/null; } || true)
	case "$err" in
		*"ssl error 62"*) ok "untrusted CA refused (BR_ERR_X509_NOT_TRUSTED)" ;;
		*)                bad "a cert outside trust/ was not refused: ${err:-no error}" ;;
	esac
fi
grep -q 'trust-anchors-in-binary: [1-9]' <<< "$out" \
	&& ok "trust anchors are compiled into the binary, not read from a directory" \
	|| bad "no trust anchor strings found in the shipped binary"

echo
section "A7  flip a byte in the verity HASH TREE -- boot must refuse"
# the data region is covered by the tree; the tree itself must be covered too,
# or an attacker could rewrite data + recompute the tree. flip the first hash
# block (one past the superblock at data-end). the superblock block itself is
# NOT covered -- dm-mod.create ignores it -- which is the one honest gap here.
blocks=$(grep -oE '4096 4096 [0-9]+ [0-9]+' cmdline.txt | head -1 | awk '{print $3}')
if [ -n "${blocks:-}" ]; then
	cp stick.img $XT/xos-a7.img
	flip $XT/xos-a7.img $((ROOT_OFF + (blocks + 1) * 4096 + 16))
	o7=$(boot_img $XT/xos-a7.img)
	grep -q 'dm-verity device corrupted' <<< "$o7" && ok "hash-tree corruption panicked the kernel" \
		|| bad "a flipped hash-tree byte did not panic"
	rm -f $XT/xos-a7.img
else
	bad "could not parse data-block count from cmdline.txt"
fi

echo
section "A8  kernel attack surface is closed"
# reuses A2's clean boot output ($out); every line is a deterministic init probe.
grep -q 'devmem-node: absent'  <<< "$out" && ok "/dev/mem absent"          || bad "/dev/mem present"
grep -q 'kcore: absent'        <<< "$out" && ok "/proc/kcore absent"       || bad "/proc/kcore present"
grep -q 'kexec-loaded: absent' <<< "$out" && ok "kexec unavailable"        || bad "kexec present"
grep -q 'vsyscall-map: 0'      <<< "$out" && ok "no fixed vsyscall page"   || bad "vsyscall page mapped"
grep -q 'lockdown: .*\[confidentiality\]' <<< "$out" && ok "lockdown=confidentiality enforced" || bad "lockdown not in confidentiality mode"
grep -q 'module-loader: absent' <<< "$out" && ok "no loadable module support" || bad "module loading is possible"
grep -q 'devport-node: absent'  <<< "$out" && ok "/dev/port absent"           || bad "/dev/port present"
# the product thesis: no driver in this kernel can bind the host's own disks.
grep -q 'host-disk-drivers: none' <<< "$out" && ok "no sata/nvme/mmc driver in the running kernel" \
	|| bad "a host-disk driver is registered (sata/nvme/mmc)"
# ipv4-only: a compiled-in v6 stack would auto-configure a SLAAC address, the
# stable network identity this stick refuses. /proc/net/if_inet6 exists iff
# CONFIG_IPV6 was built, so its absence proves the README's "no ipv6 stack".
grep -q 'ipv6-stack: absent' <<< "$out" && ok "no ipv6 stack in the running kernel" \
	|| bad "an ipv6 stack is present (SLAAC would leak a stable address to the LAN)"
grep -q 'mem-autoinit: heap alloc:on, heap free:on' <<< "$out" \
	&& ok "memory zeroed on both alloc and free" || bad "init_on_free not active"

echo
section "A9  write / exec containment"
grep -q 'remount-rw: refused' <<< "$out" && ok "/ cannot be remounted rw"      || bad "/ was remounted rw"
grep -q 'tmp-exec: refused'   <<< "$out" && ok "noexec /tmp blocks execution"  || bad "a binary ran from /tmp"
# /dev is the one mount init tightens after the kernel made it. the remount
# used to fail in silence; now it is loud, and the probe reads the flags back.
grep -q 'dev-noexec: yes' <<< "$out" && grep -q 'dev-nosuid: yes' <<< "$out" \
	&& ! grep -q 'dev remount FAILED' <<< "$out" \
	&& ok "/dev is nosuid,noexec (the W^X claim in init's header holds at runtime)" \
	|| bad "/dev still allows suid or exec (or the remount failed)"
grep -q 'home-mode: 700' <<< "$out" && grep -q 'home-final: 700 tmpfs' <<< "$out" \
	&& ok "the tmpfs home is root-only (0700) before and after state_open" \
	|| bad "the home is not 0700 -- another uid could read the operator's files"
grep -q 'grader-privdrop: ok'  <<< "$out" && ok "learn's answer uid can neither read nor write the home" || bad "nobody can reach the operator's home"
grep -q 'kptr-restrict: 2'    <<< "$out" && ok "kernel pointers restricted"    || bad "kptr_restrict not 2"
grep -q 'dmesg-restrict: 1'   <<< "$out" && ok "dmesg restricted to privileged readers" || bad "dmesg_restrict not 1"
grep -q 'sysctls-hardened: yes' <<< "$out" && ok "every hardening sysctl took" || bad "a hardening sysctl is not at its value"
grep -q 'sysctls-hardened: '  <<< "$out" && ! grep -qE 'sysctl (FAILED|MISSING)' <<< "$out" \
	&& ok "no sysctl write failed and every key exists" || bad "a sysctl write failed or a key has no /proc/sys entry (or the probe never ran)"
# the home must be writable -- it is the tmpfs every session lives on. a probe
# whose output nobody reads is a test that cannot fail, so read it.
grep -q 'writable-home: yes (tmpfs)' <<< "$out" \
	&& ok "the operator's home is writable tmpfs" \
	|| bad "home is not writable (learn, ssh keys and abduco all need it)"
# losetup backs the p3 provisioning path; if it cannot attach, A16 fails later
# for a reason that looks like encryption rather than a missing loop device.
grep -q 'losetup: ok' <<< "$out" \
	&& ok "loop device attaches (the p3 provisioning path is usable)" \
	|| bad "losetup failed: $(grep -oP 'losetup: \K.*' <<< "$out" | head -1)"

echo
section "A10  boot the stick over emulated USB (the real hardware path)"
o10=$(boot_usb stick.img)
if grep -q XOS-TEST-BEGIN <<< "$o10"; then
	ok "booted from usb-storage via dm-mod.waitfor"
	grep -q 'Secure boot enabled' <<< "$o10" && ok "secure boot enforcing over USB" || bad "secure boot not enabled over USB"
	grep -q 'write-to-root: refused'  <<< "$o10" && ok "root unwritable over USB"       || bad "root writable over USB"
	grep -qF "fingerprint: $want_fp" <<< "$o10" \
		&& ok "same fingerprint words over usb -- stable per image, per boot path" \
		|| bad "fingerprint words changed on the usb boot path"
	grep -q 'tether-armed: yes' <<< "$o10" \
		&& ok "tether armed on the real usb boot path" \
		|| bad "tether did not arm over usb"
	assert_complete "$o10" "A10 boot"
else
	bad "stick did not boot over emulated USB (waitfor may have timed out)"
fi

echo
section "A11  a superseded but validly-signed image must be refused"
# secure boot checks WHO signed an image, never WHEN. without revocation an old
# release stays bootable forever: drop it on the ESP -- plain FAT, because
# something has to boot -- and the firmware runs it, signature valid, every gate
# green. this asserts dbx actually closes that.
# the stub comes from the pinned arch package, same as uki() -- one path rule.
stub=$(./build.sh stub 2>/dev/null) || stub=
if signed_ready A11; then
	mk_uki a11 "$(cat cmdline.txt) xos.rel=old"
	if ! sbverify --cert keys/db.crt $XT/xos-a11-signed.efi >/dev/null 2>&1; then
		bad "could not build a validly-signed superseded image to test with"
	else
		ok "the superseded image is validly signed by db"
		h=$(python3 pehash.py --verify $XT/xos-a11-signed.efi) \
			&& ok "authenticode digest agrees with its own signature" \
			|| bad "pehash.py disagrees with the signature -- dbx would revoke nothing"
		# revoke it in firmware only; the tracked `revoked` file is untouched.
		virt-fw-vars --input ovmf-vars.fd --output ovmf-vars.fd \
			--add-dbx-hash "$SBGUID_T" "$h" >/dev/null 2>&1 \
			|| bad "could not enroll the test revocation into dbx"
		# drop the revoked image into a copy of the stick's ESP and boot that
		cp stick.img $XT/xos-a11.img
		mcopy -o -i $XT/xos-a11.img@@1M $XT/xos-a11-signed.efi ::/EFI/BOOT/BOOTX64.EFI
		o11=$(boot_refused $XT/xos-a11.img)
		if grep -q XOS-TEST-BEGIN <<< "$o11"; then
			bad "a revoked image still booted -- dbx is not being enforced"
		else
			has_denied=$(grep -ic 'access denied\|security violation' <<< "$o11" || true)
			[ "${has_denied:-0}" -gt 0 ] \
				&& ok "firmware refused the revoked image" \
				|| bad "revoked image did not boot, but not visibly refused by dbx"
		fi
		# revocation must not have collaterally killed the good image
		o11b=$(boot_img stick.img)
		if grep -q XOS-TEST-BEGIN <<< "$o11b"; then
			ok "the current image still boots with dbx enrolled"
			assert_complete "$o11b" "A11 clean re-boot"
		else
			bad "dbx enrollment broke the image we actually ship"
		fi
	fi
	rm -f $XT/xos-a11.efi $XT/xos-a11-signed.efi $XT/xos-a11.img
fi

echo
section "A12  learn describes the system that is actually running"
# G24 checks the corpus against the BUILD TREE. this checks it against reality:
# a ref that names a command the booted system does not have is a lie the build
# cannot see, and the whole point of learn is that its questions are answerable
# on the stick, offline.
grep -q 'no-bash: absent' <<< "$out" && ok "bash is gone -- one shell" || bad "a second shell shipped"
grep -q 'shell-vi-default: yes' <<< "$out" && ok "vi-mode line editing is the default shell behavior" || bad "vi keybindings are not the default"
grep -q 'shell-vi-prompt: yes' <<< "$out" \
	&& ok "the interactive prompt actually renders through PS1_CMD (vi state visible)" \
	|| bad "shell-vi-prompt probe failed -- the prompt hook did not run"
refs=$(grep -oP 'learn-refs: \K[0-9]+' <<< "$out" | head -1)
runs=$(grep -oP 'learn-runs: \K[0-9]+' <<< "$out" | head -1)
if [ "${refs:-0}" -gt 0 ] && [ "${refs:-0}" = "${runs:-x}" ]; then
	ok "learn lists all $refs corpus entries from inside the booted system"
else
	bad "learn corpus unreadable at runtime (refs=${refs:-?} listed=${runs:-?})"
fi
grep -qE 'learn-ref-ls: .' <<< "$out" && ! grep -q 'learn-ref-ls: MISSING' <<< "$out" \
	&& ok "learn ref resolves an entry at runtime" \
	|| bad "learn ref ls returned nothing -- the manpage substitute is empty (or the probe never ran)"
grep -q 'learn-ref-verbs: ok' <<< "$out" \
	&& ok "learn ref resolves xos's own verbs (irc, scrub, recon_accept) at runtime" \
	|| bad "a learn ref page for an xos verb is empty on the booted system"
les=$(grep -oP 'learn-levels: \K[0-9]+' <<< "$out" | head -1)
pls=$(grep -oP 'learn-pools: \K[0-9]+' <<< "$out" | head -1)
[ "${les:-0}" -gt 0 ] && ok "curriculum present in the image ($les levels)" \
	|| bad "no levels in the booted image"
# the pools are what the question generator rolls against. without them every
# question renders with %placeholders% still in it.
[ "${pls:-0}" -gt 0 ] && ok "generator pools present ($pls)" \
	|| bad "no pools in the booted image -- questions cannot render"
grep -q 'learn-phrases: yes' <<< "$out" && ok "phrase macros ship" \
	|| bad "learn/phrases missing -- prompts would show literal %macro%"
grep -q 'learn-varies: yes' <<< "$out" \
	&& ok "a rendered prompt has no unexpanded macro" \
	|| bad "a prompt rendered with a literal %macro% in it"
grep -q 'learn-chains: yes' <<< "$out" \
	&& ok "challenge track holds its shape on the booted system" \
	|| bad "learn challenge check failed at runtime"
grep -q 'learn-vs: yes' <<< "$out" \
	&& ok "the reference names the command it is confused with" \
	|| bad "learn/vs did not ship -- cards lose their vs line"

echo
section "A13  a session outlives the terminal that started it"
# the whole point of shipping abduco. these probes come from a boot where NOTHING
# was attached to the session -- stdin was /dev/null -- so a listed session with a
# living child is proof the program is owned by abduco and not by a terminal.
grep -q 'devpts-mounted: devpts' <<< "$out" && ok "devpts is mounted" \
	|| bad "no devpts -- nothing can allocate a terminal"
grep -q 'ptmx-node: yes' <<< "$out" && ok "/dev/ptmx is a character device" \
	|| bad "/dev/ptmx missing -- pty allocation would fail before it even tries"
grep -q 'pty-alloc: ok' <<< "$out" && ok "a pty can actually be allocated" \
	|| bad "pty allocation failed"
grep -q 'legacy-ptys: absent' <<< "$out" && ok "the obsolete pty interface is gone" \
	|| bad "legacy ptys are compiled in"
grep -q 'abduco-runs: yes' <<< "$out" && ok "abduco runs in the image" \
	|| bad "abduco missing or broken"
grep -q 'abduco-session-listed: yes' <<< "$out" \
	&& ok "a detached session survives with no terminal attached" \
	|| bad "the detached session vanished"
grep -q 'abduco-child-alive: yes' <<< "$out" \
	&& ok "the detached program kept running and produced output" \
	|| bad "the detached program did not run"
tty_n=$(grep -oP 'ttys-spawned: \K[0-9]+' <<< "$out" | head -1)
[ "${tty_n:-0}" -ge 2 ] && ok "$tty_n virtual terminals spawned" \
	|| bad "only ${tty_n:-0} virtual terminals"
# the console supervisor honours its device argument. a POSIX gotcha
# (`_dev=$1 _fail=0 _t0` sets the vars only for the command `_t0`) left it
# empty and spun forever on every real boot; no test caught it because test
# boots power off before the console is set up.
grep -q 'console-device-ok: yes' <<< "$out" \
	&& ok "the console supervisor runs with a real device" \
	|| bad "the console got an empty device -- it would error-loop on real hardware"
# what this actually proves: the boot ran to the end of the probe block with PID 1
# alive and no kernel panic. it does NOT exercise a console session exiting -- the
# respawn-after-exit path is G40 (respawn_wait) and console-device-ok above, so the
# label says only what the check sees.
grep -q 'XOS-TEST-DONE' <<< "$out" && ! grep -q 'Kernel panic' <<< "$out" \
	&& ok "the boot reached DONE with PID 1 alive and no kernel panic" || bad "the boot panicked (or never reached DONE)"

echo
section "A14  state can be encrypted AND authenticated"
# p3's whole reason for existing. encryption alone gives confidentiality: an
# attacker cannot read it. it does not stop them CHANGING it -- decrypting
# tampered ciphertext yields attacker-controlled garbage the filesystem parses
# as root. --integrity makes tampering refused instead, which is the same
# fail-closed property verity gives the read-only root.
grep -q 'flock-works: yes' <<< "$out" && ok "file locking works" \
	|| bad "flock() is ENOSYS -- cryptsetup cannot lock, and the flock applet is a lie"
grep -q 'cryptsetup-runs: yes' <<< "$out" \
	&& ok "cryptsetup runs, using the kernel crypto backend" \
	|| bad "cryptsetup missing, or linked against a crypto library instead of the kernel"
grep -q 'crypto-aes: yes'     <<< "$out" && ok "aes is available in the kernel crypto api"   || bad "aes missing from the kernel crypto api"
grep -q 'crypto-sha512: yes'  <<< "$out" && ok "sha512 is available in the kernel crypto api" || bad "sha512 missing from the kernel crypto api"
grep -q 'loop-node: present'  <<< "$out" && ok "/dev/loop0 exists"                            || bad "no loop device node"
grep -q 'dm-control: present' <<< "$out" && ok "/dev/mapper/control exists"                   || bad "no device-mapper control node"
grep -q 'luks-format: ok' <<< "$out" && ok "a LUKS2 volume can be created with integrity" \
	|| bad "luksFormat failed"
grep -q 'luks-open: ok' <<< "$out" && ok "it unlocks with the right passphrase" \
	|| bad "luksOpen failed"
grep -q 'luks-integrity-active: integrity: hmac' <<< "$out" \
	&& ok "the opened volume really is authenticated, not merely encrypted" \
	|| bad "no integrity on the opened volume -- encryption without authentication"
grep -q 'luks-wrong-pass-refused: refused' <<< "$out" \
	&& ok "the wrong passphrase is refused" || bad "a wrong passphrase opened the volume"
grep -q 'fs-ext4: yes' <<< "$out" && ok "ext4 is available for the state filesystem" || bad "no ext4"
grep -q 'fs-vfat: yes' <<< "$out" && ok "vfat available (usb sticks, esp)" || bad "no vfat"
grep -q 'fs-exfat: yes' <<< "$out" && ok "exfat available (large sd cards, modern sticks)" || bad "no exfat"
grep -q 'fs-iso9660: yes' <<< "$out" && ok "iso9660 available (loop-mount an image)" || bad "no iso9660"
grep -q 'fs-ntfs3: yes' <<< "$out" && ok "ntfs available (read a windows disk)" || bad "no ntfs"
# the shipped scrub function: a full read of the verity device, as an operator
# would run it. rot would panic the boot instead (A1/A7 prove that alarm).
grep -q 'scrub-clean: yes' <<< "$out" \
	&& ok "scrub read every verity-covered byte and found them all intact" \
	|| bad "the shipped scrub function did not come back clean"
grep -q 'entropy-trusted: random.trust_cpu=1' <<< "$out" \
	&& ok "the entropy source is pinned on the signed cmdline" \
	|| bad "random.trust_cpu is not pinned -- keys may be generated on a thin pool"
# the clock floor. no RTC is compiled in, so system time is set by luck; the
# floor makes it impossible to push BELOW the build date, which is the property
# TLS validation needs -- a clock set backwards revalidates revoked certs.
grep -q 'clock-floor: [0-9]' <<< "$out" && ok "a signed clock floor is pinned on the cmdline" \
	|| bad "no clock floor -- time can be set to anything, incl. before a revocation"
grep -q 'clock-not-before-floor: yes' <<< "$out" \
	&& ok "the running clock is at or above the floor" \
	|| bad "the clock is below the floor -- init did not raise it"
# a machine whose rtc is already sane must make NO network time call -- the
# the shipped tunnel's own handshake, as init saw it. A15 tests tls-time; this
# is the layer under it, and it printed unread until now.
#
# $net_ok is a HOST-side probe, and the guest is behind qemu's user-mode NAT
# with its own resolver -- the host can be online while the guest's DNS is not.
# keying the assertion off $net_ok alone made this fail on a boot whose only
# fault was `resolve ...: Try again`. a gate that cries wolf is a gate you stop
# reading, so a guest-side network failure SKIPS; only a handshake that came
# back wrong FAILS.
# tr -d '\r': this comes off a serial console, and init strips the CR on the
# handshake line but not on this one -- "none\r" is not "none".
tls_err=$(grep -oP 'tls-stderr: \K.*' <<< "$out" | head -1 | tr -d '\r')
if grep -q 'tls-handshake: HTTP/1' <<< "$out"; then
	ok "init's tls handshake reached an https server through the shipped anchors"
	[ "$tls_err" = none ] \
		&& ok "the tls tunnel wrote nothing to stderr" \
		|| bad "the tls tunnel handshook but still wrote to stderr: $tls_err"
elif [ "$net_ok" != yes ] || [[ "$tls_err" =~ (resolve|Try\ again|Network\ is\ unreachable|No\ route) ]]; then
	skipped "no network in the guest ($tls_err) -- init's tls handshake not evaluated"
else
	bad "tls-handshake did not return HTTP/1: $(grep -oP 'tls-handshake: \K.*' <<< "$out" | head -1)"
fi

# tls-time pass exists for floored clocks only, and its absence is a privacy
# property worth pinning.
grep -q 'tls-time: skipped (rtc sane)' <<< "$out" \
	&& ok "sane rtc: no tls-time network call was made" \
	|| bad "tls-time ran (or failed) on a boot whose clock was already right"

echo
section "A15  a clock set to the past cannot fall below the signed floor"
# boot with the RTC at 2010. the floor is the build date; init must raise the
# clock to it. this is the property that stops an attacker on the network from
# winding time back to before a certificate was revoked.
backout=$(boot_backclock stick.img)
grep -q 'clock-not-before-floor: yes' <<< "$backout" \
	&& ok "clock forced to 2010 was raised to the build-date floor" \
	|| bad "the clock stayed in the past -- the floor did not hold"
# the floor made time not-backward; tls-time must then make it RIGHT. this is
# the real production path end to end: floored clock -> handshake against the
# compiled-in anchors -> Date header parsed -> clock advanced, forward only.
# needs the network (same probe A6 ran); the floor above holds without it.
if [ "$net_ok" = yes ]; then
	grep -q 'advanced to tls time' <<< "$backout" \
		&& ok "floored clock was advanced to authenticated tls time" \
		|| bad "tls-time did not advance a floored clock (dead-rtc machines stay 90 days behind)"
	grep -q 'tls-time: synced' <<< "$backout" \
		&& ok "probe agrees: tls-time synced" \
		|| bad "tls-time probe did not report synced"
else
	skipped "no network -- tls-time advance not evaluated (floor still asserted)"
fi
# this is a second full boot of the same stick -- free vehicle for the
# per-boot properties: the mac must be fresh, the fingerprint must not be.
mac15=$(grep -oP 'mac-uplink: \K[0-9a-f:]{17}' <<< "$backout" | head -1)
[ -n "$mac15" ] && [ "$mac15" != "$mac2" ] \
	&& ok "a second boot drew a different mac" || bad "mac repeated across boots"
grep -qF "fingerprint: $want_fp" <<< "$backout" \
	&& ok "fingerprint words identical across boots" \
	|| bad "fingerprint words changed between boots of the same image"
assert_complete "$backout" "A15 boot"
# the same floored boot with no network device: the ladder must give up and
# say so -- "unreachable", never "synced" and never the rtc-sane default.
nonic=$(XOS_NONIC=1 boot_backclock stick.img)
grep -q 'clock-not-before-floor: yes' <<< "$nonic" \
	&& ok "no network: the floor still held" || bad "no network: the floor did not hold"
grep -q 'tls-time: unreachable' <<< "$nonic" \
	&& ok "no network: tls-time reports unreachable, not synced" \
	|| bad "no network: tls-time did not say unreachable ($(grep -o 'tls-time: .*' <<< "$nonic" | head -1))"
assert_complete "$nonic" "A15 no-nic boot"

echo
section "A16  state survives a real power cycle"
# the whole reason p3 exists. a blank disk is attached and xos is booted twice.
# boot 1 provisions it -- LUKS2 with integrity, a filesystem, a marker file.
# boot 2 gets the SAME disk and must read the marker back. the file is a plain
# image (no host root needed); xos, which is root inside qemu, does every
# privileged step. this is "reboot and your work is still there", proven.
p3disk=$XT/xos-p3test.img
rm -f "$p3disk"; truncate -s 64M "$p3disk"
b1=$(boot_state "$p3disk")
grep -q 'ledger: first boot recorded' <<< "$b1" \
	&& ok "boot 1 opened the ledger at one" \
	|| bad "no ledger entry on first boot"
if grep -q 'teststate-phase: provision' <<< "$b1" \
   && grep -q 'teststate-format: ok' <<< "$b1" \
   && grep -q 'teststate-mkfs: ok' <<< "$b1"; then
	ok "boot 1 provisioned p3 (luks2 + integrity + a filesystem)"
else
	bad "boot 1 did not provision p3"
fi
grep -q 'recon: first visit to machine' <<< "$b1" \
	&& ok "boot 1 recorded a recon baseline for this machine" \
	|| bad "recon did not record a baseline on first visit"
grep -q 'teststate-write: ok' <<< "$b1" \
	&& ok "boot 1 wrote the marker into p3 and synced it" \
	|| bad "boot 1 could not write to p3 (boot 2's read-back proves nothing without this)"
assert_complete "$b1" "A16 boot 1"
# boot 2 is the same machine, same disk -- but a pci device has appeared
# (an xhci controller). recon must read the marker back AND call out the
# new hardware; a machine that grew a device since your last visit is
# exactly what recon exists to notice.
b2=$(boot_state "$p3disk" -device qemu-xhci)
grep -q 'teststate-open: ok' <<< "$b2" \
	&& ok "boot 2 reopened the encrypted partition boot 1 made" \
	|| bad "boot 2 could not open p3 (the marker read below cannot mean anything)"
grep -q 'teststate-prior-marker: survived-a-reboot' <<< "$b2" \
	&& ok "boot 2 read the marker back -- state survived the power cycle" \
	|| bad "the marker did not survive the reboot"
grep -qE 'recon: MACHINE [0-9a-f]{16} CHANGED' <<< "$b2" \
	&& ok "boot 2 noticed the machine changed" \
	|| bad "a new pci device went unremarked -- recon is blind"
# the ledger must count across a real power cycle, and carry the previous
# boot's timestamp -- a rolled-back p3 image shows a lower number than the
# one you remember, which is the only thing on the stick that can say so.
grep -qE 'ledger: boot 2 on this state \(last was [0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$b2" \
	&& ok "boot 2 counted, and named when boot 1 happened" \
	|| bad "the ledger did not advance to 2 across the power cycle"
grep -q 'new:  pci' <<< "$b2" \
	&& ok "the diff names the device that appeared" \
	|| bad "recon said 'changed' but not what changed"
# the persistent home carries whatever mode mkfs gave its root (0755); init
# chmods it 700 after the mount, and that chmod used to fail in silence.
# A16's p3 is a whole disk the real state_open() scan never matches (A19 has
# the partitioned one), so the home here is still the tmpfs; it must stay
# root-only through the teststate open/close, and no chmod may have failed.
grep -q 'home-final: 700 tmpfs' <<< "$b2" && ! grep -q 'home is not root-only' <<< "$b2" \
	&& ok "the home stayed root-only (0700) through a p3 open and release" \
	|| bad "the home is not 0700 after the p3 round trip"
assert_complete "$b2" "A16 boot 2"
# boot 3 is the same machine AND the same hardware as boot 2 -- recon must now
# report NO change. the other half of the guarantee: a feature that cried
# "changed" on every boot would be as useless as one that never noticed.
b3=$(boot_state "$p3disk" -device qemu-xhci)
# ...but the baseline was NOT silently replaced by boot 2: nobody accepted the
# change, so the alarm must repeat. it used to clear itself after one line.
grep -q 'recon: MACHINE [0-9a-f]\{16\} still CHANGED since its baseline' <<< "$b3" \
	&& ok "boot 3 saw identical hardware and said nothing changed" \
	|| bad "recon cried 'changed' on an unchanged machine -- false alarms"
grep -q 'ledger: boot 3 on this state' <<< "$b3" \
	&& ok "boot 3 counted on -- the ledger is monotonic" \
	|| bad "the ledger lost count on boot 3"
assert_complete "$b3" "A16 boot 3"
# boots 4-7: the branches three boots never reached. a variant stick carries a
# test-only word (G31 keeps them off production): xos.testaccept runs the real
# recon_accept on the test volume after boot 4 counted, xos.testledger junks
# the ledger after boot 5 counted -- init's own hand, because the lab console
# is a fifo where a typed sync never reaches the disk. then the accepted
# baseline must hold, the junk must be caught and kept, the count restarted,
# the removed controller named, and the corruption still warned about a boot
# later. the sticks are signed here like A11's superseded image.
if signed_ready "A16 boots 4-7"; then
	mk_uki a16a "$(cat cmdline.txt) xos.testaccept"; mk_stick a16a
	mk_uki a16l "$(cat cmdline.txt) xos.testledger"; mk_stick a16l
	b4=$(XOS_STICK=$XT/xos-a16a.img boot_state "$p3disk" -device qemu-xhci)
	grep -q 'still CHANGED' <<< "$b4" && grep -q 'testaccept: accepted: machine' <<< "$b4" \
		&& ok "boot 4 was still alarmed, then recon_accept took the new baseline" \
		|| bad "boot 4 did not accept the changed baseline"
	grep -q 'ledger: boot 4 on this state' <<< "$b4" && ok "boot 4 counted" || bad "boot 4 lost count"
	assert_complete "$b4" "A16 boot 4"
	b5=$(XOS_STICK=$XT/xos-a16l.img boot_state "$p3disk" -device qemu-xhci)
	grep -qE 'recon: machine [0-9a-f]{16} is as you left it' <<< "$b5" \
		&& ok "boot 5: the accepted baseline holds -- 'as you left it'" \
		|| bad "boot 5 did not say 'as you left it' after the accept"
	grep -q 'ledger: boot 5 on this state' <<< "$b5" && grep -q 'testledger: corrupted' <<< "$b5" \
		&& ok "boot 5 counted, then the ledger was junked for the next boot" \
		|| bad "boot 5 did not count, or did not corrupt the ledger"
	assert_complete "$b5" "A16 boot 5"
	# no xhci now: the controller accepted in boot 4 is gone, and the diff must say so
	b6=$(boot_state "$p3disk")
	grep -q 'ledger CORRUPT -- kept as evidence, count restarts' <<< "$b6" \
		&& grep -q 'ledger: first boot recorded on this state' <<< "$b6" \
		&& ok "boot 6 found the junked ledger, kept it as evidence, restarted the count" \
		|| bad "boot 6 did not catch the corrupt ledger"
	grep -qE 'recon: MACHINE [0-9a-f]{16} CHANGED since your last visit' <<< "$b6" && grep -q 'gone: ' <<< "$b6" \
		&& ok "boot 6 named the device that disappeared (gone:)" \
		|| bad "recon did not report the removed controller"
	assert_complete "$b6" "A16 boot 6"
	b7=$(boot_state "$p3disk")
	grep -q 'ledger: was found CORRUPT on' <<< "$b7" && grep -q 'ledger: boot 2 on this state' <<< "$b7" \
		&& ok "boot 7 still warns of the kept corruption, and counts on from the restart" \
		|| bad "boot 7 forgot the corruption, or lost the restarted count"
	assert_complete "$b7" "A16 boot 7"
fi
rm -f "$p3disk"

echo
section "A17  remote access: wireguard up, ssh in over it, invisible otherwise"
# the "ssh in from the operator box and attach to what is running" ask. a full
# two-machine handshake is verified on real hardware; here every component is
# proven: the wireguard interface comes up and wg configures it, dropbear
# accepts a real ed25519 pubkey login end to end, and a wrong key is refused.
# dropbear only ever binds to the wireguard address in the real flow, so xos
# stays invisible on the network it is plugged into.
#
# why not a real connect THROUGH the tunnel here: the harness would have to be
# the wg peer, which needs a host-side wireguard interface (root + kernel
# module on the build host), and the client key that A19's provision boot
# fabricates never leaves the guest's p3 -- by design. so the through-tunnel
# login stays a real-hardware check; A19 asserts the production dropbear binds
# the tunnel address, and this section proves the auth path end to end.
grep -q 'wg-iface-up: ok' <<< "$out" && ok "a wireguard interface comes up" \
	|| bad "no wireguard -- the kernel or wg userland is missing"
grep -q 'wg-show: ok' <<< "$out" && ok "wg configures the interface (key, port)" \
	|| bad "wg could not configure the interface"
grep -q 'ssh-listening: yes' <<< "$out" && ok "dropbear listens" || bad "dropbear did not start"
grep -q 'ssh-pubkey-login: ok' <<< "$out" \
	&& ok "an ed25519 public-key login works end to end" \
	|| bad "pubkey ssh login failed"
grep -q 'ssh-wrong-key-refused: refused' <<< "$out" \
	&& ok "a key not in authorized_keys is refused" \
	|| bad "the wrong key was accepted -- auth is not enforced"

echo
section "A18  yank the boot stick -- the machine must die"
# the dead-man tether. root is a RAM copy, so removal would otherwise change
# nothing. boot over emulated usb with a qmp monitor attached; xos.testtether
# keeps init alive after the probe block (A18 owns this boot's lifetime), then
# hot-remove the usb device the way a hand does and assert the poweroff.
if signed_ready A18; then
	mk_uki a18 "$(cat cmdline.txt) xos.testtether"; mk_stick a18
	a18log=$XT/xos-a18.log; a18qmp=$XT/xos-a18.qmp; rm -f "$a18log" "$a18qmp"
	timeout 360 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" \
		-device qemu-xhci,id=xhci \
		-drive if=none,id=stick,format=raw,readonly=on,file=$XT/xos-a18.img \
		-device usb-storage,bus=xhci.0,drive=stick,id=stickdev \
		-qmp unix:"$a18qmp",server,nowait \
		-nic user,model=virtio-net-pci -nographic -no-reboot </dev/null >"$a18log" 2>&1 &
	qpid=$!
	t=0; while [ "$t" -lt 180 ] && ! grep -q 'XOS-TEST-DONE' "$a18log" 2>/dev/null; do sleep 1; t=$((t+1)); done
	if ! grep -q 'tether-armed: yes' "$a18log" 2>/dev/null; then
		bad "tether did not arm on the usb boot"; kill "$qpid" 2>/dev/null
	else
		ok "tether armed over emulated usb"
		python3 - "$a18qmp" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
f.readline(); f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
f.write(json.dumps({"execute": "device_del", "arguments": {"id": "stickdev"}}) + "\n"); f.flush(); f.readline()
PY
		t=0; while [ "$t" -lt 30 ] && kill -0 "$qpid" 2>/dev/null; do sleep 1; t=$((t+1)); done
		grep -q 'boot stick removed -- powering off' "$a18log" \
			&& ok "init saw the yank and announced the poweroff" \
			|| bad "no removal message -- the tether never fired"
		if kill -0 "$qpid" 2>/dev/null; then
			bad "machine still running ${t}s after the stick was pulled"; kill "$qpid" 2>/dev/null
		else
			ok "machine powered off within ${t}s of the yank"
		fi
	fi
	wait "$qpid" 2>/dev/null
	rm -f $XT/xos-a18.efi $XT/xos-a18-signed.efi $XT/xos-a18.img "$a18log" "$a18qmp"
fi

echo
section "A19  every opt-out knob holds, and the state prompt is real"
# the knobs are guards; a guard that silently stopped guarding is the exact
# regression class this harness exists for. one signed variant UKI turns every
# opt-out on at once and asserts each visibly took. then two production-
# flavoured boots (no xos.test -- the probe block ends in poweroff and never
# reaches state_open) attach a PARTITIONED luks disk and prove the real
# state_open() scan finds it: the unlock prompt must appear, and xos.nostate
# must make it not. A16's whole-disk vdb has no partition attr, so the real
# scan never sees it -- this is the only place the production path runs.
if signed_ready A19; then
	mk_uki a19 "$(cat cmdline.txt) xos.nonet xos.realmac xos.notether xos.nostate"; mk_stick a19
	o19=$(boot_img $XT/xos-a19.img)
	grep -q 'net-has-address: no' <<< "$o19" \
		&& ok "xos.nonet: no address was configured" \
		|| bad "xos.nonet did not hold -- the box got a lease"
	grep -q 'net-dns-servers: 0' <<< "$o19" \
		&& ok "xos.nonet: no resolver was written" \
		|| bad "xos.nonet: dns servers appeared"
	grep -q 'dhcp-client: none' <<< "$o19" \
		&& ok "xos.nonet: no dhcp client was started" \
		|| bad "xos.nonet: a dhcp client is running"
	grep -q 'irc-nonet: refused (good)' <<< "$o19" \
		&& ok "irc on a box with no network refuses instead of claiming a tunnel" \
		|| bad "irc claimed success with no network (the socket alone used to pass for 'up')"
	# the same opt-out image with the rtc in 2010: the floor holds, and tls-time
	# says it was switched off rather than pretending the rtc was sane.
	o19c=$(boot_backclock $XT/xos-a19.img)
	grep -q 'clock-not-before-floor: yes' <<< "$o19c" \
		&& ok "xos.nonet + old rtc: the floor held with no network" \
		|| bad "xos.nonet + old rtc: the floor did not hold"
	grep -q 'tls-time: off (xos.nonet)' <<< "$o19c" \
		&& ok "xos.nonet + old rtc: tls-time reports off (xos.nonet)" \
		|| bad "xos.nonet + old rtc: tls-time did not report off ($(grep -o 'tls-time: .*' <<< "$o19c" | head -1))"
	assert_complete "$o19c" "A19 nonet backclock boot"
	grep -q 'mac-randomized: off (xos.realmac)' <<< "$o19" \
		&& ok "xos.realmac: burned-in mac kept" \
		|| bad "xos.realmac did not hold"
	grep -q 'tether-armed: off (xos.notether)' <<< "$o19" \
		&& ok "xos.notether: tether stayed down" \
		|| bad "xos.notether did not hold"
	assert_complete "$o19" "A19 opt-out boot"

	# the partitioned luks disk, built host-side: gpt with one partition at
	# 1MiB, a luks2 header dd'd into it. in the guest it enumerates as vdb1
	# WITH a partition attr -- exactly what the real scan looks for.
	a19disk=$XT/xos-a19-state.img; a19luks=$XT/xos-a19.luks
	truncate -s 48M "$a19disk"
	printf 'label: gpt\n, 40M, L\n' | sfdisk "$a19disk" >/dev/null 2>&1
	truncate -s 40M "$a19luks"
	printf 'testpass' | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
		--pbkdf-force-iterations 1000 --batch-mode --key-file - "$a19luks" >/dev/null 2>&1
	dd if="$a19luks" of="$a19disk" bs=1M seek=1 conv=notrunc status=none

	# production cmdline: the test flags stripped, nothing else touched. this
	# boot never prints XOS-TEST-END; it is killed by its own timeout after
	# the assertion window.
	prodcmd=$(tr ' ' '\n' < cmdline.txt | grep -v '^xos\.test' | tr '\n' ' ')
	mk_uki a19p "$prodcmd"; mk_stick a19p
	o19p=$(timeout 90 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" \
		-drive file=$XT/xos-a19p.img,if=virtio,format=raw,readonly=on \
		-drive file="$a19disk",if=virtio,format=raw \
		-nic user,model=virtio-net-pci -nographic -no-reboot < /dev/null 2>&1)
	grep -q 'unlock persistent state?' <<< "$o19p" \
		&& ok "the real state_open() scan found the partitioned luks disk and asked" \
		|| bad "no unlock prompt -- the production state scan is not finding partitions"

	# a boot stick whose OWN p3 header is gone. grow a copy of the production
	# stick by 8 MiB, append a third partition, lay a LUKS header in it with the
	# magic zeroed in both header copies. isLuks fails, so state_open used to
	# drop it in silence: no prompt, no word. it must say so now.
	a19h=$XT/xos-a19h.img
	cp $XT/xos-a19p.img "$a19h"
	truncate -s $(( $(stat -c%s "$a19h") + 8*1024*1024 )) "$a19h"
	sfdisk --relocate gpt-bak-std "$a19h" >/dev/null 2>&1
	printf ', , L\n' | sfdisk --append "$a19h" >/dev/null 2>&1
	a19hst=$(sfdisk -d "$a19h" | sed -n 's/.*img3 : start= *\([0-9]*\),.*/\1/p')
	if [ -n "$a19hst" ]; then
		dd if="$a19luks" of="$a19h" bs=512 seek="$a19hst" count=64 conv=notrunc status=none
		dd if=/dev/zero of="$a19h" bs=1 seek=$((a19hst*512)) count=6 conv=notrunc status=none
		dd if=/dev/zero of="$a19h" bs=1 seek=$((a19hst*512 + 16384)) count=6 conv=notrunc status=none
		o19h=$(timeout 90 qemu-system-x86_64 -machine q35,smm=on -m 512 \
			"${QEMU_FW[@]}" \
			-drive file="$a19h",if=virtio,format=raw,readonly=on \
			-nic user,model=virtio-net-pci -nographic -no-reboot < /dev/null 2>&1)
		grep -q 'p3 is there but its LUKS header is unreadable' <<< "$o19h" \
			&& ok "a boot stick with an unreadable p3 header says so" \
			|| bad "an unreadable p3 header was dropped in silence (no 'unreadable' line)"
		grep -q 'unlock persistent state?' <<< "$o19h" \
			&& bad "an unreadable p3 still produced an unlock prompt" \
			|| ok "no unlock prompt for a p3 that cannot be opened"
		grep -q 'this image is:' <<< "$o19h" \
			&& ok "the boot carried on stateless after the unreadable p3" \
			|| bad "the damaged-p3 boot never reached the banner"
	else
		bad "could not append a third partition to the test stick (sfdisk)"
	fi
	rm -f "$a19h"

	# a malformed xos.epoch (the floor's one silent degradation) must be
	# announced. appended last: cmdline_get takes the last occurrence.
	mk_uki a19x "$(cat cmdline.txt) xos.epoch=abc"; mk_stick a19x
	o19x=$(boot_backclock $XT/xos-a19x.img)
	grep -q 'clock floor SKIPPED: xos.epoch is not a number' <<< "$o19x" \
		&& ok "a malformed xos.epoch is announced, not silently ignored" \
		|| bad "a malformed xos.epoch skipped the floor without a word"
	grep -q 'tls-time: skipped (rtc sane)' <<< "$o19x" \
		&& ok "with no floor applied, tls-time stays out (the announced degradation, nothing more)" \
		|| bad "tls-time ran or misreported under a malformed epoch ($(grep -o 'tls-time: .*' <<< "$o19x" | head -1))"
	assert_complete "$o19x" "A19 malformed-epoch boot"

	# same disk, same cmdline plus xos.nostate: the prompt must NOT appear.
	mk_uki a19n "$prodcmd xos.nostate"; mk_stick a19n
	o19n=$(timeout 90 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" \
		-drive file=$XT/xos-a19n.img,if=virtio,format=raw,readonly=on \
		-drive file="$a19disk",if=virtio,format=raw \
		-nic user,model=virtio-net-pci -nographic -no-reboot < /dev/null 2>&1)
	if grep -q 'unlock persistent state?' <<< "$o19n"; then
		bad "xos.nostate did not hold -- the unlock prompt appeared anyway"
	elif grep -q 'this image is:' <<< "$o19n"; then
		ok "xos.nostate: same disk, no prompt, boot carried on"
	else
		bad "the nostate boot never reached the banner -- nothing was proven"
	fi

	# ── the crown jewel: the REAL production unlock, typed at the prompt ────
	# a fresh partitioned-but-blank disk is provisioned by a teststate boot
	# (which now targets vdb1 and drops an operator-style wg0.conf on it),
	# then a production boot gets the passphrase typed over the serial
	# console -- the same keystrokes a hand would make. everything after is
	# the path real hardware runs: scan, prompt, cryptsetup open, mount,
	# ledger, wireguard from the conf, dropbear bound to the tunnel address.
	a19e=$XT/xos-a19e.img
	truncate -s 48M "$a19e"
	printf 'label: gpt\n, 40M, L\n' | sfdisk "$a19e" >/dev/null 2>&1
	prov=$(boot_state "$a19e")
	grep -q 'teststate-mkfs: ok' <<< "$prov" \
		&& ok "provision boot formatted the partition (vdb1, not the whole disk)" \
		|| bad "teststate did not provision vdb1"

	# type the passphrase: qemu's stdin is a fifo; write only after the
	# prompt has actually appeared in the log, the way a human waits.
	boot_typed() { # $1=stick $2=disk $3=passphrase $4=log [$5=extra opts for the state disk]
		local fifo=$XT/xos-a19.fifo t=0
		rm -f "$fifo" "$4"; mkfifo "$fifo"
		timeout 150 qemu-system-x86_64 -machine q35,smm=on -m 512 \
			"${QEMU_FW[@]}" \
			-drive file="$1",if=virtio,format=raw,readonly=on \
			-drive file="$2",if=virtio,format=raw"${5:-}" \
			-nic user,model=virtio-net-pci -nographic -no-reboot < "$fifo" > "$4" 2>&1 &
		qp19=$!
		# rdwr: a write-only open of a fifo blocks until a reader appears, and
		# a qemu that died on startup is a reader that never comes.
		exec 9<> "$fifo"
		# answer every prompt that appears -- init allows three tries, so a
		# wrong passphrase re-prompts. type once per prompt seen, stop the
		# moment a terminal verdict lands.
		local sent=0 seen
		while [ "$sent" -lt 3 ]; do
			t=0
			while [ "$t" -lt 90 ]; do
				grep -aqE 'state unlocked|continuing without persistence|would not mount' "$4" && break 2
				seen=$(grep -ac 'unlock persistent state?' "$4" || true)
				[ "${seen:-0}" -gt "$sent" ] && break
				sleep 1; t=$((t+1))
			done
			[ "$t" -ge 90 ] && break
			printf '%s\n' "$3" >&9
			sent=$((sent+1))
		done
		t=0
		while [ "$t" -lt 45 ] && ! grep -aqE 'state unlocked|continuing without persistence|would not mount' "$4"; do sleep 1; t=$((t+1)); done
		sleep 5   # let the wg/ssh lines land before the kill
		# an optional command typed at the shell once the wg/ssh lines have
		# landed (the shell is spawned after them); the caller names a marker
		# the command prints last, and this waits for it.
		if [ -n "${6:-}" ]; then
			printf '%s\n' "$6" >&9
			t=0; while [ "$t" -lt 30 ] && ! grep -aq "${7:-PROBE-DONE}" "$4"; do sleep 1; t=$((t+1)); done
		fi
		exec 9>&-
		kill "$qp19" 2>/dev/null; wait "$qp19" 2>/dev/null
		rm -f "$fifo"
	}

	a19log=$XT/xos-a19-typed.log
	boot_typed "$XT/xos-a19p.img" "$a19e" testpass "$a19log" "" 'busybox true && echo TYPED-FG-OK' TYPED-FG-OK
	# the serial console shell has working job control: a typed command runs
	# in the FOREGROUND and prints. it did not, on every serial console, for as
	# long as the shell was started through cttyhack on /dev/console -- each
	# command died in the background with "can't set tty process group".
	grep -aq 'TYPED-FG-OK' "$a19log" && ! grep -aq 'tty process group' "$a19log" \
		&& ok "a command typed at the serial console runs in the foreground (job control works)" \
		|| bad "the serial console shell cannot run a typed command ($(grep -aoE "can't set tty process group[^.]*|TYPED-FG-OK" "$a19log" | head -1))"
	# the only boot where the real p3 is the home: init's own unlock line now
	# states the mode and the filesystem it found, read back after the chmod
	# (busybox stat -f names ext4 "ext2/ext3"). nothing is typed at the shell:
	# the lab console is a fifo with no controlling terminal, and a typed
	# command there is backgrounded and never runs.
	grep -aq 'state unlocked -- /tmp/home persists across reboots (0700, ext2/ext3)' "$a19log" \
		&& ok "the unlocked p3 home is root-only (0700) on its own filesystem" \
		|| bad "after a real unlock init did not report the p3 home as 0700 ext4 ($(grep -ao 'state unlocked -- [^\n]*' "$a19log" | head -1))"
	# match the SUCCESS line, not the substring both outcomes share. init says
	# "state unlocked -- <home> persists across reboots" when it worked and
	# "state unlocked but the filesystem would not mount -- p3 is damaged" when
	# it did not, so a bare 'state unlocked' passed this either way: the one
	# assertion carrying the whole production-unlock claim could not fail.
	if grep -aq 'state unlocked -- .* persists across reboots' "$a19log"; then
		ok "typed passphrase: the real state_open opened and mounted p3"
	elif grep -aq 'state unlocked but' "$a19log"; then
		bad "p3 unlocked but did not MOUNT -- the filesystem is damaged (this used to read as a pass)"
	else
		bad "the production unlock did not accept a typed passphrase"
	fi
	grep -aq 'ledger: boot 2 on this state' "$a19log" \
		&& ok "the production boot counted in the same ledger" \
		|| bad "ledger did not carry from the provision boot to the real unlock"
	grep -aq 'wireguard up on wg0 (10.9.0.2/32)' "$a19log" \
		&& ok "wireguard came up from an operator-style conf (Address included)" \
		|| bad "the real wg path did not bring the tunnel up"
	grep -aq 'ssh listening on the tunnel only (10.9.0.2:22)' "$a19log" \
		&& ok "dropbear bound to the tunnel address, nothing else" \
		|| bad "ssh did not come up on the tunnel"
	grep -aq 'note: state opened on /dev/vdb1, not the boot stick' "$a19log" \
		&& ok "off-stick state is announced (boot-disk-first ordering held)" \
		|| bad "state opened off the boot stick without saying so"

	boot_typed $XT/xos-a19p.img "$a19e" wrongpass "$a19log"
	grep -aq 'wrong passphrase -- 2 attempt(s) left' "$a19log" \
		&& ok "a typo gets a retry instead of costing the whole session" \
		|| bad "no retry after a wrong passphrase"
	grep -aq 'wrong passphrase -- continuing without persistence' "$a19log" \
		&& ok "three wrong passphrases are refused out loud, and the boot goes on" \
		|| bad "wrong passphrase was not refused loudly"

	# the RIGHT passphrase on a p3 that unlocks but holds no filesystem (the
	# a19disk is LUKS with nothing inside): both mount paths must name the
	# damage, not fall through as "wrong passphrase" by omission. once with the
	# disk writable (the rw path), once read-only (the vault path).
	boot_typed $XT/xos-a19p.img "$a19disk" testpass "$a19log"
	grep -aq 'state unlocked but the filesystem would not mount -- p3 is damaged' "$a19log" \
		&& ok "right passphrase, no filesystem: the rw path says p3 is damaged" \
		|| bad "a p3 that unlocks but will not mount was not called damaged (rw path)"
	grep -aq 'this image is:' "$a19log" \
		&& ok "the boot carried on after the damaged rw mount" || bad "the damaged-rw boot never reached the banner"
	boot_typed $XT/xos-a19p.img "$a19disk" testpass "$a19log" ",readonly=on"
	grep -aq 'state unlocked but the read-only filesystem would not mount -- p3 is damaged' "$a19log" \
		&& ok "right passphrase, no filesystem, write-protected: the vault path says p3 is damaged" \
		|| bad "a write-protected p3 that unlocks but will not mount was not called damaged (vault path)"

	# NOT driven here: corrupting the ledger from the console and powering off
	# cleanly. the console is a non-tty fifo under qemu, and busybox ash job
	# control backgrounds every EXTERNAL command typed into it -- `sync` and
	# `poweroff` both return exit 2 without doing their work, so the junk write
	# never reaches the virtio disk before the VM is killed and the next boot
	# sees the ledger intact. ledger_note's CORRUPT/evidence/restart logic
	# (init, `ledger_note`) is a few lines of string handling, read-verified and
	# proven by hand (printf junk + reboot through a real console shows
	# `ledger CORRUPT -- kept as evidence, count restarts` then
	# `was found CORRUPT`); driving it in CI needs a test hook that corrupts the
	# ledger in init's own context, which is more fort surface than the bug it
	# would guard. A16 already proves the ledger counts and persists across a
	# real power cycle; A18 drives a real init poweroff.

	rm -f $XT/xos-a19*.efi $XT/xos-a19*.img "$a19luks" "$a19log"
fi

section "A20  a usb-serial adapter becomes a vt320 login line"
# the vt320 path: xos boots on machines with no com port, so a hardware terminal
# is reached over a usb-serial dongle. attach qemu's usb-serial (an ftdi ft232)
# to the same xhci bus the stick is on and prove the whole chain: the drivers are
# compiled in (ttyUSB enumerates), and init lines it for a vt320 (19200). without
# this, a kernel that quietly dropped usb-serial would ship and the terminal
# would stay dark -- the one promise the feature makes.
if ! qemu-system-x86_64 -device help 2>/dev/null | grep -q '"usb-serial"'; then
	skipped "this qemu has no usb-serial device -- A20 not evaluated"
else
	serout=$(boot_usbserial stick.img)
	grep -qE 'serial-usb: .*/dev/tty(USB|ACM)[0-9]' <<< "$serout" \
		&& ok "the usb-serial adapter enumerated (driver compiled in and bound)" \
		|| bad "no ttyUSB/ttyACM -- usb-serial driver missing or did not bind"
	grep -q 'serial-baud: 19200' <<< "$serout" \
		&& ok "init set the serial line to 19200 for a vt320" \
		|| bad "the usb-serial line was not set to the vt320 baud"
	# the TERM, which this section never checked. it is what puts a serial
	# session on learn's mono tier -- attributes, no colour -- and the whole
	# vt320 half of lib/ui is drawn for it. the device node and the baud were
	# asserted while the one setting that decides how the screen looks was not.
	grep -q 'serial-term: vt320' <<< "$serout" \
		&& ok "the serial line got TERM=vt320 (learn draws it on the mono tier)" \
		|| bad "the serial TERM is not vt320 -- a serial session draws for the wrong hardware"
	# the DEFAULT above cannot fail on its own; this asserts the term console_loop
	# ACTUALLY assigned the enumerated line, read from its own beacon. a broken
	# case in console_loop (mislabelling a ttyUSB as TERM=linux) fails here.
	grep -q 'serial-term-picked: vt320' <<< "$serout" \
		&& ok "console_loop picked vt320 for the real serial device (not just the default)" \
		|| bad "console_loop assigned the serial line the wrong TERM -- a mislabelled serial console"
	# and its geometry, because the brief-height gate is measured against it: a
	# serial line reports no window size, so init pins 80x24 and G50 budgets 19
	# rendered rows from it. if these ever disagree, a teaching page scrolls its
	# own first line away on the terminal the mono tier exists for.
	#
	# BUT the winsize ioctl needs a real tty backing, and qemu's usb-serial here
	# is a `null` chardev (a sink, by design -- see boot_usbserial): the guest
	# ftdi ttyUSB then answers TIOCGWINSZ like a non-tty, so `stty size` comes
	# back empty however correctly init pinned it. a real usb-serial dongle backs
	# a real tty where the pin sticks (verified on a pty). so: a numeric size is
	# held to 24x80; an EMPTY one is the rig's limit, skipped and left to the
	# real-hardware check, not failed. a WRONG number still fails loud.
	_ssz=$(grep -o 'serial-size: [^[:space:]]*' <<< "$serout" | awk '{print $2}')
	case "$_ssz" in
		24x80) ok "the serial line is 80x24, the screen G50 measures briefs against" ;;
		'')    skipped "serial-size unreadable on the qemu null-chardev ftdi (winsize needs a real tty backing) -- 24x80 pin verified on real usb-serial hardware" ;;
		*)     printf '%s\n' "$serout" > $XT/xos-a20.serout
		       bad "the serial geometry is $_ssz, not 24x80 -- G50's brief budget no longer matches it (full serout: $XT/xos-a20.serout)" ;;
	esac
	assert_complete "$serout" "A20 usb-serial boot"
	# the two knobs README documents for other hardware, never passed by any
	# round until now: a vt100 at 9600 on the signed cmdline must reach the
	# line the loop set up, in both the baud and the TERM it picked.
	if signed_ready "A20 knobs"; then
		mk_uki a20v "$(cat cmdline.txt) xos.term=vt100 xos.baud=9600"; mk_stick a20v
		servar=$(boot_usbserial $XT/xos-a20v.img)
		grep -q 'serial-baud: 9600' <<< "$servar" && grep -q 'serial-term-picked: vt100' <<< "$servar" \
			&& ok "xos.term and xos.baud on the signed cmdline reach the serial line (vt100, 9600)" \
			|| bad "the serial knobs did not take ($(grep -oE 'serial-(baud|term-picked): [^ ]*' <<< "$servar" | tr '\n' ' '))"
		assert_complete "$servar" "A20 knobs boot"
	fi
fi

section "A21  vault mode: a write-protected stick runs from RAM, untouched"
# the FlashBlu30's hardware write-protect switch is the whole vault story, and
# nothing tested it: dev_ro(), the --readonly LUKS open and the /tmp/p3ro sidecar
# never ran under qemu. a virtio disk attached readonly=on makes the guest kernel
# mark /sys/class/block/vdb/ro=1 -- exactly what dev_ro reads -- so the real vault
# path runs here for the first time. it needs a provisioned p3 (ext4 + files) and
# a production stick, both of which A19's rig knows how to make.
if signed_ready A21; then
	# a production stick: the test flags stripped, so state_open runs for real
	a21cmd=$(tr ' ' '\n' < cmdline.txt | grep -v '^xos\.test' | tr '\n' ' ')
	mk_uki a21 "$a21cmd"; mk_stick a21
	# provision a p3 (ext4 + wg0.conf), exactly the way A19's crown-jewel does
	a21disk=$XT/xos-a21-state.img
	truncate -s 48M "$a21disk"
	printf 'label: gpt\n, 40M, L\n' | sfdisk "$a21disk" >/dev/null 2>&1
	prov=$(boot_state "$a21disk")
	grep -q 'teststate-mkfs: ok' <<< "$prov" \
		&& ok "provision boot laid down a p3 to run vault mode against" \
		|| bad "could not provision the p3 for the vault test"
	# boot production with that SAME disk attached READ-ONLY -- the switch is on.
	a21log=$XT/xos-a21.log a21fifo=$XT/xos-a21.fifo
	rm -f "$a21fifo" "$a21log"; mkfifo "$a21fifo"
	timeout 150 qemu-system-x86_64 -machine q35,smm=on -m 512 \
		"${QEMU_FW[@]}" \
		-drive file=$XT/xos-a21.img,if=virtio,format=raw,readonly=on \
		-drive file="$a21disk",if=virtio,format=raw,readonly=on \
		-nic user,model=virtio-net-pci -nographic -no-reboot < "$a21fifo" > "$a21log" 2>&1 &
	qp21=$!
	exec 9<> "$a21fifo"
	# type the passphrase at each prompt (three tries, same as the real hand)
	a21sent=0; a21seen=0; a21t=0
	while [ "$a21sent" -lt 3 ]; do
		a21t=0
		while [ "$a21t" -lt 90 ]; do
			grep -aqE 'vault mode:|continuing without persistence|would not mount' "$a21log" && break 2
			a21seen=$(grep -ac 'unlock persistent state?' "$a21log" || true)
			[ "${a21seen:-0}" -gt "$a21sent" ] && break
			sleep 1; a21t=$((a21t+1))
		done
		[ "$a21t" -ge 90 ] && break
		printf 'testpass\n' >&9
		a21sent=$((a21sent+1))
	done
	# wait for the vault line, then drive a write-probe at the login shell: the
	# read-only p3 sidecar must refuse a write; the RAM $HOME must accept one.
	a21t=0
	while [ "$a21t" -lt 45 ] && ! grep -aqE 'vault mode:|continuing without persistence|would not mount' "$a21log"; do sleep 1; a21t=$((a21t+1)); done
	sleep 3
	printf '%s\n' 'touch /tmp/p3ro/vaultprobe 2>&1 | grep -qi read-only && echo VAULT-P3-RO; touch "$HOME/vaultprobe" 2>/dev/null && echo VAULT-HOME-OK; . /etc/shrc 2>/dev/null; recon_accept 2>&1 | grep -q "vault mode" && echo VAULT-ACCEPT-REFUSED; echo VAULT-PROBE-DONE' >&9
	a21t=0
	while [ "$a21t" -lt 30 ] && ! grep -aq 'VAULT-PROBE-DONE' "$a21log"; do sleep 1; a21t=$((a21t+1)); done
	sleep 2
	exec 9>&-; kill "$qp21" 2>/dev/null; wait "$qp21" 2>/dev/null; rm -f "$a21fifo"

	grep -aq 'vault mode: p3 is write-protected' "$a21log" \
		&& ok "the write-protect switch put the boot in vault mode (dev_ro + --readonly open)" \
		|| bad "vault mode did not engage on a read-only p3 -- the switch story is unproven"
	# the RAM staging of wg0.conf/authorized_keys/ledger/recon and the home
	# chmod now report their failures; a vault boot on a good p3 has none.
	! grep -aqE 'vault: could not (stage|link)|home is not root-only' "$a21log" \
		&& ok "every p3 file staged into RAM and the home is root-only" \
		|| bad "vault staging reported a failure: $(grep -aE 'vault: could not|home is not root-only' "$a21log" | head -1)"
	grep -aq 'VAULT-P3-RO' "$a21log" \
		&& ok "a write to p3 is refused -- the stick stays untouched in vault mode" \
		|| bad "p3 took a write in vault mode (or the probe never ran) -- the core promise is unproven"
	grep -aq 'VAULT-HOME-OK' "$a21log" \
		&& ok "the RAM \$HOME still takes writes -- work continues, nothing persists" \
		|| bad "the RAM home was not writable in vault mode"
	# what init SAYS in vault mode must be true: no persistence claim, a ledger
	# that reports and does not count, recon that records nothing, and a
	# recon_accept that refuses.
	grep -aq 'vault mode -- .* is RAM: nothing you do persists' "$a21log" \
		&& ok "the banner says nothing persists in vault mode" \
		|| bad "vault mode did not say that nothing persists"
	grep -aq 'persists across reboots' "$a21log" \
		&& bad "vault mode still claimed persistence across reboots" \
		|| ok "no persistence claim was made in vault mode"
	grep -aq 'ledger: vault mode -- this boot is not counted' "$a21log" \
		&& ok "the ledger reports the stick's count and counts nothing in vault mode" \
		|| bad "the ledger counted a vault boot (a number the stick never stores)"
	grep -aqE 'recon: .*(vault mode|is as you left it)' "$a21log" \
		&& ok "recon records nothing in vault mode (or found the machine unchanged)" \
		|| bad "recon claimed to record a baseline in vault mode"
	grep -aq 'VAULT-ACCEPT-REFUSED' "$a21log" \
		&& ok "recon_accept refuses in vault mode and says why" \
		|| bad "recon_accept did not refuse in vault mode"
	rm -f $XT/xos-a21*.efi $XT/xos-a21*.img "$a21disk" "$a21log"
fi


section "A22  clone: a booted stick copies itself onto a plugged-in spare"
# the field clone verb -- a booted xos writes a full, verified copy of its own
# stick onto a spare, with no build host and no keys. driven through the
# xos.testclone probe hook: clone runs non-interactively, the spare's own model
# fed in as the confirmation a hand would type. the spare is attached as
# REMOVABLE usb (what a spare stick looks like); the boot disk is virtio and is
# excluded. we assert clone's own verdict AND cmp the spare image to the stick
# from outside the guest, so the copy is proven twice.
if signed_ready A22; then
	mk_uki a22 "$(cat cmdline.txt) xos.testclone"; mk_stick a22
	a22stick=$XT/xos-a22.img a22spare=$XT/xos-a22-spare.img
	a22ssz=$(stat -c%s "$a22stick"); truncate -s $((a22ssz + 8*1024*1024)) "$a22spare"
	a22out=$(timeout 200 qemu-system-x86_64 -machine q35,smm=on -m 512 "${QEMU_FW[@]}" \
		-drive file="$a22stick",if=virtio,format=raw,readonly=on \
		-device qemu-xhci,id=xhci \
		-drive if=none,id=spare,format=raw,file="$a22spare" \
		-device usb-storage,bus=xhci.0,drive=spare,removable=on \
		-nic user,model=virtio-net-pci -nographic -no-reboot < /dev/null 2>&1)
	if grep -q 'clone-test: .*is an exact copy of this stick' <<< "$a22out"; then
		ok "clone found the spare, confirmed it by model, copied and read it back clean"
	else
		bad "clone did not report a verified copy"
		printf '%s\n' "$a22out" | grep -a 'clone-test:' | sed 's/^/    /'
	fi
	if cmp -n "$a22ssz" "$a22stick" "$a22spare" >/dev/null 2>&1; then
		ok "the spare image byte-matches the stick over its whole length"
	else
		bad "the spare's bytes do not match the stick -- clone was not faithful"
	fi
	assert_complete "$a22out" "A22 clone boot"
	# the refusals, which are most of what clone is: a spare too small to hold
	# the stick, and two spares at once. neither may write a byte.
	a22small=$XT/xos-a22-small.img; truncate -s $((a22ssz - 8*1024*1024)) "$a22small"
	a22s=$(timeout 200 qemu-system-x86_64 -machine q35,smm=on -m 512 "${QEMU_FW[@]}" \
		-drive file="$a22stick",if=virtio,format=raw,readonly=on \
		-device qemu-xhci,id=xhci \
		-drive if=none,id=small,format=raw,file="$a22small" \
		-device usb-storage,bus=xhci.0,drive=small,removable=on \
		-nic user,model=virtio-net-pci -nographic -no-reboot < /dev/null 2>&1)
	grep -q 'clone-test: clone: the spare (.*) is smaller than this stick' <<< "$a22s" \
		&& ok "clone refuses a spare smaller than the stick, and says the sizes" \
		|| bad "clone did not refuse a too-small spare"
	cmp -s -n 1048576 /dev/zero "$a22small" 2>/dev/null \
		&& ok "the too-small spare was not written" || bad "clone wrote to a spare it should have refused"
	a22two=$XT/xos-a22-two.img; truncate -s $((a22ssz + 8*1024*1024)) "$a22two"
	a22t=$(timeout 200 qemu-system-x86_64 -machine q35,smm=on -m 512 "${QEMU_FW[@]}" \
		-drive file="$a22stick",if=virtio,format=raw,readonly=on \
		-device qemu-xhci,id=xhci \
		-drive if=none,id=sp1,format=raw,file="$a22spare" \
		-device usb-storage,bus=xhci.0,drive=sp1,removable=on \
		-drive if=none,id=sp2,format=raw,file="$a22two" \
		-device usb-storage,bus=xhci.0,drive=sp2,removable=on \
		-nic user,model=virtio-net-pci -nographic -no-reboot < /dev/null 2>&1)
	grep -q 'clone-test: clone: more than one spare is plugged in' <<< "$a22t" \
		&& ok "clone refuses to guess between two spares" \
		|| bad "clone did not refuse with two spares attached"
	cmp -s -n 1048576 /dev/zero "$a22two" 2>/dev/null \
		&& ok "neither spare was written when two were present" || bad "clone wrote with two spares attached"
	rm -f $XT/xos-a22*.efi $XT/xos-a22-signed.efi "$a22spare" "$a22small" "$a22two" $XT/xos-a22.img
fi

printf '  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
if [ "$sections" -ne "$EXPECTED_SECTIONS" ]; then
	printf '\033[1;31m  only %d of %d checks ran -- the harness was truncated\033[0m\n\n' \
		"$sections" "$EXPECTED_SECTIONS"
	exit 1
fi
if [ "$crit_skip" -gt 0 ] && [ -z "${XOS_ALLOW_SKIP:-}" ]; then
	printf '\033[1;31m  %d critical section(s) SKIPPED -- dbx/tether/unlock/vault/clone never ran, so this is NOT a pass.\033[0m\n' "$crit_skip"
	printf '\033[1;31m  run on a host with the systemd-boot stub + an unlocked key, or set XOS_ALLOW_SKIP=1 to accept a stub-less run.\033[0m\n\n'
	exit 1
fi
echo
[ "$fail" -eq 0 ]

# the carrier stick -- one 256 GB stick for everything

the default xos kit is two sticks: the 16 GB Kanguru FlashBlu30 *fort* (xos image
+ LUKS state, hardware write-protect switch = vault/work) and any 256 GB exFAT
`XOS-KNOW` stick of read-only reference payload. this file describes a third
arrangement -- **one 256 GB stick** carrying xos, a general-purpose alpine live
daily-driver, and the reference payload together, for when you want a normal pc
(dwl + emulators) some of the time and xos the rest, out of one pocket.

it is a **provisioning recipe, not a build target**. xos does not build alpine
and `build.sh` lays down none of this for you -- the signed image stays exactly
what its source says. the one tool xos gives you is `build.sh sign` (below), so
the second os boots under xos's own secure boot.

## the tradeoff, up front

a hardware write-protect switch is **whole-disk** -- `init` reads `ro=1` off the
block device and opens p3 read-only ("vault mode"); the flag covers the whole
device, not a partition. so a WP switch **cannot coexist with a writable save
partition**: flip it and *everything* goes read-only, including the emulator
saves you wanted to keep.

the carrier therefore uses **no WP switch**. xos on it boots `xos.nostate`
(stateless, RAM-only) -- nothing persists from an xos session, which is
functionally vault-like, but it is **not hardware vault**: the read-only
partitions are software-read-only only. a compromised session could in principle
write to the stick. xos-image tampering is still caught by attestation on the
next boot (verity + the db signature cover p2 and the UKI), and alpine mounts its
own root read-only, so the exposure is bounded -- but it is real, and it is the
price of one stick.

**keep the FlashBlu30 as the real fort** for high-stakes work, where true vault
mode and the LUKS loot partition matter. the carrier is the everyday-convenience
stick. don't put secrets on it you wouldn't put on a laptop.

> if you ever source a 256 GB stick with a *genuine* hardware WP switch, the
> layout below already supports a better mode: WP-on is a per-boot pure-read-only
> session (xos vault + read-only alpine, no saves), WP-off enables saves. rare
> hardware, so not assumed here.

## why it doesn't break xos

attestation and verity are scoped to xos's **own** artifacts -- the p2 verity
volume and the db-signed UKI, addressed by PARTUUID -- never the GPT, the ESP,
free space, or any other partition. adding partitions after xos's changes nothing
it measures. two mechanical constraints:

- **everything new must start at or after 74 MiB** (`STATE_START_S`). the xos
  flasher (`build.sh usb`) rewrites the GPT to its own two-partition layout on
  every update and then re-appends the partition entries it found past the image
  region. entries *inside* the first 74 MiB are destroyed on re-flash.
- keep the `sfdisk` restore line the flasher prints. tail-preservation is
  automatic but if the re-add ever fails, that line puts your partitions back.

## layout (GPT, one 256 GB stick)

| # | label | size | fs | mode | purpose |
|---|---|---|---|---|---|
| 1 | XOS-ESP | 64 MiB | FAT32 | ro | xos db-signed UKI (rewritten on xos update) |
| 2 | XOS-ROOT | 8 MiB | squashfs+verity | ro | xos rootfs; boots `xos.nostate` |
| 3 | ALPINE-ESP | 512 MiB | FAT32 | ro | alpine UKI (db-co-signed) + kernel/initramfs |
| 4 | ALPINE-ROOT | ~2 GB | squashfs | ro | alpine live root: dwl + emulators; overlay in RAM |
| 5 | XOS-SAVE | 2--4 GB | ext4 | **rw** | the only writable slice: emulator saves + alpine `lbu` apkovl |
| 6 | XOS-KNOW | rest (~250 GB) | exFAT | ro | reference payload, shared by xos readers **and** alpine |

- **no LUKS state partition.** it needs writes; loot stays in RAM or, by hand,
  on p5.
- **wear is confined to p5.** p1--p4 and p6 are written once at provision and
  read forever -- reads don't wear flash. at emulator-save write volumes the
  stick effectively lasts forever.
- **alpine gets its own ESP (p3)**, separate from xos's (p1), because a re-flash
  rewrites p1 -- a shared ESP would lose alpine's boot files on every xos update.

## provisioning

read `docs/building.md` first; this assumes you can already build and flash xos.

1. **lay down xos, no state partition.**

   ```sh
   ./build.sh usb /dev/sdX        # p1 + p2 only -- do NOT run addstate
   ```

   the carrier boots xos stateless, so skip `addstate` entirely (a LUKS p3 would
   only waste the space and never unlock writable without the switch anyway).

2. **make xos boot stateless.** the signed cmdline is baked into the UKI, so add
   `xos.nostate` by editing `cmdline.txt` before `./build.sh uki`/`usb`, or pass
   it at the firmware boot menu if your firmware allows cmdline edits (most under
   secure boot do not -- baking it in is the reliable path). `xos.nostate` is
   read by `init`; with no p3 present it is also the default behaviour, so this is
   belt-and-braces.

3. **add p3--p6, all at/after 74 MiB.** the exact starts depend on the device;
   `sgdisk -p /dev/sdX` after step 1 shows the first free sector (it will be at
   or past sector 151552 = 74 MiB). then, roughly:

   ```sh
   sgdisk \
     -n 3:0:+512M -t 3:C12A7328-F81F-11D2-BA4B-00A08693446B -c 3:ALPINE-ESP \
     -n 4:0:+2G   -t 4:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 4:ALPINE-ROOT \
     -n 5:0:+4G   -t 5:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 5:XOS-SAVE \
     -n 6:0:0     -t 6:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 6:XOS-KNOW \
     /dev/sdX
   mkfs.fat  -F 32 -n ALPINE-ESP /dev/sdX3
   mkfs.ext4 -L XOS-SAVE          /dev/sdX5
   mkfs.exfat -n XOS-KNOW         /dev/sdX6
   # p4 (ALPINE-ROOT) is written as a raw squashfs image, see step 4:
   ```

4. **build alpine as a live UKI.** on an alpine host (or in a chroot), build a
   diskless/run-from-RAM system -- squashfs root, `mkinitfs`, a unified kernel
   image (kernel + initramfs + cmdline in one PE). install dwl, a terminal, and
   your emulators into the squashfs. point the cmdline at `LABEL=ALPINE-ROOT` for
   the squashfs and set the overlay to tmpfs so the running system writes to RAM,
   not the stick. `dd` the squashfs onto p4; put the UKI on p3 as
   `EFI/BOOT/BOOTX64.EFI`.

   persistence goes through alpine's own `lbu`: point its backup at the ext4
   `XOS-SAVE` (p5), and mount p5 at your emulators' save directory. p5 is the
   only thing that ever takes writes.

5. **co-sign the alpine UKI with xos's db key.** xos owns secure boot -- its db
   is an allowlist that no longer trusts the Microsoft/shim chain, so a stock
   alpine bootloader will not boot. sign the UKI you built in step 4 with the
   same key that signs xos:

   ```sh
   ./build.sh sign /path/to/alpine/EFI/BOOT/BOOTX64.EFI
   ```

   it unlocks the sealed db key into RAM, `sbsign`s the image in place, verifies
   the result against `keys/db.crt`, and is a no-op if the file is already signed
   by that key. it does **not** touch the enrolled varstore. copy the signed UKI
   onto p3 afterwards (or sign it in place on the mounted partition).

6. **populate p6.** stage the reference payload onto `XOS-KNOW` exactly as for a
   standalone knowledge stick -- `arsenal/build-books.sh`, `build-maps.sh`,
   `build-games.sh`, plus any zims you supply. see the main README's "carrying
   it" section.

## using it

- **boot** via the firmware boot menu (the F-key entry): pick `XOS-ESP` or
  `ALPINE-ESP`. both binaries are db-signed, so secure-boot enforcement stays on
  for both -- no shim, no MOK, no third-party boot manager to trust.
- **xos** runs a stateless RAM session. mount the reference payload by hand; the
  readers find it by label:

  ```sh
  mkdir -p /run/media/x/XOS-KNOW && mount -o ro LABEL=XOS-KNOW /run/media/x/XOS-KNOW
  ```

  (`atlas`, `arsenal`, `kiwix-*` glob `/run/media/*/XOS-KNOW/…`.)
- **alpine** runs live from RAM; p5 holds your saves and `lbu` config; p6 is
  readable here too if you want the same reference tree in your normal pc.

## updating xos on the carrier

`./build.sh usb /dev/sdX` re-flashes p1+p2 and preserves p3--p6 (they sit past
the image region). re-run `./build.sh sign` on the alpine UKI only if you rebuilt
alpine -- an xos update never touches it. verify with `sgdisk -p /dev/sdX` that
all six partitions survived; if the tail re-add ever failed, the flasher printed
the `sfdisk` line to restore them.

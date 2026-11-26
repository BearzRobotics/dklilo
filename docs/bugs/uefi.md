# UEFI loader bugs (`src/uefi/main.zig`)

## UEFI-01: One failed boot blocks later boots with an initrd
**Severity:** High · **Status:** Fixed (reproduced first)

Lines 314-325 install the initrd `LoadFile2` protocol on a new handle and never uninstall it. After `StartImage` fails or returns, the next install of the same device path fails.

**Reproduction:** the test EFI app as `image =` plus an `initrd`. First attempt returned. Second: `initrd protocol install failed: AlreadyStarted`. Only restarting the loader clears it.

**Fix (applied):** the protocol is uninstalled, and the initramfs forgotten and freed, on every return from a boot attempt. The line numbers above describe release 0.0.4.

**Regression test:** `tests/qemu/l2-uefi-retry.sh`, case "the same entry boots twice". The old loader printed `initrd protocol install failed: AlreadyStarted`.

## UEFI-02: A stale initrd can go to the next entry
**Severity:** High · **Status:** Fixed (reproduced first)

If the next entry has no initrd, nothing replaces the leftover protocol or resets `initrd_data`, so that kernel can receive the previous entry's initramfs.

**Reproduced:** in `tests/qemu/l2-uefi-retry.sh`, after booting an entry with an initramfs, the old loader offered it (`initrd=12`) to the next entry, which has none.

**Fix (applied):** see UEFI-01.

## UEFI-03: Failed attempts leak memory and images
**Severity:** Low · **Status:** Fixed (by review; no test observes the leaks)

`joined` and `opts` (290, 302) are never freed. The loaded image is not unloaded when a later step fails (306-319). `chainEfi` does not free the handle buffer or device path.

**Fix (applied):** the command line, joined initramfs, handle buffer and device path are freed, and an image that was loaded but never started is unloaded. The line numbers above describe release 0.0.4.

## UEFI-04: `other = windows` takes the first match on any FAT volume
**Severity:** Medium · **Status:** Fixed (reproduced first)

Lines 352-376 follow firmware handle order, preferring neither the boot disk nor an ESP, unlike SPEC 5.6. A USB stick can be started instead of the installed system. A load failure returns without trying other matches.

**Fix (applied):** the volume dklilo was loaded from is tried first, then others on its disk, then other disks, and a boot manager that fails to load doesn't end the search. The line numbers above describe release 0.0.4.

**Regression test:** `tests/qemu/l5-uefi-windows-disks.sh`. On 0.0.4 it started the other disk's boot manager. The "keeps searching" case was shown to fail on the code before this fix; 0.0.4 happens to pass it because it tries the other disk first.

**Limit:** only volumes the firmware has connected are seen. The preference is by volume and disk, not by partition type.

## UEFI-05: Block device properties are trusted
**Severity:** Medium · **Status:** Fixed (by review; not tested)

`block_size` is not validated (the shared code assumes 512-4096), and `io_align` above 4096 is not satisfied by the bounce buffer (114-145).

**Fix (applied):** a device whose block size isn't 512 to 4096, or whose `io_align` is not a power of two up to 64 KiB, is skipped, and the bounce buffer is aligned to what the device asks. The line numbers above describe release 0.0.4.

## UEFI-06: Device tree copy uses boot-services memory
**Severity:** Medium · **Status:** Fixed (by review; not checked against the specification text)

Line 185 publishes the copy in `boot_services_data`, which is reclaimable after `ExitBootServices`. I believe EBBR requires ACPI-reclaim memory for the DTB but did not check. Linux's EFI stub may copy it first; other consumers may not. The copy also happens on every platform that has the table.

**Fix (applied):** the copy is allocated as ACPI reclaim memory, which an operating system keeps until it has read its tables. I believe this is what EBBR asks for, but did not check the document. The AArch64 and RISC-V boots in the QEMU suite exercise the copy.

## UEFI-07: Smaller issues
**Severity:** Low · **Status:** Partly fixed

- Config bytes are widened one at a time to UTF-16 (62, 303), garbling non-ASCII text.
- A config read error drops to the manual prompt with no message (417-418).
- `say` silently drops messages over 256 bytes.
- `serial =` is ignored.

**Fixed:** text, including the kernel command line, is converted from UTF-8 (shown to fail first in `tests/qemu/l2-uefi-retry.sh`); a configuration read error is reported; and a long message is cut short, not dropped.

**Open:** `serial =` is still not used. The manual now says so.

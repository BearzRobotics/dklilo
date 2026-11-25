# UEFI loader bugs (`src/uefi/main.zig`)

## UEFI-01: One failed boot blocks later boots with an initrd
**Severity:** High · **Status:** Reproduced (OVMF)

Lines 314-325 install the initrd `LoadFile2` protocol on a new handle and never uninstall it. After `StartImage` fails or returns, the next install of the same device path fails.

**Reproduction:** the test EFI app as `image =` plus an `initrd`. First attempt returned. Second: `initrd protocol install failed: AlreadyStarted`. Only restarting the loader clears it.

**Fix:** keep the handle and uninstall on every return path.

## UEFI-02: A stale initrd can go to the next entry
**Severity:** High · **Status:** Code review (follows from UEFI-01)

If the next entry has no initrd, nothing replaces the leftover protocol or resets `initrd_data`, so that kernel can receive the previous entry's initramfs.

## UEFI-03: Failed attempts leak memory and images
**Severity:** Low · **Status:** Code review

`joined` and `opts` (290, 302) are never freed. The loaded image is not unloaded when a later step fails (306-319). `chainEfi` does not free the handle buffer or device path.

## UEFI-04: `other = windows` takes the first match on any FAT volume
**Severity:** Medium · **Status:** Code review

Lines 352-376 follow firmware handle order, preferring neither the boot disk nor an ESP, unlike SPEC 5.6. A USB stick can be started instead of the installed system. A load failure returns without trying other matches.

## UEFI-05: Block device properties are trusted
**Severity:** Medium · **Status:** Code review

`block_size` is not validated (the shared code assumes 512-4096), and `io_align` above 4096 is not satisfied by the bounce buffer (114-145).

## UEFI-06: Device tree copy uses boot-services memory
**Severity:** Medium · **Status:** Needs verification against the specification

Line 185 publishes the copy in `boot_services_data`, which is reclaimable after `ExitBootServices`. I believe EBBR requires ACPI-reclaim memory for the DTB but did not check. Linux's EFI stub may copy it first; other consumers may not. The copy also happens on every platform that has the table.

## UEFI-07: Smaller issues
**Severity:** Low · **Status:** Code review

- Config bytes are widened one at a time to UTF-16 (62, 303), garbling non-ASCII text.
- A config read error drops to the manual prompt with no message (417-418).
- `say` silently drops messages over 256 bytes.
- `serial =` is ignored.

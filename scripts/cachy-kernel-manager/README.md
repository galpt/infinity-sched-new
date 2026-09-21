# Kernel Manager Cleanup

This script reclaims disk space after rebuilding kernels with the CachyOS kernel manager. It cleans build trees, stale packages, source tarballs, and orphaned boot images. Everything is listed before anything is removed, and the running kernel is never touched.

## What it cleans

Build trees hold compiled objects from finished builds and are safe to remove, since the next build extracts fresh sources. Built packages are kept by default, because reinstalling without them means rebuilding. Source tarballs are kept by default, because rebuilding without them means downloading again. Boot images from kernels you no longer have installed are listed by default and removed only when you confirm twice.

A boot file counts as orphaned only when three checks all agree. Its name must not match the running kernel, no package may own it, and no live boot entry may reference it. Files owned by a package, files for the running kernel, the microcode image, config files, directories, and the bootloader history are never deleted.

## Flags

You can read every flag below. Each flag is shown in code form.

```text
--dry-run        List only. Nothing is removed and no prompt appears.
--yes            Confirm the plan without asking. Required for any removal.
--drop-packages  Also remove built package files. They are kept by default.
--drop-tarballs  Also remove source tarballs. They are kept by default.
--prune-boot     Also remove orphaned boot files. Listing only by default.
--help           Show usage and exit.
```

Removal needs `--yes` in every case. Boot pruning additionally needs `--prune-boot`, so one flag alone never deletes boot files.

## Examples

You can preview everything without changing anything with the command below:

```sh
./safe-clean-cachy-kernel-manager.sh --dry-run
```

You can clean build trees only, which is the safest reclaim, with the command below:

```sh
./safe-clean-cachy-kernel-manager.sh --yes
```

You can include packages, tarballs, and boot orphans with the command below:

```sh
./safe-clean-cachy-kernel-manager.sh --yes --drop-packages --drop-tarballs --prune-boot
```

## Logs and testing

Every run writes a timestamped log under `/tmp` with the before and after disk state. For testing, point the script at throwaway directories with the command below:

```sh
CACHY_KM_CACHE=/tmp/mk BOOT_DIR=/tmp/mb ./safe-clean-cachy-kernel-manager.sh --dry-run
```

## Limits

Boot scanning covers top level files only. Bootloader subdirectories are out of scope. System map files are never touched. A log of every run stays in `/tmp` for review.

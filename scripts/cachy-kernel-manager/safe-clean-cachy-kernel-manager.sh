#!/usr/bin/env bash
#
# safe-clean-cachy-kernel-manager.sh
# Cleans disk space used by the CachyOS kernel manager build cache and,
# optionally, orphaned /boot files left by uninstalled kernels.
#
# Scope (v1):
#   - Manager cache (default $HOME/.cache/cachyos-km/pkgbuilds):
#       src/ + pkg/ build trees, *.pkg.tar.zst built packages,
#       cachyos-*.tar.gz + NVIDIA-*.tar.xz source tarballs.
#     Small files (PKGBUILD, .SRCINFO, *.patch, config, .testscript) are
#     NEVER deleted.
#   - /boot (default /boot), TOP LEVEL ONLY: initramfs-* / vmlinuz-* files
#     that are both (a) not part of the running kernel name and (b) owned
#     by no package (pacman -Qo reports no owner).
#     ESP subvolumes / subdirectories (e.g. the hashed limine dir under
#     /boot) are out of scope in v1 and are never recursed into.
#
# Safety:
#   - Read-only plan phase always runs first (sizes in bytes + paths).
#   - Interactive prompt unless --yes. --dry-run forces list-only, no prompt.
#   - Boot pruning needs TWO keys: --prune-boot AND --yes together.
#     An interactive "y" answer alone never authorizes /boot deletes.
#   - Running kernel (uname -r), amd-ucode.img, *.conf and directories
#     are never deleted from /boot.
#   - Symlinks are never followed (find -P; files removed with rm without
#     -r; src/pkg dirs removed only after basename + PKGBUILD checks).
#   - sudo is used only where needed (boot reads/deletes when unreadable
#     or unwritable; cache work never uses sudo).
#
# Usage:
#   ./safe-clean-cachy-kernel-manager.sh [--dry-run] [--yes]
#       [--drop-packages] [--drop-tarballs] [--prune-boot] [--help]
#
#   No flags            Show plan, prompt, then clean src/+pkg/ only.
#   --dry-run           List only, no prompt, no deletes (wins over --yes).
#   --yes               Execute after showing plan, no prompt.
#   --drop-packages     Also remove *.pkg.tar.zst (default: keep).
#   --drop-tarballs     Also remove source tarballs (default: keep).
#   --prune-boot        Also remove orphaned /boot files, but ONLY with
#                       --yes at the same time (two-key rule).
#
# Env overrides (testability; all destructive paths derive from these):
#   CACHY_KM_CACHE  default $HOME/.cache/cachyos-km/pkgbuilds
#   BOOT_DIR        default /boot

set -euo pipefail

# ---------------------------------------------------------------- config ---

CACHE_DIR="${CACHY_KM_CACHE:-$HOME/.cache/cachyos-km/pkgbuilds}"
BOOT_DIR="${BOOT_DIR:-/boot}"
RUNNING_KERNEL="$(uname -r)"
LOG_FILE="/tmp/safe-clean-cachy-kernel-manager-$(date +%Y%m%d-%H%M%S).log"

DRY_RUN=0
ASSUME_YES=0
DROP_PACKAGES=0
DROP_TARBALLS=0
PRUNE_BOOT=0

# ------------------------------------------------------------ helpers ---

# Duplicate all output to the timestamped log (same /tmp pattern as the
# old infinity-source script, but covering the full run).
exec > >(tee "$LOG_FILE") 2>&1

log() {
    printf '%s\n' "$*"
}

human_bytes() {
    # Pretty-print a byte count; fall back to raw bytes if numfmt missing.
    local bytes="${1:-0}"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || printf '%s B' "$bytes"
    else
        printf '%s B' "$bytes"
    fi
}

dir_bytes() {
    # Size of one directory in bytes (0 on error, never fails the script).
    local d="$1"
    du -sb -- "$d" 2>/dev/null | awk '{print $1}' || true
}

file_bytes() {
    # Size of one regular file in bytes (0 on error).
    local f="$1"
    stat -c %s -- "$f" 2>/dev/null || printf '0'
}

usage() {
    sed -n '2,/^set -euo/p' -- "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------- flags ---

while [ $# -gt 0 ]; do
    case "${1:-}" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --drop-packages) DROP_PACKAGES=1; shift ;;
        --drop-tarballs) DROP_TARBALLS=1; shift ;;
        --prune-boot) PRUNE_BOOT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Error: unknown argument: $1" >&2
            echo "Try --help." >&2
            exit 2
            ;;
    esac
done

# --dry-run always wins: list only, no prompt, no deletes.
if [ "$DRY_RUN" -eq 1 ]; then
    ASSUME_YES=0
fi

# --------------------------------------------------------------- guards ---

if [ ! -d "$CACHE_DIR" ]; then
    echo "Error: cache dir missing: $CACHE_DIR" >&2
    echo "Nothing to clean. Aborting." >&2
    exit 1
fi

BOOT_AVAILABLE=1
BOOT_NEEDS_SUDO=0
if [ ! -d "$BOOT_DIR" ]; then
    log "Warning: boot dir missing: $BOOT_DIR (boot section skipped)."
    BOOT_AVAILABLE=0
elif [ ! -r "$BOOT_DIR" ] || [ ! -x "$BOOT_DIR" ]; then
    # /boot is typically root-only (e.g. drwx------). The read-only plan
    # scan below uses non-interactive sudo (sudo -n) so --dry-run never
    # blocks on a password prompt; deletes use interactive sudo instead.
    BOOT_NEEDS_SUDO=1
fi

# Two-key rule for /boot: deletion allowed ONLY with both flags together
# (plus not a dry run). Anything else forces list-only for boot.
BOOT_DELETE_ALLOWED=0
if [ "$PRUNE_BOOT" -eq 1 ] && [ "$ASSUME_YES" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    BOOT_DELETE_ALLOWED=1
fi

# ------------------------------------------------------------ collectors ---

BUILD_DIRS=()   # src/ + pkg/ dirs under cache profiles
PKG_FILES=()    # *.pkg.tar.zst built packages
TARBALLS=()     # cachyos-*.tar.gz + NVIDIA-*.tar.xz
BOOT_CANDIDATES=()   # orphaned initramfs-*/vmlinuz-* (top level only)
BOOT_UNVERIFIABLE=() # matched prefix but ownership could not be checked

collect_build_dirs() {
    # Top-level profiles only: $CACHE/<profile>/{src,pkg}. Never follows
    # symlinks (find -P) so a symlinked src/pkg never matches -type d.
    BUILD_DIRS=()
    while IFS= read -r -d '' d; do
        BUILD_DIRS+=("$d")
    done < <(find -P "$CACHE_DIR" -mindepth 2 -maxdepth 2 -type d \
        \( -name src -o -name pkg \) -print0 2>/dev/null || true)
}

collect_pkg_files() {
    # Built packages. The trailing * also catches detached .sig files
    # (e.g. foo.pkg.tar.zst.sig) next to the package.
    PKG_FILES=()
    while IFS= read -r -d '' f; do
        PKG_FILES+=("$f")
    done < <(find -P "$CACHE_DIR" -type f -name '*.pkg.tar.zst*' -print0 2>/dev/null || true)
}

collect_tarballs() {
    # Rebuild inputs. Kept by default (warned as needed for rebuild).
    TARBALLS=()
    while IFS= read -r -d '' f; do
        TARBALLS+=("$f")
    done < <(find -P "$CACHE_DIR" -type f \
        \( -name 'cachyos-*.tar.gz' -o -name 'NVIDIA-*.tar.xz' \) \
        -print0 2>/dev/null || true)
}

boot_find_prefix_files() {
    # Top level of BOOT_DIR only (never recursive: ESP subdirs such as the
    # hashed limine dir are out of scope v1). Prints NUL-separated paths.
    # Uses non-interactive sudo (sudo -n) for the read-only scan when the
    # directory is not readable, so --dry-run never blocks on a password.
    # NOTE: find exits 0 even on permission errors (error goes to stderr),
    # so the sudo choice is made up front from BOOT_NEEDS_SUDO, never from
    # the find exit status.
    if [ "$BOOT_NEEDS_SUDO" -eq 1 ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo -n find -P "$BOOT_DIR" -mindepth 1 -maxdepth 1 -type f \
                \( -name 'initramfs-*' -o -name 'vmlinuz-*' \) \
                -print0 2>/dev/null || true
        else
            log "Warning: $BOOT_DIR is not readable and sudo is unavailable (boot scan skipped)."
        fi
    else
        find -P "$BOOT_DIR" -mindepth 1 -maxdepth 1 -type f \
            \( -name 'initramfs-*' -o -name 'vmlinuz-*' \) \
            -print0 2>/dev/null || true
    fi
}

is_boot_protected() {
    # Defense in depth: never delete these from /boot, even if they ever
    # appeared in a candidate list. Directories are already excluded by
    # the -type f scan; this covers name-based protection.
    local base
    base="$(basename -- "$1")"
    case "$base" in
        amd-ucode.img|*.conf) return 0 ;;
    esac
    case "$base" in
        *"$RUNNING_KERNEL"*) return 0 ;;  # running kernel, never touch
    esac
    return 1
}

collect_boot_candidates() {
    BOOT_CANDIDATES=()
    BOOT_UNVERIFIABLE=()
    [ "$BOOT_AVAILABLE" -eq 1 ] || return 0
    if ! command -v pacman >/dev/null 2>&1; then
        log "Warning: pacman not found; boot ownership cannot be verified (list-only)."
        while IFS= read -r -d '' f; do
            is_boot_protected "$f" && continue
            BOOT_UNVERIFIABLE+=("$f")
        done < <(boot_find_prefix_files || true)
        return 0
    fi
    while IFS= read -r -d '' f; do
        is_boot_protected "$f" && continue
        # Owned by a package -> keep. "No package owns" -> orphan candidate.
        # Any other pacman failure -> unverifiable, never auto-delete.
        pq_out=""
        pq_status=0
        pq_out="$(pacman -Qo -- "$f" 2>&1)" && pq_status=0 || pq_status=$?
        if [ "$pq_status" -eq 0 ]; then
            continue
        elif printf '%s' "$pq_out" | grep -q "No package owns"; then
            BOOT_CANDIDATES+=("$f")
        else
            BOOT_UNVERIFIABLE+=("$f")
        fi
    done < <(boot_find_prefix_files || true)
}

sum_file_bytes() {
    # Sum sizes of files in the named array (nameref). Skips symlinks.
    local -n arr=$1
    local total=0 b f
    for f in ${arr[@]+"${arr[@]}"}; do
        [ -f "$f" ] || continue
        [ ! -L "$f" ] || continue
        b="$(file_bytes "$f")"
        total=$((total + b))
    done
    printf '%s' "$total"
}

print_file_list() {
    # $1 = array name (nameref), $2 = indent prefix.
    local -n arr=$1
    local prefix="$2" f b
    if [ "${#arr[@]}" -eq 0 ]; then
        log "${prefix}(none)"
        return 0
    fi
    for f in "${arr[@]}"; do
        b="$(file_bytes "$f")"
        log "${prefix}$(human_bytes "$b")  ($b bytes)  $f"
    done
}

boot_file_bytes() {
    # Size of one /boot file. Uses non-interactive sudo for the read-only
    # stat when /boot is root-only (plan phase must never block on a
    # password); falls back to 0 if unreadable.
    local f="$1"
    if [ "$BOOT_NEEDS_SUDO" -eq 1 ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo -n stat -c %s -- "$f" 2>/dev/null || printf '0'
        else
            printf '0'
        fi
    else
        file_bytes "$f"
    fi
}

sum_boot_bytes() {
    # Sum sizes of files in the named boot array (nameref). Discovery
    # already used find -P -type f (no symlinks, no recursion), so no
    # per-file existence re-check here (it would fail unprivileged on a
    # root-only /boot and misreport 0).
    local -n arr=$1
    local total=0 b f
    for f in ${arr[@]+"${arr[@]}"}; do
        b="$(boot_file_bytes "$f")"
        total=$((total + b))
    done
    printf '%s' "$total"
}

print_boot_list() {
    # $1 = array name (nameref), $2 = indent prefix (sudo-aware sizes).
    local -n arr=$1
    local prefix="$2" f b
    if [ "${#arr[@]}" -eq 0 ]; then
        log "${prefix}(none)"
        return 0
    fi
    for f in "${arr[@]}"; do
        b="$(boot_file_bytes "$f")"
        log "${prefix}$(human_bytes "$b")  ($b bytes)  $f"
    done
}

# ---------------------------------------------------------- space state ---

print_space_summary() {
    local label="$1"
    log "--- $label ---"
    log "df ($CACHE_DIR):"
    df -h -- "$CACHE_DIR" 2>&1 || log "(df on cache failed)"
    if [ -d "$BOOT_DIR" ]; then
        log "df ($BOOT_DIR):"
        df -h -- "$BOOT_DIR" 2>&1 || log "(df on boot failed)"
    fi
    log "du (cache): $(du -sh -- "$CACHE_DIR" 2>/dev/null || echo '(du failed)')"
    log "Running kernel: $RUNNING_KERNEL"
}

# -------------------------------------------------------------- removers ---

safe_remove_build_dir() {
    # Removes one src/ or pkg/ dir ONLY after verifying:
    #   1. basename is exactly "src" or "pkg",
    #   2. it is a real directory, not a symlink,
    #   3. its parent (the profile dir) contains a PKGBUILD,
    #   4. the profile dir sits directly inside CACHY_KM_CACHE.
    # Aborts the whole script otherwise (fail-closed).
    local dir="$1"
    local base parent grandparent
    base="$(basename -- "$dir")"
    parent="$(dirname -- "$dir")"
    grandparent="$(dirname -- "$parent")"
    if [ "$base" != "src" ] && [ "$base" != "pkg" ]; then
        echo "SAFETY ABORT: unexpected build dir basename '$base': $dir" >&2
        exit 1
    fi
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        echo "SAFETY ABORT: not a real directory: $dir" >&2
        exit 1
    fi
    if [ ! -f "$parent/PKGBUILD" ]; then
        echo "SAFETY ABORT: parent has no PKGBUILD, refusing rm -rf: $dir" >&2
        exit 1
    fi
    if [ "$grandparent" != "$CACHE_DIR" ]; then
        echo "SAFETY ABORT: profile dir not directly under cache: $dir" >&2
        exit 1
    fi
    case "$dir" in
        "$CACHE_DIR"/*) ;;  # must live under the cache env var
        *) echo "SAFETY ABORT: path escapes cache dir: $dir" >&2; exit 1 ;;
    esac
    rm -rf -- "$dir"
}

remove_cache_file() {
    # Files under the cache: regular files only, never symlinks,
    # never recursive. No sudo (user-owned cache).
    local f="$1"
    case "$f" in
        "$CACHE_DIR"/*) ;;
        *) echo "SAFETY ABORT: path escapes cache dir: $f" >&2; exit 1 ;;
    esac
    if [ -L "$f" ]; then
        echo "Skipping symlink (never follow): $f" >&2
        return 0
    fi
    if [ ! -f "$f" ]; then
        echo "Skipping (not a regular file): $f" >&2
        return 0
    fi
    rm -f -- "$f"
}

remove_boot_file() {
    # Boot files: re-checks every protection immediately before rm.
    # Uses sudo only when needed (not root and target not writable).
    # NOTE: the -L/-f checks must run with the same privilege as the rm
    # itself: on a root-only /boot an unprivileged test always fails and
    # would wrongly skip (or misjudge) the file.
    local f="$1"
    case "$f" in
        "$BOOT_DIR"/*) ;;
        *) echo "SAFETY ABORT: path escapes boot dir: $f" >&2; exit 1 ;;
    esac
    if is_boot_protected "$f"; then
        echo "Skipping protected boot file: $f" >&2
        return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        if [ -L "$f" ] || [ ! -f "$f" ]; then
            echo "Skipping (not a regular file): $f" >&2
            return 0
        fi
        rm -f -- "$f"
    elif [ -w "$f" ] && [ -w "$(dirname -- "$f")" ]; then
        # Writable without privilege (e.g. a mock BOOT_DIR in tests).
        if [ -L "$f" ] || [ ! -f "$f" ]; then
            echo "Skipping (not a regular file): $f" >&2
            return 0
        fi
        rm -f -- "$f"
    else
        # Privileged delete (interactive sudo: user passed --yes --prune-boot).
        # NOTE: no "--" here: /usr/bin/test has no end-of-options marker
        # and errors out on it. Paths are absolute under BOOT_DIR, so a
        # leading dash is impossible.
        if sudo test -L "$f" 2>/dev/null; then
            echo "Skipping symlink (never follow): $f" >&2
            return 0
        fi
        if ! sudo test -f "$f" 2>/dev/null; then
            echo "Skipping (not a regular file): $f" >&2
            return 0
        fi
        sudo rm -f -- "$f"
    fi
}

# ================================================================== main ===

log "=============================================================="
log " CachyOS kernel-manager cleanup -- $(date)"
log " Log: $LOG_FILE"
log " Kernel: $RUNNING_KERNEL"
log " Cache: $CACHE_DIR"
log " Boot:  $BOOT_DIR (top level only; ESP subdirs out of scope v1)"
log " Flags: --dry-run=$DRY_RUN --yes=$ASSUME_YES --drop-packages=$DROP_PACKAGES --drop-tarballs=$DROP_TARBALLS --prune-boot=$PRUNE_BOOT"
log "=============================================================="
log ""

print_space_summary "BEFORE"
log ""

# ---- read-only plan phase (no deletes above this line) ----
collect_build_dirs
collect_pkg_files
collect_tarballs
collect_boot_candidates

BUILD_BYTES=0
for d in ${BUILD_DIRS[@]+"${BUILD_DIRS[@]}"}; do
    b="$(dir_bytes "$d")"
    BUILD_BYTES=$((BUILD_BYTES + b))
done
PKG_BYTES="$(sum_file_bytes PKG_FILES)"
TAR_BYTES="$(sum_file_bytes TARBALLS)"
BOOT_BYTES="$(sum_boot_bytes BOOT_CANDIDATES)"

log "========== PLAN (read-only) =========="
printf '  %-14s %12s  %-10s  %s\n' "CATEGORY" "BYTES" "HUMAN" "ACTION"
printf '  %-14s %12s  %-10s  %s\n' "build-trees" "$BUILD_BYTES" "$(human_bytes "$BUILD_BYTES")" "remove src/+pkg/ (default)"
printf '  %-14s %12s  %-10s  %s\n' "packages" "$PKG_BYTES" "$(human_bytes "$PKG_BYTES")" "$([ "$DROP_PACKAGES" -eq 1 ] && echo 'remove (--drop-packages)' || echo 'KEEP (default)')"
printf '  %-14s %12s  %-10s  %s\n' "tarballs" "$TAR_BYTES" "$(human_bytes "$TAR_BYTES")" "$([ "$DROP_TARBALLS" -eq 1 ] && echo 'remove (--drop-tarballs)' || echo 'KEEP (default; needed for rebuild)')"
printf '  %-14s %12s  %-10s  %s\n' "boot-orphans" "$BOOT_BYTES" "$(human_bytes "$BOOT_BYTES")" "$([ "$BOOT_DELETE_ALLOWED" -eq 1 ] && echo 'remove (--prune-boot --yes)' || echo 'LIST ONLY (default)')"
# NOTE: printf is used instead of log() to keep column alignment; stdout is
# already duplicated into the log by the tee redirect at the top.
log ""
log "--- build trees: src/ + pkg/ (${#BUILD_DIRS[@]} dirs, $(human_bytes "$BUILD_BYTES")) ---"
for d in ${BUILD_DIRS[@]+"${BUILD_DIRS[@]}"}; do
    log "  $(human_bytes "$(dir_bytes "$d")")  $d"
done
[ "${#BUILD_DIRS[@]}" -eq 0 ] && log "  (none)"
log ""
log "--- built packages: *.pkg.tar.zst* (${#PKG_FILES[@]} files, $(human_bytes "$PKG_BYTES")) ---"
print_file_list PKG_FILES "  "
if [ "$DROP_PACKAGES" -eq 0 ] && [ "${#PKG_FILES[@]}" -gt 0 ]; then
    log "  (kept by default; pass --drop-packages to remove)"
fi
log ""
log "--- source tarballs (${#TARBALLS[@]} files, $(human_bytes "$TAR_BYTES")) ---"
print_file_list TARBALLS "  "
if [ "$DROP_TARBALLS" -eq 0 ] && [ "${#TARBALLS[@]}" -gt 0 ]; then
    log "  WARNING: tarballs are needed to rebuild without re-downloading; kept by default."
fi
log ""
log "--- boot orphans: initramfs-*/vmlinuz-* top level only (${#BOOT_CANDIDATES[@]} files, $(human_bytes "$BOOT_BYTES")) ---"
print_boot_list BOOT_CANDIDATES "  "
if [ "${#BOOT_UNVERIFIABLE[@]}" -gt 0 ]; then
    log "  Unverifiable (ownership check failed; never auto-deleted):"
    print_boot_list BOOT_UNVERIFIABLE "    "
fi
if [ "$BOOT_DELETE_ALLOWED" -eq 0 ]; then
    if [ "$PRUNE_BOOT" -eq 1 ]; then
        log "  Two-key rule: --prune-boot was given without --yes, so boot files are LISTED ONLY (nothing removed)."
    else
        log "  Boot pruning is OFF (default); candidates listed only. Pass --prune-boot --yes to remove."
    fi
    log "  Protected (never deleted): running kernel '*${RUNNING_KERNEL}*', amd-ucode.img, *.conf, directories."
fi
log ""
log "========== END OF PLAN =========="
log ""

# ---- mode handling: dry-run exits here; otherwise prompt unless --yes ----
if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry-run: no changes made. Log: $LOG_FILE"
    exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    log "This will remove build trees (src/, pkg/) under:"
    log "  $CACHE_DIR"
    [ "$DROP_PACKAGES" -eq 1 ] && log "Plus built packages (*.pkg.tar.zst)."
    [ "$DROP_TARBALLS" -eq 1 ] && log "Plus source tarballs."
    log "Boot files are never removed in this mode (need --prune-boot --yes)."
    log ""
    read -rp "Proceed? [y/N] " reply || reply=""
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) log "Aborted."; exit 0 ;;
    esac
fi

# ---- execute (plan already shown) ----
log ""
log "Cleaning build trees (src/, pkg/)..."
for d in ${BUILD_DIRS[@]+"${BUILD_DIRS[@]}"}; do
    log "  rm -rf $d"
    safe_remove_build_dir "$d"
done
[ "${#BUILD_DIRS[@]}" -eq 0 ] && log "  (nothing to remove)"

if [ "$DROP_PACKAGES" -eq 1 ]; then
    log "Removing built packages..."
    for f in ${PKG_FILES[@]+"${PKG_FILES[@]}"}; do
        log "  rm -f $f"
        remove_cache_file "$f"
    done
    [ "${#PKG_FILES[@]}" -eq 0 ] && log "  (nothing to remove)"
else
    log "Keeping built packages (default; --drop-packages not given)."
fi

if [ "$DROP_TARBALLS" -eq 1 ]; then
    log "Removing source tarballs..."
    for f in ${TARBALLS[@]+"${TARBALLS[@]}"}; do
        log "  rm -f $f"
        remove_cache_file "$f"
    done
    [ "${#TARBALLS[@]}" -eq 0 ] && log "  (nothing to remove)"
else
    log "Keeping source tarballs (default; needed for rebuild)."
fi

if [ "$BOOT_DELETE_ALLOWED" -eq 1 ]; then
    log "Pruning orphaned boot files (--prune-boot --yes confirmed)..."
    for f in ${BOOT_CANDIDATES[@]+"${BOOT_CANDIDATES[@]}"}; do
        log "  rm -f $f"
        remove_boot_file "$f"
    done
    [ "${#BOOT_CANDIDATES[@]}" -eq 0 ] && log "  (nothing to remove)"
else
    log "Boot files untouched (list-only; need --prune-boot --yes)."
fi

log ""
print_space_summary "AFTER"
log ""
log "Done. Log written to: $LOG_FILE"

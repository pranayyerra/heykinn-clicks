#!/bin/bash
#
# One-time cleanup of empty replica bucket directories on a managed drive.
#
# Replicas are filed under the first two characters of their id
# (HeykinnClicks/Replicas/ab/<uuid>.jpg), and until now removing a replica
# deleted the file and left the directory. Migration cleanup and retargeting
# both drain replicas, so a drive can carry up to 256 empty folders that the
# app never looks at and the user does see.
#
# The app now prunes as it removes, and sweeps after any sync that removed
# files — so this is only for the directories already there. It is not part of
# normal operation and nothing calls it.
#
#   ./Packaging/prune-empty-replicas.sh "/Volumes/My Passport"           # dry run
#   ./Packaging/prune-empty-replicas.sh "/Volumes/My Passport" --apply   # delete
#   ./Packaging/prune-empty-replicas.sh "/Volumes/My Passport" --apply --include-ds-store
#
# Refuses to touch anything outside <drive>/HeykinnClicks/Replicas, refuses a
# drive with no marker file, and never removes a directory holding a real file.
set -euo pipefail

DRIVE="${1:-}"
APPLY="no"
INCLUDE_DS_STORE="no"
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)             APPLY="yes"; shift ;;
        --include-ds-store)  INCLUDE_DS_STORE="yes"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$DRIVE" ]; then
    echo "usage: $0 <drive path> [--apply] [--include-ds-store]" >&2
    echo "example: $0 \"/Volumes/My Passport\"" >&2
    exit 2
fi

[ -d "$DRIVE" ] || { echo "Not mounted: $DRIVE" >&2; exit 1; }

# The marker is what makes a drive one the app manages. Without it this is
# somebody's ordinary disk and the script has no business on it.
MARKER="$DRIVE/.heykinn-clicks-drive.json"
[ -f "$MARKER" ] || {
    echo "No marker file at $MARKER — that is not a drive this app manages." >&2
    echo "Refusing, because the only thing identifying a managed drive is missing." >&2
    exit 1
}

ROOT="$DRIVE/HeykinnClicks/Replicas"
[ -d "$ROOT" ] || { echo "No replica folder at $ROOT — nothing to clean."; exit 0; }

echo "Drive:   $DRIVE"
echo "Pruning: $ROOT"
[ "$APPLY" = "yes" ] && echo "Mode:    APPLY (directories will be deleted)" \
                     || echo "Mode:    dry run (nothing will be deleted)"
echo

empty=0
ds_only=0
occupied=0
removed=0

# Depth 1 only: buckets are direct children of the replica root, and limiting
# the depth means no recursion can wander somewhere unintended.
while IFS= read -r bucket; do
    [ -d "$bucket" ] || continue

    real_files="$(find "$bucket" -mindepth 1 ! -name '.DS_Store' -print -quit 2>/dev/null || true)"
    any_entry="$(find "$bucket" -mindepth 1 -print -quit 2>/dev/null || true)"

    if [ -z "$any_entry" ]; then
        empty=$((empty + 1))
        echo "  empty          $(basename "$bucket")"
        if [ "$APPLY" = "yes" ]; then
            rmdir "$bucket" && removed=$((removed + 1))
        fi
    elif [ -z "$real_files" ]; then
        ds_only=$((ds_only + 1))
        echo "  .DS_Store only $(basename "$bucket")"
        if [ "$APPLY" = "yes" ] && [ "$INCLUDE_DS_STORE" = "yes" ]; then
            rm -f "$bucket/.DS_Store"
            rmdir "$bucket" && removed=$((removed + 1))
        fi
    else
        occupied=$((occupied + 1))
    fi
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d)

echo
echo "Holding photos:   $occupied"
echo "Empty:            $empty"
echo "Only .DS_Store:   $ds_only"
if [ "$APPLY" = "yes" ]; then
    echo "Removed:          $removed"
else
    echo
    echo "Nothing was changed. Re-run with --apply to remove the empty ones."
    if [ "$ds_only" -gt 0 ]; then
        echo "Add --include-ds-store to also clear the ones holding only a Finder .DS_Store file."
    fi
fi

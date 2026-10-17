
#!/usr/bin/env bash
# fs-inventory.sh
# Inventory files belonging to a specific mounted filesystem.

set -u
export LC_ALL=C

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <mount-point-or-path>"
    exit 1
fi

TARGET=$(realpath -e -- "$1") || {
    echo "ERROR: Path does not exist: $1" >&2
    exit 1
}

if [[ ! -d "$TARGET" ]]; then
    echo "ERROR: Target must be a directory or mount point." >&2
    exit 1
fi

MOUNT=$(findmnt -n -o TARGET -T "$TARGET") || exit 1
SOURCE=$(findmnt -n -o SOURCE -T "$TARGET")
FSTYPE=$(findmnt -n -o FSTYPE -T "$TARGET")

echo "========================================"
echo " FILESYSTEM INVENTORY"
echo "========================================"
printf "Target:     %s\n" "$TARGET"
printf "Mount:      %s\n" "$MOUNT"
printf "Source:     %s\n" "$SOURCE"
printf "Type:       %s\n" "$FSTYPE"
echo "----------------------------------------"
echo "Filesystem capacity:"
df -hT -- "$TARGET"
echo "----------------------------------------"
echo "Scanning files on the target filesystem..."
echo

# -xdev prevents crossing onto another filesystem.
# -print0 safely handles filenames containing spaces or newlines.
COUNT=0
TOTAL_BYTES=0

while IFS= read -r -d '' FILE; do
    ((COUNT += 1))
    SIZE=$(stat -c '%s' -- "$FILE" 2>/dev/null) || continue
    ((TOTAL_BYTES += SIZE))
done < <(find "$TARGET" -xdev -type f -print0 2>/dev/null)

printf "Regular files found: %s\n" "$COUNT"
printf "Sum of apparent file sizes: %s bytes\n" "$TOTAL_BYTES"
echo
echo "Largest 20 files:"
find "$TARGET" -xdev -type f \
    -printf '%s\t%p\n' 2>/dev/null |
    sort -nr |
    head -n 20 |
    numfmt --field=1 --to=iec --suffix=B

echo
echo "NOTE: Run as root to inspect files across protected directories."
echo "This is a read-only inventory; it does not delete or modify files."

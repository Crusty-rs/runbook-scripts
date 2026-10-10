#!/usr/bin/env bash
#
# nfs_client_setup.sh — interactively mount an NFS share on this machine.
#
# Asks a few questions (press Enter to accept the [default]), shows a summary,
# and only changes the system after you confirm. Works on RHEL/Rocky/Alma/
# Fedora (dnf/yum) and Debian/Ubuntu (apt).
#
# What it does:
#   1. Installs the NFS client package
#   2. Checks the server answers on the NFS port and lists its exports
#   3. Creates the mount point and test-mounts the share
#   4. Optionally makes the mount permanent in /etc/fstab (backed up first),
#      with _netdev,nofail so a missing server never blocks boot
#   5. Checks it can write to the share (rw mounts)
#
# Usage:  sudo ./nfs_client_setup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
info() { echo "${bold}==>${reset} $*"; }
warn() { echo "${bold}WARNING:${reset} $*" >&2; }
die()  { echo "${bold}ERROR:${reset} $*" >&2; exit 1; }

ask() {
    local __var=$1 __q=$2 __def=${3:-} __ans
    while :; do
        read -r -p "$__q${__def:+ [$__def]}: " __ans
        __ans=${__ans:-$__def}
        [[ -n $__ans ]] && break
        echo "  A value is required."
    done
    printf -v "$__var" '%s' "$__ans"
}

ask_yn() {
    local __ans __def=$2 __hint
    [[ $__def == y ]] && __hint="Y/n" || __hint="y/N"
    while :; do
        read -r -p "$1 [$__hint]: " __ans
        __ans=${__ans:-$__def}
        case ${__ans,,} in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

ask_choice() {
    local __var=$1 __q=$2 __def=$3; shift 3
    local __ans __o
    while :; do
        read -r -p "$__q ($(IFS=/; echo "$*")) [$__def]: " __ans
        __ans=${__ans:-$__def}
        for __o in "$@"; do
            [[ ${__ans,,} == "${__o,,}" ]] && { printf -v "$__var" '%s' "$__o"; return; }
        done
        echo "  Please choose one of: $*"
    done
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

if command -v dnf >/dev/null || command -v yum >/dev/null; then
    FAMILY=rhel; PKG=nfs-utils
    PM=$(command -v dnf >/dev/null && echo dnf || echo yum)
elif command -v apt-get >/dev/null; then
    FAMILY=debian; PKG=nfs-common; PM=apt-get
else
    die "Unsupported system: need dnf, yum or apt-get"
fi

cat <<EOF

${bold}NFS client setup${reset}  ($(hostname), $FAMILY)
Press Enter to accept the value in [brackets].

EOF

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
ask SERVER "NFS server (hostname or IP)"

# Reachability check on the NFS port (2049) before asking anything else
if timeout 5 bash -c "exec 3<>/dev/tcp/$SERVER/2049" 2>/dev/null; then
    echo "  OK: $SERVER answers on port 2049."
else
    warn "$SERVER does not answer on TCP 2049 (wrong name, server down, or firewall)."
    ask_yn "Continue anyway?" n || exit 1
fi

# List exports when the server allows it (NFSv3/mountd; NFSv4-only servers won't answer)
if command -v showmount >/dev/null; then
    exports=$(timeout 5 showmount -e --no-headers "$SERVER" 2>/dev/null | awk '{print $1}' || true)
    if [[ -n $exports ]]; then
        echo "  Exports offered by $SERVER:"
        while read -r e; do echo "    $e"; done <<< "$exports"
    fi
fi
default_export=$(head -1 <<< "${exports:-}")

while :; do
    ask EXPORT "Export path on the server" "${default_export:-/srv/nfs/share}"
    [[ $EXPORT == /* ]] && break
    echo "  Use the absolute path the server exports (starting with /)."
done

while :; do
    ask MOUNTPOINT "Local mount point" "/mnt/$(basename "$EXPORT")"
    [[ $MOUNTPOINT == /* && $MOUNTPOINT != / ]] || { echo "  Use an absolute path other than /."; continue; }
    MOUNTPOINT=${MOUNTPOINT%/}
    if mountpoint -q "$MOUNTPOINT"; then
        echo "  Something is already mounted on $MOUNTPOINT. Pick another path."; continue
    fi
    if [[ -d $MOUNTPOINT && -n $(ls -A "$MOUNTPOINT" 2>/dev/null) ]]; then
        echo "  $MOUNTPOINT is not empty; its files would be hidden while mounted."
        ask_yn "  Use it anyway?" n || continue
    fi
    break
done

echo
ask_choice VERS "NFS version" "4.2" 4.2 4.1 4 3

echo
ask_choice ACCESS "Mount read-write or read-only" "rw" rw ro

echo
echo "'hard' keeps retrying if the server goes away (safe for data, the"
echo "default). 'soft' gives up with an error (avoids hangs, may lose writes)."
ask_choice RECOVERY "Hard or soft mount" "hard" hard soft

echo
echo "Permanent: added to /etc/fstab so it mounts at every boot."
echo "On-demand: also in fstab, but mounted only when first accessed (automount)."
ask_choice PERSIST "Make it permanent" "permanent" permanent on-demand no

OPTS="$ACCESS,vers=$VERS,$RECOVERY"
FSTAB_OPTS="$OPTS,_netdev,nofail"
[[ $PERSIST == on-demand ]] && FSTAB_OPTS+=",noauto,x-systemd.automount,x-systemd.idle-timeout=600"
FSTAB_LINE="$SERVER:$EXPORT  $MOUNTPOINT  nfs  $FSTAB_OPTS  0 0"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

${bold}Summary${reset}
  Package      : $PKG
  Share        : $SERVER:$EXPORT
  Mount point  : $MOUNTPOINT
  Options      : $OPTS
  /etc/fstab   : $( [[ $PERSIST == no ]] && echo "not changed (mount lasts until reboot)" || echo "$PERSIST")
EOF
[[ $PERSIST != no ]] && echo "      $FSTAB_LINE"
echo
ask_yn "Apply these changes?" n || { echo "Nothing changed."; exit 0; }
echo

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
info "Installing $PKG"
if [[ $FAMILY == rhel ]]; then
    $PM install -y -q "$PKG"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG" >/dev/null
fi

info "Creating $MOUNTPOINT"
mkdir -p "$MOUNTPOINT"

info "Test-mounting $SERVER:$EXPORT"
if ! mount -t nfs -o "$OPTS" "$SERVER:$EXPORT" "$MOUNTPOINT"; then
    cat >&2 <<EOF

${bold}Mount failed.${reset} Common causes:
  - this client's IP isn't in the server's allowed clients (check exportfs -v there)
  - wrong export path (paths are case-sensitive)
  - NFS version $VERS not enabled on the server (try 4 or 3)
  - firewall on the server blocking port 2049
Nothing was added to /etc/fstab.
EOF
    exit 1
fi

if [[ $PERSIST != no ]]; then
    info "Adding to /etc/fstab"
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    if awk -v mp="$MOUNTPOINT" '$1 !~ /^#/ && $2 == mp {found=1} END {exit !found}' /etc/fstab; then
        warn "$MOUNTPOINT already in /etc/fstab — commenting out the old line"
        sed -i "\|^[^#].*[[:space:]]${MOUNTPOINT}[[:space:]]|s|^|# replaced by $(basename "$0"): |" /etc/fstab
    fi
    printf '# NFS share added by %s on %s\n%s\n' "$(basename "$0")" "$(date '+%F %T')" "$FSTAB_LINE" >> /etc/fstab
    systemctl daemon-reload 2>/dev/null || true

    # Prove the fstab entry itself works: remount from it
    umount "$MOUNTPOINT"
    if [[ $PERSIST == on-demand ]]; then
        systemctl restart "$(systemd-escape -p --suffix=automount "$MOUNTPOINT")"
        ls "$MOUNTPOINT" >/dev/null       # first access triggers the mount
    else
        mount "$MOUNTPOINT"
    fi
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo
info "Mounted:"
findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNTPOINT" | sed 's/^/    /'
df -h "$MOUNTPOINT" | sed 's/^/    /'

if [[ $ACCESS == rw ]]; then
    testfile="$MOUNTPOINT/.nfs_write_test_$(hostname -s)_$$"
    if touch "$testfile" 2>/dev/null; then
        rm -f "$testfile"
        echo "    Write test: OK"
    else
        warn "Mounted, but this user can't write. Check the directory owner/mode on"
        warn "the server, and root_squash if you are writing as root."
    fi
fi

echo
echo "${bold}Done.${reset} Unmount with: sudo umount $MOUNTPOINT"

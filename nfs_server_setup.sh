#!/usr/bin/env bash
#
# nfs_server_setup.sh — interactively create and export an NFS share.
#
# Asks a few questions (press Enter to accept the [default]), shows a summary,
# and only changes the system after you confirm. Works on RHEL/Rocky/Alma/
# Fedora (dnf/yum, firewalld, SELinux) and Debian/Ubuntu (apt, ufw).
#
# What it does:
#   1. Installs the NFS server package and enables the service
#   2. Creates the share directory with the owner/permissions you choose
#   3. Writes the export to /etc/exports.d/<name>.exports (your /etc/exports
#      is left untouched) and reloads exports
#   4. Optionally restricts the server to NFSv4 only
#   5. Opens the firewall and sets SELinux booleans when those are active
#
# Usage:  sudo ./nfs_server_setup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
info() { echo "${bold}==>${reset} $*"; }
warn() { echo "${bold}WARNING:${reset} $*" >&2; }
die()  { echo "${bold}ERROR:${reset} $*" >&2; exit 1; }

# ask VAR "Question" "default"
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

# ask_yn "Question" y|n  -> returns 0 for yes
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

# ask_choice VAR "Question" default option1 option2 ...
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
    FAMILY=rhel; PKG=nfs-utils; SERVICE=nfs-server
    PM=$(command -v dnf >/dev/null && echo dnf || echo yum)
elif command -v apt-get >/dev/null; then
    FAMILY=debian; PKG=nfs-kernel-server; SERVICE=nfs-server; PM=apt-get
else
    die "Unsupported system: need dnf, yum or apt-get"
fi

# Suggest the local subnet as the default client range
default_net=$(ip -o -4 route show scope link 2>/dev/null | awk '!/docker|virbr|podman|cni/ {print $1; exit}' || true)
default_net=${default_net:-192.168.1.0/24}

cat <<EOF

${bold}NFS server setup${reset}  ($(hostname), $FAMILY)
Press Enter to accept the value in [brackets].

EOF

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
while :; do
    ask SHARE_DIR "Directory to share" "/srv/nfs/share"
    [[ $SHARE_DIR == /* ]] || { echo "  Use an absolute path (starting with /)."; continue; }
    case $SHARE_DIR in
        /|/etc|/etc/*|/usr|/usr/*|/boot|/boot/*|/proc*|/sys*|/dev*|/bin*|/sbin*|/lib*)
            echo "  Refusing to export a system directory. Pick another path."; continue ;;
    esac
    SHARE_DIR=${SHARE_DIR%/}
    break
done

echo
echo "Which clients may mount it? Examples:"
echo "  192.168.10.0/24   a whole subnet"
echo "  10.0.0.5          one host"
echo "  *.lab.example.com hosts in a domain"
echo "  Separate several with spaces."
ask CLIENTS "Allowed clients" "$default_net"

echo
ask_choice ACCESS "Access for clients" "rw" rw ro

echo
echo "Root squash maps the client's root user to 'nobody' (recommended)."
echo "Turn it off only if clients must write as root (e.g. some installers)."
if ask_yn "Keep root squash on?" y; then SQUASH=root_squash; else SQUASH=no_root_squash; fi

echo
echo "Directory owner. Clients see files with the same numeric UID/GID, so"
echo "pick a user that exists with the same UID on the clients, or 'nobody'."
NOBODY=$(getent passwd nobody >/dev/null && echo nobody || echo nfsnobody)
NOGROUP=$(getent group nobody >/dev/null && echo nobody || echo nogroup)
while :; do
    ask OWNER "Owner (user:group)" "$NOBODY:$NOGROUP"
    u=${OWNER%%:*}; g=${OWNER#*:}; [[ $OWNER == *:* ]] || g=$u
    getent passwd "$u" >/dev/null || { echo "  User '$u' does not exist."; continue; }
    getent group  "$g" >/dev/null || { echo "  Group '$g' does not exist."; continue; }
    OWNER="$u:$g"; break
done
while :; do
    ask MODE "Permissions" "2775"
    [[ $MODE =~ ^[0-7]{3,4}$ ]] && break
    echo "  Use octal like 755, 775 or 2775 (2 = new files keep the group)."
done

echo
echo "NFSv4-only needs just TCP port 2049 and is the modern default."
echo "Say no if you have old clients that still mount with NFSv3."
if ask_yn "NFSv4 only?" y; then V4ONLY=yes; else V4ONLY=no; fi

FW=none
if systemctl is-active --quiet firewalld 2>/dev/null; then FW=firewalld
elif command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then FW=ufw
fi
OPEN_FW=no
if [[ $FW != none ]]; then
    echo
    if ask_yn "Open NFS in the firewall ($FW)?" y; then OPEN_FW=yes; fi
fi

# Export options and file name
OPTS="$ACCESS,sync,$SQUASH,no_subtree_check"
NAME=$(echo "${SHARE_DIR#/}" | tr '/' '_' | tr -cd '[:alnum:]_-')
EXPORT_FILE="/etc/exports.d/${NAME}.exports"
EXPORT_LINE="$SHARE_DIR"
for c in $CLIENTS; do EXPORT_LINE+=" $c($OPTS)"; done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

${bold}Summary${reset}
  Package       : $PKG (service: $SERVICE)
  Share         : $SHARE_DIR  (owner $OWNER, mode $MODE)
  Clients       : $CLIENTS
  Options       : $OPTS
  NFSv4 only    : $V4ONLY
  Firewall      : $( [[ $OPEN_FW == yes ]] && echo "open NFS in $FW" || echo "no change ($FW)")
  Export file   : $EXPORT_FILE
      $EXPORT_LINE

EOF
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

info "Creating $SHARE_DIR"
mkdir -p "$SHARE_DIR"
chown "$OWNER" "$SHARE_DIR"
chmod "$MODE" "$SHARE_DIR"

if [[ $V4ONLY == yes ]]; then
    info "Restricting to NFSv4"
    if command -v nfsconf >/dev/null; then
        nfsconf --set nfsd vers3 n
        nfsconf --set nfsd vers4 y
    else
        warn "nfsconf not found; edit /etc/nfs.conf [nfsd] vers3=n yourself"
    fi
fi

info "Writing $EXPORT_FILE"
mkdir -p /etc/exports.d
if [[ -f $EXPORT_FILE ]]; then
    cp -a "$EXPORT_FILE" "$EXPORT_FILE.bak.$(date +%Y%m%d%H%M%S)"
fi
if grep -qs "^${SHARE_DIR}[[:space:]]" /etc/exports; then
    warn "$SHARE_DIR is also listed in /etc/exports — remove one of the two entries"
fi
printf '# Created by %s on %s\n%s\n' "$(basename "$0")" "$(date '+%F %T')" "$EXPORT_LINE" > "$EXPORT_FILE"

info "Enabling and starting $SERVICE"
systemctl enable --now "$SERVICE" >/dev/null
systemctl restart "$SERVICE"
exportfs -ra

if [[ $OPEN_FW == yes ]]; then
    info "Opening firewall ($FW)"
    if [[ $FW == firewalld ]]; then
        firewall-cmd -q --permanent --add-service=nfs
        if [[ $V4ONLY == no ]]; then
            firewall-cmd -q --permanent --add-service={mountd,rpc-bind}
        fi
        firewall-cmd -q --reload
    else
        for c in $CLIENTS; do
            if [[ $c =~ ^[0-9./]+$ ]]; then
                ufw allow from "$c" to any port 2049 proto tcp >/dev/null
            else
                warn "ufw needs an IP/subnet; open port 2049 for '$c' yourself"
            fi
        done
        if [[ $V4ONLY == no ]]; then
            warn "NFSv3 on ufw also needs rpcbind (111) and mountd ports opened"
        fi
    fi
fi

if command -v getenforce >/dev/null && [[ $(getenforce) != Disabled ]]; then
    info "Setting SELinux boolean for $ACCESS exports"
    if [[ $ACCESS == rw ]]; then setsebool -P nfs_export_all_rw 1
    else setsebool -P nfs_export_all_ro 1; fi
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo
info "Active exports:"
exportfs -v | sed 's/^/    /'

server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

${bold}Done.${reset} On a client, mount it with:
    sudo mount -t nfs ${server_ip:-<server-ip>}:$SHARE_DIR /mnt/nfs
or run nfs_client_setup.sh there and use:
    server: ${server_ip:-<server-ip>}    export: $SHARE_DIR

EOF

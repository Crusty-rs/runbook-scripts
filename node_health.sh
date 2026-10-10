#!/usr/bin/env bash
#
# node_health.sh — SSH (key auth, no passwords) into a list of nodes, collect
# uptime and basic health, and write one CSV row per node.
#
# Usage:
#   ./node_health.sh [-f nodes.txt] [-o report.csv] [-u user] [-p parallel]
#
# nodes.txt: one host per line (name, IP or user@host); blank lines and
# lines starting with # are ignored.
#
# Needs: SSH key access already set up (ssh-copy-id user@node). The script
# uses BatchMode, so it never prompts for a password — a node that would ask
# for one is reported as UNREACHABLE instead of hanging the run.
#
# Status column:
#   OK          everything under the thresholds below
#   WARN / CRIT a threshold crossed (reason in the "issues" column)
#   UNREACHABLE ssh failed (reason in the "issues" column)

set -uo pipefail

NODES_FILE="nodes.txt"
OUT="node_health_$(date +%Y%m%d_%H%M).csv"
SSH_USER=""
PARALLEL=10

# Thresholds (percent / load-per-CPU)
WARN_DISK=80;  CRIT_DISK=90
WARN_MEM=85;   CRIT_MEM=95
WARN_LOAD=1.0; CRIT_LOAD=2.0          # load1 divided by CPU count

while getopts ":f:o:u:p:h" opt; do
    case $opt in
        f) NODES_FILE=$OPTARG ;;
        o) OUT=$OPTARG ;;
        u) SSH_USER=$OPTARG ;;
        p) PARALLEL=$OPTARG ;;
        h) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Usage: $0 [-f nodes.txt] [-o report.csv] [-u user] [-p parallel]" >&2; exit 1 ;;
    esac
done

[[ -r $NODES_FILE ]] || { echo "Error: cannot read $NODES_FILE" >&2; exit 1; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR)

HEADER="node,hostname,os,kernel,uptime_days,last_boot,cpus,load1,load5,load15,mem_used_pct,swap_used_pct,root_disk_pct,max_disk_pct,max_disk_mount,failed_units,zombies,status,issues,checked_at"

# ---------------------------------------------------------------------------
# Runs ON THE NODE. Uses only /proc, df and standard tools, so it works on
# minimal installs. Prints one CSV line (without the leading node column).
# ---------------------------------------------------------------------------
read -r -d '' REMOTE <<'REMOTE_EOF'
export LC_ALL=C
q() { printf '"%s"' "$(printf '%s' "$1" | tr -d '"\n')"; }

host=$(hostname -f 2>/dev/null || hostname)
os=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
kernel=$(uname -r)

read -r up _ < /proc/uptime
uptime_days=$(awk -v s="$up" 'BEGIN{printf "%.1f", s/86400}')
last_boot=$(date -d "@$(( $(date +%s) - ${up%.*} ))" '+%Y-%m-%d %H:%M')

cpus=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
read -r l1 l5 l15 _ < /proc/loadavg

read -r mem swap < <(awk '
    /^MemTotal:/ {mt=$2} /^MemAvailable:/ {ma=$2}
    /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2}
    END {printf "%.1f %.1f\n", mt ? (mt-ma)*100/mt : 0, st ? (st-sf)*100/st : 0}' /proc/meminfo)

root_disk=$(df -P / | awk 'NR==2 {sub("%","",$5); print $5}')
read -r max_disk max_mount < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null |
    awk 'NR>1 {sub("%","",$5); if ($5+0 >= m) {m=$5+0; mp=$6}} END {print m+0, mp}')

if command -v systemctl >/dev/null; then
    failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | wc -l)
else
    failed=0
fi
zombies=$(ps -eo stat= 2>/dev/null | grep -c '^Z')

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(q "$host")" "$(q "$os")" "$(q "$kernel")" "$uptime_days" "$(q "$last_boot")" \
    "$cpus" "$l1" "$l5" "$l15" "$mem" "$swap" "$root_disk" "$max_disk" "$(q "$max_mount")" \
    "$failed" "$zombies"
REMOTE_EOF

# ---------------------------------------------------------------------------
# Decide OK / WARN / CRIT from the collected numbers
# ---------------------------------------------------------------------------
grade() {   # args: cpus load1 mem disk failed zombies
    awk -v cpus="$1" -v l1="$2" -v mem="$3" -v disk="$4" -v failed="$5" -v zomb="$6" \
        -v wd="$WARN_DISK" -v cd="$CRIT_DISK" -v wm="$WARN_MEM" -v cm="$CRIT_MEM" \
        -v wl="$WARN_LOAD" -v cl="$CRIT_LOAD" '
    function flag(level, msg) { issues = issues (issues ? "; " : "") msg
                                if (level == "CRIT" || status != "CRIT") status = level }
    BEGIN {
        status = "OK"; issues = ""
        load = cpus > 0 ? l1 / cpus : l1
        if      (disk >= cd) flag("CRIT", "disk " disk "%")
        else if (disk >= wd) flag("WARN", "disk " disk "%")
        if      (mem  >= cm) flag("CRIT", "mem " mem "%")
        else if (mem  >= wm) flag("WARN", "mem " mem "%")
        if      (load >= cl) flag("CRIT", sprintf("load %.2f/cpu", load))
        else if (load >= wl) flag("WARN", sprintf("load %.2f/cpu", load))
        if (failed > 0) flag("WARN", failed " failed unit(s)")
        if (zomb   > 0) flag("WARN", zomb " zombie(s)")
        printf "%s,\"%s\"", status, issues
    }'
}

# ---------------------------------------------------------------------------
# Check one node -> prints one complete CSV row
# ---------------------------------------------------------------------------
check_node() {
    local node=$1 target=$1 now line err
    [[ -n $SSH_USER && $node != *@* ]] && target="$SSH_USER@$node"
    now=$(date '+%Y-%m-%d %H:%M:%S')
    err=$(mktemp)

    if line=$(ssh "${SSH_OPTS[@]}" "$target" 'bash -s' <<< "$REMOTE" 2>"$err") && [[ -n $line ]]; then
        # fields: 1 host .. 6 cpus 7 load1 .. 10 mem .. 12 root_disk 13 max_disk .. 15 failed 16 zombies
        local cpus l1 mem disk failed zomb
        IFS=, read -r _ _ _ _ _ cpus l1 _ _ mem _ _ disk _ failed zomb <<< "$line"
        printf '"%s",%s,%s,"%s"\n' "$node" "$line" "$(grade "$cpus" "$l1" "$mem" "$disk" "$failed" "$zomb")" "$now"
    else
        local reason
        reason=$(tr '\n"' ' ' < "$err" | sed 's/ *$//')
        printf '"%s",,,,,,,,,,,,,,,,,UNREACHABLE,"%s","%s"\n' "$node" "${reason:-no output}" "$now"
    fi
    rm -f "$err"
}

# ---------------------------------------------------------------------------
# Main: read nodes, run checks in parallel, write CSV in nodes.txt order
# ---------------------------------------------------------------------------
mapfile -t NODES < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$NODES_FILE" | grep -v '^$')
[[ ${#NODES[@]} -gt 0 ]] || { echo "Error: no nodes in $NODES_FILE" >&2; exit 1; }

echo "Checking ${#NODES[@]} node(s), $PARALLEL at a time..."
TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

i=0
for node in "${NODES[@]}"; do
    printf -v slot '%05d' "$i"; (( i++ ))
    check_node "$node" > "$TMPDIR_RUN/$slot" &
    while (( $(jobs -rp | wc -l) >= PARALLEL )); do wait -n; done
done
wait

{ echo "$HEADER"; cat "$TMPDIR_RUN"/*; } > "$OUT"

# Summary
awk -F, 'NR>1 {
    for (i = 1; i <= NF; i++) if ($i ~ /^(OK|WARN|CRIT|UNREACHABLE)$/) { n[$i]++; break }
} END {
    printf "OK: %d  WARN: %d  CRIT: %d  UNREACHABLE: %d\n", n["OK"], n["WARN"], n["CRIT"], n["UNREACHABLE"]
}' "$OUT"
echo "Report: $OUT"

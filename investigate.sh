#!/usr/bin/env bash
# investigate.sh - read-only Linux incident investigator
#
# Usage:
#   investigate.sh disk    [path]            # default: fullest local filesystem
#   investigate.sh service <unit-name>       # e.g. nginx, sshd, postgresql
#   investigate.sh network [host]            # default: default gateway
#   investigate.sh load                      # slow / high load / high memory
#
# Options (put before the symptom):
#   -t N    disk usage threshold percent (default 85)
#
# Runs only read-only commands. Works on most Linux boxes; missing tools are
# skipped and reported. Run as root for full results (lsof, journal, ss -p).

set -u
THRESH=85
CUR=-1

# ------------------------------------------------------------------ helpers
have() { command -v "$1" >/dev/null 2>&1; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

FACTS=()           # observed facts
MISSING=()         # tools not found
H_NAME=(); H_EVID=(); H_CONF=(); H_SCORE=()   # hypotheses

fact()   { FACTS+=("$1"); }
missing(){ MISSING+=("$1"); }

# new hypothesis: hyp "name" -> sets CUR index
hyp() {
    H_NAME+=("$1"); H_EVID+=(""); H_CONF+=(""); H_SCORE+=(0)
    CUR=$(( ${#H_NAME[@]} - 1 ))
}
# evidence "text" [weight]  (weight default 1)
ev() {
    local w=${2:-1}
    H_EVID[$CUR]+="    + $1"$'\n'
    H_SCORE[$CUR]=$(( H_SCORE[$CUR] + w ))
}
# against "text"  (evidence that weakens the hypothesis)
against() {
    H_EVID[$CUR]+="    - $1"$'\n'
    H_SCORE[$CUR]=$(( H_SCORE[$CUR] - 1 ))
}
confirm() { H_CONF[$CUR]+="    \$ $1"$'\n'; }

report() {
    echo; hr; echo "OBSERVED FACTS"; hr
    if [ ${#FACTS[@]} -eq 0 ]; then echo "  (none)"; fi
    for f in "${FACTS[@]}"; do echo "  * $f"; done

    echo; hr; echo "POSSIBLE EXPLANATIONS (most likely first)"; hr
    if [ ${#H_NAME[@]} -eq 0 ]; then
        echo "  No hypothesis has supporting evidence. Facts above may still help."
    else
        # sort indexes by score desc
        local order
        order=$(for i in "${!H_NAME[@]}"; do echo "${H_SCORE[$i]} $i"; done | sort -rn | awk '{print $2}')
        local n=1
        for i in $order; do
            [ "${H_SCORE[$i]}" -le 0 ] && continue
            echo
            echo "$n) ${H_NAME[$i]}   [evidence score: ${H_SCORE[$i]}]"
            echo "   Evidence:"
            printf '%s' "${H_EVID[$i]}"
            if [ -n "${H_CONF[$i]}" ]; then
                echo "   To confirm:"
                printf '%s' "${H_CONF[$i]}"
            fi
            n=$((n+1))
        done
        [ "$n" -eq 1 ] && echo "  No hypothesis has supporting evidence. Facts above may still help."
    fi

    if [ ${#MISSING[@]} -gt 0 ]; then
        echo; hr; echo "TOOLS NOT FOUND (some checks skipped)"; hr
        printf '  %s\n' "${MISSING[@]}" | sort -u
    fi
    echo
}

[ "$(id -u)" -ne 0 ] && echo "NOTE: not running as root. Some checks will be partial." >&2

# ================================================================== DISK
investigate_disk() {
    local target=${1:-}
    local line fs size used avail pct mnt

    # pick the filesystem
    if [ -n "$target" ]; then
        line=$(df -P "$target" 2>/dev/null | tail -n 1)
    else
        line=$(df -Pl 2>/dev/null | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs|overlay|squashfs|udev)$/' \
               | sort -k5 -rn | head -n 1)
    fi
    if [ -z "$line" ]; then echo "Could not read df output."; return; fi
    read -r fs size used avail pct mnt <<<"$line"
    pct=${pct%\%}
    local base=$mnt; [ "$base" = "/" ] && base=""
    fact "Filesystem $fs on $mnt: ${pct}% used (used $((used/1024)) MB, free $((avail/1024)) MB)"

    # other full filesystems
    df -Pl 2>/dev/null | awk -v t="$THRESH" 'NR>1 {gsub("%","",$5); if ($5+0>=t) print $6" "$5"%"}' \
        | while read -r m p; do [ "$m" != "$mnt" ] && fact "Also high: $m at $p"; done

    if [ "$pct" -lt "$THRESH" ]; then
        fact "Usage is below threshold ${THRESH}%. Checking inodes and deleted files anyway."
    fi

    # inodes
    local ipct
    ipct=$(df -Pi "$mnt" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
    if [ -n "$ipct" ]; then
        fact "Inode usage on $mnt: ${ipct}%"
        if [ "${ipct:-0}" -ge 90 ]; then
            hyp "Inodes exhausted (too many small files), not bytes"
            ev "Inode usage is ${ipct}%" 3
            [ "$pct" -lt 90 ] && ev "Byte usage only ${pct}%, so the 'no space' error is about inodes" 2
            confirm "df -i $mnt"
            confirm "find $mnt -xdev -type d -print0 | xargs -0 -I{} sh -c 'echo \$(ls -1A \"{}\" | wc -l) {}' | sort -rn | head"
            confirm "# usual suspects: /var/spool, /var/lib/php/sessions, /tmp, mail queues, cache dirs"
        fi
    fi

    # du vs df
    local du_kb gap_kb gap_pct
    du_kb=$(du -xsk "$mnt" 2>/dev/null | awk '{print $1}')
    if [ -n "$du_kb" ]; then
        gap_kb=$(( used - du_kb ))
        gap_pct=$(( size > 0 ? gap_kb * 100 / size : 0 ))
        fact "du -x of $mnt sees $((du_kb/1024)) MB; df says $((used/1024)) MB used -> gap $((gap_kb/1024)) MB (${gap_pct}% of fs)"
    else
        fact "du on $mnt failed (permissions?)"
        gap_kb=0; gap_pct=0
    fi

    # deleted but open files
    local del_list del_total
    if have lsof; then
        del_list=$(lsof +L1 -nP 2>/dev/null | awk 'NR>1 && $NF ~ /deleted|^\//' )
        del_total=$(lsof +L1 -nP 2>/dev/null | awk 'NR>1 {s+=$7} END {printf "%d", s/1024/1024}')
    else
        missing "lsof (fallback: scanning /proc/*/fd)"
        del_list=$(find /proc/[0-9]*/fd -lname '*(deleted)' -printf '%p -> %l\n' 2>/dev/null | head -n 40)
        del_total=$(find /proc/[0-9]*/fd -lname '*(deleted)' 2>/dev/null \
            | while read -r fd; do stat -L -c %s "$fd" 2>/dev/null; done | awk '{s+=$1} END {printf "%d", s/1024/1024}')
    fi
    if [ -n "$del_list" ]; then
        local cnt; cnt=$(printf '%s\n' "$del_list" | wc -l)
        fact "$cnt deleted-but-still-open files found, about ${del_total:-?} MB held"
        if [ "${del_total:-0}" -ge 100 ] || [ "$gap_pct" -ge 5 ]; then
            hyp "Deleted files still held open by a process (space not freed until process restarts)"
            ev "$cnt deleted-but-open files, ~${del_total:-?} MB" 3
            [ "$gap_pct" -ge 5 ] && ev "df/du gap of $((gap_kb/1024)) MB matches this pattern" 2
            H_EVID[$CUR]+="$(printf '%s\n' "$del_list" | head -n 8 | cut -c1-150 | sed 's/^/        /')"$'\n'
            confirm "lsof +L1 -nP | sort -k7 -rn | head     # size in column 7, PID in column 2"
            confirm "# fix is usually: restart that service, or truncate via /proc/<PID>/fd/<N> (: > /proc/PID/fd/N)"
        fi
    fi

    if [ "$gap_pct" -ge 5 ] && [ -z "$del_list" ]; then
        hyp "Files hidden under a mount point (written before something was mounted over the dir)"
        ev "df/du gap of $((gap_kb/1024)) MB but no deleted-open files found" 2
        confirm "mkdir /mnt/rootview && mount --bind / /mnt/rootview && du -xsh /mnt/rootview/* | sort -rh | head   # bind mount shows hidden data"
        confirm "# also check: du run as root? (non-root du misses files)"
        hyp "Reserved blocks (ext2/3/4 keeps 5% for root by default)"
        if have tune2fs && [[ $fs == /dev/* ]]; then
            local rsv; rsv=$(tune2fs -l "$fs" 2>/dev/null | awk -F: '/Reserved block count/ {gsub(/ /,"",$2); print $2}')
            [ -n "$rsv" ] && ev "Reserved block count on $fs: $rsv blocks (x4K ~ $((rsv*4/1024)) MB)" 1
        fi
        confirm "tune2fs -l $fs | grep -i reserved"
    fi

    # top dirs and big files
    echo "Scanning for top directories and large files on $mnt (may take a moment)..." >&2
    local topdirs; topdirs=$(du -xsk "$base"/* "$base"/.[!.]* 2>/dev/null | sort -rn | head -n 8 \
                    | awk '{printf "%d MB  %s\n", $1/1024, $2}')
    [ -n "$topdirs" ] && fact "Top dirs on $mnt:"$'\n'"$(printf '%s\n' "$topdirs" | sed 's/^/      /')"

    local bigfiles; bigfiles=$(find "$mnt" -xdev -type f -size +500M -printf '%s %p\n' 2>/dev/null \
                    | sort -rn | head -n 8 | awk '{printf "%d MB  %s\n", $1/1024/1024, $2}')
    if [ -n "$bigfiles" ]; then
        fact "Files over 500 MB:"$'\n'"$(printf '%s\n' "$bigfiles" | sed 's/^/      /')"
        hyp "A few very large files (logs, dumps, backups, core files) are eating the space"
        ev "Files over 500 MB exist: see list in facts" 2
        if printf '%s' "$bigfiles" | grep -qiE '\.log|/var/log|journal'; then
            ev "At least one big file looks like a log" 2
            confirm "ls -lhS /var/log | head; journalctl --disk-usage; tail -n 50 <that log>   # is it still growing?"
            confirm "# check logrotate: cat /etc/logrotate.conf; ls /etc/logrotate.d; grep -l <logname> /etc/logrotate.d/*"
        fi
        if printf '%s' "$bigfiles" | grep -qiE 'core|\.dump|\.sql|\.tar|\.gz|\.bak'; then
            ev "At least one big file looks like a dump/backup/core" 1
            confirm "ls -lh --time-style=long-iso <file>   # is it old? safe to move/delete?"
        fi
        confirm "find $mnt -xdev -type f -size +500M -exec ls -lh {} \\;"
    fi

    # journal
    if have journalctl; then
        local jsz; jsz=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[GM]')
        [ -n "$jsz" ] && fact "systemd journal uses $jsz"
        if [[ $jsz == *G ]]; then
            hyp "systemd journal grew large (no SystemMaxUse set)"
            ev "Journal size is $jsz" 2
            confirm "grep -E '^(SystemMaxUse|MaxRetentionSec)' /etc/systemd/journald.conf"
            confirm "journalctl --vacuum-size=500M   # (write action, only if you decide to)"
        fi
    fi

    # docker
    if have docker && docker info >/dev/null 2>&1; then
        local dsz; dsz=$(docker system df 2>/dev/null | awk 'NR>1 {print $1": "$4" (reclaimable "$5")"}' | tr '\n' ';')
        [ -n "$dsz" ] && fact "Docker usage: $dsz"
        if docker system df 2>/dev/null | awk 'NR>1 && $4 ~ /GB/ {f=1} END {exit !f}'; then
            hyp "Docker images/containers/volumes/build cache using the space"
            ev "docker system df shows GB-scale usage" 2
            confirm "docker system df -v | head -40"
            confirm "du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -rh | head   # container stdout logs"
        fi
    fi

    # tmp / crash dirs
    for d in /tmp /var/tmp /var/crash /var/lib/systemd/coredump /var/cache/apt /var/cache/dnf /var/cache/yum; do
        [ -d "$d" ] || continue
        local dsz; dsz=$(du -xsk "$d" 2>/dev/null | awk '{print $1}')
        [ "${dsz:-0}" -ge 1048576 ] && fact "$d uses $((dsz/1024)) MB"
    done

    # recently grown files (last 24h, > 50MB)
    local recent; recent=$(find "$mnt" -xdev -type f -size +50M -mmin -1440 -printf '%s %p\n' 2>/dev/null \
                   | sort -rn | head -n 5 | awk '{printf "%d MB  %s\n", $1/1024/1024, $2}')
    if [ -n "$recent" ]; then
        fact "Files >50 MB changed in last 24h:"$'\n'"$(printf '%s\n' "$recent" | sed 's/^/      /')"
        hyp "Something is actively writing right now (runaway log, loop, stuck job)"
        ev "Large files modified in the last 24h" 2
        confirm "watch -n5 'df -h $mnt'   # still growing?"
        confirm "lsof -nP +D <dir-of-growing-file> 2>/dev/null | head   # who writes it"
    fi
}

# ================================================================== SERVICE
investigate_service() {
    local svc=${1:?service name required}
    local unit=$svc
    [[ $unit != *.service && $unit != *.* ]] && unit="$svc.service"

    if ! have systemctl; then
        missing "systemctl (non-systemd host)"
        fact "pgrep -f $svc: $(pgrep -f "$svc" | tr '\n' ' ' || echo none)"
        have service && fact "service $svc status: $(service "$svc" status 2>&1 | head -n 3 | tr '\n' ' ')"
        hyp "Service not running (init.d system, limited checks)"
        confirm "service $svc status; tail -n 50 /var/log/$svc*; tail -n 50 /var/log/syslog /var/log/messages"
        return
    fi

    if ! systemctl cat "$unit" >/dev/null 2>&1; then
        fact "Unit '$unit' is not known to systemd"
        hyp "Package not installed or unit name is wrong"
        ev "systemctl cannot find $unit" 3
        confirm "systemctl list-units --all --type=service | grep -i ${svc%.service}"
        confirm "ls /etc/systemd/system /lib/systemd/system | grep -i ${svc%.service}"
        return
    fi

    local active sub enabled result mainstatus nrestarts execstart user cond
    active=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null)
    sub=$(systemctl show -p SubState --value "$unit" 2>/dev/null)
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null)
    result=$(systemctl show -p Result --value "$unit" 2>/dev/null)
    mainstatus=$(systemctl show -p ExecMainStatus --value "$unit" 2>/dev/null)
    nrestarts=$(systemctl show -p NRestarts --value "$unit" 2>/dev/null)
    execstart=$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n1)
    user=$(systemctl show -p User --value "$unit" 2>/dev/null)
    cond=$(systemctl show -p ConditionResult --value "$unit" 2>/dev/null)

    fact "$unit: state=$active/$sub enabled=$enabled result=$result exit-status=$mainstatus restarts=${nrestarts:-?}"
    [ -n "$execstart" ] && fact "ExecStart binary: $execstart"
    [ -n "$user" ] && fact "Runs as user: $user"

    if [ "$active" = "active" ]; then
        fact "Service is active now. Checking for restart loops / recent failures."
        [ "${nrestarts:-0}" -gt 0 ] && { hyp "Service crashes and gets restarted (restart loop)"; ev "NRestarts=$nrestarts" 3; confirm "journalctl -u $unit -n 200 --no-pager | grep -iE 'fail|error|exit|signal'"; }
    fi

    local log; log=$(journalctl -u "$unit" -n 80 --no-pager 2>/dev/null)
    [ -z "$log" ] && log=$(journalctl -u "$unit" -n 80 --no-pager -b 2>/dev/null)

    local lastlines; lastlines=$(printf '%s\n' "$log" | tail -n 12)
    [ -n "$lastlines" ] && fact "Last journal lines:"$'\n'"$(printf '%s\n' "$lastlines" | cut -c1-160 | sed 's/^/      /')"

    # ---- pattern matching on journal
    if printf '%s' "$log" | grep -qiE 'address already in use|bind.*failed|could not bind|port.*in use'; then
        hyp "Port already taken by another process"
        ev "Journal mentions 'address already in use' / bind failure" 3
        confirm "ss -lntp | grep -E ':<port>'   # who owns it"
        confirm "journalctl -u $unit -n 50 --no-pager | grep -i bind"
    fi
    if printf '%s' "$log" | grep -qiE 'permission denied|operation not permitted|EACCES'; then
        hyp "Permission problem (file, dir, socket, or capability)"
        ev "Journal mentions 'permission denied'" 3
        confirm "journalctl -u $unit -n 50 --no-pager | grep -i denied"
        confirm "ls -la <path from log>; id $user"
        confirm "systemctl show $unit -p ProtectSystem -p ProtectHome -p ReadOnlyPaths -p NoNewPrivileges"
    fi
    if printf '%s' "$log" | grep -qiE 'no such file|not found|cannot open|does not exist'; then
        hyp "Missing file, directory, config, or binary"
        ev "Journal mentions 'no such file' / 'not found'" 3
        confirm "journalctl -u $unit -n 50 --no-pager | grep -iE 'no such|not found'"
    fi
    if printf '%s' "$log" | grep -qiE 'syntax error|config.*(error|invalid)|unknown directive|parse error|unexpected'; then
        hyp "Config file has a syntax error"
        ev "Journal mentions a config/syntax error" 3
        case $svc in
            nginx*)   confirm "nginx -t" ;;
            apache2*|httpd*) confirm "apachectl configtest" ;;
            sshd*|ssh)  confirm "sshd -t" ;;
            haproxy*) confirm "haproxy -c -f /etc/haproxy/haproxy.cfg" ;;
            postgres*) confirm "sudo -u postgres postgres -C config_file   # then check that file" ;;
            *) confirm "journalctl -u $unit -n 50 --no-pager | grep -iE 'syntax|config|line'" ;;
        esac
    fi
    if printf '%s' "$log" | grep -qiE 'out of memory|oom|cannot allocate memory'; then
        hyp "Killed or failing because of memory (OOM)"
        ev "Journal mentions OOM / memory allocation" 3
        confirm "dmesg -T | grep -iE 'killed process|out of memory' | tail"
        confirm "systemctl show $unit -p MemoryMax -p MemoryCurrent"
    fi
    if printf '%s' "$log" | grep -qiE 'no space left|disk full|ENOSPC'; then
        hyp "Disk is full where the service writes"
        ev "Journal mentions 'no space left'" 3
        confirm "$0 disk"
    fi
    if printf '%s' "$log" | grep -qiE 'start request repeated too quickly|start-limit-hit'; then
        hyp "Start rate limit hit (it failed several times in a row, systemd gave up)"
        ev "Journal mentions 'start request repeated too quickly'" 3
        confirm "journalctl -u $unit -n 200 --no-pager   # look at the FIRST failure, not the last"
        confirm "systemctl reset-failed $unit   # (write action) then try again"
    fi
    if printf '%s' "$log" | grep -qiE 'dependency|failed to start.*required|job.*canceled'; then
        hyp "A required dependency (another unit, mount, network) failed"
        ev "Journal mentions a dependency failure" 2
        confirm "systemctl list-dependencies $unit --failed"
    fi
    if printf '%s' "$log" | grep -qiE 'timeout|timed out'; then
        hyp "Startup timed out (slow start, or Type=notify/forking never signalled ready)"
        ev "Journal mentions a timeout" 2
        confirm "systemctl show $unit -p Type -p TimeoutStartUSec"
    fi
    if printf '%s' "$log" | grep -qiE 'connection refused|could not connect|unreachable'; then
        hyp "Service depends on another host/port it cannot reach (DB, broker, API)"
        ev "Journal mentions connection refused / unreachable" 2
        confirm "journalctl -u $unit -n 50 --no-pager | grep -iE 'refused|connect'"
        confirm "$0 network <that host>"
    fi

    # ---- structural checks
    if [ "$result" = "exit-code" ] && [ "${mainstatus:-0}" -ne 0 ]; then
        hyp "Program itself exits with error code $mainstatus (not a systemd problem)"
        ev "Result=exit-code, ExecMainStatus=$mainstatus" 2
        [ -n "$execstart" ] && confirm "sudo -u ${user:-root} $execstart   # run by hand with same args from: systemctl cat $unit"
    fi
    if [ "$result" = "signal" ]; then
        hyp "Process was killed by a signal (crash, OOM killer, or manual kill)"
        ev "Result=signal" 2
        confirm "systemctl show $unit -p ExecMainCode -p ExecMainStatus; dmesg -T | tail -n 30"
    fi
    if [ "$cond" = "no" ]; then
        hyp "A Condition* line in the unit is false, so systemd skipped it silently"
        ev "ConditionResult=no" 3
        confirm "systemctl cat $unit | grep -i condition"
    fi
    if [ -n "$execstart" ] && [ ! -x "$execstart" ]; then
        hyp "ExecStart binary missing or not executable"
        ev "$execstart is not an executable file" 3
        confirm "ls -l $execstart; which ${execstart##*/}"
    fi
    if [ -n "$user" ] && ! getent passwd "$user" >/dev/null 2>&1; then
        hyp "Unit runs as user '$user' which does not exist"
        ev "getent passwd $user finds nothing" 3
        confirm "getent passwd $user"
    fi
    if [ "$enabled" = "disabled" ] && [ "$active" != "active" ]; then
        hyp "Service simply not enabled, so it does not start on boot"
        ev "is-enabled=disabled" 1
        confirm "systemctl enable --now $unit   # (write action)"
    fi
    if [ "$enabled" = "masked" ]; then
        hyp "Unit is masked (someone disabled it on purpose)"
        ev "is-enabled=masked" 3
        confirm "ls -l /etc/systemd/system/$unit   # points to /dev/null"
    fi
    if have systemd-analyze; then
        local verify; verify=$(systemd-analyze verify "$unit" 2>&1 | grep -v '^$' | head -n 5)
        if [ -n "$verify" ]; then
            fact "systemd-analyze verify says:"$'\n'"$(printf '%s\n' "$verify" | sed 's/^/      /')"
            hyp "Unit file has a problem"
            ev "systemd-analyze verify printed warnings" 2
            confirm "systemd-analyze verify $unit"
        fi
    fi
    # drop-ins / recent changes
    local changed; changed=$(find /etc/systemd/system /etc/"${svc%.service}" /etc/"${svc%.service}".conf /etc/"${svc%.service}".d \
                    -mtime -2 -type f 2>/dev/null | head -n 5)
    if [ -n "$changed" ]; then
        fact "Files changed in last 48h:"$'\n'"$(printf '%s\n' "$changed" | sed 's/^/      /')"
        hyp "A recent config or unit change broke it"
        ev "Config/unit files modified in the last 48h" 2
        confirm "ls -l --time-style=long-iso $(printf '%s ' $changed)"
        confirm "systemctl daemon-reload   # (write action) needed after unit edits"
    fi
    # SELinux
    if have getenforce && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        fact "SELinux is Enforcing"
        local avc=""
        have ausearch && avc=$(ausearch -m avc -ts recent 2>/dev/null | grep -c 'denied')
        [ -z "$avc" ] && [ -r /var/log/audit/audit.log ] && avc=$(tail -n 2000 /var/log/audit/audit.log | grep -c 'avc:.*denied')
        if [ "${avc:-0}" -gt 0 ]; then
            hyp "SELinux is blocking the service"
            ev "$avc recent AVC denials" 3
            confirm "ausearch -m avc -ts recent | audit2why"
        fi
    fi
    # disk full on / or /var
    df -Pl / /var 2>/dev/null | awk 'NR>1 {gsub("%","",$5); if ($5+0>=98) print $6}' | while read -r m; do
        fact "$m is at 98%+ usage"
    done
    # listening ports
    if have ss; then
        local ports; ports=$(ss -lntpH 2>/dev/null | grep -i "${svc%.service}" | awk '{print $4}' | tr '\n' ' ')
        [ -n "$ports" ] && fact "Listening sockets owned by $svc: $ports"
    else missing "ss"; fi

    if [ ${#H_NAME[@]} -eq 0 ] && [ "$active" != "active" ]; then
        hyp "No clear pattern in journal; read the full log around the failure"
        ev "Service is $active but no known error text matched" 1
        confirm "journalctl -u $unit -b --no-pager | tail -n 100"
        confirm "systemctl status $unit -l --no-pager"
    fi
}

# ================================================================== NETWORK
investigate_network() {
    if ! have ip; then
        missing "ip (iproute2) - only basic checks possible"
        local gwhex; gwhex=$(awk '$2=="00000000" {print $3; exit}' /proc/net/route 2>/dev/null)
        if [ -n "$gwhex" ]; then
            local gwip; gwip=$(printf '%d.%d.%d.%d' 0x${gwhex:6:2} 0x${gwhex:4:2} 0x${gwhex:2:2} 0x${gwhex:0:2})
            fact "Default gateway (from /proc/net/route): $gwip"
            have ping && { ping -c 2 -W 2 "${1:-$gwip}" >/dev/null 2>&1 && fact "ping ${1:-$gwip}: OK" || fact "ping ${1:-$gwip}: FAILED"; }
            fact "Install iproute2 (ip) and rerun for full checks; meanwhile: cat /proc/net/arp; ifconfig -a"
        else
            fact "No default route in /proc/net/route"
            hyp "No default gateway configured"; ev "no default route" 3; confirm "cat /proc/net/route"
        fi
        return
    fi
    local gw dev target
    gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    target=${1:-$gw}

    if [ -z "$gw" ]; then
        fact "No default route"
        hyp "No default gateway configured (DHCP failed, or static config missing)"
        ev "ip route shows no default" 3
        confirm "ip route; cat /etc/netplan/*.yaml /etc/network/interfaces /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null"
        confirm "journalctl -u NetworkManager -u systemd-networkd -u dhclient -n 50 --no-pager"
    else
        fact "Default gateway $gw via $dev"
    fi
    [ -z "$target" ] && { echo "No target and no gateway."; report; exit 1; }

    # interfaces
    local ifsum; ifsum=$(ip -br -4 addr 2>/dev/null)
    [ -n "$ifsum" ] && fact "Interfaces:"$'\n'"$(printf '%s\n' "$ifsum" | sed 's/^/      /')"

    if [ -n "$dev" ]; then
        local oper carrier
        oper=$(cat /sys/class/net/"$dev"/operstate 2>/dev/null)
        carrier=$(cat /sys/class/net/"$dev"/carrier 2>/dev/null)
        fact "$dev operstate=$oper carrier=${carrier:-?}"
        if [ "$oper" = "down" ] || [ "$carrier" = "0" ]; then
            hyp "Link is down (cable, switch port, VM NIC, or interface admin-down)"
            ev "$dev operstate=$oper carrier=${carrier:-?}" 4
            confirm "ip link show $dev; ethtool $dev | grep -iE 'link|speed'"
            confirm "dmesg -T | grep -i $dev | tail"
        fi
        if ! ip -4 addr show "$dev" 2>/dev/null | grep -q 'inet '; then
            hyp "Interface $dev has no IPv4 address"
            ev "no 'inet' on $dev" 4
            confirm "journalctl -u NetworkManager -u systemd-networkd -n 50 --no-pager; dhclient -v $dev   # (write action)"
        fi
        local err drop
        err=$(cat /sys/class/net/"$dev"/statistics/rx_errors 2>/dev/null)
        drop=$(cat /sys/class/net/"$dev"/statistics/rx_dropped 2>/dev/null)
        [ "${err:-0}" -gt 0 ] || [ "${drop:-0}" -gt 0 ] && fact "$dev rx_errors=$err rx_dropped=$drop"
    fi

    # ARP / neighbour
    local neigh; neigh=$(ip neigh show "$target" 2>/dev/null)
    [ -n "$neigh" ] && fact "Neighbour entry: $neigh"

    # ping
    local pingout pingok=0
    if have ping; then
        pingout=$(ping -c 3 -W 2 "$target" 2>&1)
        if printf '%s' "$pingout" | grep -qE ' 0% packet loss'; then
            pingok=1; fact "ping $target: OK ($(printf '%s' "$pingout" | grep -oE 'rtt.*' | head -n1))"
        else
            fact "ping $target: FAILED ($(printf '%s' "$pingout" | grep -oE '[0-9]+% packet loss|Network is unreachable|Name or service not known' | head -n1))"
        fi
    else missing "ping"; fi

    # re-read neighbour after ping
    neigh=$(ip neigh show "$target" 2>/dev/null)
    if printf '%s' "$neigh" | grep -qE 'FAILED|INCOMPLETE'; then
        hyp "No ARP reply from $target (wrong VLAN, wrong subnet, host down, or L2 problem)"
        ev "Neighbour state is FAILED/INCOMPLETE: $neigh" 4
        confirm "ip neigh show; arping -I $dev -c 3 $target"
        confirm "ip -4 addr show $dev   # is $target inside this subnet/mask?"
    elif [ "$pingok" -eq 0 ] && printf '%s' "$neigh" | grep -qE 'REACHABLE|STALE|DELAY'; then
        hyp "ARP works but ICMP does not: a firewall drops it (local OUTPUT/INPUT or on $target)"
        ev "Neighbour is resolved ($neigh) yet ping fails" 3
        confirm "iptables -S OUTPUT; iptables -S INPUT; nft list ruleset | head -60"
        confirm "tcpdump -ni $dev icmp and host $target   # do echo requests leave? do replies come back?"
    fi
    if [ "$pingok" -eq 0 ] && printf '%s' "$pingout" | grep -q 'Network is unreachable'; then
        hyp "No route to $target"
        ev "ping says 'Network is unreachable'" 4
        confirm "ip route get $target; ip route"
    fi

    # firewall
    local fw=""
    if have nft; then
        local n; n=$(nft list ruleset 2>/dev/null | grep -cE '\b(drop|reject)\b')
        [ "${n:-0}" -gt 0 ] && fw="nft has $n drop/reject rules"
    fi
    if have iptables; then
        local pol; pol=$(iptables -S 2>/dev/null | grep -E '^-P (INPUT|OUTPUT) (DROP|REJECT)' | tr '\n' ' ')
        [ -n "$pol" ] && fw="$fw; iptables default policy: $pol"
    fi
    [ -n "$fw" ] && fact "Firewall: $fw"
    if [ -n "$fw" ] && [ "$pingok" -eq 0 ]; then
        hyp "Local firewall blocks the traffic"
        ev "$fw" 2
        confirm "iptables -L -n -v | grep -vE '^\s*0\s+0' | head -40   # rules with hit counters"
        confirm "nft list ruleset"
    fi

    # beyond gateway
    if [ "$pingok" -eq 1 ] && [ "$target" = "$gw" ]; then
        local ext=""
        have ping && ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 && ext=ok || ext=fail
        fact "ping 1.1.1.1 (beyond gateway): $ext"
        if [ "$ext" = "fail" ]; then
            hyp "Gateway reachable but nothing beyond it (upstream link, NAT, or gateway's own route)"
            ev "gateway pings, 1.1.1.1 does not" 3
            confirm "traceroute -n 1.1.1.1  # or: tracepath -n 1.1.1.1"
        fi
        # DNS
        local dns; dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
        fact "DNS servers: ${dns:-none}"
        if ! getent hosts example.com >/dev/null 2>&1; then
            hyp "DNS resolution broken"
            ev "getent hosts example.com fails" 3
            confirm "cat /etc/resolv.conf; resolvectl status 2>/dev/null; dig @${dns%% *} example.com"
        else
            fact "DNS lookup of example.com: OK"
        fi
    fi

    # recent network events
    if have journalctl; then
        local ev_lines; ev_lines=$(journalctl -k -n 300 --no-pager 2>/dev/null | grep -iE "link (is )?(down|up)|carrier|${dev:-NOMATCH}" | tail -n 5)
        [ -n "$ev_lines" ] && fact "Recent kernel link events:"$'\n'"$(printf '%s\n' "$ev_lines" | cut -c1-140 | sed 's/^/      /')"
        local nm; nm=$(journalctl -u NetworkManager -u systemd-networkd -n 20 --no-pager 2>/dev/null | grep -iE 'fail|error|dhcp|lease' | tail -n 4)
        [ -n "$nm" ] && fact "Network manager log:"$'\n'"$(printf '%s\n' "$nm" | cut -c1-140 | sed 's/^/      /')"
    fi
    # duplicate default routes
    local ndef; ndef=$(ip -4 route show default 2>/dev/null | wc -l)
    if [ "$ndef" -gt 1 ]; then
        hyp "More than one default route (traffic may leave the wrong interface)"
        ev "$ndef default routes present" 2
        confirm "ip route show default; ip route get 1.1.1.1"
    fi
}

# ================================================================== LOAD
investigate_load() {
    local ncpu l1 l5 l15
    ncpu=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    read -r l1 l5 l15 _ < /proc/loadavg
    fact "Load average: $l1 $l5 $l15 on $ncpu CPUs; uptime: $(uptime -p 2>/dev/null || uptime)"

    # cpu split from /proc/stat (1s sample)
    local a b
    a=$(head -n1 /proc/stat); sleep 1; b=$(head -n1 /proc/stat)
    read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ <<<"$a"
    read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ <<<"$b"
    local tot=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u1+n1+s1+i1+w1+q1+sq1+st1) ))
    [ "$tot" -eq 0 ] && tot=1
    local usr=$(( (u2-u1+n2-n1)*100/tot )) sys=$(( (s2-s1)*100/tot )) iow=$(( (w2-w1)*100/tot )) stl=$(( (st2-st1)*100/tot )) idl=$(( (i2-i1)*100/tot ))
    fact "CPU now: user ${usr}% sys ${sys}% iowait ${iow}% steal ${stl}% idle ${idl}%"

    local highload=0
    [ "$(awk -v l="$l5" -v c="$ncpu" 'BEGIN{print (l > c*1.5)?1:0}')" = "1" ] && highload=1

    # top processes
    local topcpu; topcpu=$(ps -eo pid,user,pcpu,pmem,stat,etime,comm --sort=-pcpu 2>/dev/null | head -n 6 | sed 's/^/      /')
    fact "Top CPU:"$'\n'"$topcpu"
    local topmem; topmem=$(ps -eo pid,user,pcpu,pmem,rss,comm --sort=-rss 2>/dev/null | head -n 6 | sed 's/^/      /')
    fact "Top memory:"$'\n'"$topmem"

    # D state
    local dstate; dstate=$(ps -eo pid,stat,wchan:20,comm 2>/dev/null | awk '$2 ~ /^D/' | head -n 8)
    local dcount; dcount=$(printf '%s\n' "$dstate" | grep -c .)

    if [ "$iow" -ge 20 ] || [ "$dcount" -ge 2 ]; then
        hyp "Disk I/O is the bottleneck (slow storage, full disk sync, or a heavy job)"
        [ "$iow" -ge 20 ] && ev "iowait is ${iow}%" 3
        [ "$dcount" -ge 1 ] && ev "$dcount processes in D (uninterruptible) state:"$'\n'"$(printf '%s\n' "$dstate" | sed 's/^/        /')" 3
        confirm "iostat -xz 1 5   # look at %util and await"
        confirm "iotop -o -b -n 3   # who does the I/O"
        confirm "dmesg -T | grep -iE 'I/O error|blk_update|reset|timeout' | tail"
    fi
    if [ "$usr" -ge 70 ] && [ "$highload" -eq 1 ]; then
        hyp "CPU-bound process(es) eating the CPU"
        ev "user CPU is ${usr}% and load $l5 > $ncpu CPUs" 3
        confirm "top -o %CPU -b -n1 | head -20"
        confirm "pidstat -u 1 5"
    fi
    if [ "$sys" -ge 40 ]; then
        hyp "High kernel/system time (bad driver, too many syscalls, swap thrashing, or spinlocks)"
        ev "sys CPU is ${sys}%" 2
        confirm "perf top   # or: pidstat -u 1 5 (look at %system)"
    fi
    if [ "$stl" -ge 10 ]; then
        hyp "VM host is overloaded (CPU steal)"
        ev "steal is ${stl}%" 3
        confirm "vmstat 1 5   # 'st' column; raise with the hypervisor/cloud team"
    fi
    if [ "$highload" -eq 1 ] && [ "$idl" -ge 60 ] && [ "$iow" -lt 20 ]; then
        hyp "Load is high but CPU is idle: processes are blocked on something (NFS, locks, D state)"
        ev "load $l5 vs idle ${idl}%" 2
        confirm "ps -eo pid,stat,wchan:30,comm | awk '\$2 ~ /^D/'"
        confirm "mount | grep -E 'nfs|cifs'; df -h   # a hung network mount makes df hang too"
    fi

    # memory
    local memtot memavail swaptot swapfree
    memtot=$(awk '/MemTotal/ {print $2}' /proc/meminfo); memavail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    swaptot=$(awk '/SwapTotal/ {print $2}' /proc/meminfo); swapfree=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
    local availpct=$(( memtot>0 ? memavail*100/memtot : 0 ))
    local swapused=$(( swaptot - swapfree ))
    fact "Memory: $((memtot/1024)) MB total, $((memavail/1024)) MB available (${availpct}%); swap used $((swapused/1024)) MB of $((swaptot/1024)) MB"
    local si so
    read -r si so <<<"$(vmstat 1 2 2>/dev/null | tail -n1 | awk '{print $7, $8}')"
    [ -n "${si:-}" ] && fact "Swap activity (per s): in=$si out=$so"
    if [ "$availpct" -le 10 ] || [ "${so:-0}" -gt 100 ]; then
        hyp "Memory pressure (near OOM, swapping)"
        [ "$availpct" -le 10 ] && ev "only ${availpct}% memory available" 3
        [ "${so:-0}" -gt 100 ] && ev "swap-out rate $so/s" 3
        confirm "ps -eo pid,rss,comm --sort=-rss | head"
        confirm "free -m; cat /proc/meminfo | grep -iE 'slab|shmem|huge'   # kernel/slab/tmpfs can hold memory too"
    fi
    local oom; oom=$(dmesg -T 2>/dev/null | grep -iE 'out of memory|killed process' | tail -n 3)
    [ -z "$oom" ] && have journalctl && oom=$(journalctl -k -n 2000 --no-pager 2>/dev/null | grep -iE 'out of memory|killed process' | tail -n 3)
    if [ -n "$oom" ]; then
        fact "OOM killer events:"$'\n'"$(printf '%s\n' "$oom" | cut -c1-140 | sed 's/^/      /')"
        hyp "OOM killer has been killing processes"
        ev "OOM messages in kernel log" 3
        confirm "journalctl -k --no-pager | grep -iE 'oom|killed process' | tail -20"
    fi

    # process count / forks
    local nproc_total; nproc_total=$(ps -e --no-headers 2>/dev/null | wc -l)
    fact "Process count: $nproc_total"
    local zomb; zomb=$(ps -eo stat 2>/dev/null | grep -c '^Z')
    [ "$zomb" -gt 20 ] && { hyp "Many zombie processes (parent not reaping)"; ev "$zomb zombies" 2; confirm "ps -eo pid,ppid,stat,comm | awk '\$3 ~ /^Z/' | head; # then check the PPID"; }
    if [ "$nproc_total" -gt 2000 ]; then
        hyp "Very many processes (fork bomb, runaway cron, or worker pool misconfig)"
        ev "$nproc_total processes" 2
        confirm "ps -eo comm --no-headers | sort | uniq -c | sort -rn | head"
    fi

    # recent cron / timers
    if have journalctl; then
        local cronl; cronl=$(journalctl -n 500 --no-pager 2>/dev/null | grep -iE 'CRON|Started .*\.timer|Starting .*\.service' | tail -n 5)
        [ -n "$cronl" ] && fact "Recent cron/timer activity:"$'\n'"$(printf '%s\n' "$cronl" | cut -c1-140 | sed 's/^/      /')"
    fi
    # hung tasks
    local hung; hung=$(dmesg -T 2>/dev/null | grep -i 'blocked for more than' | tail -n 3)
    if [ -n "$hung" ]; then
        fact "Kernel hung-task warnings:"$'\n'"$(printf '%s\n' "$hung" | cut -c1-140 | sed 's/^/      /')"
        hyp "Kernel reports tasks hung on I/O or a lock"
        ev "'blocked for more than' messages in dmesg" 3
        confirm "dmesg -T | grep -A 20 'blocked for more than' | tail -40   # the stack trace names the subsystem"
    fi
}

# ================================================================== MAIN
while getopts ":t:h" o; do
    case $o in
        t) THRESH=$OPTARG ;;
        h|*) sed -n '2,15p' "$0"; exit 0 ;;
    esac
done
shift $((OPTIND-1))

SYMPTOM=${1:-}; shift || true
echo "== Linux incident investigator :: $(hostname) :: $(date '+%F %T') :: symptom: ${SYMPTOM:-none}"

case $SYMPTOM in
    disk|disk-full|df)      investigate_disk "$@" ;;
    service|svc|unit)       investigate_service "$@" ;;
    network|net|gateway)    investigate_network "$@" ;;
    load|slow|cpu|memory|mem) investigate_load "$@" ;;
    *) sed -n '2,15p' "$0"; exit 1 ;;
esac
report

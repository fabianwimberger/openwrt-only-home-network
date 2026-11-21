#!/usr/bin/env bash
# Wire and link-health bench for wired access points, one command per question.
#
#   bench.sh [run] [--quick] [--phy] [-t SEC] [HOST...]   iperf3 up/down/bidir + loss + counters
#   bench.sh serve [--phy] [HOST...]                      install and start iperf3 on the APs
#   bench.sh cmd [-t N] [-i N] [-P N] [--bidir] [-R] [HOST]   print the iperf3 line to paste
#   bench.sh stop                                         kill, uninstall, "tools left: 0"
#   bench.sh report [--since 7d] [--vs-latest]            mean/min per host and metric
#   bench.sh stress [MINUTES]                             TCP bidir, 64-byte UDP flood, AP-to-AP, ping mesh
#   bench.sh cable [TAG]                                  tag the following runs (before/after a cable swap)
#
# Every mode ends with one line: WIRE OK or WIRE NOT OK plus the counter deltas.
# Another user of the APs (running iperf3 without our marker, a foreign client on port
# 5201, uptime under 10 minutes) stops the script; --force overrides that.
set -euo pipefail

CONF="${OPENWRT_BENCH_HOSTS:-$HOME/.config/openwrt-bench/hosts}"
STATE="${OPENWRT_BENCH_STATE:-$HOME/.local/state/openwrt-bench}"
PHY_MAX="${BENCH_PHY_MAX:-0}"
LOSS_MAX="${BENCH_LOSS_MAX:-0.5}"
MIN_UPTIME=600
PORT=5201
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR)
ME="${USER:-user}@$(hostname -s 2>/dev/null || echo desktop)"

die() { echo "Error: $*" >&2; exit 1; }
abort() { echo "ABORTED: $*"; exit 2; }

[[ -f "$CONF" ]] || die "$CONF not found; copy bench/hosts.example there and fill in your APs"
for tool in iperf3 jq ping ssh; do command -v "$tool" >/dev/null || die "$tool is required"; done
mkdir -p "$STATE"

declare -A ADDR IFACE
ALL=()
while read -r name ip iface _; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    ALL+=("$name"); ADDR[$name]="$ip"; IFACE[$name]="${iface:-eth0}"
done <"$CONF"
[[ ${#ALL[@]} -gt 0 ]] || die "no hosts in $CONF"

# Each remote script goes over stdin: the OpenWrt images ship no base64.
remote() { "${SSH[@]}" "root@$1" sh -s; }

FORCE=0 PHY=0 HOSTS=()
pick_hosts() {
    HOSTS=()
    local a
    for a in "$@"; do
        [[ -n "${ADDR[$a]:-}" ]] || die "unknown host '$a' (known: ${ALL[*]})"
        HOSTS+=("$a")
    done
    [[ ${#HOSTS[@]} -gt 0 ]] || HOSTS=("${ALL[@]}")
}

lock() {
    exec 9>"$STATE/.lock"
    flock -n 9 || abort "another bench.sh is running on this machine"
}

# ---- guard: is somebody else on the APs? -------------------------------------------------

hexip() { local a b c d; IFS=. read -r a b c d <<<"$1"; printf '%02X%02X%02X%02X' "$d" "$c" "$b" "$a"; }

guard() { # guard <mode> hosts...   mode=use (serve/run) or stop
    local mode="$1" name ip out up pid owner foreign why bad=0
    shift
    for name in "$@"; do
        ip="${ADDR[$name]}"
        out=$(remote "$ip" <<EOF 2>/dev/null
up=\$(cut -d. -f1 /proc/uptime)
pid=none
for p in /proc/[0-9]*; do [ "\$(cat \$p/comm 2>/dev/null)" = iperf3 ] && pid=\${p#/proc/}; done
owner=\$(cat /tmp/bench.owner 2>/dev/null | cut -d' ' -f1)
foreign=\$(awk -v me=$(hexip "$(local_ip "$ip")") 'NR>1 && \$4=="01" && \$2 ~ /:1451\$/ {split(\$3,a,":"); if (a[1]!=me) n++} END{print n+0}' /proc/net/tcp)
echo "\$up \$pid \${owner:-none} \$foreign"
EOF
) || { echo "$name: not reachable over ssh" >&2; bad=1; continue; }
        read -r up pid owner foreign <<<"$out"
        why=""
        [[ "$foreign" -gt 0 ]] && why+="$foreign foreign client(s) on :$PORT; "
        [[ "$pid" != none && "$owner" != "$ME" ]] && why+="iperf3 pid $pid running without our marker (owner: $owner); "
        [[ "$mode" == use && "$up" -lt "$MIN_UPTIME" ]] && why+="uptime ${up}s (rebooting or flashing?); "
        if [[ -n "$why" && "$FORCE" != 1 ]]; then echo "$name: busy: $why" >&2; bad=1; fi
    done
    [[ "$bad" == 0 ]] || abort "APs in use by someone else or unreachable; --force overrides"
}

local_ip() { ip -o route get "$1" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1; }
desk_dev() { ip -o route get "$1" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }

# ---- counters ---------------------------------------------------------------------------

# prints: carrier_changes speed crc rxerr phy_blocks   (phy "-" without --phy)
counters() {
    {
        printf 'IF=%s\n' "${IFACE[$1]}"
        cat <<'EOF'
d=/sys/class/net/$IF
r() { cat "$1" 2>/dev/null || echo 0; }
p=-
if command -v mdio >/dev/null 2>&1; then
    v=$(mdio mdio-bus mmd 5:3 raw 33 2>/dev/null | head -1)
    [ -n "$v" ] && p=$((v & 255))
fi
echo "$(r $d/carrier_changes) $(r $d/speed) $(r $d/statistics/rx_crc_errors) $(r $d/statistics/rx_errors) $p"
EOF
    } | remote "${ADDR[$1]}"
}

desk_counters() { # carrier_changes crc rx_errors tx_errors
    local d="/sys/class/net/$1"
    echo "$(cat "$d/carrier_changes") $(cat "$d/statistics/rx_crc_errors") $(cat "$d/statistics/rx_errors") $(cat "$d/statistics/tx_errors")"
}

delta() { [[ "$1" == - || "$2" == - ]] && echo 0 || echo $(($2 - $1)); }

# verdict <label> ; reads SNAP0 SNAP1 LOSS DESK0 DESK1 for HOSTS. Sets VERDICT and prints it.
verdict() {
    local name c0 s0 crc0 rx0 p0 c1 s1 crc1 rx1 p1 dc dcrc drx dp parts="" bad=""
    for name in "${HOSTS[@]}"; do
        read -r c0 s0 crc0 rx0 p0 <<<"${SNAP0[$name]}"
        read -r c1 s1 crc1 rx1 p1 <<<"${SNAP1[$name]}"
        dc=$((c1 - c0)); dcrc=$((crc1 - crc0)); drx=$((rx1 - rx0)); dp=$(delta "$p0" "$p1")
        parts+="$name carr+$dc crc+$dcrc rxerr+$drx"
        [[ "$p1" != - ]] && parts+=" phy+$dp"
        parts+=" loss${LOSS[$name]:-0}% ${s1}M | "
        [[ "$dc" -gt 0 ]] && bad+="$name carrier+$dc; "
        [[ "$dcrc" -gt 0 ]] && bad+="$name crc+$dcrc; "
        [[ "$drx" -gt 0 ]] && bad+="$name rxerr+$drx; "
        [[ "$dp" -gt "$PHY_MAX" ]] && bad+="$name phy+$dp; "
        [[ "$s1" != "$s0" ]] && bad+="$name speed ${s0}->${s1}; "
        awk -v l="${LOSS[$name]:-0}" -v m="$LOSS_MAX" 'BEGIN{exit !(l+0>m+0)}' && bad+="$name loss ${LOSS[$name]}%; "
    done
    local a b c d e f g h
    read -r a b c d <<<"$DESK0"; read -r e f g h <<<"$DESK1"
    parts+="desk carr+$((e - a)) crc+$((f - b)) err+$((g - c + h - d))"
    [[ $((e - a)) -gt 0 ]] && bad+="desktop NIC carrier+$((e - a)); "
    [[ $((f - b)) -gt 0 ]] && bad+="desktop NIC crc+$((f - b)); "
    if [[ -z "$bad" ]]; then VERDICT="WIRE OK  $1  $parts"; else VERDICT="WIRE NOT OK  ${bad%; }  [$1  $parts]"; fi
    echo "$VERDICT"
}

declare -A SNAP0 SNAP1 LOSS
DESK0="" DESK1="" DESKDEV=""

snap_all() { # snap_all SNAP0|SNAP1
    local name
    for name in "${HOSTS[@]}"; do
        if [[ "$1" == SNAP0 ]]; then SNAP0[$name]="$(counters "$name")"; else SNAP1[$name]="$(counters "$name")"; fi
    done
    if [[ "$1" == SNAP0 ]]; then DESK0="$(desk_counters "$DESKDEV")"; else DESK1="$(desk_counters "$DESKDEV")"; fi
}

# ---- serve / stop ------------------------------------------------------------------------

serve_host() {
    {
        printf 'PHY=%s ME=%s\n' "$PHY" "$ME"
        cat <<'EOF'
apk list --installed 2>/dev/null | grep -q '^iperf3-' || apk add iperf3 >/dev/null 2>&1
if [ "$PHY" = 1 ]; then apk list --installed 2>/dev/null | grep -q '^mdio-tools-' || apk add mdio-tools >/dev/null 2>&1; fi
running=0
for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = iperf3 ] && running=1; done
[ "$running" = 1 ] || iperf3 -s -D
echo "$ME $(date +%s)" > /tmp/bench.owner
EOF
    } | remote "${ADDR[$1]}"
}

serving_hosts() { [[ -f "$STATE/serving" ]] && cat "$STATE/serving" || true; }

do_serve() {
    local name
    for name in "${HOSTS[@]}"; do
        serve_host "$name" || die "$name: could not install or start iperf3 (no internet on the AP?)"
    done
    sleep 1
}

mark_serving() {
    printf '%s\n' "${HOSTS[@]}" >"$STATE/serving"
}

# Kills iperf3 and removes the tools; echoes the number of leftovers.
stop_host() {
    remote "${ADDR[$1]}" <<'EOF'
for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = iperf3 ] && kill "${p#/proc/}"; done
sleep 1
rm -f /tmp/bench.owner /tmp/watch.*
apk del iperf3 mdio-tools >/dev/null 2>&1
n=$(apk list --installed 2>/dev/null | grep -c -E '^(iperf3|mdio-tools)-')
for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = iperf3 ] && n=$((n + 1)); done
echo "$n"
EOF
}

# ---- run ---------------------------------------------------------------------------------

PRESERVED=0 PIDS=()
# A "serve" the user started explicitly stays up; anything the run installed goes again.
cleanup_run() {
    local p n
    for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
    [[ "$PRESERVED" == 1 ]] || for n in "${HOSTS[@]}"; do stop_host "$n" >/dev/null 2>&1 || true; done
}

mbit() { jq -r "((.end.$1.bits_per_second // 0) / 1000000) | floor"; }
iperf() { iperf3 "$@" -J 2>/dev/null || echo '{}'; }

cmd_run() {
    local quick=0 secs=10 cable="" a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick) quick=1 ;;
            --phy) PHY=1 ;;
            --force) FORCE=1 ;;
            -t) secs="$2"; shift ;;
            --cable) cable="$2"; shift ;;
            [0-9]*) secs="$1" ;;
            -*) die "unknown option $1" ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    [[ "$quick" == 1 ]] && secs=3
    pick_hosts "${args[@]}"
    lock
    guard use "${HOSTS[@]}"

    local name ip
    PRESERVED=0
    [[ -f "$STATE/serving" ]] && PRESERVED=1
    do_serve
    DESKDEV="$(desk_dev "${ADDR[${HOSTS[0]}]}")"
    local result previous
    result="$STATE/$(date +%Y%m%d-%H%M%S).tsv"
    previous="$(find "$STATE" -maxdepth 1 -name '*.tsv' | sort | tail -1 || true)"
    [[ -z "$cable" && -f "$STATE/cable" ]] && cable="$(cat "$STATE/cable")"
    {
        echo "# date=$(date -Is)"
        echo "# mode=$([[ "$quick" == 1 ]] && echo quick || echo full)$([[ "$PHY" == 1 ]] && echo ' phy')"
        [[ -n "$cable" ]] && echo "# cable=$cable"
    } >"$result"
    # Always clean up, also when interrupted; a pre-existing "serve" stays up.
    trap cleanup_run EXIT

    snap_all SNAP0
    printf '%-14s %6s %6s %6s %6s %6s %7s %5s %4s %5s %s\n' host up down bi-up bi-dn loss% maxrtt carr crc rxerr link
    local up down bi bi_up bi_down ping_out ping_pid loss maxrtt n tests
    tests=$([[ "$quick" == 1 ]] && echo 2 || echo 3)
    for name in "${HOSTS[@]}"; do
        ip="${ADDR[$name]}"
        local before
        before="${SNAP0[$name]}"
        ping_out="$(mktemp)"
        ping -c "$((secs * tests * 5 + 15))" -i 0.2 -q "$ip" >"$ping_out" 2>&1 &
        ping_pid=$!
        up=$(iperf -c "$ip" -P 4 -t "$secs" | mbit sum_sent)
        down=$(iperf -c "$ip" -P 4 -t "$secs" -R | mbit sum_received)
        bi_up="" bi_down=""
        if [[ "$quick" != 1 ]]; then
            bi=$(iperf -c "$ip" -P 4 -t "$secs" --bidir)
            bi_up=$(mbit sum_sent <<<"$bi")
            # In --bidir the download is sum_sent_bidir_reverse; sum_received is the far end of the upload.
            bi_down=$(mbit sum_sent_bidir_reverse <<<"$bi")
        fi
        kill -INT "$ping_pid" 2>/dev/null || true
        wait "$ping_pid" 2>/dev/null || true
        loss=$(grep -oE '[0-9.]+% packet loss' "$ping_out" | cut -d% -f1 || true)
        maxrtt=$(grep -oE 'min/avg/max[^=]*= [0-9./]+' "$ping_out" | awk -F'[ /]' '{print $(NF-2)}' || true)
        rm -f "$ping_out"
        LOSS[$name]="${loss:-?}"
        [[ "${loss:-?}" == "?" ]] && LOSS[$name]=100
        SNAP1[$name]="$(counters "$name")"
        local c0 s0 crc0 rx0 p0 c1 s1 crc1 rx1 p1
        read -r c0 s0 crc0 rx0 p0 <<<"$before"; read -r c1 s1 crc1 rx1 p1 <<<"${SNAP1[$name]}"
        printf '%-14s %6s %6s %6s %6s %6s %7s %5s %4s %5s %s\n' "$name" "$up" "$down" "${bi_up:--}" "${bi_down:--}" \
            "${LOSS[$name]}" "${maxrtt:-?}" "$((c1 - c0))" "$((crc1 - crc0))" "$((rx1 - rx0))" "${s1}M$([[ "$p1" != - ]] && echo " phy+$(delta "$p0" "$p1")")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$up" "$down" "$bi_up" "$bi_down" "${LOSS[$name]}" \
            "${maxrtt:-}" "$((c1 - c0))" "$((crc1 - crc0))" "$((rx1 - rx0))" "$(delta "$p0" "$p1")" >>"$result"
        if [[ -n "$previous" ]] && p=$(grep -m1 "^$name"$'\t' "$previous"); then
            IFS=$'\t' read -r _ pu pd pbu pbd pl _ <<<"$p"
            printf '%-14s %6s %6s %6s %6s %6s   (previous run)\n' "" "$pu" "$pd" "${pbu:--}" "${pbd:--}" "$pl"
        fi
    done
    DESK1="$(desk_counters "$DESKDEV")"
    verdict "$([[ "$quick" == 1 ]] && echo quick || echo full) ${secs}s" >/dev/null
    echo "# verdict=$VERDICT" >>"$result"
    echo "$VERDICT"
}

# ---- serve / stop / cmd ------------------------------------------------------------------

cmd_serve() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in --phy) PHY=1 ;; --force) FORCE=1 ;; -*) die "unknown option $1" ;; *) args+=("$1") ;; esac
        shift
    done
    pick_hosts "${args[@]}"
    lock
    guard use "${HOSTS[@]}"
    local name
    DESKDEV="$(desk_dev "${ADDR[${HOSTS[0]}]}")"
    if [[ ! -f "$STATE/baseline" ]]; then
        snap_all SNAP0
        { echo "$DESKDEV $DESK0"; for name in "${HOSTS[@]}"; do echo "$name ${SNAP0[$name]}"; done; date +%s; } >"$STATE/baseline"
    fi
    do_serve
    mark_serving
    echo "serving iperf3 on ${HOSTS[*]} (port $PORT); next: bench.sh cmd, finish with: bench.sh stop"
    verdict_now serve
}

# Verdict against the counters taken at serve time, or against boot (3 carrier changes are normal) without a baseline.
verdict_now() {
    local label="$1" name since="since boot" dev c crc rx tx t0 n s p
    [[ ${#HOSTS[@]} -gt 0 ]] || pick_hosts
    DESKDEV="$(desk_dev "${ADDR[${HOSTS[0]}]}")"
    snap_all SNAP1
    DESK0="$DESK1"
    for n in "${HOSTS[@]}"; do read -r _ s _ _ p <<<"${SNAP1[$n]}"; SNAP0[$n]="3 $s 0 0 $p"; done
    if [[ -f "$STATE/baseline" ]]; then
        read -r dev c crc rx tx <"$STATE/baseline"
        [[ "$dev" == "$DESKDEV" ]] && DESK0="$c $crc $rx $tx"
        while read -r name rest; do
            [[ -n "${ADDR[$name]:-}" ]] && SNAP0[$name]="$rest"
        done < <(sed -n '2,$p' "$STATE/baseline" | grep -v '^[0-9]*$')
        t0=$(tail -1 "$STATE/baseline")
        since="since serve $(( ($(date +%s) - t0) / 60 )) min ago"
    fi
    LOSS=()
    verdict "$label $since" >/dev/null
    echo "$VERDICT"
}

cmd_stop() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in --force) FORCE=1 ;; -*) die "unknown option $1" ;; *) args+=("$1") ;; esac
        shift
    done
    pick_hosts "${args[@]}"
    lock
    guard stop "${HOSTS[@]}"
    local name left=0 n
    # Verdict first: the baseline lives in the state dir, the tools are about to go.
    local v
    v="$(verdict_now stop)"
    for name in "${HOSTS[@]}"; do
        n=$(stop_host "$name") || n=1
        left=$((left + n))
    done
    rm -f "$STATE/serving" "$STATE/baseline"
    echo "tools left: $left"
    echo "$v"
}

cmd_cmd() {
    local t=10 i=1 P=1 extra=() host=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t) t="$2"; shift ;; -i) i="$2"; shift ;; -P) P="$2"; shift ;; -P[0-9]*) P="${1#-P}" ;;
            --bidir) extra+=(--bidir) ;; -R|--reverse) extra+=(-R) ;;
            -*) die "unknown option $1" ;; *) host="$1" ;;
        esac
        shift
    done
    pick_hosts ${host:+"$host"}
    local name
    for name in "${HOSTS[@]}"; do
        echo "iperf3 -c ${ADDR[$name]} -t $t -i $i -P$P${extra[*]:+ ${extra[*]}}"
    done
    local down=""
    for name in "${HOSTS[@]}"; do
        iperf3 -c "${ADDR[$name]}" -t 1 >/dev/null 2>&1 || down+="$name "
    done
    [[ -z "$down" ]] || echo "(no iperf3 server on: ${down% }; run bench.sh serve first)" >&2
    verdict_now cmd
}

cmd_cable() {
    if [[ $# -eq 0 ]]; then
        cat "$STATE/cable" 2>/dev/null || echo "(no cable tag)"
    elif [[ "$1" == --clear ]]; then
        rm -f "$STATE/cable"; echo "cable tag cleared"
    else
        echo "$1" >"$STATE/cable"; echo "cable tag: $1 (written to every run from now on)"
    fi
}

# ---- report ------------------------------------------------------------------------------

cmd_report() {
    local since=7d vs=0
    while [[ $# -gt 0 ]]; do
        case "$1" in --since) since="$2"; shift ;; --vs-latest) vs=1 ;; *) die "unknown option $1" ;; esac
        shift
    done
    python3 -I - "$STATE" "$since" "$vs" <<'PY'
import glob, os, re, sys, time, statistics
from datetime import datetime

state, since, vs = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
m = re.fullmatch(r"(\d+)([hdw])", since)
if not m:
    sys.exit("Error: --since takes e.g. 12h, 7d, 2w")
cutoff = time.time() - int(m[1]) * {"h": 3600, "d": 86400, "w": 604800}[m[2]]

COLS = ["up", "down", "bi-up", "bi-dn", "loss", "maxrtt"]
runs = []
for f in sorted(glob.glob(os.path.join(state, "*.tsv"))):
    stamp = os.path.basename(f)[:-4]
    try:
        ts = datetime.strptime(stamp, "%Y%m%d-%H%M%S").timestamp()
    except ValueError:
        continue
    if ts < cutoff:
        continue
    run = {"stamp": stamp, "cable": "-", "mode": "full", "verdict": "", "rows": {}}
    for line in open(f):
        line = line.rstrip("\n")
        if line.startswith("#"):
            k, _, v = line[1:].strip().partition("=")
            if k in ("cable", "mode", "verdict"):
                run[k] = v
            continue
        p = line.split("\t")
        if len(p) < 6:
            continue
        vals = {}
        for c, v in zip(COLS, p[1:7]):
            try:
                vals[c] = float(v)
            except ValueError:
                pass
        run["rows"][p[0]] = vals
    runs.append(run)

if not runs:
    print(f"NO DATA  no runs in the last {since}")
    sys.exit(0)

def agg(rs, host, col):
    v = [r["rows"][host][col] for r in rs if host in r["rows"] and col in r["rows"][host]]
    if not v:
        return None
    worst = max(v) if col in ("loss", "maxrtt") else min(v)
    return len(v), statistics.mean(v), worst

hosts = sorted({h for r in runs for h in r["rows"]})
tags = []
for r in runs:
    if r["cable"] not in tags:
        tags.append(r["cable"])
fmt = lambda x: "-" if x is None else f"{x:.0f}" if x >= 100 else f"{x:.2f}".rstrip("0").rstrip(".")
span = f"{runs[0]['stamp'][:8]} .. {runs[-1]['stamp'][:8]}"
print(f"{len(runs)} runs, {span}   (mean / min; loss and maxrtt show the worst value)")

latest = runs[-1]
prior = [r for r in runs[:-1]]
if len(tags) > 1:
    head = f"{'host':<12} {'metric':<7}" + "".join(f" {'cable=' + t:>22}" for t in tags) + "   last vs first"
    print(head)
    for h in hosts:
        for c in COLS:
            cells, means = [], []
            for t in tags:
                a = agg([r for r in runs if r["cable"] == t], h, c)
                cells.append("-" if a is None else f"{fmt(a[1])} / {fmt(a[2])} (n={a[0]})")
                means.append(None if a is None else a[1])
            if all(x is None for x in means):
                continue
            ch = ""
            if means[0] and means[-1] is not None:
                ch = f"{(means[-1] - means[0]) / means[0] * 100:+.0f}%"
            print(f"{h:<12} {c:<7}" + "".join(f" {x:>22}" for x in cells) + f"   {ch}")
elif vs:
    print(f"{'host':<12} {'metric':<7} {'latest':>8} {'prior mean':>11} {'delta':>7}   ({latest['stamp']}, {len(prior)} earlier runs)")
    for h in hosts:
        for c in COLS:
            a = agg(prior, h, c)
            cur = latest["rows"].get(h, {}).get(c)
            if cur is None and a is None:
                continue
            d = "" if a is None or cur is None or a[1] == 0 else f"{(cur - a[1]) / a[1] * 100:+.0f}%"
            print(f"{h:<12} {c:<7} {fmt(cur):>8} {fmt(a[1] if a else None):>11} {d:>7}")
else:
    print(f"{'host':<12} {'metric':<7} {'n':>3} {'mean':>8} {'min/worst':>10} {'latest':>8}")
    for h in hosts:
        for c in COLS:
            a = agg(runs, h, c)
            if a is None:
                continue
            print(f"{h:<12} {c:<7} {a[0]:>3} {fmt(a[1]):>8} {fmt(a[2]):>10} {fmt(latest['rows'].get(h, {}).get(c)):>8}")

# Verdict: the latest run's own verdict plus a throughput check against the earlier runs.
bad = []
if latest["verdict"].startswith("WIRE NOT OK"):
    bad.append(latest["verdict"].split("  ")[1])
same = [r for r in prior if r["cable"] == latest["cable"]]
for h, vals in latest["rows"].items():
    for c in ("up", "down"):
        a = agg(same, h, c)
        if a and c in vals and a[1] > 0 and vals[c] < a[1] * 0.85:
            bad.append(f"{h} {c} {(vals[c] - a[1]) / a[1] * 100:+.0f}% vs mean")
    if vals.get("loss", 0) > 0.5:
        bad.append(f"{h} loss {vals['loss']:g}%")
tag = f" cable={latest['cable']}" if latest["cable"] != "-" else ""
base = f"latest {latest['stamp']}{tag}, {len(same)} earlier run(s) to compare"
print(("WIRE NOT OK  " + "; ".join(bad) + f"  [{base}]") if bad else f"WIRE OK  {base}; up/down within 15% of the mean")
PY
}

# ---- stress ------------------------------------------------------------------------------

cmd_stress() {
    local minutes=10 args=() cable=""
    while [[ $# -gt 0 ]]; do
        case "$1" in --force) FORCE=1 ;; -*) die "unknown option $1" ;; [0-9]*) minutes="$1" ;; *) args+=("$1") ;; esac
        shift
    done
    PHY=1
    pick_hosts "${args[@]}"
    lock
    guard use "${HOSTS[@]}"
    PRESERVED=0
    [[ -f "$STATE/serving" ]] && PRESERVED=1
    do_serve
    DESKDEV="$(desk_dev "${ADDR[${HOSTS[0]}]}")"
    local dir name ip
    dir="$STATE/stress-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dir"
    local total=$((minutes * 60)) pt=$((minutes * 15))
    [[ "$pt" -lt 15 ]] && pt=15
    total=$((pt * 4))
    trap cleanup_run EXIT

    # Counters every 5 s: one long ssh per AP, one loop on the desktop.
    for name in "${HOSTS[@]}"; do
        {
            printf 'IF=%s\n' "${IFACE[$name]}"
            cat <<'EOF'
d=/sys/class/net/$IF
r() { cat "$1" 2>/dev/null || echo 0; }
while :; do
    p=-
    command -v mdio >/dev/null 2>&1 && { v=$(mdio mdio-bus mmd 5:3 raw 33 2>/dev/null | head -1); [ -n "$v" ] && p=$((v & 255)); }
    echo "$(date +%s) $(r $d/carrier_changes) $(r $d/speed) $(r $d/statistics/rx_crc_errors) $(r $d/statistics/rx_errors) $p"
    sleep 5
done
EOF
        } | "${SSH[@]}" "root@${ADDR[$name]}" sh -s >"$dir/counters-$name.tsv" 2>/dev/null &
        PIDS+=($!)
    done
    ( while :; do echo "$(date +%s) $(desk_counters "$DESKDEV")"; sleep 5; done ) >"$dir/counters-desktop.tsv" &
    PIDS+=($!)
    sleep 6

    # Ping mesh: desktop to every AP, every AP to every other AP.
    local pingpids=() n2
    for name in "${HOSTS[@]}"; do
        ping -c "$((total * 5 + 20))" -i 0.2 -q "${ADDR[$name]}" >"$dir/ping-desktop-$name.log" 2>&1 &
        pingpids+=($!)
        for n2 in "${HOSTS[@]}"; do
            [[ "$n2" == "$name" ]] && continue
            "${SSH[@]}" "root@${ADDR[$name]}" "ping -c $((total + 10)) -q ${ADDR[$n2]}" >"$dir/ping-$name-$n2.log" 2>&1 &
            pingpids+=($!)
        done
    done
    PIDS+=("${pingpids[@]}")

    DESK0="$(desk_counters "$DESKDEV")"
    for name in "${HOSTS[@]}"; do SNAP0[$name]="$(counters "$name")"; done

    echo "stress: ${#HOSTS[@]} APs, 4 phases of ${pt}s (TCP bidir, 64-byte UDP flood, AP-to-AP, mixed), log in $dir"
    local tp=()
    echo "phase 1/4: TCP bidir -P4 to every AP"
    for name in "${HOSTS[@]}"; do iperf -c "${ADDR[$name]}" -P 4 -t "$pt" --bidir >>"$dir/iperf.jsonl" & tp+=($!); done
    wait "${tp[@]}"; tp=()
    echo "phase 2/4: 64-byte UDP flood to every AP"
    for name in "${HOSTS[@]}"; do iperf -c "${ADDR[$name]}" -u -b 0 -l 64 -t "$pt" >>"$dir/iperf.jsonl" & tp+=($!); done
    wait "${tp[@]}"; tp=()
    echo "phase 3/4: AP to AP (bidir)"
    if [[ ${#HOSTS[@]} -ge 2 ]]; then
        "${SSH[@]}" "root@${ADDR[${HOSTS[0]}]}" "iperf3 -c ${ADDR[${HOSTS[1]}]} -P 4 -t $pt --bidir" >"$dir/ap-to-ap.txt" 2>&1 || true
    else
        sleep "$pt"
    fi
    echo "phase 4/4: TCP bidir to every AP plus AP-to-AP at the same time"
    for name in "${HOSTS[@]}"; do iperf -c "${ADDR[$name]}" -P 4 -t "$pt" --bidir >>"$dir/iperf.jsonl" & tp+=($!); done
    [[ ${#HOSTS[@]} -ge 2 ]] && { "${SSH[@]}" "root@${ADDR[${HOSTS[1]}]}" "iperf3 -c ${ADDR[${HOSTS[0]}]} -P 4 -t $pt" >>"$dir/ap-to-ap.txt" 2>&1 & tp+=($!); }
    wait "${tp[@]}"
    sleep 2

    for name in "${HOSTS[@]}"; do SNAP1[$name]="$(counters "$name")"; done
    DESK1="$(desk_counters "$DESKDEV")"
    for p in "${pingpids[@]}"; do kill -INT "$p" 2>/dev/null || true; done
    wait "${pingpids[@]}" 2>/dev/null || true
    PIDS=()

    local l
    for name in "${HOSTS[@]}"; do
        LOSS[$name]=0
        for f in "$dir"/ping-desktop-"$name".log "$dir"/ping-"$name"-*.log; do
            [[ -f "$f" ]] || continue
            l=$(grep -oE '[0-9.]+% packet loss' "$f" | cut -d% -f1 || true)
            [[ -z "$l" ]] && l=100
            awk -v a="$l" -v b="${LOSS[$name]}" 'BEGIN{exit !(a+0>b+0)}' && LOSS[$name]="$l"
        done
    done
    # Events between samples show flaps that a before/after delta would hide only if they cancel out.
    local flaps=0
    for name in "${HOSTS[@]}"; do
        awk 'NR>1 && $2!=prev {n++} {prev=$2} END{exit n>0}' "$dir/counters-$name.tsv" || flaps=1
    done
    verdict "stress ${minutes}min (${pt}s x4)" >/dev/null
    [[ "$flaps" == 1 && "$VERDICT" == "WIRE OK"* ]] && VERDICT="WIRE NOT OK  carrier changed during the run  [${VERDICT#WIRE OK  }]"
    {
        echo "$VERDICT"
        for name in "${HOSTS[@]}"; do echo "$name: $(head -1 "$dir/counters-$name.tsv") -> $(tail -1 "$dir/counters-$name.tsv")"; done
    } >"$dir/summary.txt"
    local result
    result="$STATE/$(date +%Y%m%d-%H%M%S).tsv"
    { echo "# date=$(date -Is)"; echo "# mode=stress"; echo "# verdict=$VERDICT"; } >"$result"
    echo "$VERDICT"
}

# ---- dispatch ----------------------------------------------------------------------------

sub="${1:-run}"
case "$sub" in
    run|serve|stop|cmd|report|stress|cable) shift ;;
    -h|--help|help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) sub=run ;;
esac
"cmd_$sub" "$@"

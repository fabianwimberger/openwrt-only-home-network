#!/usr/bin/env bash
# The roaming story of one client: every hostapd and usteer log line that mentions its MAC,
# from all nodes, merged in time order. Needs hostapd log_level=1 (baked into the templates).
#   roamlog.sh <mac|name> [--lines N]
# A name is looked up in ~/.config/openwrt-bench/names ("mac name" per line, untracked).
set -euo pipefail
# shellcheck source=tools/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUERY="" LINES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lines) LINES="$2"; shift ;;
        -h|--help) sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) QUERY="$1" ;;
    esac
    shift
done
[[ -n "$QUERY" ]] || die "usage: roamlog.sh <mac|name> [--lines N]"
MAC="$(name_to_mac "$QUERY")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mapfile -t NODES < <(nodes_present)
pids=()
for n in "${NODES[@]}"; do
    { printf 'MAC=%s\n' "$MAC"; echo 'logread | grep -i -- "$MAC"'; } | rsh "$n" >"$TMP/$n.log" 2>/dev/null &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done

python3 -I - "$TMP" "$LINES" "$MAC" "${NODES[@]}" <<'PY'
import os, re, sys
from datetime import datetime
tmp, limit, mac, nodes = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
out = []
for n in nodes:
    path = os.path.join(tmp, n + ".log")
    if not os.path.exists(path):
        continue
    for line in open(path, errors="replace"):
        m = re.match(r"(\w{3} \w{3} +\d+ \d\d:\d\d:\d\d \d{4}) (\S+) (.*)", line.rstrip("\n"))
        if not m or "dropbear" in m[3]:
            continue
        ts = datetime.strptime(re.sub(r" +", " ", m[1]), "%a %b %d %H:%M:%S %Y")
        out.append((ts, n, m[3]))
out.sort()
if limit:
    out = out[-limit:]
for ts, n, msg in out:
    print(f"{ts:%m-%d %H:%M:%S} {n:<18} {msg}")
nodes_seen = sorted({n for _, n, _ in out})
print(f"\nROAMLOG {mac}: {len(out)} lines from {len(nodes_seen)} node(s)" + ("" if out else " (no log lines; is hostapd log_level=1 set and the client recent?)"))
PY

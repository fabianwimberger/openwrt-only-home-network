#!/usr/bin/env bash
# Every associated client on every node: SSID, band, signal, rate, idle time.
#   clients.sh [--by ssid|node]
# Without --by it lists one row per client. Names come from ~/.config/openwrt-bench/names
# ("mac name" per line, untracked), so no device name lives in the repository.
set -euo pipefail
# shellcheck source=tools/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --by) BY="$2"; shift ;;
        -h|--help) sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done
[[ -z "$BY" || "$BY" == ssid || "$BY" == node ]] || die "--by takes ssid or node"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mapfile -t NODES < <(nodes_present)

collect() {
    rsh "$1" >"$TMP/$1.tsv" 2>/dev/null <<'EOF'
iw dev | awk '
/^\tInterface /{i=$2}
/^\t\tssid /{s=$0; sub(/^\t\tssid /,"",s); ssid[i]=s}
/^\t\ttype /{t[i]=$2}
/^\t\tchannel /{f=$3; sub(/^\(/,"",f); fr[i]=f}
END{for (i in t) if (t[i]=="AP") printf "%s\t%s\t%s\n", i, ssid[i], fr[i]}' |
while IFS="$(printf '\t')" read -r i s f; do
    iw dev "$i" station dump | awk -v i="$i" -v s="$s" -v f="$f" '
    /^Station /{ if (m) out(); m=$2; sg=""; tx=""; ina="" }
    /^\tinactive time:/{ina=$3}
    /^\tsignal:/{sg=$2}
    /^\ttx bitrate:/{tx=$3}
    END{ if (m) out() }
    function out() { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", i, s, f, m, sg, tx, ina }'
done
EOF
}
pids=()
for n in "${NODES[@]}"; do collect "$n" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || true; done

python3 -I - "$TMP" "$NAMES_FILE" "$BY" "${NODES[@]}" <<'PY'
import os, sys
tmp, names_file, by, nodes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
names = {}
if os.path.exists(names_file):
    for line in open(names_file):
        p = line.split(None, 1)
        if len(p) == 2 and not p[0].startswith("#"):
            names[p[0].lower()] = p[1].strip()
rows = []
for n in nodes:
    path = os.path.join(tmp, n + ".tsv")
    if not os.path.exists(path):
        continue
    for line in open(path):
        i, ssid, freq, mac, sig, tx, idle = (line.rstrip("\n").split("\t") + [""] * 7)[:7]
        if not mac:
            continue
        band = "2.4" if freq and float(freq) < 3000 else "5"
        rows.append(dict(node=n, ssid=ssid, band=band, mac=mac.lower(), sig=sig, tx=tx, idle=idle))
if by == "ssid":
    ssids = sorted({r["ssid"] for r in rows})
    w = max([len(s) for s in ssids] + [4]) + 2
    print(f"{'SSID':<{w}}" + "".join(f"{n:>{len(n) + 2}}" for n in nodes) + "   total")
    for s in ssids:
        cnt = [sum(1 for r in rows if r['ssid'] == s and r['node'] == n) for n in nodes]
        print(f"{s:<{w}}" + "".join(f"{c:>{len(n) + 2}}" for c, n in zip(cnt, nodes)) + f"{sum(cnt):>8}")
elif by == "node":
    for n in nodes:
        print(f"{n:<20} {sum(1 for r in rows if r['node'] == n)}")
else:
    print(f"{'node':<18} {'ssid':<16} {'band':>4} {'mac':<17} {'name':<18} {'dBm':>5} {'Mbit/s':>7} {'idle ms':>8}")
    for r in sorted(rows, key=lambda r: (r["node"], r["ssid"], r["mac"])):
        print(f"{r['node']:<18} {r['ssid']:<16} {r['band']:>4} {r['mac']:<17} {names.get(r['mac'], ''):<18} {r['sig']:>5} {r['tx']:>7} {r['idle']:>8}")
print(f"\nCLIENTS {len(rows)} on {len({r['node'] for r in rows})}/{len(nodes)} nodes")
PY

#!/usr/bin/env bash
# Who hears whom: every node scans on each of its radios (iw scan ap-force) and the result is
# printed as one table per band, row hears column, median beacon dBm over the rounds,
# plus the number of foreign BSSes per channel as heard from each node.
#   survey.sh [--rounds 3]
# A scan takes a radio off its channel for a moment, so clients on that radio see a short hiccup.
set -euo pipefail
# shellcheck source=tools/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUNDS=3
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rounds) ROUNDS="$2"; shift ;;
        -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mapfile -t NODES < <(nodes_present)
[[ ${#NODES[@]} -gt 0 ]] || die "no node profiles found"

scan_node() {
    {
        printf 'ROUNDS=%s\n' "$ROUNDS"
        cat <<'EOF'
iw dev | awk '
/^\tInterface /{i=$2}
/^\t\taddr /{a[i]=$2}
/^\t\ttype /{t[i]=$2}
/^\t\tchannel /{f=$3; sub(/^\(/,"",f); fr[i]=f}
END{for (i in t) printf "IF\t%s\t%s\t%s\t%s\n", i, a[i], t[i], fr[i]}'
ifs=$(iw dev | awk '/^phy#/{p=$1} /^\tInterface /{i=$2} /^\t\ttype (AP|managed)$/{ if (!(p in d)) {d[p]=1; print i} }')
r=1
while [ "$r" -le "$ROUNDS" ]; do
    for i in $ifs; do
        iw dev "$i" scan ap-force 2>/dev/null | awk -v r="$r" '
        /^BSS /{ if (b) out(); b=$2; sub(/\(.*/,"",b); f=""; sg=""; s="" }
        /^\tfreq:/{f=$2}
        /^\tsignal:/{sg=$2}
        /^\tSSID:/{s=$0; sub(/^\tSSID: ?/,"",s)}
        END{ if (b) out() }
        function out() { printf "BSS\t%s\t%s\t%s\t%s\t%s\n", r, b, f, sg, s }'
    done
    r=$((r + 1))
done
EOF
    } | rsh "$1" >"$TMP/$1.tsv" 2>/dev/null
}

pids=()
for n in "${NODES[@]}"; do scan_node "$n" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || true; done

python3 -I - "$TMP" "${NODES[@]}" <<'PY'
import statistics, sys, os
tmp, nodes = sys.argv[1], sys.argv[2:]
owner, heard, foreign = {}, {}, {}
for n in nodes:
    path = os.path.join(tmp, n + ".tsv")
    if not os.path.exists(path):
        continue
    for line in open(path):
        p = line.rstrip("\n").split("\t")
        if p[0] == "IF" and len(p) >= 4 and p[3] == "AP":
            owner[p[2].lower()] = n
for n in nodes:
    path = os.path.join(tmp, n + ".tsv")
    if not os.path.exists(path):
        continue
    best = {}  # (target, band, round) -> strongest dBm
    for line in open(path):
        p = line.rstrip("\n").split("\t")
        if p[0] != "BSS" or len(p) < 5 or not p[3] or not p[4]:
            continue
        rnd, bssid, freq, sig = p[1], p[2].lower(), float(p[3]), float(p[4])
        band = "2.4" if freq < 3000 else "5"
        t = owner.get(bssid)
        if t is None:
            ch = int(freq)
            foreign.setdefault((n, band), {}).setdefault(ch, set()).add((rnd, bssid))
            continue
        k = (t, band, rnd)
        best[k] = max(best.get(k, -200), sig)
    for (t, band, _), sig in best.items():
        heard.setdefault((n, t, band), []).append(sig)
width = max(len(x) for x in nodes) + 2
for band in ("2.4", "5"):
    print(f"\n{band} GHz (row hears column, median dBm)")
    print(" " * width + "".join(f"{t:>{width + 2}}" for t in nodes))
    for n in nodes:
        cells = []
        for t in nodes:
            v = heard.get((n, t, band))
            cells.append("" if n == t else ("-" if not v else f"{statistics.median(v):.0f}"))
        print(f"{n:<{width}}" + "".join(f"{c:>{width + 2}}" for c in cells))
print("\nforeign BSSes heard per channel (strongest listener view)")
chans = {}
for (n, band), d in foreign.items():
    for ch, s in d.items():
        chans[(band, ch)] = max(chans.get((band, ch), 0), len({b for _, b in s}))
for (band, ch), cnt in sorted(chans.items()):
    print(f"  {band:>3} GHz  {ch} MHz: {cnt}")
missing = [n for n in nodes if not os.path.exists(os.path.join(tmp, n + ".tsv")) or os.path.getsize(os.path.join(tmp, n + ".tsv")) == 0]
print(f"\nSURVEY {'NOT OK' if missing else 'OK'}  {len(nodes) - len(missing)}/{len(nodes)} nodes scanned" + (f", no data from {', '.join(missing)}" if missing else ""))
PY

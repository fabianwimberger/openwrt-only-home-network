#!/usr/bin/env bash
# Runs repeated short iperf3 tests against one AP and prints only when the wire under it
# drops: useful while wiggling a cable or a plug. Ctrl-C ends it with a summary.
#
#   wire-watch.sh [threshold Mbit/s] [seconds per test] [host]
#
# Defaults: threshold 1700, 3 s per test, host ap-main. Anything below the threshold
# prints a DROP line, a failed connection prints LOST, and everything else stays quiet.
set -uo pipefail

CONF="${OPENWRT_BENCH_HOSTS:-$HOME/.config/openwrt-bench/hosts}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

thr="${1:-1700}"
secs="${2:-3}"
host="${3:-${BENCH_WATCH_HOST:-ap-main}}"

ip=$(awk -v h="$host" '$1 == h { print $2 }' "$CONF" 2>/dev/null)
[[ -n "$ip" ]] || { echo "Error: $host not in $CONF" >&2; exit 1; }

"$HERE/bench.sh" serve "$host" >/dev/null 2>&1 || { echo "Error: no iperf3 server on $host" >&2; exit 1; }

tests=0 drops=0 worst=99999
summary() {
    "$HERE/bench.sh" stop "$host" >/dev/null 2>&1
    [[ "$worst" == 99999 ]] && worst=0
    echo "stopped after $tests tests: $drops drop(s), worst $worst Mbit/s (threshold $thr)"
}
trap summary EXIT
trap 'exit 130' INT TERM

echo "watching $host ($ip), threshold $thr Mbit/s, ${secs}s per test - only drops print, Ctrl-C to stop"
while :; do
    out=$(iperf3 -c "$ip" -P 4 -t "$secs" -J 2>/dev/null)
    tests=$((tests + 1))
    if [[ -z "$out" ]]; then
        drops=$((drops + 1))
        printf '%s  LOST  no result from %s\n' "$(date +%T)" "$host"
        sleep 1
        continue
    fi
    mbit=$(jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000 | floor' <<<"$out")
    ((mbit < worst)) && worst=$mbit
    if ((mbit < thr)); then
        drops=$((drops + 1))
        printf '%s  DROP  %s Mbit/s\n' "$(date +%T)" "$mbit"
    fi
done

#!/usr/bin/env bash
#
# timeline-patterns.sh — run the zymtrace timeline pattern API on one window and print a
# compact per-lane summary. The full response is saved to a file for jq or python3; it is never printed.
#
# Usage:
#   timeline-patterns.sh <gateway-url> <project-id> <start> <end> [--query '<CEL>'] [--occurrences] [--out <file>]
#
#   <start> <end>   Window as Unix epoch milliseconds (end exclusive). Keep it narrow: a few
#                   seconds to a few minutes of dense work. Windows above 1,000,000
#                   high-resolution events are rejected (exit code 3): halve and retry.
#   --query         CEL filter, e.g. 'k8s.pod.name == "trainer-0"' (same syntax as the query bar).
#   --occurrences   Also return every occurrence's extents. The file gets large: query it with
#                   jq or python3 (see reference.md § jq recipes).
#   --out           Output file (default: ${TMPDIR:-/tmp}/zymtrace/patterns_<start>_<end>[_occ].json,
#                   directory created if missing).
#
# Summary columns, per lane (one CUDA stream, or its sync lane), root patterns by total time:
#   count     occurrences in the window
#   span%     total occurrence time / window length. An occurrence runs from its first span's
#             start to its last span's end, idle inside included: this is not GPU-busy time.
#   dur_med   median occurrence duration (ms);  dur_max  slowest occurrence (ms)
#   dur_cv    stddev / mean of the duration (spread; high = unstable)
#   per_med   median start-to-start period (ms); gap_med = per_med - dur_med, the time between
#             repeats. Idle only if no other span on the lane falls in it (reference.md § jq recipes).
#   template  the repeated sequence: leaf (kernel/copy/sync) names, P<i> = nested pattern, xN = repeats
#   A run root (template "X xN": X repeated N times back to back) that occurs once reports the
#   N repeats instead (count, duration, period), so per_med is the cadence of X.
#
# Auth: export ZYMTRACE_API_TOKEN (or ZYMTRACE_MCP_TOKEN) when service-token auth is on.
# Needs project read access. Requires: curl, and jq or python3 for JSON (jq when it's
# installed, else python3).

set -euo pipefail

usage() { sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  JSON_TOOL=python3
else
  die "needs jq or python3 to handle JSON. Install jq (macOS 15+ ships it; brew install jq / apt-get install -y jq / dnf install -y jq)"
fi

# JSON operations, implemented twice: in jq (used when installed) and in python3 (fallback).
PY_ENGINE='
import json, math, re, sys

def rnd(x):
    # half away from zero, like jq round (Python round is half-to-even)
    return math.copysign(math.floor(abs(x) + 0.5), x)

def num(x):
    x = round(x, 3)
    return str(int(x)) if x == int(x) else repr(x)

def ms(ns):
    return num(rnd(ns / 1e6 * 1000) / 1000)

def short(s):
    return s[:45] + "..." if len(s) > 48 else s

op, args = sys.argv[1], sys.argv[2:]
if op == "body":
    f = {"start_ts": int(args[0]), "end_ts": int(args[1])}
    if args[2]:
        f["query"] = args[2]
    print(json.dumps({"filter": f}, separators=(",", ":")))
elif op == "summary":
    win_ns = int(args[0])
    with open(args[1]) as fh:
        doc = json.load(fh)
    leaves = doc["leaves"]
    if not doc["lanes"]:
        print("no high-resolution events in this window (high-resolution profiling was off, "
              "the scope matched nothing, or the GPU was idle)")
    for lane in doc["lanes"]:
        print("\nlane: " + " / ".join(lane["names"]))
        print("\t".join(["count", "span%", "dur_med", "dur_max", "dur_cv", "per_med", "gap_med", "template"]))
        roots = sorted((lane["patterns"][i] for i in lane["roots"]), key=lambda p: -p["duration"][3])[:8]
        for p in roots:
            d, per = p["duration"], p.get("period")
            if len(p["template"]) == 1 and "*" in p["template"][0] and p["duration"][0] == 1:
                d, per = p["elements"][0]["duration"], p["elements"][0].get("period")
            items = []
            for t in p["template"]:
                m = re.match(r"^([LP])([0-9]+)(?:\*([0-9]+))?$", t)
                if not m:
                    continue
                name = short(leaves[int(m.group(2))]) if m.group(1) == "L" else "P" + m.group(2)
                items.append(name + (" x" + m.group(3) if m.group(3) else ""))
            print("\t".join([
                num(d[0]),
                num(rnd(p["duration"][3] / win_ns * 1000) / 10),
                ms(d[5]),
                ms(d[2]),
                num(rnd(d[6] / d[4] * 100) / 100) if d[4] > 0 else "0",
                ms(per[5]) if per else "-",
                ms(per[5] - d[5]) if per else "-",
                " > ".join(items)]))
'

# json_op <operation> [args...]
json_op() {
  local op="$1"; shift
  if [ "$JSON_TOOL" = python3 ]; then python3 -c "$PY_ENGINE" "$op" "$@"; return; fi
  case "$op" in
    body) jq -nc --argjson s "$1" --argjson e "$2" --arg q "$3" \
      '{filter: ({start_ts: $s, end_ts: $e} + (if $q == "" then {} else {query: $q} end))}' ;;
    summary) jq -r --argjson win_ns "$1" '
      def ms: . / 1e6 | (. * 1000 | round) / 1000;
      def short: if length > 48 then .[0:45] + "..." else . end;
      .leaves as $L
      | if (.lanes | length) == 0 then
          "no high-resolution events in this window (high-resolution profiling was off, the scope matched nothing, or the GPU was idle)"
        else
          .lanes[] | . as $lane
          | "\nlane: \($lane.names | join(" / "))",
            (["count", "span%", "dur_med", "dur_max", "dur_cv", "per_med", "gap_med", "template"] | @tsv),
            ([$lane.roots[] | $lane.patterns[.]] | sort_by(-.duration[3]) | .[0:8][]
             | . as $p
             | (if ($p.template | length) == 1 and ($p.template[0] | contains("*")) and $p.duration[0] == 1
                then $p.elements[0] else $p end) as $s
             | [ $s.duration[0],
                 ($p.duration[3] / $win_ns * 1000 | round / 10),
                 ($s.duration[5] | ms),
                 ($s.duration[2] | ms),
                 (if $s.duration[4] > 0 then ($s.duration[6] / $s.duration[4] * 100 | round / 100) else 0 end),
                 (if $s.period then ($s.period[5] | ms) else "-" end),
                 (if $s.period then (($s.period[5] - $s.duration[5]) | ms) else "-" end),
                 ($p.template | map(
                    capture("^(?<k>[LP])(?<i>[0-9]+)(?:\\*(?<n>[0-9]+))?$") as $c
                    | (if $c.k == "L" then ($L[$c.i | tonumber] | short) else "P\($c.i)" end)
                      + (if $c.n then " x\($c.n)" else "" end)) | join(" > ")) ]
             | @tsv)
        end' "$2" ;;
  esac
}

[ $# -ge 4 ] || usage
GW="${1%/}"; GW="${GW%/mcp}"; PROJECT="$2"; START="$3"; END="$4"; shift 4
case "$GW" in http://*|https://*) ;; *) die "gateway URL must start with http:// or https://" ;; esac
[[ "$START" =~ ^[0-9]{13}$ && "$END" =~ ^[0-9]{13}$ ]] || die "start/end must be epoch milliseconds (13 digits)"
[ "$END" -gt "$START" ] || die "end must be after start"

QUERY=""; OCC=false; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --query) [ $# -ge 2 ] || die "--query needs a value"; QUERY="$2"; shift 2 ;;
    --occurrences) OCC=true; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a value"; OUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument '$1'" ;;
  esac
done
if [ -z "$OUT" ]; then
  OUT="${TMPDIR:-/tmp}"; OUT="${OUT%/}/zymtrace/patterns_${START}_${END}.json"
  if [ "$OCC" = true ]; then OUT="${OUT%.json}_occ.json"; fi
fi
mkdir -p "$(dirname "$OUT")" || die "cannot create $(dirname "$OUT")"

TOKEN="${ZYMTRACE_API_TOKEN:-${ZYMTRACE_MCP_TOKEN:-}}"
body=$(json_op body "$START" "$END" "$QUERY")

TMP="$OUT.partial"
args=(-sS -m 300 -o "$TMP" -w '%{http_code}' -X POST
      -H 'Accept: application/json' -H 'Content-Type: application/json' --data-binary "$body")
[ -n "$TOKEN" ] && args+=(-H "Authorization: Bearer $TOKEN")
code=$(curl "${args[@]}" "$GW/public/api/v1/projects/$PROJECT/timeline/pattern?occurrences=$OCC") \
  || { rm -f "$TMP"; die "request failed"; }

if [ "$code" != "200" ]; then
  msg=$(head -c 500 "$TMP"); rm -f "$TMP"
  if [ "$code" = "400" ] && grep -q 'events, above the' <<<"$msg"; then
    printf 'too many events: %s\n' "$msg" >&2
    exit 3
  fi
  case "$code" in
    401) printf 'hint: export ZYMTRACE_API_TOKEN with a service token (auth is on)\n' >&2 ;;
    403) printf 'hint: the token cannot read project %s\n' "$PROJECT" >&2 ;;
  esac
  die "HTTP $code: $msg"
fi
mv "$TMP" "$OUT"

window_ms=$((END - START))
secs=$(awk -v ms="$window_ms" 'BEGIN{printf "%.3f", ms/1000}')
echo "window: $START..$END ($secs s)  saved: $OUT  ($(wc -c <"$OUT" | tr -d ' ') bytes)"

json_op summary "$((window_ms * 1000000))" "$OUT"

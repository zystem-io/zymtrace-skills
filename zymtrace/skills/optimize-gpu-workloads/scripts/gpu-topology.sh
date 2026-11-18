#!/usr/bin/env bash
#
# gpu-topology.sh — GPU topology of the hosts in a scope, and how the profiled processes used it
# during one window. Saves both responses to files and prints a compact summary per host.
#
# Usage:
#   gpu-topology.sh <gateway-url> <project-id> <start> <end> [--query '<CEL>'] [--out-dir <dir>]
#
#   <start> <end>   The window of the GPU profile you're analyzing, as Unix epoch milliseconds
#                   (end exclusive). The topology is each host's latest snapshot before <end>;
#                   the NUMA placement and stall reasons cover the CUDA work inside the window.
#   --query         CEL over host.name, host.arch, user.tag, cluster.name, e.g.
#                   'host.name == "gpu-node-1"'. Scope it to the hosts of the profile: the NUMA
#                   placement scans every CUDA event of the matching hosts in the window.
#   --out-dir       Where to save topology_<start>_<end>_{hosts,analysis}.json
#                   (default: ${TMPDIR:-/tmp}/zymtrace, created if missing).
#
# Per host it prints:
#   numa      NUMA nodes: CPUs, memory, distance to the other nodes.
#   gpu       Physical GPUs in host order (GPU0..), their NUMA node (? = not reported or a
#             mask too wide to decode), NVLinks grouped by type
#             and version (Switch = to an NVSwitch, Gpu = direct, Inactive = down), and their row
#             of the connection matrix (as `nvidia-smi topo -m`: SELF, NV<n> = n NVLinks,
#             PIX/PXB = PCIe switch, PHB = PCIe host bridge, NODE = across host bridges in one
#             NUMA node, SYS = across NUMA nodes). MIG instances are listed under their GPU.
#   placement Per profiled process and GPU: the CPUs its CUDA work ran on in the window, and the
#             ones outside the GPU's NUMA node (empty = well placed).
#   stalls    PC-sampling stall categories in the window, host-wide and per GPU (only when PC
#             sampling is on).
#
# Sources: public POST /public/api/v1/project/{id}/host-metadata (topology) and the UI's
# internal POST /internal/api/v1/project/{id}/analyze (placement, stalls). The internal endpoint
# is unversioned; if it's missing the script still prints the topology and says what's missing.
#
# Auth: export ZYMTRACE_API_TOKEN (or ZYMTRACE_MCP_TOKEN) when service-token auth is on. Needs
# project read access. Requires: curl, and jq or python3 for JSON (jq when it's installed, else
# python3).

set -euo pipefail

usage() { sed -n '3,37p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
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
import json, math, sys

op, args = sys.argv[1], sys.argv[2:]

def ok(x):
    return x["Ok"] if isinstance(x, dict) and "Ok" in x else None

def rnd(x):  # round half away from zero, like jq
    return math.floor(x + 0.5)

def num(x):
    return str(int(x)) if x == int(x) else repr(x)

def gib(b):
    return num(rnd(b / 1073741824 * 10) / 10)

def pct(r):
    return num(rnd(r * 1000) / 10) + "%"

def ranges(cpus):
    out = []
    for c in sorted(set(cpus)):
        if out and out[-1][1] == c - 1:
            out[-1][1] = c
        else:
            out.append([c, c])
    return ",".join(str(a) if a == b else "%d-%d" % (a, b) for a, b in out)

def nodes_of(mask):  # None (printed ?) past 2^53, where jq loses precision
    if any(v >= 9007199254740992 for v in mask):
        return None
    return [w * 64 + j for w, v in enumerate(mask) for j in range(64) if (v >> j) & 1]

def join_ints(xs):
    return ",".join(str(x) for x in xs)

def short(u):
    return u.split("-", 1)[1] if u.startswith(("GPU-", "MIG-")) else u

def link_label(link):
    kind, val = next(iter(link.items()))
    v = val.get("version", "Invalid")
    return kind if v == "Invalid" else kind + " " + v.replace("Version", "").replace("_", ".")

def top(bottlenecks, n):
    return ", ".join(b["kind"] + " " + pct(b["ratio"]) for b in [b for b in sorted(bottlenecks, key=lambda b: -b["ratio"]) if b["ratio"] >= 0.0005][:n])

def gpu_name(i, uuid):
    return "GPU%d" % i if i is not None else uuid

if op == "hosts_body":
    body = {"start_ts": int(args[0]), "end_ts": int(args[1]), "page": {"page": 1, "page_size": 100}}
    if args[2]:
        body["query"] = args[2]
    print(json.dumps(body, separators=(",", ":")))
elif op == "analysis_body":
    with open(args[3]) as fh:
        opts = json.load(fh)["display_options"]
    body = {"start_ts": int(args[0]), "end_ts": int(args[1]), "page": {"page": 1, "page_size": 100}, "opts": opts}
    if args[2]:
        body["query"] = args[2]
    print(json.dumps(body, separators=(",", ":")))
elif op == "next_page":
    with open(args[0]) as fh:
        print((json.load(fh).get("pagination") or {}).get("next_page") or "")
elif op == "summary":
    with open(args[0]) as fh:
        hosts = json.load(fh)["hosts"]
    analysis = {}
    if args[1]:
        with open(args[1]) as fh:
            for a in json.load(fh)["hosts"]:
                analysis[a["host"]["host_name"]] = a
    if not hosts:
        print("no GPU hosts match (only hosts that report a GPU are listed)")
    for h in hosts:
        print("\nhost: " + h["host_name"] + ("  type: " + h["host_type"] if h.get("host_type") else ""))
        cpu, numa = ok(h.get("cpu")), ok(h.get("numa"))
        if cpu:
            print("cpu: %s, %d cores / %d threads, %s GiB" % (
                ", ".join(cpu["model"]), sum(cpu["num_cores"]), sum(cpu["num_threads"]), gib(cpu["memory"])))
        else:
            print("cpu: not reported")
        if numa:
            print("numa\tcpus\tmem_gib\tdistance")
            for n in numa["nodes"]:
                print("\t".join([str(n["id"]), ranges(n["cpus"]), gib(n["memory"]), join_ints(n["distance"])]))
        else:
            print("numa: not reported")
        phys = [g for g in h["gpus"] if "Physical" in g["kind"]]
        index = {short(g["uuid"]): i for i, g in enumerate(phys)}
        node_of = {}
        print("gpu\tuuid\tname\tmem_gib\tnuma\tnvlink\tmatrix (" + " ".join("GPU%d" % i for i in range(len(phys))) + ")")
        for i, g in enumerate(phys):
            p = g["kind"]["Physical"]
            mask = ok(p.get("memory_affinity"))
            nodes = nodes_of(mask) if mask is not None else None
            node_of[i] = nodes
            labels = [link_label(l) for l in p.get("links") or []]
            links = ", ".join("%dx %s" % (labels.count(l), l) for l in sorted(set(labels))) if labels else "none"
            conn = ok(p.get("connections"))
            print("\t".join(["GPU%d" % i, g["uuid"], g["name"], gib(g["memory"]),
                             join_ints(nodes) if nodes is not None else "?", links,
                             " ".join(conn) if conn is not None else "?"]))
        for g in h["gpus"]:
            if "Mig" in g["kind"]:
                m = g["kind"]["Mig"]
                prof = ok(m.get("mig_profile"))
                print("  MIG %s on %s, profile %s, %s GiB" % (
                    g["uuid"], gpu_name(index.get(short(m["parent_uuid"])), m["parent_uuid"]),
                    prof if prof is not None else "?", gib(g["memory"])))
        a = analysis.get(h["host_name"])
        if a is None:
            continue
        items = a["numa_issues"]["items"]
        if items:
            print("placement\tgpu\tgpu_numa\tcpus_seen\toff_node")
            rows = []
            for it in items:
                i = index.get(short(it["gpu_uuid"]))
                proc = (it["process"].get("script_name") or it["process"]["main_exe"]).rsplit("/", 1)[-1]
                off = it["info"]["non_affine_cpus"]
                nodes = node_of.get(i) if i is not None else None
                rows.append((i if i is not None else 1 << 30, "\t".join([
                    proc, gpu_name(i, it["gpu_uuid"]),
                    join_ints(nodes) if nodes is not None else "?",
                    str(len(it["info"]["on_cpus"])),
                    "%d (%s)" % (len(off), ranges(off)) if off else "0"])))
            for _, row in sorted(rows, key=lambda r: r[0]):
                print(row)
        else:
            print("placement: no CUDA work with CPU ids in the window")
        for e in a["numa_issues"].get("errors") or []:
            print("placement error: " + (e if isinstance(e, str) else json.dumps(e, separators=(",", ":"))))
        gb = a["gpu_bottlenecks"]
        if any(b["ratio"] > 0 for b in gb["host_wide"]):
            print("stalls host-wide: " + top(gb["host_wide"], 8))
            for it in sorted(gb["per_gpu"]["items"], key=lambda x: index.get(short(x["gpu_uuid"]), 1 << 30)):
                print("stalls %s: %s" % (gpu_name(index.get(short(it["gpu_uuid"])), it["gpu_uuid"]), top(it["bottlenecks"], 3)))
        else:
            print("stalls: none in the window (PC sampling off or no samples)")
'

JQ_DEFS='
def ok: if type == "object" and has("Ok") then .Ok else null end;
def num: if . == floor then floor | tostring else tostring end;
def gib: . / 1073741824 * 10 | round / 10 | num;
def pct: (. * 1000 | round / 10 | num) + "%";
def ranges: sort | unique
  | reduce .[] as $c ([]; if length > 0 and .[-1][1] == $c - 1 then .[-1][1] = $c else . + [[$c, $c]] end)
  | map(if .[0] == .[1] then "\(.[0])" else "\(.[0])-\(.[1])" end) | join(",");
def nz: if . == "" or . == false then null else . end;
def nodes_of: if any(.[]; . >= 9007199254740992) then null else [to_entries[] | .key as $w | .value as $v | range(0; 64) as $j
  | select((($v / pow(2; $j)) | floor) % 2 == 1) | $w * 64 + $j] end;
def short: sub("^(GPU|MIG)-"; "");
def link_label: to_entries[0] | (.value.version // "Invalid") as $v
  | if $v == "Invalid" then .key else "\(.key) \($v | sub("^Version"; "") | sub("_"; "."))" end;
def top($n): [sort_by(-.ratio)[] | select(.ratio >= 0.0005)][0:$n] | map("\(.kind) \(.ratio | pct)") | join(", ");
'

# json_op <operation> [args...]
json_op() {
  local op="$1"; shift
  if [ "$JSON_TOOL" = python3 ]; then python3 -c "$PY_ENGINE" "$op" "$@"; return; fi
  case "$op" in
    hosts_body) jq -nc --argjson s "$1" --argjson e "$2" --arg q "$3" \
      '{start_ts: $s, end_ts: $e, page: {page: 1, page_size: 100}} + (if $q == "" then {} else {query: $q} end)' ;;
    analysis_body) jq -c --argjson s "$1" --argjson e "$2" --arg q "$3" \
      '{start_ts: $s, end_ts: $e, page: {page: 1, page_size: 100}, opts: .display_options}
       + (if $q == "" then {} else {query: $q} end)' "$4" ;;
    next_page) jq -r '.pagination.next_page // empty' "$1" ;;
    summary)
      local analysis_file="${2:-}"
      [ -n "$analysis_file" ] || analysis_file=/dev/null
      jq -r -n --slurpfile hm "$1" --rawfile an "$analysis_file" "$JQ_DEFS"'
        (if $an == "" then {} else ($an | fromjson | [.hosts[] | {key: .host.host_name, value: .}] | from_entries) end) as $A
        | if ($hm[0].hosts | length) == 0 then "no GPU hosts match (only hosts that report a GPU are listed)" else
        $hm[0].hosts[] as $h
        | ($h.cpu | ok) as $cpu | ($h.numa | ok) as $numa
        | [$h.gpus[] | select(.kind.Physical)] as $phys
        | ($phys | to_entries | map({key: (.value.uuid | short), value: .key}) | from_entries) as $index
        | [$phys[] | .kind.Physical.memory_affinity | ok | if . == null then null else nodes_of end] as $nodes
        | "\nhost: \($h.host_name)" + (if ($h.host_type // "") != "" then "  type: \($h.host_type)" else "" end),
          (if $cpu then "cpu: \($cpu.model | join(", ")), \($cpu.num_cores | add) cores / \($cpu.num_threads | add) threads, \($cpu.memory | gib) GiB" else "cpu: not reported" end),
          (if $numa then ("numa\tcpus\tmem_gib\tdistance",
             ($numa.nodes[] | "\(.id)\t\(.cpus | ranges)\t\(.memory | gib)\t\(.distance | map(tostring) | join(","))"))
           else "numa: not reported" end),
          ("gpu\tuuid\tname\tmem_gib\tnuma\tnvlink\tmatrix (" + ([range(0; $phys | length) | "GPU\(.)"] | join(" ")) + ")"),
          ($phys | to_entries[] | .key as $i | .value as $g | $g.kind.Physical as $p
           | [($p.links // [])[] | link_label] as $labels
           | ($p.connections | ok) as $conn
           | ["GPU\($i)", $g.uuid, $g.name, ($g.memory | gib),
              (if $nodes[$i] == null then "?" else ($nodes[$i] | map(tostring) | join(",")) end),
              (if ($labels | length) == 0 then "none" else ($labels | group_by(.) | map("\(length)x \(.[0])") | join(", ")) end),
              (if $conn == null then "?" else ($conn | join(" ")) end)] | join("\t")),
          ($h.gpus[] | select(.kind.Mig) | .kind.Mig as $m | $index[$m.parent_uuid | short] as $parent
           | "  MIG \(.uuid) on \(if $parent == null then $m.parent_uuid else "GPU\($parent)" end), profile \(($m.mig_profile | ok) // "?"), \(.memory | gib) GiB"),
          ($A[$h.host_name] as $a
           | if $a == null then empty else
               (if ($a.numa_issues.items | length) > 0 then
                  ("placement\tgpu\tgpu_numa\tcpus_seen\toff_node",
                   ($a.numa_issues.items
                    | map(. as $it | $index[$it.gpu_uuid | short] as $i
                      | {i: ($i // 1073741824), row: ([
                          ((($it.process.script_name | nz) // $it.process.main_exe) | split("/") | last),
                          (if $i == null then $it.gpu_uuid else "GPU\($i)" end),
                          (if $i == null or $nodes[$i] == null then "?" else ($nodes[$i] | map(tostring) | join(",")) end),
                          ($it.info.on_cpus | length | tostring),
                          (if ($it.info.non_affine_cpus | length) == 0 then "0"
                           else "\($it.info.non_affine_cpus | length) (\($it.info.non_affine_cpus | ranges))" end)
                        ] | join("\t"))})
                    | sort_by(.i) | .[].row))
                else "placement: no CUDA work with CPU ids in the window" end),
               (($a.numa_issues.errors // [])[] | "placement error: \(.)"),
               ($a.gpu_bottlenecks as $gb
                | if ([$gb.host_wide[] | select(.ratio > 0)] | length) > 0 then
                    ("stalls host-wide: \($gb.host_wide | top(8))",
                     ($gb.per_gpu.items | map(. as $it | {i: ($index[$it.gpu_uuid | short] // 1073741824), it: $it})
                      | sort_by(.i) | .[]
                      | "stalls \(if .i == 1073741824 then .it.gpu_uuid else "GPU\(.i)" end): \(.it.bottlenecks | top(3))"))
                  else "stalls: none in the window (PC sampling off or no samples)" end)
             end)
        end' ;;
  esac
}

[ $# -ge 4 ] || usage
GW="${1%/}"; GW="${GW%/mcp}"; PROJECT="$2"; START="$3"; END="$4"; shift 4
case "$GW" in http://*|https://*) ;; *) die "gateway URL must start with http:// or https://" ;; esac
[[ "$START" =~ ^[0-9]{13}$ && "$END" =~ ^[0-9]{13}$ ]] || die "start/end must be epoch milliseconds (13 digits)"
[ "$END" -gt "$START" ] || die "end must be after start"

QUERY=""; OUT_DIR="${TMPDIR:-/tmp}/zymtrace"
while [ $# -gt 0 ]; do
  case "$1" in
    --query) [ $# -ge 2 ] || die "--query needs a value"; QUERY="$2"; shift 2 ;;
    --out-dir) [ $# -ge 2 ] || die "--out-dir needs a value"; OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument '$1'" ;;
  esac
done
mkdir -p "$OUT_DIR"
HOSTS="$OUT_DIR/topology_${START}_${END}_hosts.json"
ANALYSIS="$OUT_DIR/topology_${START}_${END}_analysis.json"
TOKEN="${ZYMTRACE_API_TOKEN:-${ZYMTRACE_MCP_TOKEN:-}}"

# api METHOD PATH OUT [BODY] -> HTTP status on stdout; the body goes to OUT (cleared first, so a
# failed request never shows an earlier run's file).
api() {
  rm -f "$3"
  local args=(-sS -m 120 -o "$3" -w '%{http_code}' -X "$1" -H 'Accept: application/json')
  [ -n "$TOKEN" ] && args+=(-H "Authorization: Bearer $TOKEN")
  [ $# -ge 4 ] && args+=(-H 'Content-Type: application/json' --data-binary "$4")
  curl "${args[@]}" "$GW$2" || true
}

code=$(api POST "/public/api/v1/project/$PROJECT/host-metadata" "$HOSTS" "$(json_op hosts_body "$START" "$END" "$QUERY")")
if [ "$code" != "200" ]; then
  msg=$(head -c 500 "$HOSTS" 2>/dev/null || true); rm -f "$HOSTS"
  case "$code" in
    401) printf 'hint: export ZYMTRACE_API_TOKEN with a service token (auth is on)\n' >&2 ;;
    403) printf 'hint: the token cannot read project %s\n' "$PROJECT" >&2 ;;
  esac
  die "host-metadata: HTTP $code: $msg"
fi
if [ -n "$(json_op next_page "$HOSTS")" ]; then
  printf 'warning: more than 100 GPU hosts match; only the first 100 are shown. Narrow --query to the hosts of the profile.\n' >&2
fi

# Placement and stalls: the internal analyze endpoint, with the instance's default display options.
analysis_ok=""
BOOT=$(mktemp "${TMPDIR:-/tmp}/zymtrace_bootstrap.XXXXXX")
trap 'rm -f "$BOOT"' EXIT
trap 'exit 130' INT TERM
code=$(api GET "/internal/api/v1/bootstrap" "$BOOT")
if [ "$code" = "200" ]; then
  code=$(api POST "/internal/api/v1/project/$PROJECT/analyze" "$ANALYSIS" "$(json_op analysis_body "$START" "$END" "$QUERY" "$BOOT")")
  if [ "$code" = "200" ]; then analysis_ok=1; else
    printf 'warning: NUMA placement and stalls not measured: internal analyze API returned HTTP %s: %s\n' \
      "$code" "$(head -c 300 "$ANALYSIS" 2>/dev/null || true)" >&2
    rm -f "$ANALYSIS"
  fi
else
  printf 'warning: NUMA placement and stalls not measured: internal bootstrap API returned HTTP %s\n' "$code" >&2
fi

echo "window: $START..$END  saved: $HOSTS${analysis_ok:+, $ANALYSIS}"
json_op summary "$HOSTS" "${analysis_ok:+$ANALYSIS}"

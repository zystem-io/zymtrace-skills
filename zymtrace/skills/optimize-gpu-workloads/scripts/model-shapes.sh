#!/usr/bin/env bash
#
# model-shapes.sh — the models a scope ran in a window, and one model's module tree (tensor
# shapes, dtypes, TP sharding). Saves the responses to files and prints a compact summary.
#
# Usage:
#   model-shapes.sh <gateway-url> <project-id> <start> <end> [--query '<CEL>']
#                   [--shape <ids> [--module <path>]] [--out-dir <dir>]
#
#   <start> <end>   The window of the GPU profile, as Unix epoch milliseconds (end exclusive).
#                   Models whose first/last seen overlaps it are listed.
#   --query         CEL over host.name, process.executable.name, script.name, job.tag,
#                   container.name, k8s.pod.name, k8s.deployment.name, k8s.namespace.name,
#                   slurm.job.id, slurm.job.name, slurm.job.user, user.tag, cluster.name.
#                   Use the same scope as the profile.
#   --shape <ids>   The shape_ids of one listed model (comma-separated, as printed). Prints the
#                   model's structure and the GEMM weights whose per-rank dimensions aren't a
#                   multiple of 64.
#   --module <path> With --shape: every module at or under <path>, with its tensors. <path> is the
#                   `file` of a Model Layer frame (e.g. model.layers.12.self_attn).
#   --out-dir       Where to save models_<start>_<end>.json and shape_<first id>.json
#                   (default: ${TMPDIR:-/tmp}/zymtrace, created if missing).
#
# List columns: model (serving name), architecture, params_b (billions), tp, pp, processes,
# hosts, first/last seen, shape_ids. Tensor shapes are logical (whole-model) shapes; a tensor that
# vLLM tensor parallelism splits has `sharded=<dim>`, and its per-rank size on that dim is the
# shape divided by tp.
#
# Source: the UI's internal API (/internal/api/v1/project/{id}/models), which is unversioned —
# used here until the MCP has a models tool. Needs zymtrace 26.10.3+ and model shapes on the
# workload (ZYMTRACE_CUDAPROFILER__MODEL_SHAPE__ENABLED=true; on AMD,
# ZYMTRACE_ROCMPROFILER__MODEL_SHAPE__ENABLED=true).
#
# Auth: export ZYMTRACE_API_TOKEN (or ZYMTRACE_MCP_TOKEN) when service-token auth is on. Needs
# project read access. Requires: curl, and jq or python3 for JSON (jq when it's installed, else
# python3).

set -euo pipefail

usage() { sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  JSON_TOOL=python3
else
  die "needs jq or python3 to handle JSON. Install jq (macOS 15+ ships it; brew install jq / apt-get install -y jq / dnf install -y jq)"
fi

MAX_STRUCTURE=60  # structure rows printed
MAX_MODULES=80    # --module rows printed
MAX_ALIGN=40      # alignment rows printed

# JSON operations, implemented twice: in jq (used when installed) and in python3 (fallback).
PY_ENGINE='
import json, math, re, sys

op, args = sys.argv[1], sys.argv[2:]

def rnd(x):  # round half away from zero, like jq
    return math.floor(x + 0.5)

def num(x):
    return str(int(x)) if x == int(x) else repr(x)

def collapse(path):
    return ".".join("*" if re.match(r"^[0-9]+$", s) else s for s in path.split(".")) if path else ""

def depth(path):
    return len(path.split(".")) if path else 0

def fmt_shape(shape):
    return "[" + ",".join(num(x) for x in shape) + "]"

def tensor_text(t):
    s = t["name"] + " " + t["dtype"] + " " + fmt_shape(t["shape"])
    if t.get("sharded_dim") is not None:
        s += " sharded=" + str(t["sharded_dim"])
    if t.get("alias_of"):
        s += " alias=" + t["alias_of"]
    if t.get("packed_bits") is not None:
        s += " packed=" + str(t["packed_bits"])
    if t.get("is_buffer"):
        s += " buffer"
    return s

def load(path):
    with open(path) as fh:
        return json.load(fh)

def entry_for(models, ids):
    for m in models:
        if ",".join(m["shape_ids"]) == ids:
            return m
    return None

if op == "list_body":
    body = {"start_ts": int(args[0]), "end_ts": int(args[1])}
    if args[2]:
        body["query"] = args[2]
    print(json.dumps(body, separators=(",", ":")))
elif op == "list":
    models = load(args[0])["models"]
    if not models:
        print("no models in this window and scope (model shapes off, no PyTorch model loaded, or the scope matched nothing)")
    else:
        print("model\tarchitecture\tparams_b\ttp\tpp\tprocesses\thosts\tfirst_seen\tlast_seen\tshape_ids")
    for m in models:
        print("\t".join([m.get("serving_name") or "(no identity)", m.get("model_architecture") or "?",
                         num(rnd(m["param_count"] / 1e7) / 100), str(m["tp_size"]), str(m["pp_size"]),
                         str(m["process_count"]), str(m["host_count"]), str(m["first_seen"]), str(m["last_seen"]),
                         ",".join(m["shape_ids"])]))
elif op == "shape":
    shape, models, ids = load(args[0]), load(args[1])["models"], args[2]
    max_structure, max_align = int(args[3]), int(args[4])
    m = entry_for(models, ids)
    tp = m["tp_size"] if m else 1
    print("model: %s  architecture: %s  params: %s B  modules: %d  tp %s x pp %s" % (
        (m.get("serving_name") or "(no identity)") if m else "?", (m.get("model_architecture") or "?") if m else "?",
        num(rnd(shape["param_count"] / 1e7) / 100), len(shape["modules"]),
        m["tp_size"] if m else "? (assumed 1)", m["pp_size"] if m else "?"))
    groups = {}
    for mod in shape["modules"]:
        p = collapse(mod["path"])
        if depth(p) > 4:
            continue
        key = (p, mod["class_name"])
        g = groups.setdefault(key, {"count": 0, "params": 0})
        g["count"] += 1
        g["params"] = max(g["params"], mod["param_count"])
    print("structure (numbered siblings collapsed to *, depth <= 4):")
    print("path\tclass\tcount\tparams_m_each")
    rows = list(groups.items())
    for (p, c), g in rows[:max_structure]:
        print("\t".join([p or "(root)", c, str(g["count"]), num(rnd(g["params"] / 1e5) / 10)]))
    if len(rows) > max_structure:
        print("... %d more rows (drill in with --module <path>)" % (len(rows) - max_structure))
    align = {}
    for mod in shape["modules"]:
        if not re.search(r"linear|lmhead", mod["class_name"], re.I):
            continue
        for t in mod["tensors"]:
            if t["name"] != "weight" or len(t["shape"]) != 2 or t.get("is_buffer") or t.get("packed_bits") is not None:
                continue
            local = [x / tp if t.get("sharded_dim") == d else x for d, x in enumerate(t["shape"])]
            if all(x == int(x) and int(x) % 64 == 0 for x in local):
                continue
            key = (collapse(mod["path"]), mod["class_name"], t["dtype"], fmt_shape(t["shape"]), fmt_shape(local))
            align[key] = align.get(key, 0) + 1
    print("gemm weights with a per-rank dim that is not a multiple of 64 (tp %s):" % tp)
    if not align:
        print("none")
    else:
        print("module\tclass\tdtype\tshape\tper_rank\tcount")
        items = list(align.items())
        for (p, c, dt, s, l), n in items[:max_align]:
            print("\t".join([p + ".weight", c, dt, s, l, str(n)]))
        if len(items) > max_align:
            print("... %d more rows" % (len(items) - max_align))
elif op == "module":
    shape, prefix, max_modules = load(args[0]), args[1], int(args[2])
    mods = [m for m in shape["modules"] if m["path"] == prefix or m["path"].startswith(prefix + ".")]
    if not mods:
        print("no module at " + prefix + " (paths look like model.layers.12.self_attn: copy the layer frame file field)")
    else:
        print("path\tclass\tparams_m\ttensors")
    for m in mods[:max_modules]:
        print("\t".join([m["path"], m["class_name"], num(rnd(m["param_count"] / 1e5) / 10),
                         "; ".join(tensor_text(t) for t in m["tensors"]) or "-"]))
    if len(mods) > max_modules:
        print("... %d more modules (narrow --module)" % (len(mods) - max_modules))
'

JQ_DEFS='
def nz: if . == "" or . == false then null else . end;
def num: if . == floor then floor | tostring else tostring end;
def collapse: if . == "" then "" else split(".") | map(if test("^[0-9]+$") then "*" else . end) | join(".") end;
def depth: if . == "" then 0 else split(".") | length end;
def fmt_shape: "[" + (map(num) | join(",")) + "]";
def tensor_text: "\(.name) \(.dtype) \(.shape | fmt_shape)"
  + (if .sharded_dim != null then " sharded=\(.sharded_dim)" else "" end)
  + (if (.alias_of | nz) then " alias=\(.alias_of)" else "" end)
  + (if .packed_bits != null then " packed=\(.packed_bits)" else "" end)
  + (if .is_buffer then " buffer" else "" end);
'

# json_op <operation> [args...]
json_op() {
  local op="$1"; shift
  if [ "$JSON_TOOL" = python3 ]; then python3 -c "$PY_ENGINE" "$op" "$@"; return; fi
  case "$op" in
    list_body) jq -nc --argjson s "$1" --argjson e "$2" --arg q "$3" \
      '{start_ts: $s, end_ts: $e} + (if $q == "" then {} else {query: $q} end)' ;;
    list) jq -r "$JQ_DEFS"'
      .models
      | if length == 0 then "no models in this window and scope (model shapes off, no PyTorch model loaded, or the scope matched nothing)"
        else ("model\tarchitecture\tparams_b\ttp\tpp\tprocesses\thosts\tfirst_seen\tlast_seen\tshape_ids",
              (.[] | [((.serving_name | nz) // "(no identity)"), ((.model_architecture | nz) // "?"),
                      (.param_count / 1e7 | round / 100 | num), (.tp_size | tostring), (.pp_size | tostring),
                      (.process_count | tostring), (.host_count | tostring), (.first_seen | tostring), (.last_seen | tostring),
                      (.shape_ids | join(","))] | join("\t")))
        end' "$1" ;;
    shape) jq -r -n --slurpfile s "$1" --slurpfile l "$2" --arg ids "$3" \
             --argjson max_structure "$4" --argjson max_align "$5" "$JQ_DEFS"'
      $s[0] as $shape
      | ([$l[0].models[] | select((.shape_ids | join(",")) == $ids)][0]) as $m
      | (if $m then $m.tp_size else 1 end) as $tp
      | "model: \(if $m then (($m.serving_name | nz) // "(no identity)") else "?" end)  architecture: \(if $m then (($m.model_architecture | nz) // "?") else "?" end)  params: \($shape.param_count / 1e7 | round / 100 | num) B  modules: \($shape.modules | length)  tp \(if $m then $m.tp_size else "? (assumed 1)" end) x pp \(if $m then $m.pp_size else "?" end)",
        "structure (numbered siblings collapsed to *, depth <= 4):",
        "path\tclass\tcount\tparams_m_each",
        ([$shape.modules | to_entries[] | (.value.path | collapse) as $p | select(($p | depth) <= 4)
          | {i: .key, p: $p, c: .value.class_name, n: .value.param_count}]
         | group_by([.p, .c]) | map({i: (map(.i) | min), p: .[0].p, c: .[0].c, count: length, params: (map(.n) | max)})
         | sort_by(.i) as $rows
         | ($rows[0:$max_structure][] | [(if .p == "" then "(root)" else .p end), .c, (.count | tostring), (.params / 1e5 | round / 10 | num)] | join("\t")),
           (if ($rows | length) > $max_structure then "... \(($rows | length) - $max_structure) more rows (drill in with --module <path>)" else empty end)),
        "gemm weights with a per-rank dim that is not a multiple of 64 (tp \($tp)):",
        ([$shape.modules | to_entries[] | .key as $i | .value as $mod
          | select($mod.class_name | test("linear|lmhead"; "i"))
          | $mod.tensors[] | select(.name == "weight" and (.shape | length) == 2 and (.is_buffer | not) and .packed_bits == null)
          | . as $t | [range(0; 2) as $d | $t.shape[$d] | if $t.sharded_dim == $d then . / $tp else . end] as $local
          | select(any($local[]; . != floor or (. % 64) != 0))
          | {i: $i, key: [($mod.path | collapse), $mod.class_name, $t.dtype, ($t.shape | fmt_shape), ($local | fmt_shape)]}]
         | group_by(.key) | map({i: (map(.i) | min), key: .[0].key, n: length}) | sort_by(.i) as $rows
         | if ($rows | length) == 0 then "none" else
             ("module\tclass\tdtype\tshape\tper_rank\tcount",
              ($rows[0:$max_align][] | [(.key[0] + ".weight"), .key[1], .key[2], .key[3], .key[4], (.n | tostring)] | join("\t")),
              (if ($rows | length) > $max_align then "... \(($rows | length) - $max_align) more rows" else empty end))
           end)' ;;
    module) jq -r --arg prefix "$2" --argjson max_modules "$3" "$JQ_DEFS"'
      [.modules[] | select(.path == $prefix or (.path | startswith($prefix + ".")))] as $mods
      | if ($mods | length) == 0 then "no module at \($prefix) (paths look like model.layers.12.self_attn: copy the layer frame file field)"
        else ("path\tclass\tparams_m\ttensors",
              ($mods[0:$max_modules][] | [.path, .class_name, (.param_count / 1e5 | round / 10 | num),
                (if (.tensors | length) == 0 then "-" else (.tensors | map(tensor_text) | join("; ")) end)] | join("\t")),
              (if ($mods | length) > $max_modules then "... \(($mods | length) - $max_modules) more modules (narrow --module)" else empty end))
        end' "$1" ;;
  esac
}

[ $# -ge 4 ] || usage
GW="${1%/}"; GW="${GW%/mcp}"; PROJECT="$2"; START="$3"; END="$4"; shift 4
case "$GW" in http://*|https://*) ;; *) die "gateway URL must start with http:// or https://" ;; esac
[[ "$START" =~ ^[0-9]{13}$ && "$END" =~ ^[0-9]{13}$ ]] || die "start/end must be epoch milliseconds (13 digits)"
[ "$END" -gt "$START" ] || die "end must be after start"

QUERY=""; SHAPE=""; MODULE=""; OUT_DIR="${TMPDIR:-/tmp}/zymtrace"
while [ $# -gt 0 ]; do
  case "$1" in
    --query) [ $# -ge 2 ] || die "--query needs a value"; QUERY="$2"; shift 2 ;;
    --shape) [ $# -ge 2 ] || die "--shape needs a value"; SHAPE="$2"; shift 2 ;;
    --module) [ $# -ge 2 ] || die "--module needs a value"; MODULE="$2"; shift 2 ;;
    --out-dir) [ $# -ge 2 ] || die "--out-dir needs a value"; OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -z "$MODULE" ] || [ -n "$SHAPE" ] || die "--module needs --shape"
[ -z "$SHAPE" ] || [[ "$SHAPE" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--shape takes the comma-separated shape_ids of one model, as listed"
mkdir -p "$OUT_DIR"
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

# fail WHAT CODE FILE: explain a non-200 response and exit.
fail() {
  local msg; msg=$(head -c 500 "$3" 2>/dev/null || true); rm -f "$3"
  case "$2" in
    401) printf 'hint: export ZYMTRACE_API_TOKEN with a service token (auth is on)\n' >&2 ;;
    403) printf 'hint: the token cannot read project %s\n' "$PROJECT" >&2 ;;
    404) [ "$1" = models ] && printf 'hint: this instance has no models API; model shapes need zymtrace 26.10.3+\n' >&2 ;;
  esac
  die "$1: HTTP $2: $msg"
}

LIST="$OUT_DIR/models_${START}_${END}.json"
code=$(api POST "/internal/api/v1/project/$PROJECT/models" "$LIST" "$(json_op list_body "$START" "$END" "$QUERY")")
[ "$code" = "200" ] || fail models "$code" "$LIST"

if [ -z "$SHAPE" ]; then
  echo "window: $START..$END  saved: $LIST"
  json_op list "$LIST"
  exit 0
fi

SHAPE_FILE="$OUT_DIR/shape_${SHAPE%%,*}.json"
code=$(api GET "/internal/api/v1/project/$PROJECT/models/$SHAPE" "$SHAPE_FILE")
[ "$code" = "200" ] || fail shape "$code" "$SHAPE_FILE"
echo "window: $START..$END  saved: $LIST, $SHAPE_FILE"
if [ -n "$MODULE" ]; then
  json_op module "$SHAPE_FILE" "$MODULE" "$MAX_MODULES"
else
  json_op shape "$SHAPE_FILE" "$LIST" "$SHAPE" "$MAX_STRUCTURE" "$MAX_ALIGN"
fi

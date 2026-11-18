#!/usr/bin/env bash
#
# high-res-rule.sh — turn zymtrace high-resolution profiling on and off through the public
# agent-config API, once or on a schedule. High-resolution profiling feeds the GPU timeline
# and the timeline pattern API.
#
# Usage:
#   high-res-rule.sh <gateway-url> list
#   high-res-rule.sh <gateway-url> hosts
#   high-res-rule.sh <gateway-url> enable  --expr '<CEL>' [--duration 5m] [--project <uuid>] [--apply]
#   high-res-rule.sh <gateway-url> disable [--expr '<CEL>'] [--project <uuid>] [--apply]
#   high-res-rule.sh <gateway-url> run     --expr '<CEL>' --duration 2m --every 20m [--project <uuid>] [--apply]
#
#   list     Print every high-resolution rule with its scope and expiry.
#   hosts    Print the hosts with GPUs that reported in the last hour (to pick a scope).
#   enable   Add a high-resolution-only rule for --expr that expires after --duration
#            (1s to 10m, default 5m: the UI's limits). It replaces an earlier
#            high-resolution-only rule with the same --expr and --project, so repeated
#            calls (e.g. from cron) don't pile up.
#   disable  Remove high-resolution-only rules: those with this --expr (and --project, if
#            given), or all of them without --expr.
#   run      Capture on a schedule until stopped: on for --duration (1s to 10m), every
#            --every. The rule is removed after each window and on Ctrl-C / SIGTERM. Each
#            rule also expires on its own after --duration plus up to 60s, never past 10m,
#            so a killed run cleans up by itself.
#
# enable, disable and run are DRY RUNS unless --apply is given. The API replaces the whole
# rule list, so every write reads the list and its version first, changes only the
# high-resolution rules of this scope, and writes it back with that version, retrying if
# someone else saved in between.
#
# Timing: rule changes reach the profilers within about 60s (ingest re-reads the rules
# every 30s and each profiler polls ingest every 30s), and expiry is enforced on the same
# schedule. A capture window can start and end up to about a minute late.
#
# Auth: if the backend has auth on, export ZYMTRACE_API_TOKEN; with auth off, nothing is
# needed. The token is only read from the environment. Exit code 4 means the token isn't
# allowed to change agent config (HTTP 403): service tokens can't today, so turn
# high-resolution profiling on in the UI instead.
#
# Requires: curl, and jq or python3 for JSON (jq when it's installed, else python3).

set -euo pipefail

usage() { sed -n '3,41p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

command -v curl >/dev/null || die "curl is required"
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  JSON_TOOL=python3
else
  die "needs jq or python3 to handle JSON. Install jq (macOS 15+ ships it; brew install jq / apt-get install -y jq / dnf install -y jq)"
fi

[ $# -ge 2 ] || usage
GW="${1%/}"
CMD="$2"
shift 2
case "$GW" in http://*|https://*) ;; *) die "gateway URL must start with http:// or https:// (got '$GW')" ;; esac
GW="${GW%/mcp}"

EXPR=""; EXPR_SET=0; DURATION="5m"; EVERY=""; PROJECT=""; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --expr) [ $# -ge 2 ] || die "--expr needs a value"; EXPR="$2"; EXPR_SET=1; shift 2 ;;
    --duration) [ $# -ge 2 ] || die "--duration needs a value"; DURATION="$2"; shift 2 ;;
    --every) [ $# -ge 2 ] || die "--every needs a value"; EVERY="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument '$1'" ;;
  esac
done

MAX_SECS=600   # the UI's upper limit for a high-resolution rule
GRACE_SECS=60  # run: keep each rule alive past --duration to cover propagation

# api METHOD PATH [BODY] -> response body on stdout. Returns 4 on HTTP 403 (not allowed,
# retrying won't help) and 1 on any other failure; the reason goes to stderr.
api() {
  local method="$1" path="$2" body="${3:-}" out code
  out=$(mktemp)
  local args=(-sS -m 30 -o "$out" -w '%{http_code}' -X "$method" -H 'Accept: application/json')
  if [ -n "${ZYMTRACE_API_TOKEN:-}" ]; then args+=(-H "Authorization: Bearer $ZYMTRACE_API_TOKEN"); fi
  if [ -n "$body" ]; then args+=(-H 'Content-Type: application/json' --data-binary "$body"); fi
  if ! code=$(curl "${args[@]}" "$GW/public/api/v1$path"); then
    rm -f "$out"; printf 'error: request to %s failed\n' "$path" >&2; return 1
  fi
  if [ "${code:0:1}" != "2" ]; then
    printf 'error: %s %s returned HTTP %s: %s\n' "$method" "$path" "$code" "$(head -c 500 "$out")" >&2
    case "$code" in
      401) printf 'hint: auth is on: export ZYMTRACE_API_TOKEN with a service token\n' >&2 ;;
      403)
        if [[ "$path" == /agent/config/* ]]; then
          printf 'not allowed: this token cannot change agent config. No service token can today, so with auth on, turn high-resolution profiling on in the UI instead: the button on the CUDA timeline page, or Settings -> Agent Config -> CUDA Profiler -> Add Rule -> High-resolution profiling.\n' >&2
        else
          printf 'not allowed: this token cannot list agents (needs admin:audit:read); pick the scope with the MCP discover tools instead.\n' >&2
        fi
        rm -f "$out"; return 4 ;;
    esac
    rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

# Duration like 30s, 5m, 2m30s or 1h -> seconds. Plain numbers are rejected on purpose.
to_secs() {
  local d="$1" total=0
  if [[ -z "$d" || ! "$d" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]]; then
    die "durations look like 30s, 5m, 2m30s or 1h (got '$d')"
  fi
  if [[ "$d" =~ ([0-9]+)h ]]; then total=$((total + BASH_REMATCH[1] * 3600)); fi
  if [[ "$d" =~ ([0-9]+)m ]]; then total=$((total + BASH_REMATCH[1] * 60)); fi
  if [[ "$d" =~ ([0-9]+)s ]]; then total=$((total + BASH_REMATCH[1])); fi
  echo "$total"
}

# Capture length: 1s..10m, like the UI.
capture_secs() {
  local s
  s=$(to_secs "$1") || exit 1
  if [ "$s" -lt 1 ] || [ "$s" -gt "$MAX_SECS" ]; then die "--duration must be between 1s and 10m (got '$1')"; fi
  echo "$s"
}

require_expr() {
  if [ "$EXPR_SET" -ne 1 ] || [ -z "${EXPR// /}" ]; then
    die "--expr is required: scope high-resolution profiling to a pod, container, process or host (it has high overhead)"
  fi
}

# `ours` selects the high-resolution-only rules this call manages: those with this
# expression (any expression: $all) and this project (any project: $anyproj).
ALL=false; ANYPROJ=false
if [ "$CMD" = disable ]; then
  if [ "$EXPR_SET" -ne 1 ]; then ALL=true; fi
  if [ -z "$PROJECT" ]; then ANYPROJ=true; fi
fi
export EXPR PROJECT ALL ANYPROJ

# JSON operations, implemented twice: in jq (used when installed) and in python3 (fallback).
# Both read the API response on stdin where the operation needs one.
JQ_DEFS='
  def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch null);
  def active: .expires_at != null and (((.expires_at | ts) // 0) > now);
  def high_res_only: (.settings | length) > 0 and all(.settings[]; .setting.HighResProfiling == true);
  def ours: high_res_only and ($all or .expression == $expr)
    and ($anyproj or (.project // "") == $project);
  def new_entry($secs): {
    expression: $expr,
    project: (if $project == "" then null else $project end),
    expires_at: (now + $secs | floor | todate),
    settings: [{setting: {HighResProfiling: true}}]};
'
JQ_ARGS=(--arg expr "$EXPR" --arg project "$PROJECT" --argjson all "$ALL" --argjson anyproj "$ANYPROJ")

PY_ENGINE='
import json, os, re, sys, time
from datetime import datetime, timezone

E = os.environ
op, args = sys.argv[1], sys.argv[2:]

def ts(s):
    s = re.sub(r"\.[0-9]+", "", s).replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        return None

def is_high_res(x):
    return (x.get("setting") or {}).get("HighResProfiling") is True

def active(e):
    return e.get("expires_at") is not None and (ts(e["expires_at"]) or 0) > time.time()

def high_res_only(e):
    s = e.get("settings") or []
    return len(s) > 0 and all(is_high_res(x) for x in s)

def ours(e):
    return (high_res_only(e)
            and (E["ALL"] == "true" or e.get("expression") == E["EXPR"])
            and (E["ANYPROJ"] == "true" or (e.get("project") or "") == E["PROJECT"]))

def new_entry(secs):
    expires = datetime.fromtimestamp(int(time.time()) + secs, timezone.utc)
    return {"expression": E["EXPR"], "project": E["PROJECT"] or None,
            "expires_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "settings": [{"setting": {"HighResProfiling": True}}]}

def entries(doc):
    return doc["config"]["config"]["entries"]

if op == "rules_table":
    rows = [(i, e) for i, e in enumerate(entries(json.load(sys.stdin)))
            if any(is_high_res(x) for x in e.get("settings") or [])]
    if not rows:
        print("no high-resolution rules")
    else:
        print("#\texpression\tproject\texpires_at\tstate")
        for i, e in rows:
            state = ("ACTIVE, NO EXPIRY" if e.get("expires_at") is None
                     else "active" if active(e) else "expired")
            print("\t".join([str(i), e.get("expression") or "<all agents>", e.get("project") or "-",
                             e.get("expires_at") or "never", state]))
elif op == "ours_count":
    print(sum(1 for e in entries(json.load(sys.stdin)) if ours(e)))
elif op == "ours_list":
    print(json.dumps([e for e in entries(json.load(sys.stdin)) if ours(e)], indent=2))
elif op == "new_entry":
    print(json.dumps(new_entry(int(args[0])), indent=2))
elif op == "write_body":
    cfg = json.load(sys.stdin)["config"]
    kept = [e for e in cfg["config"]["entries"] if not ours(e)]
    if args[0] == "on":
        kept.append(new_entry(int(args[1])))
    print(json.dumps({"config": {"config": {"entries": kept}, "version": cfg["version"]}},
                     separators=(",", ":")))
elif op == "hosts_body":
    end = int(args[0])
    print(json.dumps({"start_ts": end - 3600000, "end_ts": end,
                      "pagination": {"sort": [], "page": {"page": 1, "page_size": 500}}}))
elif op == "hosts_table":
    gpus = [h for h in json.load(sys.stdin)["hosts"] if h.get("has_gpu")]
    if not gpus:
        print("no hosts with GPUs reported in the last hour")
    else:
        print("host_name\tcluster_name\tprofiler_version")
        for h in gpus:
            print("\t".join([h["host_name"], h.get("cluster_name") or "-", h["service_version"]]))
'

# json_op <operation> [args...]
json_op() {
  local op="$1"; shift
  if [ "$JSON_TOOL" = python3 ]; then python3 -c "$PY_ENGINE" "$op" "$@"; return; fi
  case "$op" in
    rules_table) jq -r "${JQ_ARGS[@]}" "$JQ_DEFS"'
      [.config.config.entries | to_entries[]
       | select(any(.value.settings[]; .setting.HighResProfiling == true))]
      | if length == 0 then "no high-resolution rules" else
        (["#", "expression", "project", "expires_at", "state"] | @tsv),
        (.[] | [ .key,
                 (if .value.expression == "" then "<all agents>" else .value.expression end),
                 (.value.project // "-"),
                 (.value.expires_at // "never"),
                 (if .value.expires_at == null then "ACTIVE, NO EXPIRY"
                  elif (.value | active) then "active"
                  else "expired" end) ] | @tsv)
        end' ;;
    ours_count) jq "${JQ_ARGS[@]}" "$JQ_DEFS"'[.config.config.entries[] | select(ours)] | length' ;;
    ours_list) jq "${JQ_ARGS[@]}" "$JQ_DEFS"'[.config.config.entries[] | select(ours)]' ;;
    new_entry) jq -n "${JQ_ARGS[@]}" --argjson secs "$1" "$JQ_DEFS"'new_entry($secs)' ;;
    write_body) jq -c "${JQ_ARGS[@]}" --arg mode "$1" --argjson secs "${2:-0}" "$JQ_DEFS"'
      {config: {config: {entries: ([.config.config.entries[] | select(ours | not)]
                                   + (if $mode == "on" then [new_entry($secs)] else [] end))},
                version: .config.version}}' ;;
    hosts_body) jq -nc --argjson e "$1" '{start_ts: ($e - 3600000), end_ts: $e,
      pagination: {sort: [], page: {page: 1, page_size: 500}}}' ;;
    hosts_table) jq -r '
      [.hosts[] | select(.has_gpu)] as $g
      | if ($g | length) == 0 then "no hosts with GPUs reported in the last hour" else
        (["host_name", "cluster_name", "profiler_version"] | @tsv),
        ($g[] | [.host_name, (.cluster_name // "-"), .service_version] | @tsv) end' ;;
  esac
}

print_rules() { json_op rules_table; }

# preview on <secs> | off: print the rules this write would remove and the rule it would add.
# Prints the number of rules it would remove on stdout's last line.
preview() {
  local mode="$1" secs="${2:-0}" current n
  current=$(api GET /agent/config/get) || exit $?
  n=$(json_op ours_count <<<"$current") || exit 1
  if [ "$n" -gt 0 ]; then
    echo "Existing high-resolution rule(s) for this scope, to be $([ "$mode" = on ] && echo replaced || echo removed) ($n):" >&2
    json_op ours_list <<<"$current" >&2
  fi
  if [ "$mode" = on ]; then
    echo "Rule to add (appended last, so it wins over earlier rules for this setting):" >&2
    json_op new_entry "$secs" >&2
  fi
  echo "$n"
}

# write_rules on <secs> | off: drop this scope's high-resolution rules, append a fresh one
# for "on", and write the list back with the version read. Retries when another writer
# saved in between (the API rejects a stale version); returns 4 at once when not allowed.
write_rules() {
  local mode="$1" secs="${2:-0}" attempt current body rc
  for attempt in 1 2 3; do
    rc=0
    current=$(api GET /agent/config/get) || rc=$?
    if [ "$rc" -eq 0 ]; then
      body=$(json_op write_body "$mode" "$secs" <<<"$current") || rc=1
    fi
    if [ "$rc" -eq 0 ]; then api POST /agent/config/set "$body" >/dev/null || rc=$?; fi
    if [ "$rc" -eq 0 ]; then return 0; fi
    if [ "$rc" -eq 4 ]; then return 4; fi
    if [ "$attempt" -lt 3 ]; then log "write failed (attempt $attempt of 3), retrying"; sleep 2; fi
  done
  return 1
}

SLEEP_PID=""
pause() { sleep "$1" & SLEEP_PID=$!; wait "$SLEEP_PID" || true; SLEEP_PID=""; }

case "$CMD" in
  list)
    cur=$(api GET /agent/config/get) || exit $?
    print_rules <<<"$cur"
    ;;

  hosts)
    now_ms=$(( $(date +%s) * 1000 ))
    body=$(json_op hosts_body "$now_ms")
    cur=$(api POST /agent-inventory "$body") || exit $?
    json_op hosts_table <<<"$cur"
    ;;

  enable)
    require_expr
    secs=$(capture_secs "$DURATION")
    preview on "$secs" >/dev/null
    if [ "$APPLY" -ne 1 ]; then echo "Dry run: nothing changed. Re-run with --apply to add it."; exit 0; fi
    write_rules on "$secs" || { rc=$?; [ "$rc" -eq 4 ] && exit 4; die "could not write the rule"; }
    log "on for ${secs}s: $EXPR"
    cur=$(api GET /agent/config/get) || exit $?
    print_rules <<<"$cur"
    ;;

  disable)
    n=$(preview off)
    if [ "$n" -eq 0 ]; then echo "No high-resolution rule matches; nothing to remove."; exit 0; fi
    if [ "$APPLY" -ne 1 ]; then echo "Dry run: nothing changed. Re-run with --apply to remove them."; exit 0; fi
    write_rules off || { rc=$?; [ "$rc" -eq 4 ] && exit 4; die "could not remove the rules"; }
    log "removed $n rule(s)"
    cur=$(api GET /agent/config/get) || exit $?
    print_rules <<<"$cur"
    ;;

  run)
    require_expr
    on=$(capture_secs "$DURATION")
    [ -n "$EVERY" ] || die "--every is required for run"
    every=$(to_secs "$EVERY")
    if [ "$every" -le "$on" ]; then die "--every ($EVERY) must be longer than --duration ($DURATION)"; fi
    ttl=$(( on + GRACE_SECS ))
    if [ "$ttl" -gt "$MAX_SECS" ]; then ttl=$MAX_SECS; fi
    echo "Schedule: on for ${on}s every ${every}s ($(( on * 100 / every ))% of the time); each rule expires after ${ttl}s on its own." >&2
    if [ $(( every - on )) -lt 60 ]; then
      echo "warning: the off period ($(( every - on ))s) is shorter than the ~60s propagation; profiling may never turn off between windows" >&2
    fi
    preview on "$ttl" >/dev/null
    if [ "$APPLY" -ne 1 ]; then echo "Dry run: nothing changed. Re-run with --apply to start."; exit 0; fi

    stop() {
      trap - INT TERM
      if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null || true; fi
      log "stopping: removing the rule"
      if write_rules off; then log "off"; else log "could not remove the rule; it expires on its own within ${ttl}s"; fi
      exit 0
    }
    trap stop INT TERM

    while :; do
      if write_rules on "$ttl"; then
        log "on for ${on}s: $EXPR"
      else
        rc=$?
        if [ "$rc" -eq 4 ]; then exit 4; fi
        log "could not turn on; trying again next cycle"
      fi
      pause "$on"
      if write_rules off; then
        log "off for $(( every - on ))s"
      else
        log "could not remove the rule; it expires on its own within ${ttl}s"
      fi
      pause $(( every - on ))
    done
    ;;

  *) usage ;;
esac

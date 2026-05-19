#!/usr/bin/env bash
#
# diagnose-no-data.sh — walk the "no data appearing in zymtrace UI" diagnostic
#
# The end-to-end path is:
#   workload → profiler → backend gateway (gRPC) → ingest → ClickHouse → UI
# Any link broken = no data. This script checks all four sides.
#
# Usage:
#   ./diagnose-no-data.sh [backend-NS] [backend-REL] [profiler-NS] [profiler-REL]
#
# Defaults: zymtrace / backend / zymtrace / profiler
# Honors PREFIX env var if global.namePrefix is overridden.

set -uo pipefail

NS_BE="${1:-zymtrace}"
REL_BE="${2:-backend}"
NS_PR="${3:-zymtrace}"
REL_PR="${4:-profiler}"
PREFIX="${PREFIX:-zymtrace}"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
note()    { printf '  %s\n' "$*"; }
ok()      { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()    { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()     { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Step 1 — Profiler agent reporting?"

if ! helm status "$REL_PR" -n "$NS_PR" >/dev/null 2>&1; then
  err "profiler release '$REL_PR' not found in '$NS_PR' — install-zymtrace-profiler first"
  exit 1
fi

# DaemonSet readiness
ds_desired=$(kubectl get ds -n "$NS_PR" "${PREFIX}-profiler" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
ds_ready=$(kubectl get ds -n "$NS_PR" "${PREFIX}-profiler" -o jsonpath='{.status.numberReady}' 2>/dev/null)
note "DaemonSet ${PREFIX}-profiler: ${ds_ready:-0}/${ds_desired:-0} Ready"

if [ "${ds_ready:-0}" = "0" ]; then
  err "no profiler pods ready — check nodeSelector / tolerations / image pull"
  kubectl get pods -n "$NS_PR" -l app.kubernetes.io/component=profiler 2>&1 | head -10
  exit 1
fi

# Pick a pod, scan recent logs for positive + negative signals
POD=$(kubectl get pods -n "$NS_PR" -l app.kubernetes.io/component=profiler -o name 2>/dev/null | head -1)
[ -z "$POD" ] && POD=$(kubectl get pods -n "$NS_PR" -l app=zymtrace -o name 2>/dev/null | head -1)

if [ -z "$POD" ]; then
  err "no profiler pods to inspect"
  exit 1
fi

note "inspecting $POD"
LOGS=$(kubectl logs -n "$NS_PR" "$POD" --tail=500 2>/dev/null)

if echo "$LOGS" | grep -qE 'license is valid until|License is valid'; then
  ok "license validated"
fi
if echo "$LOGS" | grep -qE 'streaming.*connection|established.*connection'; then
  ok "streaming connection to backend established"
fi
if echo "$LOGS" | grep -qE 'connection refused|dns lookup failed|no such host'; then
  err "profiler cannot reach backend gateway — check --collection-agent value"
  echo "$LOGS" | grep -iE 'connection refused|dns lookup failed|no such host' | head -3 | sed 's/^/      /'
  warn "fix: update profiler values 'profiler.args[0]' = -collection-agent=<correct-host:port>"
  warn "then: helm upgrade --install <REL_PR> zymtrace/profiler -n <NS_PR> -f <values-file> --reset-then-reuse-values --atomic"
fi
if echo "$LOGS" | grep -qiE 'forbidden|unauthorized|invalid.*license|license.*expired'; then
  err "auth / license issue on the agent side — see § License errors in SKILL.md"
  echo "$LOGS" | grep -iE 'forbidden|unauthorized|invalid.*license|license.*expired' | head -3 | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
section "Step 2 — (GPU only) CUDA injection working?"

# Detect whether GPU profiling is enabled
gpu_enabled=$(helm get values "$REL_PR" -n "$NS_PR" 2>/dev/null | grep -A1 'cudaProfiler' | grep -E 'enabled:\s*true')

if [ -z "$gpu_enabled" ]; then
  note "GPU profiling is disabled (cudaProfiler.enabled=false) — skipping Step 2"
else
  # Search all profiler pods for the "Intercepted zymtrace implant" message
  found=""
  for p in $(kubectl get pods -n "$NS_PR" -l app.kubernetes.io/component=profiler -o name 2>/dev/null); do
    hit=$(kubectl logs -n "$NS_PR" "$p" --tail=2000 2>/dev/null | grep -E 'Intercepted.*zymtrace.*implant' | head -1)
    [ -n "$hit" ] && { found="$hit"; break; }
  done

  if [ -n "$found" ]; then
    ok "CUDA injection detected:"
    printf '      %s\n' "$found"
  else
    err "no 'Intercepted zymtrace implant' line in any profiler pod's recent logs"
    warn "this means no workload has actually loaded the CUDA profiler library."
    warn "common fixes (check each workload pod spec):"
    warn "  1. Env var: CUDA_INJECTION64_PATH=/var/lib/zymtrace/profiler/libzymtracecudaprofiler.so"
    warn "  2. Volume mount: hostPath /var/lib/zymtrace/profiler → /var/lib/zymtrace/profiler"
    warn "  3. Restart the workload after the profiler DaemonSet is up (order matters)"
    warn "  4. On the GPU node: 'ls /var/lib/zymtrace/profiler' must show libzymtracecudaprofiler.so"
  fi
fi

# ---------------------------------------------------------------------------
section "Step 3 — Backend ingest healthy?"

if ! helm status "$REL_BE" -n "$NS_BE" >/dev/null 2>&1; then
  err "backend release '$REL_BE' not found in '$NS_BE'"
  exit 1
fi

ingest_pods=$(kubectl get pods -n "$NS_BE" -l app.kubernetes.io/component=ingest --no-headers 2>/dev/null)
if [ -z "$ingest_pods" ]; then
  err "no ingest pods found"
  exit 1
fi

bad=$(echo "$ingest_pods" | awk '$3 != "Running" {print}')
if [ -n "$bad" ]; then
  err "ingest pods not Running:"
  echo "$bad" | sed 's/^/      /'
else
  ok "ingest pods Running"
fi

INGEST_LOGS=$(kubectl logs -n "$NS_BE" deployment/"${PREFIX}-ingest" --tail=200 --all-containers=true 2>/dev/null)

if echo "$INGEST_LOGS" | grep -qE 'received profile|processed batch|license is valid'; then
  ok "ingest is processing data"
fi
if echo "$INGEST_LOGS" | grep -qiE 'clickhouse.*(refused|dial tcp|cannot connect)'; then
  err "ingest cannot reach ClickHouse — check Step 4 + use_existing host/port"
  echo "$INGEST_LOGS" | grep -iE 'clickhouse.*(refused|dial tcp|cannot connect)' | head -3 | sed 's/^/      /'
fi
if echo "$INGEST_LOGS" | grep -qiE 'forbidden|unauthorized|invalid.*license'; then
  err "ingest reports auth / license error — see § License errors in SKILL.md"
fi
if echo "$INGEST_LOGS" | grep -qiE 'disk full|out of space|no space left'; then
  err "ingest reports disk pressure — see Step 4"
fi

# ---------------------------------------------------------------------------
section "Step 4 — ClickHouse storage / health?"

ch_pod="${PREFIX}-clickhouse-0"
if ! kubectl get pod -n "$NS_BE" "$ch_pod" >/dev/null 2>&1; then
  note "in-cluster ClickHouse pod '$ch_pod' not found — likely using mode: use_existing"
  warn "check the external ClickHouse manually (host: $(helm get values $REL_BE -n $NS_BE 2>/dev/null | grep -A2 use_existing | grep host || echo '?'))"
else
  # Pod status
  ch_status=$(kubectl get pod -n "$NS_BE" "$ch_pod" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$ch_status" = "Running" ]; then
    ok "ClickHouse pod Running"
  else
    err "ClickHouse pod status: $ch_status"
  fi

  # Disk usage
  df_line=$(kubectl exec -n "$NS_BE" "$ch_pod" -- df -h /var/lib/clickhouse 2>/dev/null | tail -1)
  if [ -n "$df_line" ]; then
    usage=$(echo "$df_line" | awk '{print $5}' | tr -d '%')
    note "ClickHouse data volume usage: $df_line"
    if [ "${usage:-0}" -ge 85 ] 2>/dev/null; then
      err "ClickHouse data volume is ${usage}% full — writes will stop above ~95%"
      warn "fix options:"
      warn "  1. Lower global.dataRetentionDays in values file + helm upgrade --install --reset-then-reuse-values --atomic"
      warn "  2. Expand PVC: kubectl edit pvc data-${ch_pod} -n $NS_BE  (only if storage class allowVolumeExpansion: true)"
    elif [ "${usage:-0}" -ge 70 ] 2>/dev/null; then
      warn "ClickHouse volume ${usage}% full — plan to expand or shorten retention before reaching 85%"
    fi
  fi

  # Recent CH errors
  ch_errs=$(kubectl logs -n "$NS_BE" "$ch_pod" --tail=100 2>/dev/null | grep -iE 'exception|error.*disk|cannot write' | head -5)
  if [ -n "$ch_errs" ]; then
    warn "recent ClickHouse errors:"
    echo "$ch_errs" | sed 's/^/      /'
  fi
fi

# ---------------------------------------------------------------------------
section "Summary"
echo
note "Walked all four steps. Re-run after applying fixes to confirm."
note "If everything looks OK above and the UI is still empty:"
note "  - Refresh the UI (filters / time range may be hiding data)"
note "  - Wait 30-60s after starting agents — first batch takes a moment"
note "  - Capture this script's output + chart versions and email support@zymtrace.com"

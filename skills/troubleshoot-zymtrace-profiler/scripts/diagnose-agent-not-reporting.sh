#!/usr/bin/env bash
#
# diagnose-agent-not-reporting.sh — first-pass triage for a misbehaving zymtrace profiler agent.
#
# Surfaces the signals needed to route into one of the SKILL.md scenarios:
#   - CrashLoopBackOff
#   - ImagePullBackOff
#   - OOMKilled / restart cycle
#   - No GPU profiles (CUDA injection check)
#   - NVML library not found
#   - License rejected
#
# Uses only kubectl + helm. No node-shell, no jq.
#
# Usage:
#   ./diagnose-agent-not-reporting.sh [namespace] [release-name]
#
# Defaults: zymtrace / profiler. Honors PREFIX env var if global.namePrefix is overridden.

set -uo pipefail

NS="${1:-zymtrace}"
RELEASE="${2:-profiler}"
PREFIX="${PREFIX:-zymtrace}"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
note()    { printf '  %s\n' "$*"; }
ok()      { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()    { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()     { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Helm release"
if ! helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  err "release '$RELEASE' not found in '$NS' — this is a troubleshoot, not an install. Route to install-zymtrace-profiler."
  exit 1
fi
helm status "$RELEASE" -n "$NS" 2>/dev/null | head -8

# ---------------------------------------------------------------------------
section "DaemonSet status"
kubectl get ds -n "$NS" "${PREFIX}-profiler" -o wide 2>&1
desired=$(kubectl get ds -n "$NS" "${PREFIX}-profiler" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
ready=$(kubectl get ds -n "$NS" "${PREFIX}-profiler" -o jsonpath='{.status.numberReady}' 2>/dev/null)
desired=${desired:-0}
ready=${ready:-0}

if [ "$ready" = "$desired" ] && [ "$ready" -gt 0 ]; then
  ok "DaemonSet healthy: $ready/$desired pods Ready"
else
  err "DaemonSet unhealthy: $ready/$desired pods Ready"
fi

# ---------------------------------------------------------------------------
section "Pod status (per node)"
kubectl get pods -n "$NS" -l app.kubernetes.io/component=profiler -o wide 2>&1

# ---------------------------------------------------------------------------
section "Non-Running pods — what's wrong?"
bad_pods=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=profiler --no-headers 2>/dev/null \
  | awk '$3 != "Running" {print $1}')
if [ -z "$bad_pods" ]; then
  ok "all pods Running"
else
  for p in $bad_pods; do
    echo ""
    echo "--- $p ---"
    state=$(kubectl get pod -n "$NS" "$p" -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null)
    last_reason=$(kubectl get pod -n "$NS" "$p" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)
    waiting_reason=$(kubectl get pod -n "$NS" "$p" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
    [ -n "$last_reason" ] && note "lastState.terminated.reason: $last_reason"
    [ -n "$waiting_reason" ] && note "state.waiting.reason: $waiting_reason"

    case "$waiting_reason" in
      ImagePullBackOff|ErrImagePull)
        warn "→ § ImagePullBackOff in SKILL.md"
        ;;
      CrashLoopBackOff)
        warn "→ § CrashLoopBackOff in SKILL.md"
        ;;
    esac
    case "$last_reason" in
      OOMKilled)
        warn "→ § OOMKilled / restart cycle in SKILL.md"
        ;;
    esac

    # Tail describe events for any other clues
    kubectl describe pod -n "$NS" "$p" 2>/dev/null | sed -n '/Events:/,$p' | tail -20 | sed 's/^/      /'
  done
fi

# ---------------------------------------------------------------------------
section "Recent agent logs (last 80 lines, first Running pod)"
first_running=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=profiler --no-headers 2>/dev/null \
  | awk '$3 == "Running" {print $1; exit}')

if [ -z "$first_running" ]; then
  warn "no Running pod to inspect — see Non-Running pods section above"
else
  note "from pod $first_running"
  LOGS=$(kubectl logs -n "$NS" "$first_running" --tail=200 2>/dev/null)
  echo "$LOGS" | tail -80 | sed 's/^/      /'

  # Signal extraction
  echo ""
  if echo "$LOGS" | grep -qE 'license is valid until'; then
    ok "license validated"
  fi
  if echo "$LOGS" | grep -qE 'streaming.*connection|established.*connection'; then
    ok "streaming connection to backend established"
  fi
  if echo "$LOGS" | grep -qE 'Intercepted.*zymtrace.*implant'; then
    ok "GPU implant intercepted (CUDA workload is being profiled)"
  fi

  if echo "$LOGS" | grep -qiE 'license.*(expired|invalid)|forbidden|unauthorized'; then
    err "license / auth error → § License rejected"
    echo "$LOGS" | grep -iE 'license.*(expired|invalid)|forbidden|unauthorized' | head -3 | sed 's/^/      /'
  fi
  if echo "$LOGS" | grep -qiE 'connection refused|dns lookup failed|no such host'; then
    err "cannot reach backend → wrong --collection-agent target"
    echo "$LOGS" | grep -iE 'connection refused|dns lookup failed|no such host' | head -3 | sed 's/^/      /'
  fi
  if echo "$LOGS" | grep -qiE 'failed to load nvml|could not find libnvidia-ml'; then
    err "NVML library not found → § NVML library not found"
  fi
fi

# ---------------------------------------------------------------------------
section "GPU profiling configuration"
gpu_enabled=$(helm get values "$RELEASE" -n "$NS" 2>/dev/null | grep -A1 cudaProfiler | grep -E 'enabled:\s*true')

if [ -z "$gpu_enabled" ]; then
  note "cudaProfiler is disabled — CPU profiling only. If the customer expects GPU profiles, enable it in the values file."
else
  ok "cudaProfiler enabled"
  # Check whether any workload has been intercepted yet
  intercepts=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=profiler -o name 2>/dev/null \
    | while read p; do
        kubectl logs -n "$NS" "$p" --tail=2000 2>/dev/null | grep -c 'Intercepted.*zymtrace.*implant' || true
      done | awk '{s+=$1} END {print s+0}')
  if [ "$intercepts" -gt 0 ]; then
    ok "$intercepts CUDA workload(s) intercepted across the DaemonSet"
  else
    warn "no CUDA workload interceptions yet → § No GPU profiles in SKILL.md"
    warn "  the workload (not the agent) needs CUDA_INJECTION64_PATH + the host-path mount"
  fi
fi

# ---------------------------------------------------------------------------
section "Summary"
note "DaemonSet: $ready/$desired Ready"
note "helm release: $(helm status "$RELEASE" -n "$NS" 2>/dev/null | awk -F': ' '/^STATUS:/ {print $2; exit}')"

echo
note "Next: pick the matching section in SKILL.md based on the signals above."
note "If signals are clean (all green) but the UI is still empty, the issue is downstream."
note "Hand off to ../troubleshoot-zymtrace-backend/SKILL.md § No data coming through."

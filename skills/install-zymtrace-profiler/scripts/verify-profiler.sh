#!/usr/bin/env bash
#
# verify-profiler.sh — sanity-check a zymtrace profiler DaemonSet install.
#
# Uses only standard kubectl + helm commands. No jq.
#
# Usage:
#   ./verify-profiler.sh [namespace] [release-name]
#
# Defaults: namespace=zymtrace, release-name=profiler
# Honors PREFIX env var if global.namePrefix is overridden.

set -uo pipefail

NS="${1:-zymtrace}"
RELEASE="${2:-profiler}"
PREFIX="${PREFIX:-zymtrace}"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
note()    { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Helm release: $RELEASE (namespace: $NS)"
helm status "$RELEASE" -n "$NS" 2>/dev/null | head -8 \
  || { note "release '$RELEASE' not found in '$NS'"; exit 1; }

# ---------------------------------------------------------------------------
section "DaemonSet"
kubectl get ds -n "$NS" "${PREFIX}-profiler" -o wide 2>&1

# Desired / Ready counts
desired=$(kubectl get ds -n "$NS" "${PREFIX}-profiler" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
ready=$(kubectl get ds -n "$NS" "${PREFIX}-profiler" -o jsonpath='{.status.numberReady}' 2>/dev/null)
desired=${desired:-0}
ready=${ready:-0}

# ---------------------------------------------------------------------------
section "Pods"
kubectl get pods -n "$NS" -l app.kubernetes.io/component=profiler -o wide 2>&1 \
  || kubectl get pods -n "$NS" -l app=zymtrace -o wide 2>&1

# ---------------------------------------------------------------------------
section "Sample pod logs (last 30 lines)"
first_pod=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=profiler -o name 2>/dev/null | head -1)
[ -z "$first_pod" ] && first_pod=$(kubectl get pods -n "$NS" -l app=zymtrace -o name 2>/dev/null | head -1)
if [ -n "$first_pod" ]; then
  note "from $first_pod"
  kubectl logs -n "$NS" "$first_pod" --tail=30 2>&1
else
  note "no profiler pods found"
fi

# ---------------------------------------------------------------------------
section "Backend connection evidence"
# Look for either license-validation OR streaming-connection messages in any pod.
license_ok=0
stream_ok=0
errors=""

for pod in $(kubectl get pods -n "$NS" -l app.kubernetes.io/component=profiler -o name 2>/dev/null \
            || kubectl get pods -n "$NS" -l app=zymtrace -o name 2>/dev/null); do
  logs=$(kubectl logs -n "$NS" "$pod" --tail=200 2>/dev/null)
  if echo "$logs" | grep -qE 'license is valid until|License is valid'; then
    license_ok=1
  fi
  if echo "$logs" | grep -qE 'streaming.*connection|established.*connection'; then
    stream_ok=1
  fi
  # Common failure patterns
  pod_errs=$(echo "$logs" | grep -iE 'connection refused|dns lookup failed|no such host|forbidden|unauthorized|invalid.*license|license.*expired' | head -3)
  [ -n "$pod_errs" ] && errors="${errors}${pod}:\n${pod_errs}\n"
done

if [ "$license_ok" = "1" ]; then
  note "license validated ✓"
fi
if [ "$stream_ok" = "1" ]; then
  note "streaming connection established ✓"
fi
if [ "$license_ok" = "0" ] && [ "$stream_ok" = "0" ]; then
  note "no positive connection signal in logs yet — agents may still be starting (wait 30s and re-run)"
fi
if [ -n "$errors" ]; then
  note "errors detected:"
  printf '%b' "$errors" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
section "GPU profiler library (if cudaProfiler.enabled)"
cuda_enabled=$(helm get values "$RELEASE" -n "$NS" 2>/dev/null | grep -A1 'cudaProfiler' | grep -E 'enabled:.*true')
if [ -n "$cuda_enabled" ]; then
  note "cudaProfiler enabled — checking host extraction"
  # Pick one GPU pod
  gpu_pod=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=profiler -o name 2>/dev/null | head -1)
  if [ -n "$gpu_pod" ]; then
    # The host path is /var/lib/zymtrace/profiler. We can't read it from a regular pod.
    # Three ways to verify, preferring the ones that don't need node-shell access:
    note "expected host path: /var/lib/zymtrace/profiler/libzymtracecudaprofiler.so"
    note "verify options (in order of preference):"
    note "  1. kubectl debug node/<node> -it --image=busybox -- ls /host/var/lib/zymtrace/profiler"
    note "     (needs node-debugger RBAC; uses /host as the chroot prefix)"
    note "  2. Ask the user to run on a GPU node: ls -la /var/lib/zymtrace/profiler"
    note "  3. ssh <node> 'ls -la /var/lib/zymtrace/profiler'  # if they have SSH access"
  fi
else
  note "cudaProfiler is disabled — skipping GPU library check"
fi

# ---------------------------------------------------------------------------
section "Summary"
helm_status=$(helm status "$RELEASE" -n "$NS" 2>/dev/null | awk -F': ' '/^STATUS:/ {print $2; exit}')
note "helm release: ${helm_status:-NOT FOUND}"
note "DaemonSet:    $ready/$desired pods Ready"
[ "$license_ok" = "1" ] && note "license:      validated ✓" || note "license:      not yet validated"
[ "$stream_ok" = "1" ]  && note "backend:      streaming connection established ✓" || note "backend:      no streaming connection yet"

echo
if [ "$helm_status" = "deployed" ] && [ "$ready" = "$desired" ] && [ "$ready" -gt 0 ] \
   && { [ "$license_ok" = "1" ] || [ "$stream_ok" = "1" ]; } && [ -z "$errors" ]; then
  printf '\033[1;32m✓ Profiler is healthy.\033[0m\n'
  printf '  Profiles for every process on every covered node should appear in the UI within ~30s.\n'
  printf '  For GPU profiling, the agent only ships data when workloads set CUDA_INJECTION64_PATH.\n'
else
  printf '\033[1;31m✗ Issues detected — see sections above.\033[0m\n'
  printf '  Common fixes:\n'
  printf '    - Connection refused / DNS error → wrong -collection-agent target. Check service FQDN.\n'
  printf '    - License invalid / expired → renew via support@zymtrace.com or check secret reference.\n'
  printf '    - 0/N Ready → nodeSelector mismatch. Run: kubectl get nodes --show-labels\n'
fi

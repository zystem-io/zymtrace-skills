#!/usr/bin/env bash
#
# verify-backend.sh — sanity-check a zymtrace backend install.
#
# Uses only standard kubectl + helm commands. No jq, no jsonpath beyond
# what kubectl provides natively.
#
# Usage:
#   ./verify-backend.sh [namespace] [release-name]
#
# Defaults: namespace=zymtrace, release-name=backend

set -uo pipefail

NS="${1:-zymtrace}"
RELEASE="${2:-backend}"
PREFIX="${PREFIX:-zymtrace}"   # global.namePrefix from the chart

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
note()    { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Helm release: $RELEASE (namespace: $NS)"
helm status "$RELEASE" -n "$NS" 2>/dev/null || note "release '$RELEASE' not found"

# ---------------------------------------------------------------------------
section "Pods"
kubectl get pods -n "$NS" -o wide

# ---------------------------------------------------------------------------
# The chart runs the migrate Job as a Helm pre-install/pre-upgrade hook with
# `hook-delete-policy: hook-succeeded`. On a successful install/upgrade the
# Job is GONE — that's the expected steady state, not a problem.
section "Migration job (expected absent after success — hook-deleted by Helm)"
kubectl get jobs -n "$NS" 2>&1

# ---------------------------------------------------------------------------
section "Services"
kubectl get svc -n "$NS"

# ---------------------------------------------------------------------------
section "Ingress"
kubectl get ingress -n "$NS" 2>/dev/null || note "no ingress (NodePort or port-forward access)"

# ---------------------------------------------------------------------------
section "HPA"
kubectl get hpa -n "$NS" 2>/dev/null || note "no HPAs configured"

# ---------------------------------------------------------------------------
# Logs from each backend service. Use deployment/<name> — works regardless of
# how the chart labels resources, because resource names follow <namePrefix>-<svc>.
for svc in migrate ingest gateway web symdb identity ui; do
  section "Logs: ${PREFIX}-${svc} (last 30 lines)"
  if [ "$svc" = "migrate" ]; then
    # migrate is a Helm hook Job that is auto-deleted on success.
    # Only try to fetch its logs if the Job still exists (i.e. it failed or is in-progress).
    if kubectl get job -n "$NS" "${PREFIX}-${svc}" >/dev/null 2>&1; then
      kubectl logs -n "$NS" "job/${PREFIX}-${svc}" --tail=30 2>/dev/null \
        || note "job exists but pod logs unavailable (pod may have been garbage-collected)"
    else
      note "migrate Job not present — Helm hook auto-deleted on success."
      note "If the install/upgrade actually failed, helm would have rolled back (--atomic) and you'd see"
      note "errors in 'helm history' or pod events. Check those instead of expecting a lingering Job."
    fi
  else
    kubectl logs -n "$NS" "deployment/${PREFIX}-${svc}" --tail=30 --all-containers=true 2>/dev/null \
      || note "no logs for deployment/${PREFIX}-${svc} (service may not be deployed)"
  fi
done

# ---------------------------------------------------------------------------
# Describe any pod that isn't Running/Completed — most install failures are
# diagnosed from `kubectl describe` events + image pull / secret errors.
section "Describe non-Running pods"
bad_pods=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
  | awk '$3 != "Running" && $3 != "Completed" && $3 != "Succeeded" {print $1}')
if [ -z "$bad_pods" ]; then
  note "all pods Running / Completed ✓"
else
  for p in $bad_pods; do
    printf '\n--- %s ---\n' "$p"
    kubectl describe pod -n "$NS" "$p" | tail -40
  done
fi

# ---------------------------------------------------------------------------
section "Summary"
# Helm release deployed?
helm_status=$(helm status "$RELEASE" -n "$NS" 2>/dev/null | awk -F': ' '/^STATUS:/ {print $2; exit}')
note "helm release: ${helm_status:-NOT FOUND}"

# Pod health
total=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
healthy=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
  | awk '$3 == "Running" || $3 == "Completed" || $3 == "Succeeded"' | wc -l | tr -d ' ')
note "pods: $healthy/$total Running or Completed"

# Migrate job — success can take two shapes:
#   (a) Job exists and succeeded == completions  (mid-flight or skipDelete cases)
#   (b) Job absent because Helm's hook-delete-policy removed it after success
# Treat (b) as success when helm status is "deployed".
if kubectl get job -n "$NS" "${PREFIX}-migrate" >/dev/null 2>&1; then
  mig_succ=$(kubectl get job -n "$NS" "${PREFIX}-migrate" -o=jsonpath='{.status.succeeded}' 2>/dev/null)
  mig_comp=$(kubectl get job -n "$NS" "${PREFIX}-migrate" -o=jsonpath='{.spec.completions}' 2>/dev/null)
  mig_succ=${mig_succ:-0}
  mig_comp=${mig_comp:-1}
  note "migrate job: $mig_succ/$mig_comp succeeded"
  if [ "$mig_succ" = "$mig_comp" ]; then mig_ok=true; else mig_ok=false; fi
else
  note "migrate job: hook-deleted on success (absent — expected after a clean deploy)"
  # Absence alone isn't proof of success — gate on helm_status below.
  [ "$helm_status" = "deployed" ] && mig_ok=true || mig_ok=false
fi

# Gateway service exists?
if kubectl get svc -n "$NS" "${PREFIX}-gateway" >/dev/null 2>&1; then
  gw_type=$(kubectl get svc -n "$NS" "${PREFIX}-gateway" -o=jsonpath='{.spec.type}' 2>/dev/null)
  note "gateway service: ${PREFIX}-gateway (type: ${gw_type})"
else
  note "gateway service: NOT FOUND"
fi

echo
if [ "$healthy" = "$total" ] && [ "$mig_ok" = "true" ] && [ "$helm_status" = "deployed" ]; then
  printf '\033[1;32m✓ Backend looks healthy.\033[0m Next: install the profiler agent.\n'
else
  printf '\033[1;31m✗ Issues detected — see sections above.\033[0m\n'
  printf '  Common fixes:\n'
  printf '    - Missing referenced secret (license, OIDC, signing keys) → kubectl get events -n %s --sort-by=.lastTimestamp\n' "$NS"
  printf '    - Image pull errors → check global.registry.* and pull secrets\n'
  printf '    - Migrate job failing → check ClickHouse/Postgres connectivity and credentials\n'
fi

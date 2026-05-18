#!/usr/bin/env bash
#
# preflight-upgrade.sh — gather everything needed to confirm a zymtrace
# backend upgrade before running `helm upgrade`.
#
# Uses only standard helm + kubectl commands. No jq.
#
# Usage:
#   ./preflight-upgrade.sh [namespace] [release-name]
#
# Defaults: namespace=zymtrace, release-name=backend
#
# Prints to stdout. Does NOT modify cluster state.

set -uo pipefail

NS="${1:-zymtrace}"
RELEASE="${2:-backend}"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
note()    { printf '  %s\n' "$*"; }
warn()    { printf '  \033[33m!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Tools"
helm version --short 2>/dev/null || { warn "helm not installed — stop"; exit 1; }
kubectl version --client 2>/dev/null | head -1 || { warn "kubectl not installed — stop"; exit 1; }

# ---------------------------------------------------------------------------
section "Cluster"
kubectl config current-context
kubectl cluster-info | head -2

# ---------------------------------------------------------------------------
section "Current release"
if ! helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  warn "release '$RELEASE' not found in namespace '$NS' — this skill is for upgrades; route to install-zymtrace-backend"
  exit 1
fi
helm status "$RELEASE" -n "$NS" | head -20

# ---------------------------------------------------------------------------
section "Release history (last 10)"
helm history "$RELEASE" -n "$NS" --max 10

# ---------------------------------------------------------------------------
section "In-flight operations"
status=$(helm status "$RELEASE" -n "$NS" 2>/dev/null | awk -F': ' '/^STATUS:/ {print $2; exit}')
if [ "$status" != "deployed" ]; then
  warn "release status is '$status' (not 'deployed') — resolve before upgrading"
  warn "  options: 'helm rollback' to a known-good revision, or 'helm uninstall' (destructive, confirm first)"
else
  note "release status: deployed ✓"
fi

# ---------------------------------------------------------------------------
section "Currently running image tags"
for d in zymtrace-ingest zymtrace-web zymtrace-symdb zymtrace-identity zymtrace-ui zymtrace-gateway; do
  img=$(kubectl get deploy "$d" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [ -n "$img" ]; then
    printf '  %-22s %s\n' "$d" "$img"
  fi
done

# ---------------------------------------------------------------------------
section "Refreshing helm repo (mandatory before upgrade)"
if ! helm repo list 2>/dev/null | grep -q '^zymtrace'; then
  warn "helm repo 'zymtrace' is not added"
  warn "  run: helm repo add zymtrace https://helm.zystem.io"
else
  helm repo update zymtrace 2>&1 | grep -E '(Update|Successfully)' || true
fi

# ---------------------------------------------------------------------------
section "Available chart versions (latest 5)"
helm search repo zymtrace/backend --versions 2>/dev/null | head -6 \
  || warn "no chart versions returned — repo cache may be empty"

# ---------------------------------------------------------------------------
section "Database modes (drives backup warning)"
modes=$(helm get values "$RELEASE" -n "$NS" 2>/dev/null | grep -E '^\s*mode:' | sort -u)
if [ -z "$modes" ]; then
  note "no explicit mode set — defaults to 'create' (in-cluster) for all DBs"
  warn "in-cluster DBs are managed by the chart. Surface backup recommendation per SKILL.md Step 2 before upgrade."
else
  echo "$modes" | sed 's/^/      /'
  if echo "$modes" | grep -q '"\?create"\?'; then
    warn "at least one DB is mode=create (in-cluster). Surface backup recommendation per SKILL.md Step 2 before upgrade."
  fi
fi

# ---------------------------------------------------------------------------
section "Pending migrate jobs"
pending=$(kubectl get jobs -n "$NS" -l app.kubernetes.io/component=migrate --no-headers 2>/dev/null \
  | awk '$2 != "1/1" {print}')
if [ -z "$pending" ]; then
  note "no incomplete migrate jobs ✓"
else
  warn "incomplete migrate jobs from prior revisions:"
  echo "$pending" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
section "helm-diff plugin"
if helm plugin list 2>/dev/null | grep -qi diff; then
  note "helm-diff installed ✓ — use 'helm diff upgrade' before Step 4 to preview changes"
else
  warn "helm-diff not installed. Optional but recommended:"
  warn "  helm plugin install https://github.com/databus23/helm-diff"
fi

# ---------------------------------------------------------------------------
section "Summary — confirm with the user before running helm upgrade"
note "namespace:       $NS"
note "release:         $RELEASE"
note "current status:  ${status:-unknown}"
echo
note "After confirming target chart version + image tag with the user, run the matching"
note "path (A / B / C) from SKILL.md Step 4. Always include --reset-then-reuse-values."

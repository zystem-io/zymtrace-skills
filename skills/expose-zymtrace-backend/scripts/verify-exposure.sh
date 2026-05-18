#!/usr/bin/env bash
#
# verify-exposure.sh — sanity-check zymtrace gateway exposure (NodePort / LB / Ingress).
#
# Uses standard kubectl + curl + dig. No jq.
#
# Usage:
#   ./verify-exposure.sh [namespace] [release-name]
#
# Defaults: namespace=zymtrace, release-name=backend
# Honors PREFIX env var if global.namePrefix is overridden.

set -uo pipefail

NS="${1:-zymtrace}"
RELEASE="${2:-backend}"
PREFIX="${PREFIX:-zymtrace}"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
note()    { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Helm release: $RELEASE (namespace: $NS)"
helm status "$RELEASE" -n "$NS" 2>/dev/null | head -6 \
  || { note "release '$RELEASE' not found in '$NS'"; exit 1; }

# ---------------------------------------------------------------------------
section "Gateway service"
kubectl get svc -n "$NS" "${PREFIX}-gateway" -o wide 2>&1
gw_type=$(kubectl get svc -n "$NS" "${PREFIX}-gateway" -o jsonpath='{.spec.type}' 2>/dev/null)
note "type: ${gw_type:-NOT FOUND}"

case "$gw_type" in
  NodePort)
    nport=$(kubectl get svc -n "$NS" "${PREFIX}-gateway" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    note "NodePort: ${nport}"
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
    [ -z "$node_ip" ] && node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    note "test from outside cluster: curl -I http://${node_ip}:${nport}"
    ;;
  LoadBalancer)
    lb=$(kubectl get svc -n "$NS" "${PREFIX}-gateway" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -z "$lb" ]; then
      note "LoadBalancer address not yet assigned (provisioning — may take 1–3 minutes)"
    else
      note "LoadBalancer address: $lb"
    fi
    ;;
  ClusterIP)
    note "ClusterIP only — accessible via kubectl port-forward:"
    note "  kubectl port-forward -n $NS svc/${PREFIX}-gateway 8080:80"
    ;;
esac

# ---------------------------------------------------------------------------
section "Ingress (if any)"
ing=$(kubectl get ingress -n "$NS" --no-headers 2>/dev/null)
if [ -z "$ing" ]; then
  note "no ingress configured for this release"
else
  kubectl get ingress -n "$NS" -o wide
  echo
  # For each ingress, check the ADDRESS column populated + scheme annotation
  for i in $(kubectl get ingress -n "$NS" -o name 2>/dev/null); do
    name=${i#ingress.networking.k8s.io/}
    name=${name#ingress/}
    addr=$(kubectl get "$i" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    cls=$(kubectl get "$i" -n "$NS" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
    host=$(kubectl get "$i" -n "$NS" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
    proto=$(kubectl get "$i" -n "$NS" -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/backend-protocol}' 2>/dev/null)
    proto_ver=$(kubectl get "$i" -n "$NS" -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/backend-protocol-version}' 2>/dev/null)
    nginx_proto=$(kubectl get "$i" -n "$NS" -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/backend-protocol}' 2>/dev/null)

    printf '  %s\n' "$name"
    printf '    class:    %s\n' "${cls:-<none>}"
    printf '    host:     %s\n' "${host:-<empty — direct LB DNS>}"
    printf '    address:  %s\n' "${addr:-<provisioning…>}"

    if [ "$cls" = "alb" ]; then
      if [ "$proto" = "HTTP" ] && [ "$proto_ver" = "HTTP2" ]; then
        printf '    \033[32mALB backend-protocol: HTTP/HTTP2 ✓\033[0m\n'
      elif [ -n "$proto" ] || [ -n "$proto_ver" ]; then
        printf '    \033[31m! ALB backend-protocol = %s/%s — the gateway needs HTTP + HTTP2; GRPC target groups return HTTP 464\033[0m\n' "${proto:-<unset>}" "${proto_ver:-<unset>}"
      fi
    elif [ "$cls" = "nginx" ]; then
      if [ "$nginx_proto" = "GRPC" ]; then
        printf '    \033[32mNGINX backend-protocol: GRPC ✓\033[0m\n'
      else
        printf '    \033[31m! NGINX backend-protocol = %s — should be GRPC for the zymtrace gateway\033[0m\n' "${nginx_proto:-<unset>}"
      fi
    fi
  done
fi

# ---------------------------------------------------------------------------
section "DNS resolution (if hostname configured)"
host=$(kubectl get ingress -n "$NS" -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null)
if [ -z "$host" ]; then
  note "no hostname in ingress spec — skipping DNS check"
else
  if command -v dig >/dev/null 2>&1; then
    resolved=$(dig +short "$host" 2>/dev/null | head -5)
    if [ -z "$resolved" ]; then
      note "$host → no DNS resolution (set up a Route53 / DNS A-record pointing at the ingress ADDRESS above)"
    else
      note "$host →"
      echo "$resolved" | sed 's/^/      /'
    fi
  else
    note "dig not installed — skipping DNS check"
  fi
fi

# ---------------------------------------------------------------------------
section "HTTP/HTTPS reachability"
if [ -n "${host:-}" ]; then
  # Try HTTPS first
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 "https://${host}/" 2>/dev/null || echo "000")
  if [ "$code" != "000" ]; then
    note "https://${host}/ → HTTP $code"
  else
    note "https://${host}/ → unreachable (timeout / TLS error / connection refused)"
  fi
  # Then HTTP
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 "http://${host}/" 2>/dev/null || echo "000")
  if [ "$code" != "000" ]; then
    note "http://${host}/  → HTTP $code"
  else
    note "http://${host}/  → unreachable"
  fi
else
  note "no public hostname — skipping reachability check"
  note "test manually with: kubectl port-forward -n $NS svc/${PREFIX}-gateway 8080:80 && curl -I http://localhost:8080"
fi

# ---------------------------------------------------------------------------
section "Summary"
note "exposure type: ${gw_type:-unknown}"
if [ -n "${host:-}" ]; then
  note "hostname:      $host"
fi
echo
note "If anything above is red, see SKILL.md § Common pitfalls or reference.md."

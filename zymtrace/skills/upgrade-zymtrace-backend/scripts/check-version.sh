#!/usr/bin/env bash
#
# check-version.sh — compare a zymtrace instance's version with the latest release in the
# changelog, so a skill can offer an upgrade, and check that profilers are close enough to it.
#
# Usage:
#   check-version.sh [gateway-url]
#   check-version.sh -h|--help
#
#   gateway-url   The zymtrace URL (the MCP URL without /mcp also works). The version is read
#                 from <gateway-url>/api-docs/openapi.json, which needs no token. Without a
#                 URL, or when that fails, the version in the backend Helm chart name
#                 (backend-<version>) is used.
#
# Output (exit 0 when both versions were found, 1 otherwise):
#   instance: <version> (<source>)
#   latest:   <version> (https://docs.zymtrace.com/changelog/)
#   status:   up-to-date | outdated | newer | unknown
#   behind:   <versions newer than the instance, newest first>      (outdated only)
#   notes:    https://docs.zymtrace.com/changelog/#v<digits>        (outdated only, oldest newer release)
#   profiler: <ns>/<release> <version> (<state>)                    (one per profiler Helm release)
#
# The upgrade target is always the latest release, for the backend and the profilers. A
# profiler up to PROFILER_MAX_LAG (3) releases behind the backend still works, so that lag
# isn't urgent. <state> is one of:
#   latest
#   same as the backend; upgrade both to <latest>
#   <n> behind the backend, still works; upgrade to <latest>
#   <n> behind the backend, too far; upgrade to <latest>
#   newer than the backend; upgrade the backend to <latest>
#   not in the changelog
# Profilers installed with Docker or as a binary aren't visible here; see Settings ->
# Profiler Inventory in the UI.
#
# Requires: curl, grep, sed, awk. Uses jq when it's installed (plain-text parsing otherwise)
# and helm when present.

set -uo pipefail

CHANGELOG="https://docs.zymtrace.com/changelog/"
PROFILER_MAX_LAG=3
case "${1:-}" in
  -h|--help) sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
GW="${1:-}"
GW="${GW%/}"; GW="${GW%/mcp}"

HAVE_JQ=false
command -v jq >/dev/null 2>&1 && HAVE_JQ=true

# Helm releases as "<chart>\t<namespace>/<name>\t<version>": jq on the JSON listing when
# installed, else awk on the YAML listing. The version comes from the chart name
# (backend-26.10.3 -> 26.10.3), not app_version (old charts report "latest"); anything that
# isn't N.N.N is left empty (unknown).
helm_releases() {
  command -v helm >/dev/null || return 0
  if [ "$HAVE_JQ" = true ]; then
    helm list -A -o json 2>/dev/null \
      | jq -r '.[] | "\(.chart)\t\(.namespace)/\(.name)\t\(.chart | sub("^[^-]+-"; "") | if test("^[0-9]+\\.[0-9]+\\.[0-9]+$") then . else "" end)"' 2>/dev/null
    return 0
  fi
  helm list -A -o yaml 2>/dev/null | awk '
    function flush() {
      if (chart != "") {
        v = chart; sub(/^[^-]+-/, "", v)
        if (v !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) v = ""
        printf "%s\t%s/%s\t%s\n", chart, ns, name, v
      }
      chart = name = ns = ""
    }
    /^- / { flush(); sub(/^- /, "  ") }
    /^  [a-z_]+:/ {
      key = $1; sub(/:$/, "", key)
      val = $0; sub(/^  [a-z_]+:[ ]*/, "", val); gsub(/"/, "", val)
      if (key == "chart") chart = val
      else if (key == "name") name = val
      else if (key == "namespace") ns = val
    }
    END { flush() }'
}

# .info.version of the OpenAPI document on stdin: jq when installed, else take the "info"
# object (one level of nesting allowed, for contact/license) and its "version".
openapi_version() {
  if [ "$HAVE_JQ" = true ]; then
    jq -r '.info.version // empty' 2>/dev/null
    return 0
  fi
  tr -d '\n\r\t' \
    | grep -oE '"info"[[:space:]]*:[[:space:]]*\{[^{}]*(\{[^{}]*\}[^{}]*)*\}' | head -n1 \
    | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"([^"]*)"$/\1/'
}

instance=""; source=""
if [ -n "$GW" ]; then
  instance=$(curl -fsSL -m 15 "$GW/api-docs/openapi.json" 2>/dev/null | openapi_version)
  [ -n "$instance" ] && source="$GW/api-docs/openapi.json"
fi
releases=$(helm_releases)
if [ -z "$instance" ] && [ -n "$releases" ]; then
  instance=$(awk -F'\t' '$1 ~ /^backend-/ { print $3; exit }' <<<"$releases")
  [ -n "$instance" ] && source="helm chart version"
fi
instance="${instance#v}"

# Every release heading on the changelog page (id="v<digits>">v<version>), newest first.
versions=$(curl -fsSL -m 15 "$CHANGELOG" 2>/dev/null | grep -oE 'id="v[0-9]+">v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/.*>v//' | awk '!seen[$0]++')
latest=$(head -n1 <<<"$versions")

echo "instance: ${instance:-unknown}${source:+ ($source)}"
echo "latest:   ${latest:-unknown} ($CHANGELOG)"

if [ -z "$instance" ] || [ -z "$latest" ]; then
  echo "status:   unknown"
  exit 1
fi

if [ "$instance" = "$latest" ]; then
  echo "status:   up-to-date"
elif [ "$(printf '%s\n%s\n' "$instance" "$latest" | sort -V | tail -n1)" = "$instance" ]; then
  echo "status:   newer"
else
  behind=$(while read -r v; do
    [ "$(printf '%s\n%s\n' "$v" "$instance" | sort -V | tail -n1)" = "$v" ] && [ "$v" != "$instance" ] && echo "$v"
  done <<<"$versions")
  echo "status:   outdated"
  echo "behind:   $(tr '\n' ' ' <<<"$behind" | sed 's/ $//')"
  oldest=$(tail -n1 <<<"$behind")
  echo "notes:    ${CHANGELOG}#v${oldest//./}"
fi

# Profiler Helm releases in the current kube context, compared with the latest release and
# with the backend, by how many changelog releases apart they are.
rank() { awk -v v="$1" '$0 == v { print NR; exit }' <<<"$versions"; }
backend_rank=$(rank "$instance")
awk -F'\t' '$1 ~ /^profiler-/ { print $2, $3 }' <<<"$releases" | while read -r rel ver; do
  ver="${ver#v}"
  r=$(rank "$ver")
  if [ -z "$r" ] || [ -z "$backend_rank" ]; then state="not in the changelog"
  elif [ "$r" -lt "$backend_rank" ]; then state="newer than the backend; upgrade the backend to $latest"
  elif [ "$r" -eq 1 ]; then state="latest"
  elif [ "$r" -eq "$backend_rank" ]; then state="same as the backend; upgrade both to $latest"
  elif [ $(( r - backend_rank )) -le "$PROFILER_MAX_LAG" ]; then state="$(( r - backend_rank )) behind the backend, still works; upgrade to $latest"
  else state="$(( r - backend_rank )) behind the backend, too far; upgrade to $latest"
  fi
  echo "profiler: $rel ${ver:-unknown} ($state)"
done
exit 0

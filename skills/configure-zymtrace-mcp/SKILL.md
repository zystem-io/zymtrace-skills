---
name: configure-zymtrace-mcp
description: |
  Use when connecting Claude Code (or another MCP client) to the zymtrace MCP server so the user can analyze CPU and GPU flamegraphs through natural-language queries. Walks through finding the gateway URL, generating an auth token (if service-token auth is on), running `claude mcp add`, and verifying the connection via `/mcp`. This skill is plumbing only — the analytical workflow lives in `analyze-zymtrace-workload`.
  Trigger phrases: "connect zymtrace MCP", "set up zymtrace MCP", "configure zymtrace MCP", "add zymtrace to /mcp", "connect Claude to zymtrace", "/mcp doesn't show zymtrace", "zymtrace MCP token", "Cursor zymtrace integration", "set up the zymtrace AI assistant".
metadata:
  version: "26.5.0"
  author: zymtrace
  repository: https://github.com/zystem-io/zymtrace-skills
  tags: zymtrace,mcp,claude-code,cursor,ai-assistant,setup
  tools: claude,curl,kubectl
---

# Configure zymtrace MCP

Helps the user connect Claude Code (or Cursor / Claude Desktop / any MCP client) to their zymtrace backend's MCP server. Once connected, the user can analyze their CPU and GPU flamegraphs with natural-language queries — see [`analyze-zymtrace-workload`](../analyze-zymtrace-workload/SKILL.md) for the analytical workflow.

> The MCP server is part of the zymtrace backend itself — it lives at `<gateway-host>/mcp`. If the backend isn't installed and reachable yet, route to `install-zymtrace-backend` and `expose-zymtrace-backend` first.

## Greet the user

> 👋 Let's connect Claude to your zymtrace MCP so you can analyze flamegraphs in natural language from this terminal. I'll need your zymtrace gateway URL and — if your install has service-token auth on — a token. Five minutes max.
>
> Doc reference: <https://docs.zymtrace.com/mcp/configure-mcp>

Skip the greeting if the user has already volunteered the URL and token.

## Sources of truth

- MCP configuration: <https://docs.zymtrace.com/mcp/configure-mcp>
- MCP token generation: <https://docs.zymtrace.com/mcp/mcp-token>
- MCP overview: <https://docs.zymtrace.com/mcp>

## Pre-flight

##### Claude runs
```bash
claude --version
claude mcp list 2>&1 | head -20
```

If `claude --version` is older than v2.x → MCP support varies by version; recommend updating Claude Code. If `zymtrace` already appears in `claude mcp list`, the connection exists — jump straight to verification (Step 4).

## Pre-resolve what you can

| Variable | Resolve by |
|---|---|
| Backend gateway URL | Ask the user. Typically `https://zymtrace.<their-domain>` or the ALB / Ingress hostname. If installed in-cluster only, see "Port-forward fallback" below. |
| MCP endpoint | `<gateway-url>/mcp` — append `/mcp` to whatever they give you. |
| Auth required? | If the backend has `auth.serviceToken.enabled: true` (check with `kubectl get cm -n <NS> -o yaml \| grep -i serviceToken`), the user needs a token. Otherwise skip. |
| Existing MCP servers | `claude mcp list` — to avoid name collision. |

Things you **must** ask:
- The gateway URL (don't guess).
- Whether they want this connection at user scope (global) or project scope (just this repo).

## Decision: auth or no auth?

| Backend setting | What's needed |
|---|---|
| `auth.serviceToken.enabled: false` (default) | No token. Connection is open within the network that can reach the gateway. |
| `auth.serviceToken.enabled: true` | Token required. Generate one in the zymtrace UI: Settings → Service Tokens → New Token. Full doc: <https://docs.zymtrace.com/mcp/mcp-token>. |

For production exposures behind ALB / NGINX / mTLS, service-token auth is recommended.

---

## Standard flow

### Step 1: Confirm reachability

##### Claude runs
```bash
curl -fsI <gateway-url>/health 2>&1 | head -3
```

Should return HTTP 200/204. If unreachable → the gateway isn't exposed externally; route to [`expose-zymtrace-backend`](../expose-zymtrace-backend/SKILL.md) or use the port-forward fallback below.

### Step 2: Generate a token (only if service-token auth is enabled)

##### What you need to do in a terminal (user-driven)

The token is generated through the zymtrace UI, not by this skill:

1. Open the zymtrace UI: `<gateway-url>` (e.g. `https://zymtrace.acme.com`).
2. Settings → Service Tokens → New Token.
3. Scope it to `mcp` (or whatever scope the org uses).
4. Copy the token immediately — it's shown once. Store it in your password manager or `$ZYMTRACE_MCP_TOKEN` env var.

If your install doesn't have service-token auth on, skip this step.

### Step 3: Confirm with the user before running

Print the exact command:

```bash
claude mcp add zymtrace --transport http <gateway-url>/mcp \
  --header "Authorization: Bearer $ZYMTRACE_MCP_TOKEN"   # only if auth is on
```

Wait for explicit confirmation. The `$ZYMTRACE_MCP_TOKEN` placeholder means **the user exports the token in their shell first** — never inline the literal token in the conversation or in files.

### Step 4: Add the MCP server

##### What you need to do in a terminal

The user runs this (not the skill — the token is in their env):

```bash
# Auth-on case
export ZYMTRACE_MCP_TOKEN="<paste-token>"
claude mcp add zymtrace --transport http <gateway-url>/mcp \
  --header "Authorization: Bearer $ZYMTRACE_MCP_TOKEN"

# Auth-off case
claude mcp add zymtrace --transport http <gateway-url>/mcp
```

For **project scope** instead of user scope, add `--scope project` and the MCP config lands in `.claude/settings.json` for the current repo.

### Step 5: Verify

##### Claude runs
```bash
claude mcp list | grep -i zymtrace
```

Should show the zymtrace server with `Connected` status. In a fresh Claude Code session, run `/mcp` and confirm `zymtrace` is listed.

Quick functional test:
> Ask Claude (in a new session): *"Using zymtrace MCP, list the top 5 hottest CPU functions from the last 1 hour."*

If Claude returns data, the connection works. If it errors with `unauthorized` → token wrong, regenerate. If it errors with `connection refused` → gateway URL wrong or unreachable.

### Step 6: Hand off

Direct the user to [`analyze-zymtrace-workload`](../analyze-zymtrace-workload/SKILL.md) for the analytical workflow — workload classification (inference vs training), GPU↔CPU cross-view, pattern catalogues. That's where the connected MCP actually gets used.

### Optional: pair with the GitHub MCP for code-level fixes

If the user also connects the **GitHub MCP**, Claude can pair the flamegraph analysis with the actual codebase — locating the hot function in their repo and proposing a specific edit (PR-ready), not just a generic recommendation.

##### What you need to do in a terminal

```bash
# Anthropic's first-party GitHub MCP, scoped to the relevant repo(s)
claude mcp add github --transport http https://api.githubcopilot.com/mcp/ \
  --header "Authorization: Bearer $GITHUB_TOKEN"
```

Then in a session: *"Analyze my GPU workload over the last hour, use the github MCP to find the code path in `myorg/myrepo`, and suggest a fix."* Claude pulls the flamegraph from zymtrace, locates the hot frame in the repo via GitHub MCP, and proposes the edit. The two MCPs compose without any extra configuration on the skill side.

---

## Port-forward fallback (for in-cluster-only gateways)

If the gateway has no external exposure (still `ClusterIP`), the user can MCP through a port-forward.

##### What you need to do in a terminal

```bash
kubectl port-forward -n <backend-NS> svc/<PREFIX>-gateway 8080:80
# Leave this running, then in another shell:
claude mcp add zymtrace --transport http http://localhost:8080/mcp
```

This is fine for dev / one-off investigations. For team-wide use, run [`expose-zymtrace-backend`](../expose-zymtrace-backend/SKILL.md) to give the gateway a real hostname.

---

## Done

- [ ] `claude mcp list` shows `zymtrace` with `Connected` status.
- [ ] `/mcp` in a fresh Claude Code session lists zymtrace.
- [ ] A test query (e.g. "list top 5 hottest CPU functions in the last hour") returns data.

If all three check, hand off to [`analyze-zymtrace-workload`](../analyze-zymtrace-workload/SKILL.md).

## Common pitfalls

- **`/mcp` doesn't show zymtrace after `claude mcp add`** → wrong shell scope. If you used `--scope project`, the server only appears when Claude Code runs in that repo. Add with no `--scope` flag (or `--scope user`) for global access.
- **`unauthorized` on every query** → token wrong, scoped wrong, or expired. Regenerate in Settings → Service Tokens.
- **`connection refused`** → gateway URL typo, missing `/mcp` suffix, or backend not exposed externally. Test with `curl -I <gateway-url>/health` first.
- **`Mixed Content` in browser when testing UI on HTTP gateway** → use HTTPS via [`expose-zymtrace-backend`](../expose-zymtrace-backend/SKILL.md). MCP can stay on the same URL.
- **Token committed to a values file or pasted into the session** → revoke it in the UI immediately and re-issue. Tokens belong only in env vars or password managers.

## Security constraints

- **Never** inline the MCP token in the conversation, values files, scripts, commits, or `claude mcp add` arguments. Always reference an env var (`$ZYMTRACE_MCP_TOKEN`) the user exports.
- **Never** generate, copy, or store the token on the user's behalf — the user pastes it once into their shell or password manager; the skill never sees it.
- **Never** run `claude mcp add` for them without explicit confirmation of the exact command + gateway URL.
- **Never** suggest disabling auth as a "fix" for an auth error. The fix is a valid token, not less security.
- **Never** declare the connection done without re-running `/mcp` or `claude mcp list` to verify.

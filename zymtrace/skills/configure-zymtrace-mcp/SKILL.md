---
name: configure-zymtrace-mcp
description: |
  Use when connecting a coding agent — Claude Code, OpenAI Codex, or Cursor — to the zymtrace MCP server so the user can analyze CPU and GPU flamegraphs through natural-language queries. Walks through finding the gateway URL, generating an auth token (if service-token auth is on), adding the server with the right command for the user's client, and verifying the connection. This skill is plumbing only — the analytical workflow lives in `optimize-cpu-workloads` and `optimize-gpu-workloads`.
  Trigger phrases: "connect zymtrace MCP", "set up zymtrace MCP", "configure zymtrace MCP", "add zymtrace to /mcp", "connect Claude/Codex/Cursor to zymtrace", "/mcp doesn't show zymtrace", "zymtrace MCP token", "Cursor zymtrace integration", "set up the zymtrace AI assistant".
---

# Configure zymtrace MCP

Helps the user connect their coding agent — **Claude Code, OpenAI Codex, or Cursor** — to their zymtrace backend's MCP server. Once connected, the user can analyze their CPU and GPU flamegraphs with natural-language queries — see [`optimize-cpu-workloads`](../optimize-cpu-workloads/SKILL.md) (CPU-only) or [`optimize-gpu-workloads`](../optimize-gpu-workloads/SKILL.md) (GPU) for the analytical workflow.

> The MCP server is part of the zymtrace backend itself — it lives at `<gateway-host>/mcp`. If the backend isn't installed and reachable yet, route to `install-zymtrace-backend` and `expose-zymtrace-backend` first.

**Which client?** The URL, token, and reachability steps are identical for every client; only the *add-the-server* command differs (Step 3–4). Detect the client from context — which agent is running this, or what the user says ("connect Codex", "Cursor") — and use that client's block. If unsure, ask: *"Claude Code, Codex, or Cursor?"*

## Greet the user

> 👋 Let's connect your agent to the zymtrace MCP so you can analyze flamegraphs in natural language. I'll need your zymtrace URL and — if your install has service-token auth on — a token. Five minutes max.
>
> Doc reference: <https://docs.zymtrace.com/mcp/configure-mcp>

Skip the greeting if the user has already volunteered the URL and token.

## Sources of truth

- MCP configuration: <https://docs.zymtrace.com/mcp/configure-mcp>
- Service tokens (auth): <https://docs.zymtrace.com/authentication/service-tokens>
- MCP overview: <https://docs.zymtrace.com/mcp>

## Pre-flight

Check whether zymtrace is already connected in the user's client:

| Client | Check |
|---|---|
| Claude Code | `claude mcp list 2>&1 \| head -20` (and `claude --version` — older than v2.x: MCP support varies, recommend updating) |
| Codex | `codex mcp list 2>&1 \| head -20` |
| Cursor | open `~/.cursor/mcp.json` (or project `.cursor/mcp.json`); or Settings → MCP/Tools |

If `zymtrace` already appears, the connection exists — jump straight to verification (Step 5).

## Pre-resolve what you can

| Variable | Resolve by |
|---|---|
| Backend gateway URL | Ask the user. Typically `https://zymtrace.<their-domain>` or the ALB / Ingress hostname. If installed in-cluster only, see "Port-forward fallback" below. |
| MCP endpoint | `<gateway-url>/mcp` — append `/mcp` to whatever they give you. |
| Auth required? | If the backend has `auth.serviceToken.enabled: true` (check with `kubectl get cm -n <NS> -o yaml \| grep -i serviceToken`), the user needs a token. Otherwise skip. |
| Existing MCP servers | the client's MCP list (Pre-flight table) — to avoid name collision. |

Things you **must** ask:
- The zymtrace URL (don't guess).
- Which client they're connecting (Claude Code / Codex / Cursor), if not already clear.
- For Claude Code / Codex: user scope (global) or project scope (just this repo).

## Decision: auth or no auth?

| Backend setting | What's needed |
|---|---|
| `auth.serviceToken.enabled: false` (default) | No token. Connection is open within the network that can reach the gateway. |
| `auth.serviceToken.enabled: true` | Token required. Ask the user to generate a service token in the zymtrace UI: Settings → Service Tokens → New Token. Full doc: <https://docs.zymtrace.com/authentication/service-tokens>. |

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

If the MCP (or the REST API) requires authentication, **ask the user to generate a zymtrace service token** — the skill never creates or sees it. Reference: <https://docs.zymtrace.com/authentication/service-tokens>.

##### What you need to do in a terminal (user-driven)

The token is generated through the zymtrace UI, not by this skill:

1. Open the zymtrace UI: `<gateway-url>` (e.g. `https://zymtrace.acme.com`).
2. Settings → Service Tokens → New Token.
3. Scope it to `mcp` (or whatever scope the org uses).
4. Copy the token immediately — it's shown once. Store it in your password manager or `$ZYMTRACE_MCP_TOKEN` env var.

If your install doesn't have service-token auth on, skip this step.

### Step 3: Confirm with the user before running

Print the exact command/edit for **their** client (Step 4) and wait for explicit confirmation. In every case the token stays in an env var the **user** exports first (`$ZYMTRACE_MCP_TOKEN`) — never inline the literal token in the conversation or in files.

### Step 4: Add the MCP server — pick the user's client

The user runs/edits this themselves (the token is in their env, not the skill's). Replace `<gateway-url>` with their URL; drop the auth header/line entirely if service-token auth is off.

**Claude Code**
```bash
export ZYMTRACE_MCP_TOKEN="<paste-token>"   # only if auth is on
claude mcp add zymtrace --transport http <gateway-url>/mcp \
  --header "Authorization: Bearer $ZYMTRACE_MCP_TOKEN"   # drop this line if auth is off
```
For **project scope** instead of user scope, add `--scope project` (config lands in `.claude/settings.json`).

**OpenAI Codex**
```bash
export ZYMTRACE_MCP_TOKEN="<paste-token>"   # only if auth is on
codex mcp add zymtrace --url <gateway-url>/mcp \
  --bearer-token-env-var ZYMTRACE_MCP_TOKEN   # drop this line if auth is off
```
Codex stores it as a `streamable_http` server in `~/.codex/config.toml`.

**Cursor** — no CLI; add an entry to `~/.cursor/mcp.json` (global) or `.cursor/mcp.json` (this project):
```json
{
  "mcpServers": {
    "zymtrace": {
      "url": "https://<gateway-url>/mcp",
      "headers": { "Authorization": "Bearer ${env:ZYMTRACE_MCP_TOKEN}" }
    }
  }
}
```
Drop the `"headers"` field entirely if auth is off. Cursor resolves `${env:ZYMTRACE_MCP_TOKEN}` from the environment, so the literal token still never lands in the file.

### Step 5: Verify

Confirm the server is registered in the user's client:

| Client | Verify |
|---|---|
| Claude Code | `claude mcp list \| grep -i zymtrace` → `Connected`; in a fresh session `/mcp` lists `zymtrace`. |
| Codex | `codex mcp list \| grep -i zymtrace`; restart Codex and confirm zymtrace appears in `/mcp`. |
| Cursor | Settings → MCP/Tools shows `zymtrace` with a green/active indicator. |

Quick functional test (any client), in a new session:
> *"Using zymtrace MCP, list the top 5 hottest CPU functions from the last 1 hour."*

If it returns data, the connection works. `unauthorized` → token wrong, regenerate. `connection refused` → URL wrong or unreachable.

### Step 6: Hand off

Direct the user to the analytical workflow — [`optimize-cpu-workloads`](../optimize-cpu-workloads/SKILL.md) for CPU-only deployments, [`optimize-gpu-workloads`](../optimize-gpu-workloads/SKILL.md) for GPU workloads (it adds the GPU↔CPU cross-view and inference-server pattern catalogues), or [`optimize-memory-allocation`](../optimize-memory-allocation/SKILL.md) for JVM memory-allocation / GC analysis (Java only). That's where the connected MCP actually gets used.

### Optional: pair with the GitHub MCP for code-level fixes

If the user also connects the **GitHub MCP**, Claude can pair the flamegraph analysis with the actual codebase — locating the hot function in their repo and proposing a specific edit (PR-ready), not just a generic recommendation.

##### What you need to do in a terminal

Add the GitHub MCP (`https://api.githubcopilot.com/mcp/`, bearer `$GITHUB_TOKEN`) with the **same Step 4 mechanism** as your client — e.g. Claude Code:
```bash
claude mcp add github --transport http https://api.githubcopilot.com/mcp/ \
  --header "Authorization: Bearer $GITHUB_TOKEN"
```
(Codex: `codex mcp add github --url https://api.githubcopilot.com/mcp/ --bearer-token-env-var GITHUB_TOKEN`; Cursor: a second entry in `mcp.json`.)

Then in a session: *"Analyze my GPU workload over the last hour, use the github MCP to find the code path in `myorg/myrepo`, and suggest a fix."* The agent pulls the flamegraph from zymtrace, locates the hot frame in the repo via GitHub MCP, and proposes the edit. The two MCPs compose without any extra configuration on the skill side.

---

## Port-forward fallback (for in-cluster-only gateways)

If the gateway has no external exposure (still `ClusterIP`), the user can MCP through a port-forward.

##### What you need to do in a terminal

```bash
kubectl port-forward -n <backend-NS> svc/<PREFIX>-gateway 8080:80
# Leave this running, then add http://localhost:8080/mcp via your client's Step 4 command
# (Claude: claude mcp add … http://localhost:8080/mcp; Codex: codex mcp add … --url http://localhost:8080/mcp;
#  Cursor: "url": "http://localhost:8080/mcp" in mcp.json). Auth is usually off for a local port-forward.
```

This is fine for dev / one-off investigations. For team-wide use, run [`expose-zymtrace-backend`](../expose-zymtrace-backend/SKILL.md) to give the gateway a real hostname.

---

## Done

- [ ] The client's MCP list (Step 5) shows `zymtrace` connected.
- [ ] A test query (e.g. "list top 5 hottest CPU functions in the last hour") returns data.

If both check, hand off to [`optimize-cpu-workloads`](../optimize-cpu-workloads/SKILL.md) (CPU-only), [`optimize-gpu-workloads`](../optimize-gpu-workloads/SKILL.md) (GPU), or [`optimize-memory-allocation`](../optimize-memory-allocation/SKILL.md) (JVM memory/GC).

## Common pitfalls

- **zymtrace doesn't appear after adding it** → wrong scope or stale session. Claude Code: if you used `--scope project`, it only shows in that repo — re-add with `--scope user` (or no flag). Codex/Cursor: restart the app so it re-reads the config.
- **`unauthorized` on every query** → token wrong, scoped wrong, or expired. Regenerate in Settings → Service Tokens.
- **`connection refused`** → gateway URL typo, missing `/mcp` suffix, or backend not exposed externally. Test with `curl -I <gateway-url>/health` first.
- **`Mixed Content` in browser when testing UI on HTTP gateway** → use HTTPS via [`expose-zymtrace-backend`](../expose-zymtrace-backend/SKILL.md). MCP can stay on the same URL.
- **Token committed to a values file or pasted into the session** → revoke it in the UI immediately and re-issue. Tokens belong only in env vars or password managers.

## Security constraints

- **Never** inline the MCP token in the conversation, values files, scripts, commits, `mcp.json`, or any MCP-add command arguments. Always reference an env var (`$ZYMTRACE_MCP_TOKEN`, or `${env:ZYMTRACE_MCP_TOKEN}` in Cursor's `mcp.json`) the user exports.
- **Never** generate, copy, or store the token on the user's behalf — the user pastes it once into their shell or password manager; the skill never sees it.
- **Never** add the server for them (run the CLI command or edit `mcp.json`) without explicit confirmation of the exact command/edit + gateway URL.
- **Never** suggest disabling auth as a "fix" for an auth error. The fix is a valid token, not less security.
- **Never** declare the connection done without verifying via the client's MCP list (Step 5).

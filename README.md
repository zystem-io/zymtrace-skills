# zymtrace-skills

Claude Code skills for installing, upgrading, and operating [**zymtrace**](https://zymtrace.com) — the continuous CPU and GPU profiling and optimization platform.

Once installed, describe what you want in plain English and Claude Code handles the rest:

```
"install zymtrace on my eks cluster"
"upgrade zymtrace to 26.5.0"
"expose the gateway via internal alb"
"install the profiler with gpu support"
"no profiles showing up in the ui. why?"
"connect zymtrace mcp so I can analyze my profiles from here"
"analyze my vllm workload — find the bottleneck"
"analyze the gpu flamegraph over the last 1 hour and suggest solutions"   # ← the universal starter
```

## What's inside

| Skill | What it does |
|-------|-------------|
| [`install-zymtrace-backend`](skills/install-zymtrace-backend/) | Install the backend on Kubernetes (Helm) or Docker Compose. Handles license, databases, air-gapped registries. |
| [`upgrade-zymtrace-backend`](skills/upgrade-zymtrace-backend/) | Bump image tags, chart versions, or both. Built-in rollback and verification. |
| [`expose-zymtrace-backend`](skills/expose-zymtrace-backend/) | Expose the gateway via NodePort, AWS ALB, NGINX Ingress, or cloud LoadBalancer. TLS included. |
| [`install-zymtrace-profiler`](skills/install-zymtrace-profiler/) | Install the agent on Kubernetes, Docker, or bare-metal. CPU + CUDA GPU profiling (CUDA 12.x+). |
| [`troubleshoot-zymtrace-backend`](skills/troubleshoot-zymtrace-backend/) | Diagnose "no data appearing", license errors, ingest crashes, slow queries, storage issues. |
| [`troubleshoot-zymtrace-profiler`](skills/troubleshoot-zymtrace-profiler/) | Diagnose agent-side failures — CrashLoopBackOff, OOMKilled, NVML missing, PC sampling, license rejected. |
| [`configure-zymtrace-mcp`](skills/configure-zymtrace-mcp/) | Connect Claude Code (or any MCP client) to the zymtrace MCP server so you can analyze profiles with natural-language queries. |
| [`analyze-zymtrace-workload`](skills/analyze-zymtrace-workload/) | Investigate a GPU or CPU workload through the MCP — classify (inference vs training), pull GPU + matching CPU flamegraphs, recommend a fix. |

## Install

### Recommended — as a Claude Code plugin

Inside any Claude Code session, run:

```text
/plugin marketplace add zystem-io/zymtrace-skills
/plugin install zymtrace@zymtrace-skills
/reload-plugins
```

That's it. Skills become available as `/zymtrace:install-zymtrace-backend`, `/zymtrace:upgrade-zymtrace-backend`, and so on.

### Alternative — local install

If you'd rather not go through Claude's plugin system, install the skills directly.

Get the files (pick whichever you have):

```bash
# With git
git clone https://github.com/zystem-io/zymtrace-skills.git ~/zymtrace-skills

# Or without git (curl + tar)
curl -fsSL https://github.com/zystem-io/zymtrace-skills/archive/refs/heads/main.tar.gz \
  | tar -xz -C "$HOME" \
  && mv "$HOME/zymtrace-skills-main" "$HOME/zymtrace-skills"
```

Then copy the skills into your Claude Code skills folder:

```bash
mkdir -p ~/.claude/skills
cp -R ~/zymtrace-skills/skills/* ~/.claude/skills/
```

Start a new Claude Code session and you're ready. To get updates later, redownload and re-run the copy command.

## How to use

Describe what you want — Claude Code routes to the right skill automatically. Or invoke a skill directly with its name:

```
/zymtrace:install-zymtrace-backend
/zymtrace:upgrade-zymtrace-backend
/zymtrace:expose-zymtrace-backend
/zymtrace:install-zymtrace-profiler
/zymtrace:troubleshoot-zymtrace-backend
```

(If you used the symlink path above, drop the `zymtrace:` namespace — invoke as `/install-zymtrace-backend`, etc.)

### See what's installed

Run **`/skills`** in any Claude Code session to see the full list with token costs and on/off toggles. You should see all five zymtrace skills:

```
✓ on  expose-zymtrace-backend         ·  user  ·  ~100 tok
✓ on  install-zymtrace-backend        ·  user  ·  ~120 tok
✓ on  install-zymtrace-profiler       ·  user  ·  ~170 tok
✓ on  troubleshoot-zymtrace-backend   ·  user  ·  ~120 tok
✓ on  upgrade-zymtrace-backend        ·  user  ·  ~100 tok
```

Each skill walks you through the decisions, runs the right commands, and verifies the result. You stay in the driver's seat — every change is confirmed with you first.

## Need a license or help?

- **Free CPU profiling**: works without any license.
- **GPU profiling**: ask the team for a generous free trial at <https://zymtrace.com/getstarted/>.
- **Community Slack**: <https://join.slack.com/t/zymtrace/shared_invite/zt-3fdidjufl-q~NHxDzQlzal2B9mujfaoQ>
- **Email**: <support@zymtrace.com>

## What's next

Once your backend is up and the profiler is reporting, run `/mcp` in Claude Code to connect to the zymtrace MCP server and analyze GPU and CPU flamegraphs straight from the terminal. Docs: <https://docs.zymtrace.com/mcp>

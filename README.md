# zymtrace-skills

Skills for installing, upgrading, and operating [**zymtrace**](https://zymtrace.com) — the continuous CPU and GPU profiling and optimization platform. Works in **Claude Code**, **OpenAI Codex**, and **Cursor** from the same source.

Once installed, describe what you want in plain English and your coding agent handles the rest:

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

<video src="https://github.com/user-attachments/assets/b76a4b61-7f67-4875-9fab-6502b59d2909
" controls muted loop width="90%"></video>

## What's inside




| Skill | What it does |
|-------|-------------|
| [`install-zymtrace-backend`](zymtrace/skills/install-zymtrace-backend/) | Install the backend on Kubernetes (Helm) or Docker Compose. Handles license, databases, air-gapped registries. |
| [`upgrade-zymtrace-backend`](zymtrace/skills/upgrade-zymtrace-backend/) | Bump image tags, chart versions, or both. Built-in rollback and verification. |
| [`expose-zymtrace-backend`](zymtrace/skills/expose-zymtrace-backend/) | Expose the gateway via NodePort, AWS ALB, NGINX Ingress, or cloud LoadBalancer. TLS included. |
| [`install-zymtrace-profiler`](zymtrace/skills/install-zymtrace-profiler/) | Install the agent on Kubernetes, Docker, or bare-metal. CPU + CUDA GPU profiling (CUDA 12.x+). |
| [`troubleshoot-zymtrace-backend`](zymtrace/skills/troubleshoot-zymtrace-backend/) | Diagnose "no data appearing", license errors, ingest crashes, slow queries, storage issues. |
| [`troubleshoot-zymtrace-profiler`](zymtrace/skills/troubleshoot-zymtrace-profiler/) | Diagnose agent-side failures — CrashLoopBackOff, OOMKilled, NVML missing, PC sampling, license rejected. |
| [`configure-zymtrace-mcp`](zymtrace/skills/configure-zymtrace-mcp/) | Connect Claude Code (or any MCP client) to the zymtrace MCP server so you can analyze profiles with natural-language queries. |
| [`analyze-zymtrace-workload`](zymtrace/skills/analyze-zymtrace-workload/) | Investigate a GPU or CPU workload through the MCP — classify (inference vs training), pull GPU + matching CPU flamegraphs, recommend a fix. |

### Agent (Claude Code only)

> The skills work in all three tools. The subagent below is currently only supported on Claude Code.

| Agent | What it does |
|-------|-------------|
| [`zymtrace-perf-engineer`](zymtrace/agents/zymtrace-perf-engineer.md) | Autonomous, hands-off performance investigation. Identifies the entity (script for Python, container, host, or k8s pod/deployment), pulls its metrics, then the CPU flamegraph — and the GPU flamegraph when it's a GPU workload — and returns a finished recap without stopping to confirm each step. Runs several in parallel. Invoke it by name (e.g. "use the zymtrace-perf-engineer to analyze my vLLM GPU workload"). |


## Supported tools

The same skills install into any of these agents. The repo carries a per-tool manifest; there's one canonical copy of the skills underneath.

| Tool | Install |
|------|---------|
| **Claude Code** | `claude plugin marketplace add zystem-io/zymtrace-skills` → `claude plugin install zymtrace@zymtrace-skills` |
| **OpenAI Codex** | `codex plugin marketplace add zystem-io/zymtrace-skills`, then install **zymtrace** via `/plugins` |
| **Cursor** | Settings → **Plugins** → **Team Marketplaces** → **Import** → paste the repo URL |

## Install

### Claude Code

Inside any Claude Code session (or your terminal), run:

```bash
claude plugin marketplace add zystem-io/zymtrace-skills
claude plugin install zymtrace@zymtrace-skills
```

That's it. Skills become available as `/zymtrace:install-zymtrace-backend`, `/zymtrace:upgrade-zymtrace-backend`, and so on. (`claude plugin marketplace list` confirms the marketplace was added, but it's the `install` step that enables the skills.)

### OpenAI Codex

```bash
codex plugin marketplace add zystem-io/zymtrace-skills
```

Then run `/plugins` in Codex and install **zymtrace** from the marketplace.

### Cursor

1. Open **Dashboard → Settings → Plugins**.
2. Under **Team Marketplaces**, click **Import**.
3. Paste the repository URL `https://github.com/zystem-io/zymtrace-skills` and continue.
4. Review the parsed **zymtrace** plugin, set access/name as you like, and save.

## How to use

Describe what you want — Claude Code routes to the right skill automatically. Or invoke a skill directly with its name:

```
/zymtrace:install-zymtrace-backend
/zymtrace:upgrade-zymtrace-backend
/zymtrace:expose-zymtrace-backend
/zymtrace:install-zymtrace-profiler
/zymtrace:troubleshoot-zymtrace-backend
```

Each skill walks you through the decisions, runs the right commands, and verifies the result. You stay in the driver's seat — every change is confirmed with you first.

### The agent (hands-off mode, Claude Code only)

For an investigation you want to run *unattended*, hand the whole thing to the **`zymtrace-perf-engineer`** agent (Claude Code only) — name it in your request:

```
"use the zymtrace-perf-engineer to analyze my vLLM GPU workload over the last hour"
"have the zymtrace-perf-engineer profile the inference deployment and report back"
```

It identifies the entity, pulls metrics, then the flamegraph(s), and returns one finished recap — without stopping to confirm each step. Run several at once to triage multiple workloads in parallel. Run **`/agents`** to see it in the live list. Unlike the skills, it runs autonomously, so the read-only profile pulls don't prompt for each step.

### See what's installed

Run **`/skills`** and **`/agents`** in any session to see the components with on/off toggles. For the full inventory and per-component token cost, run:

```bash
claude plugin details zymtrace
```

```text
Component inventory
  Skills (8)  analyze-zymtrace-workload, configure-zymtrace-mcp, expose-zymtrace-backend,
              install-zymtrace-backend, install-zymtrace-profiler, troubleshoot-zymtrace-backend,
              troubleshoot-zymtrace-profiler, upgrade-zymtrace-backend
  Agents (1)  zymtrace-perf-engineer
```

The command also prints a live per-component token-cost breakdown (always-on vs on-invoke).

## Contributing

Clone the repo and install the plugin from the local checkout — loads as a plugin, so `${CLAUDE_PLUGIN_ROOT}` and the helper scripts resolve:

```bash
git clone https://github.com/zystem-io/zymtrace-skills.git
cd zymtrace-skills
claude plugin validate ./zymtrace              # fast check: manifest parses (plugin root is zymtrace/)
claude plugin marketplace add "$PWD"           # register the repo-root marketplace (zymtrace-skills)
claude plugin install zymtrace@zymtrace-skills # install from it; restart to apply
```

After editing, re-read the local manifest and restart: `claude plugin marketplace update zymtrace-skills`.

Or symlink as personal skills (no `${CLAUDE_PLUGIN_ROOT}`, so bundled scripts won't resolve):

```bash
mkdir -p ~/.claude/skills
ln -s "$PWD"/zymtrace/skills/*/ ~/.claude/skills/
```

Run the tests before committing:

```bash
python -m venv .venv && source .venv/bin/activate
make install   # pytest + PyYAML
make test      # structural tests — layout, frontmatter, version sync, path checks
```

The structural suite needs no API keys, cluster, or network, and runs in CI on every branch. See [CLAUDE.md](CLAUDE.md) for repo conventions and how to add a skill.

## What's next

Once your backend is up and the profiler is reporting, run `/mcp` in Claude Code to connect to the zymtrace MCP server and analyze GPU and CPU flamegraphs straight from the terminal. Docs: <https://docs.zymtrace.com/mcp>

## Support 

- **Community Slack**: <https://join.slack.com/t/zymtrace/shared_invite/zt-3fdidjufl-q~NHxDzQlzal2B9mujfaoQ>
- **Email**: <support@zymtrace.com>

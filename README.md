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


<img width="886" height="514" alt="Image" src="https://github.com/user-attachments/assets/e0e0dcba-2496-4ea6-8dbf-1a519b403546" />


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


## Install

### Recommended — as a Claude Code plugin

Inside any Claude Code session, run:

```bash
claude plugin marketplace add zystem-io/zymtrace-skills

claude plugin install zymtrace@zymtrace-skills
```

That's it. Skills become available as `/zymtrace:install-zymtrace-backend`, `/zymtrace:upgrade-zymtrace-backend`, and so on.

(`claude plugin marketplace list` is handy to confirm the marketplace was added, but it's the `install` step that actually enables the skills.)

## How to use

Describe what you want — Claude Code routes to the right skill automatically. Or invoke a skill directly with its name:

```
/zymtrace:install-zymtrace-backend
/zymtrace:upgrade-zymtrace-backend
/zymtrace:expose-zymtrace-backend
/zymtrace:install-zymtrace-profiler
/zymtrace:troubleshoot-zymtrace-backend
```

### See what's installed

Run **`/skills`** in any Claude Code session to see the full list with token costs and on/off toggles. You should see all eight zymtrace skills:


Each skill walks you through the decisions, runs the right commands, and verifies the result. You stay in the driver's seat — every change is confirmed with you first.

## Contributing

Clone the repo and install the plugin from the local path — loads as a plugin, so `${CLAUDE_PLUGIN_ROOT}` and the helper scripts resolve:

```bash
git clone https://github.com/zystem-io/zymtrace-skills.git
cd zymtrace-skills
claude plugin add ./zymtrace
```

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

---
name: optimize-cpu-workloads
description: |
  Analyze CPU performance with zymtrace on CPU-only deployments (no GPUs) — rank the top CPU consumers (which process/function/container/host/pod is hottest), find what's eating CPU, pick the biggest-ROI app to optimize, or read a CPU flamegraph. The zymtrace MCP pulls the data (rankings, host metrics, flamegraphs); YOU analyze — name the hot stacks, identify the pattern (lock contention, allocation churn, serialization, GC, syscall-heavy), then recommend AND apply the fix in the user's source (ask for the path if it isn't local) and close with a follow-up. Scope to code the user controls (kube-proxy, k3s, systemd are context, not action items). Also for "investigate/troubleshoot/diagnose/look into" CPU or host performance. **DEFAULT when the user names only an entity with no accelerator hint** ("investigate my `payments` deployment", "what's going on with this container/pod/host", "why is this service slow") — CPU is the universal baseline (every workload has a CPU profile; GPU is the special case); pull metrics first and hand off to optimize-gpu-workloads if they show real GPU activity. Anything mentioning GPU, CUDA, an accelerator, inference, vLLM, SGLang, or Triton goes to optimize-gpu-workloads instead.
  Trigger phrases: "use zymtrace to analyze CPU profiles", "investigate/troubleshoot/diagnose my CPU usage", "investigate my deployment/container/pod/host/service", "what's going on with <service>", "why is this service slow", "what's eating my CPU", "which process/function uses the most CPU core", "find the most expensive functions/containers/app/service", "rank my apps by CPU", "biggest ROI optimization", "what should I optimize first", "where's the CPU bottleneck", "why is this service CPU-bound", "analyze the CPU flamegraph", "top CPU consumers".
---

# Optimize CPU Workloads

> The MCP fetches the data — hot traces, flamegraphs, host metrics, top functions, top entities; **you** analyze: name the hot stacks, identify the pattern, recommend and apply the fix.

**For CPU-only deployments.** This skill stays entirely on the CPU side — no GPU view, no GPU metrics, no inference-server (vLLM/SGLang/Triton) framing. A CPU-only customer never needs any of that. **Running GPU workloads?** Use [`optimize-gpu-workloads`](../optimize-gpu-workloads/SKILL.md) instead — there, cross-checking the GPU and CPU sides together is the load-bearing step.

The common discipline — data-source policy, pre-flight, rank-first vs. drill-down, scope-to-own-code/ROI, the always-recommend-and-apply-the-fix rule, the output-template skeleton, severity sizing, and security — lives in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md). **Read it.** This skill adds the CPU-specific profiles and call-tree rendering on top.

Connection setup lives in [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md); this skill assumes the MCP is connected.

## Standard starter prompts (for users who don't know what to ask)

> **"What's is consuming the most CPU coreover the last 1 hour?"** · **"Which of my apps should I optimize first?"**

Most CPU requests are **rank-first** (see the shared doc): the user wants to know *which* thing is hottest or where the best return is. Start by ranking with the MCP's **topentities** (hottest container/pod/host/process) or **topfunctions** (hottest functions), then drill into the top user-owned code with `hot_traces`. The recap leads with the ranking, then the analysis of that entry. If the user already named a workload ("analyze my API service"), skip the ranking and drill straight in.

Default to the last 1 hour if no range is given, and the whole cluster if no workload is named (ask which to narrow if results look noisy).

## The CPU analysis protocol

The MCP pulls the data; you do the analysis. Establish a data path first (pre-flight, in the shared doc).

1. **Rank first if the request is rank-shaped** ("what's eating my CPU", "which process", "biggest ROI") — use **topentities** / **topfunctions** (concise rankings), then drill into the top entry with `hot_traces`. **Rank by cores consumed** (CPU-cores, i.e. the absolute on-CPU time the entity holds — not just % of one core), so the ranking reflects real machine cost. Present it as a **table** (see [Ranking table](#ranking-table-rank-first-output)) — one row per consumer with cores over the window, **annualized core-hours** (`cores × 8,760`), and **annualized cost** only; host / container / deployment go in a reference line below the table, not as columns. Then pick the top entry. Mark third-party / unmodifiable system processes (kube-proxy, kubelet, systemd, the kernel) with **❌** and drill into the highest user-owned entry. See scope-to-own-code/ROI in the shared doc.

2. **Pull the entity's CPU metrics first, for context.** CPU utilization (and run-queue / throttling if available) — to establish how hot the workload actually runs and whether it's CPU-bound or stalled (waiting on locks, I/O, syscalls). Carry these numbers into the recap.

   **Escalation check (when you arrived here by the entity-only default).** If the metrics show **real GPU activity** (non-trivial GPU utilization / memory), this is a GPU workload, not a CPU-only one — stop and hand off to [`optimize-gpu-workloads`](../optimize-gpu-workloads/SKILL.md) for the GPU↔CPU cross-view. Don't analyze a GPU workload from the CPU side alone. (Skip this when the user explicitly asked a CPU question, or the deployment has no GPUs.)

3. **Pull the CPU call tree** at the scope the user named (executable / container / pod / host / time range) — use the **`hot_traces`** MCP tool when available (zymtrace 26.5.1+), else fall back to **`flamegraph`** (see the data-source policy in the shared doc). Read which frames are hot from the returned data.

4. **Name the pattern.** The MCP returns raw frames + percentages; naming the dominant pattern is *your* job. Common CPU patterns:
   - **Lock contention / scheduling** — time in `futex`, `pthread_mutex_lock`, `sync.(*Mutex).Lock`, runtime scheduler frames.
   - **Allocation churn / GC** — `malloc`/`free`, `gc`, `mark`, `tcmalloc`, allocator frames dominating; **on a Java service** hand off to [`optimize-memory-allocation`](../optimize-memory-allocation/SKILL.md) to name the allocation sites (JVM only).
   - **Serialization / parsing** — JSON/protobuf encode-decode, regex compilation, string formatting in the hot path.
   - **Syscall- / I/O-bound** — heavy `read`/`write`/`epoll_wait`/`send`/`recv`; the CPU is shuffling bytes or waiting.
   - **Compute hot loop** — a single user function genuinely dominating CPU time (the clean ROI case).

5. **Write the recap** using the output template (shared doc) with the CPU call-tree rendering below.

6. **Apply the fix** (shared doc — "Always recommend a fix — then apply it"). The recap is the midpoint, not the finish line.

## Cost: annualize the cores

A "cores consumed" figure is an average rate — N vCPUs held continuously over the window — so it annualizes directly. Always turn cores into money; percentages don't move budgets.

- **Annualized core-hours = cores × 8,760 h** — the window's average vCPU rate projected to a full year (the "annualized CPU core" figure for the table).
- **Annual cost ≈ annualized core-hours × per-vCPU-hour rate** (= cores × rate × 8,760).
- **Rate:** use the user's actual per-vCPU cost if known (cloud instance price, fully-loaded chargeback). **Check the repo's agent-instructions file first** for a saved rate (look for a `zymtrace-vcpu-rate` line in `AGENTS.md`, or `CLAUDE.md` for Claude Code). If none, default to **$0.04 / vCPU-hour (≈ $350 / core-year)**, **label it an assumption in the recap, and ask the user for their real rate.** When they give one, **offer to persist it** — add a `zymtrace-vcpu-rate: $<rate>/vCPU-hour` line to that agent-instructions file (`AGENTS.md` for cross-agent, `CLAUDE.md` under Claude Code) so later analyses reuse it instead of re-asking. Only write the file on the user's yes.
- **Show both** the cores over the analysis window **and** the annualized cost, side by side. E.g. with the default 1-hour window: *"`payments` held 2.5 cores over the last 1h → ≈ **$770/yr** at $0.04/vCPU-h, if sustained."* The window's average rate is what you annualize, whatever the window length.
- **Caveat once:** annualizing a short window assumes it's representative of steady-state load — state that, don't bury it.
- **Dollarize the fix in Expected Impact.** A fix that removes ~X% of an entity's CPU saves ~X% of its annual cost — e.g. "cut ~40% of `payments`' CPU → ≈ $310/yr recovered." That dollar figure *is* the ROI; lead the recap's impact with it.

## Ranking table (rank-first output)

Lead a rank-first recap with a table — one row per top consumer, hottest first. **Keep the table to cores and cost only** — no host/container/deployment columns. Carry both the annualized CPU-core usage and its cost:

| # | Workload | Cores (last \<window\>) | Annualized core-hrs | Annualized cost |
|---|----------|------------------------|---------------------|-----------------|
| 1 | payments | 2.5 | 21,900 | ≈ $770/yr |
| 2 | checkout | 1.1 | 9,636 | ≈ $340/yr |
| 3 | kube-proxy ❌ | 0.8 | 7,008 | ≈ $245/yr |

- **Cores (last \<window\>)** — average vCPUs held over the analysis window; this is what the ranking is by.
- **Annualized core-hrs** — `cores × 8,760` (the window rate projected to a year, if sustained).
- **Annualized cost** — `annualized core-hrs × per-vCPU-hour rate` (= `cores × rate × 8,760`); rate per [Cost: annualize the cores](#cost-annualize-the-cores). State the rate (and `(assumed)` if it's the default) in a line under the table.
- **Always drop the zymtrace profiler itself** (`zymtrace-profiler` / the profiler DaemonSet) from the table — it being hot usually just signals an otherwise-idle cluster, not a target. Hard skip (note "(zymtrace profiler excluded)" if it would have ranked), not an ❌ reference row.
- **Mark third-party / non-actionable code with ❌** (kube-proxy, kubelet, systemd, kernel) and exclude it from ROI; lead the analysis with the top **user-owned** row.
- **Host / container / deployment go in a reference line below the table, not in it** — e.g. *"Reference: payments → container `api-7f9c`, deployment `payments`, host `node-7`."* Include only the identifiers the MCP returns; don't invent them.

## Allocation/GC-bound? Hand off

When the CPU pattern is **allocation churn / GC** (step 4) — allocator and GC frames dominating on-CPU time — the on-CPU view can't name *which* call sites allocate. **On a Java service**, hand off to [`optimize-memory-allocation`](../optimize-memory-allocation/SKILL.md) (the JVM allocation profile, weighted by bytes) to turn "GC is hot" into a named, fixable allocation site. (Non-Java workloads have no allocation profile — stay here.)

## CPU call-tree rendering (Observed Call Tree section)

The output-template skeleton is in the shared doc. The CPU **Observed Call Tree** block renders like this:

```markdown
**Observed Call Tree — CPU profile** (<process path / container / host / time range>)

<top-level frame>  (<self % / total %>)
├── <child frame>  (<%>)
│   ├── <leaf frame>  (<%>)
│   └── <leaf frame>  (<%>)
└── <child frame>  (<%>)  ← hot path
```

**Call-tree conventions:**
- The call tree is the **CPU profile** — frames sampled while the process was on-CPU. No kernel annotations and no GPU cross-check (this skill is CPU-only).
- Use `├──` and `└──` for the hierarchy (matches what the MCP returns).
- Annotate frames with their CPU share (`self %` / `total %`) as the MCP returns them; mark the dominant path with `← hot path`.
- Keep frame/function names exactly as the MCP returns them; don't paraphrase.

## Done (CPU-specific, on top of the shared checklist)

- [ ] Ranked first when the request was rank-shaped, as a **table** of cores + **annualized core-hours** + annualized cost only (host/container/deployment in a reference line below, not columns); third-party rows marked **❌** and excluded from ROI, the top user-owned entry drilled into.
- [ ] Cores shown over the analysis window **and** annualized (core-hours + yearly cost); the fix's saving dollarized in Expected Impact.
- [ ] Rate sourced from a saved `zymtrace-vcpu-rate` (AGENTS.md/CLAUDE.md) or the user; if the default was assumed, it was labelled and the user asked for their real rate (and offered persistence).
- [ ] CPU metrics pulled first (utilization, and throttling/run-queue if available) and carried into the recap.
- [ ] CPU flamegraph pulled at the named scope; the dominant pattern named (lock contention, allocation/GC, serialization, syscall-bound, hot loop).
- [ ] Allocation profile pulled for the same filter **if** the pattern looked allocation/GC-bound.

(Plus the common Done checklist in the shared doc — template, every 🔴/🟡 has a `Fix:`, fix applied, follow-up question.)

## Common pitfalls

- **Spending 🔴 issues on code the user can't change.** kube-proxy / kubelet / systemd / kernel frames are context, not action items — keep them in the ranking, mark them non-actionable, and lead with the top user-owned entry. ROI = time spent × how fixable it is.
- **Expecting the MCP to name the pattern for you.** It returns raw data — frames, percentages. Naming the pattern (lock-contention, allocation-churn, serialization, syscall-bound) is *your* job.
- **Stopping at "here's the data" without a recommendation.** Always close with a specific fix to try, grounded in the frame names + percentages.
- **Stopping at the recap.** Diagnosis is the midpoint. Locate the source and apply the top fix; if you can't find it locally, ask for the path. Never hand back analysis alone.
- **Reaching for GPU framing.** This is a CPU-only skill. If the user actually has GPU workloads, route to [`optimize-gpu-workloads`](../optimize-gpu-workloads/SKILL.md).

## Security constraints

- Common rules (ground in returned data, never analyze local profile files, never query the DB directly) are in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md).
- **Always** ground the recommendation in the data the MCP returned (frame names, percentages, hot stacks) — don't fabricate signals the data doesn't show.
</content>

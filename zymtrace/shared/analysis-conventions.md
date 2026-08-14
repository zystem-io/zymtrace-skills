# Profile Analysis Conventions

Shared discipline for the three optimize skills — [`optimize-cpu-workloads`](../skills/optimize-cpu-workloads/SKILL.md),
[`optimize-gpu-workloads`](../skills/optimize-gpu-workloads/SKILL.md), and
[`optimize-memory-allocation`](../skills/optimize-memory-allocation/SKILL.md) — and the
**zymtrace-perf-engineer** agent. The zymtrace MCP fetches the data (rankings, flamegraphs,
metrics); **you** do the analysis: name the hot stacks, identify the pattern, recommend the fix,
**then apply it**. Each skill adds its view-specific protocol on top of the rules below.

## Hand off to the subagent for unattended / parallel runs

If you're running **inline as a skill** (the user is in the loop) and the request is
delegation-shaped — run it **unattended** ("report back when done", "just fix it"), or **several
workloads triaged at once / in parallel** — hand off to the **zymtrace-perf-engineer** subagent
instead of doing it inline; that's what it's for. For a normal single-workload analysis with the
user present, stay inline. (If you *are* the zymtrace-perf-engineer agent, this is already you —
carry on.)

## Open with your plan (💚)

Before pulling data, **tell the user what you're about to do** — a short plan, one **💚 green-heart bullet** per step, matched to the request. For example:

> 💚 Pull `<entity>` metrics and rank the top consumers
> 💚 Pull the hot call tree (and cross-check the opposite view where it applies)
> 💚 Summarize the findings and recommend fixes
> 💚 Locate the hot frame in your source and apply the top fix

Then proceed. Keep it to 3–5 bullets — the shape of the run, not a sub-task list. (The autonomous **zymtrace-perf-engineer** agent skips this preamble — it returns the finished recap directly, per its own brief.)

## Data-source policy — same instance, two paths

All metrics and flamegraphs come from the user's live zymtrace instance:

- **MCP first** (preferred). On 26.8.1+ the tools are the primary path and MCP *resources* are analysis prompts (`prompt://hot_trace?op=…`); on older instances follow the server's own instructions (resources first, then tools).
- **Gateway API as fallback** when the MCP isn't available — read its endpoints from `<gateway-url>/api-docs/openapi.json`; don't guess params.

**Tool surface — two generations; detect from the tool list, never ask the user their version.** zymtrace **26.8.1** rebuilt the MCP around scope-first discovery:

- **26.8.1+ (rebuilt MCP):** `discover_projects` / `discover` (scope resolution + entity ranking), `recommendations`, `hot_traces`, `top_functions`, `discover_metrics` + `metrics`, `flamegraph` (CSV, last resort), `get_datetime` — plus analysis prompt resources (`prompt://hot_trace?op=examine|examine_gpu|examine_third_party`). If `discover` or `top_functions` is in the tool list, you're on this surface — follow the call order below.
- **26.5.1 – 26.8.0:** rank with **`topentities`** / **`topfunctions`** (concise rankings — `hot_traces` returns full trace data, more than you need to rank), pull call trees with **`hot_traces`**, fall back to **`flamegraph`**.
- **Pre-26.5.1:** no `hot_traces` — use **`flamegraph`**.

*Version signals, if you want to confirm:* no MCP **tool** returns the server version — the tool list is the discriminator. The version is reported in the MCP `initialize` handshake (`serverInfo.version`, harness-dependent whether you can see it) and at **`GET <gateway-url>/api-docs/openapi.json` → `.info.version`**. Both are baked at build time and can lag the actual code on pre-release deployments — when the version string and the tool list disagree, trust the tool list.

**Call order on the rebuilt MCP (26.8.1+)** — mirrors the server's own instructions; run 1–3 in order, however small the observed cost:

1. **Resolve the scope** — `discover_projects` / `discover` until project, event kind, and time range are concrete. Event kinds: `on_cpu` (CPU work), `off_cpu` (waiting), `cuda` (GPU), `alloc` (allocated bytes) — default `on_cpu`, add `cuda` for GPU questions. Encode the user's scope clues in `expr` (`And`/`Or`/`Not` over host / container / pod / pod-label / deployment / namespace / thread / tag / cluster / GPU / Slurm / exe / script fields), preserving their boolean logic and negations; omit unknown details, never invent them. **Discovery stats only select the scope — they are never the answer.**
2. **Reuse `recommendations`** for the scope with a **wide range (e.g. 30 days)** before profiling — recommendations are generated once when a problem is first seen, so the cause may already be known. Verify hits against your own profiling before repeating them; pass `PrefixHash` to fetch the recommendations for one specific trace. (The `recommendations` tool exists on the older 26.5.1+ surface too, with the same wide-window advice — reuse it there as well.)
3. **Profile with `hot_traces`: survey, then drill.** Full traces are massive (~5k tokens each): survey with the defaults (`full_traces = false`, small pages), then re-fetch each of the top 1–3 traces in full — pass its `prefix_hash` back **verbatim** with `full_traces = true` and page size 1. Narrow `expr` before fetching full traces. Then `top_functions` on the same scope. **Before interpreting full traces, fetch the matching analysis prompt** (next section) — retrieve first, then analyze.
4. **Correlate metrics only when a concrete hypothesis needs one** — `discover_metrics`, then `metrics`, reusing the profiling scope's filter fields. A metric missing the entity's dimension (e.g. no Exe attribute) is host- or cluster-wide context — never attribute it to that entity. For histograms prefer `percentiles` (e.g. `[0.5, 0.95, 0.99]`) over raw buckets; choose `interval` so the range yields tens of points, not thousands; never sum temperatures or utilization percentages across devices. (This restraint governs *correlation during trace analysis*; the skills' "pull the entity's metrics first" triage step — utilization context to pick the right view — is separate and stays.)
5. **`flamegraph` is a last resort** (tens of thousands of tokens) — don't reach for it until you've fetched the top traces in full via `hot_traces`; those are far cheaper and usually sufficient. The tree is culled to ~600 highest-cost nodes; narrow `expr` to zoom into a subtree instead of paginating.

**Analysis prompts (26.8.1+) — fetch before analyzing full traces.** The server ships expert analysis prompts and exposes each one twice: via the **MCP prompts protocol** (`hot_trace_examine`, `hot_trace_examine_gpu`, `hot_trace_examine_third_party`) and mirrored as **resources** (`prompt://hot_trace?op=examine|examine_gpu|examine_third_party`) for harnesses that don't support the prompts protocol — use whichever your client supports. Retrieve the ONE prompt matching the trace, then analyze:

- `op=examine` — the user's own CPU/system code.
- `op=examine_gpu` — CUDA/GPU work (frames marked `cuda:`).
- `op=examine_third_party` — hot path inside third-party software the user can only configure, not patch.

**These are the exact prompts the backend uses to generate the stored `recommendations`.** Analyzing under the same rubric keeps your findings consistent with what the `recommendations` tool and the UI already show — hits corroborate instead of contradicting, and your drill-down extends them rather than reinventing them. The prompts carry the analysis discipline (classify executing-vs-waiting, read prefix and suffix differently, footprint patterns, root-cause priority order, certainty rules) — follow it. One precedence rule: the prompt's own "Output format" section (Diagnosis/Evidence/Recommendations/…) describes the server's recommendation records; for interactive runs, keep rendering the recap with the **Output template** below — prompt for the reasoning, skill template for the presentation. If neither the prompts protocol nor resources are reachable, proceed without; don't block the analysis on it.

**Cross-call discipline (any MCP generation):**

- Keep project, range, and filters **identical** across calls when correlating data — a cross-view or metric pulled on a different slice proves nothing.
- Event kinds are incomparable: never add or compare costs across `on_cpu` / `off_cpu` / `cuda` / `alloc`. Cost units follow the event kind — CPU cores for `on_cpu`, bytes for `alloc`, seconds otherwise. CPU-seconds, average cores, wall time, and shares have different denominators — report each with its unit, never blend them.
- Copy returned IDs and names (`project_id`, `prefix_hash`, metric names, field values) back **verbatim**; never invent them.
- An empty filtered result proves only that the filter matched nothing. Retry via `discover_projects` (or drop `expr`), or widen the range progressively (24h → a week → a month; don't exceed a month unless asked) before concluding data is absent.

**Reading a hot trace:** each trace is a shared frame **prefix** (why the code runs — caller, frequency, fan-out) plus branching **suffixes** (what consumes the cost). Suffix costs are individual and do **not** sum to the trace total. The reported global non-idle ratio is relative to the request filter — after filtering by `prefix_hash` it nears 1.0 and no longer reflects the original scope's share.

Two hard prohibitions:

- **Never** substitute local profile files (`.pftrace`, `profile_*.json`) — they aren't tied to the user's instance/filter and mislead.
- **Never** query ClickHouse or the backend DB directly (`clickhouse-client`, `kubectl exec`, raw SQL) — it bypasses access controls and the schema is easy to get subtly wrong.

No data path + no URL → ask for the URL; don't analyze files on disk or work around the instance.

## Pre-flight — know the instance

**Establish which zymtrace instance you're analyzing — you need its URL in context.** Check whether
a zymtrace MCP server is connected (in Claude Code, `claude mcp list | grep -i zymtrace`; in Codex
or Cursor, the equivalent MCP listing):

- **Connected** → proceed; the MCP is the preferred data path.
- **Not connected** → route to [`configure-zymtrace-mcp`](../skills/configure-zymtrace-mcp/SKILL.md). It needs the URL: use one the user already gave, otherwise **ask** (*"What's your zymtrace URL? — e.g. `https://zymtrace.your-company.com`"*). Never guess or assume `localhost`. With a URL but no connection, the gateway API for that same instance is the fallback.

**Default time range:** last **1 hour** if the user gives none. Use the exact range if they specify one.

## Which view — CPU or GPU

Pick the view from the request; **never ask the user "is this CPU or GPU?"** — infer it.

- **GPU signal present** — the request mentions GPU, CUDA, an accelerator, inference, an inference server (vLLM, SGLang, Triton, TensorRT-LLM), or a training/fine-tuning job → use the **GPU** workflow ([`optimize-gpu-workloads`](../skills/optimize-gpu-workloads/SKILL.md)); it cross-checks CPU anyway.
- **No accelerator signal — only an entity named** (a container, deployment, pod, host, process, or just "what's slow / what's hot") → default to the **CPU** workflow ([`optimize-cpu-workloads`](../skills/optimize-cpu-workloads/SKILL.md)). **CPU is the universal baseline:** every profiled entity has a CPU profile; GPU is the special case.
- **Memory-allocation / GC signal on a Java service** — "what's allocating", "why is GC busy", "reduce heap churn", "JVM memory allocations" → use the **memory-allocation** workflow ([`optimize-memory-allocation`](../skills/optimize-memory-allocation/SKILL.md)), which reads the JVM allocation profile (bytes allocated). **JVM-only** — non-Java workloads have no allocation profile. The CPU workflow also hands off here when a Java service's hot pattern turns out to be allocator/GC frames.

Then **let the metrics decide.** You pull the entity's metrics first regardless (next steps). If an entity you reached via the CPU default turns out to show real GPU activity (non-trivial GPU utilization / memory), it's a GPU workload — switch to the GPU workflow for the cross-view rather than analyzing GPU work from the CPU side alone.

## Two request shapes: rank-first vs. drill-down

- **Drill-down** — the user already named a workload ("analyze my training job", "my API service"). Go straight to your skill's protocol.
- **Rank-first** — the user asks *which* thing is hottest or where the best return is ("which process uses the most CPU", "what's eating my CPU", "biggest ROI", "what should I optimize first"). Start by ranking with the MCP's entity ranking — **`discover`** on 26.8.1+, **`topentities`** on older instances — or the functions ranking (**`top_functions`** / **`topfunctions`**), then drill into the top entry with `hot_traces`. Note `discover`'s ranking axis: its stats blocks are per **(project, event kind, exe/script)** entity, each carrying total weight and top-k attribute values (hosts, containers, pods, GPUs, tags) — so a container/pod/host ranking is read off those attribute breakdowns, or produced by narrowing `expr`, not returned as its own list the way `topentities` did. The recap leads with the ranking, then the analysis of the top user-owned entry.

**Always exclude the zymtrace profiler itself** (the zymtrace agent — e.g. `zymtrace-profiler` / the profiler DaemonSet) from rankings entirely. It's the tool doing the measuring; it surfacing near the top almost always just means the cluster is otherwise idle, not that it needs fixing. **Drop it from the table** rather than listing it (note "(zymtrace profiler excluded)" if it would have ranked) — this is a hard skip, distinct from the ❌ reference rows below.

**Scope to code the user controls.** When the user says "focus on apps that are mine" — or whenever
the top consumer is something they can't change (kube-proxy, kubelet, systemd, the kernel, other
system daemons) — keep those in the ranking for context but mark them **non-actionable** and don't
spend 🔴 issues on them. ROI is `time spent × how fixable it is`: rank the user's own code by share
and lead with the entry where a realistic change recovers the most. Say plainly when the single
biggest consumer is third-party and the best actionable win is further down.

## Always recommend a fix — then apply it

**Always recommend a fix.** Every 🔴 issue gets a concrete `**Fix:**` block — whether or not the
user asked for solutions. Don't hedge with "let me know if you want suggestions" or "ask about
constraints first". Lead with the most plausible specific fix from the data; the user can push back
if their constraints don't fit. Analysis without recommendations is incomplete output.

**Write the summary of findings and recommendations before finding the source to modify.** Output the
complete recap (the template above) as a finished deliverable *first* — findings and `Fix:`
recommendations in full — before you touch any file *or even search the working directory for the
source*. The user sees the whole diagnosis before any code work begins; don't interleave edits into
the recap or start hunting for files mid-analysis.

**Then apply it — don't stop at the recap.** Your job is to fix the code, not only diagnose it.
After the recap is shown, **act on the top 🔴 issue's `Fix:`**:

1. **Find the source locally.** The flamegraph names the hot frame — `<module>.<function>` or `<file>:<line>`. Search the working directory.
   - **Found** → make the edit: the code change for a code-level fix, or the launch config / Helm values / manifest for a flag or env-var fix. Show the diff.
   - **Not found** → **ask the user for the path**: *"I can apply this — where's the source for `<frame>`? (path to the repo / file)"*. Don't guess a path or fabricate a file; wait, then apply.
2. **Don't auto-apply a risky or ambiguous change.** When the fix needs a judgment call (a real refactor, a behavior change, a flag with tradeoffs), propose the exact edit and confirm before writing. One-line config/flag fixes you can apply directly and show.
3. **Always close with a follow-up question.** Never end on the recap alone — apply the next 🔴? run/benchmark to confirm the win? open a PR? drill into a 🟡?

**Optional pairing — GitHub MCP.** If the GitHub MCP is also connected, the local edit can become a
`<file>:<line>` pull request: make the change, then **ask whether to open a PR** — only on a yes.
Mention the PR option once if both MCPs are available; never push a PR unprompted.

## Output template

Every recap follows this shape. The **Observed Call Tree** block is view-specific — your skill
defines how to render it. Everything else below is common.

```markdown
# <Workload> Flamegraph Analysis

**Observed Call Tree** (<process path / container / time range>)

<view-specific — see your skill (CPU call tree, or GPU call tree with kernel annotations)>

**Key Findings**

<1–2 paragraphs naming what the workload IS and the dominant pattern.>

---

## 🔴 Top issues (max 3, in priority order)

### 1. <Title>

<Observation paragraph — frame/function names + percentages from the actual flamegraph. Plain prose, no label.>

**Fix:** <Concrete action — always present, never gated on whether the user asked. Name the specific change with a 1–3 line snippet when the fix is one line.>

### 2. <Title>
…

---

## 🟡 To consider after the above (max 2)

- <One-line observation> — **Fix:** <one-line action>

---

**Expected Impact**

<Qualitative description of what the fixes should achieve. Numbers only if the MCP returned them or they're well-known order-of-magnitude estimates.>
```

**Severity & sizing:**
- 🔴 **Critical** (max 3) — the dominant bottlenecks: >20% of time, or the dominant pattern. Hard cap at 3; demote a 4th to 🟡 or drop it.
- 🟡 **Minor follow-up** (max 2) — secondary issues worth a one-liner each: observation + fix on one line. No paragraphs. Drop a 3rd.
- Anything past 3+2 isn't surfaced. The user can re-query to drill.

**Issue body conventions:**
- Each issue is a `### N. <Title>` sub-heading, then a plain prose paragraph (the observation — the paragraph IS the observation, no `Observation:` label), a blank line, then `**Fix:**` on its own line in bold with the concrete action.
- The blank line between observation and Fix is load-bearing — without it, prose and action blur together.
- The observation always cites frame/function/kernel names + percentages from the actual flamegraph. No inference; no rephrasing of names.
- Include a 1–3 line code/config snippet when the fix is one line. Skip the snippet when the fix needs a real conversation about constraints.
- 🟡 follow-ups use the inline single-line shape: `<observation> — **Fix:** <action>`.

## Done — common checklist

- [ ] Opened with a short 💚 plan (interactive runs) before pulling data.
- [ ] Recap (findings + recommendations) written and shown **before** searching for or editing source.
- [ ] Workload metrics pulled first and carried into the recap as context.
- [ ] Recap follows the **Output template**: title, observed call tree, Key Findings, 🔴 block (max 3, each with observation + `**Fix:**`), 🟡 block (max 2 one-liners), Expected Impact.
- [ ] **Every** 🔴 has a concrete `**Fix:**` grounded in the flamegraph data — never punted ("ask me if you want suggestions"), never invented. Same for each 🟡.
- [ ] No more than 3 🔴 and 2 🟡. Drop the lowest-priority ones if you have more.
- [ ] Workload identity (entity + time range) in the recap so the user can re-query before/after.
- [ ] **Acted on the top fix, not just recommended it:** located the hot frame's source locally and applied the edit (or asked for the path when it wasn't local). Risky/ambiguous changes proposed-then-confirmed; one-line config fixes applied and shown.
- [ ] If the GitHub MCP is connected and the fix is code-level: offered a PR, opened one only on the user's yes.
- [ ] **Closed with a follow-up question** — never ended on the recap alone.

## Security constraints

- **Always** ground the recommendation in the data the MCP returned (frame/kernel names, percentages, hot stacks). Synthesize across views — but don't fabricate signals the data doesn't show.
- **Never** analyze local profile files (`.pftrace`, `profile_*.json`) as a substitute for the MCP, and **never** query ClickHouse / the backend DB directly — see the data-source policy above.
</content>
</invoke>

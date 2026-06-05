# Profile Analysis Conventions

Shared discipline for the two analysis skills — [`optimize-cpu-workloads`](../skills/optimize-cpu-workloads/SKILL.md)
and [`optimize-gpu-workloads`](../skills/optimize-gpu-workloads/SKILL.md) — and the
**zymtrace-perf-engineer** agent. The zymtrace MCP fetches the data (rankings, flamegraphs,
metrics); **you** do the analysis: name the hot stacks, identify the pattern, recommend the fix,
**then apply it**. Each skill adds its view-specific protocol on top of the rules below.

## Data-source policy — same instance, two paths

All metrics and flamegraphs come from the user's live zymtrace instance:

- **MCP first** (preferred). Use MCP resources first, then tools as a fallback (per the server's own instructions).
- **Gateway API as fallback** when the MCP isn't available — read its endpoints from `<gateway-url>/api-docs/openapi.json`; don't guess params.

**Pulling traces — `hot_traces` first.** For the call-tree / flamegraph step on **all three profile types — CPU, GPU, and allocation (ALLOC)** — prefer the **`hot_traces`** MCP tool when it's available; it's present on zymtrace **26.5.1 and above**. Fall back to the **`flamegraph`** MCP tool on older instances or whenever `hot_traces` isn't exposed. Try `hot_traces` first and drop to `flamegraph` if it's absent or errors; don't ask the user which version they run — detect it from the tool list.

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
- **Rank-first** — the user asks *which* thing is hottest or where the best return is ("which process uses the most CPU", "what's eating my CPU", "biggest ROI", "what should I optimize first"). Start by ranking with the MCP's **topentities** (hottest container/pod/host/process) or **topfunctions** (hottest functions), then drill into the top entry. The recap leads with the ranking, then the analysis of the top user-owned entry.

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

**Then apply it — don't stop at the recap.** Your job is to fix the code, not only diagnose it.
After the recap, **act on the top 🔴 issue's `Fix:`**:

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

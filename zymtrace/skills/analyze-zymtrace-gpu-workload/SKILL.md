---
name: analyze-zymtrace-workload
description: |
  Use for ANY analysis of CPU or GPU performance with zymtrace — ranking the top consumers (which process, function, container, or pod is hottest), finding a workload's bottleneck, deciding which of the user's own apps to optimize first (biggest ROI), or reading a flamegraph. The zymtrace MCP pulls the data (rankings, flamegraphs, metrics) from the user's instance — YOU do the analysis. Use the MCP first; if it isn't available, fall back to the zymtrace gateway API for the same instance. This skill adds the discipline: pull the entity's metrics first, scope recommendations to code the user controls (third-party/system processes like kube-proxy are context, not action items), and always cross-check the opposite side (CPU for a GPU workload, GPU for a CPU one) with the same filter — the bottleneck often hides on the side the user didn't ask about. The job doesn't end at diagnosis: locate the hot frame in the user's source and apply the fix (ask for the path if the source isn't local), then always close with a follow-up question.
  Trigger phrases: "use zymtrace to analyze CPU/GPU profiles", "which process/function uses the most CPU/GPU", "what's eating my CPU", "top CPU/GPU consumers", "rank my apps by CPU", "biggest ROI optimization", "what should I optimize first", "where's the bottleneck in vllm/sglang", "analyze my GPU/training/inference workload", "find the hot kernel", "GPU isn't saturated", "investigate using flamegraph".
---

# Analyze zymtrace Workload

> The zymtrace MCP fetches the data — rankings, flamegraphs, and metrics for the user's instance. **You** do the analysis: name the hot stacks, identify the pattern, recommend the fix. This skill's discipline is to make sure you **always pull both the GPU and the CPU view with the same filter** — half the time the bottleneck is on the side the customer didn't ask about.

> **Always recommend a fix.** Every 🔴 issue in the recap gets a concrete `**Fix:**` block — whether or not the customer asked for solutions. Don't hedge with "let me know if you want suggestions" or "ask about constraints before recommending". Lead with the most plausible specific fix from the data; the customer can push back if their constraints don't fit. Profile analysis without recommendations is incomplete output.

> **Then apply it — don't stop at the recommendation.** Your job is to fix the code, not only diagnose it. After the recap, locate the hot frame's source in the working directory and make the edit (or change the launch config / manifest for a flag fix). If you can't find the source locally, **ask the user for the path** — don't guess or fabricate a file. **Always end with a follow-up question** (apply the next fix? run it to confirm? open a PR? drill into a 🟡?). See [Don't stop at diagnosis — fix it](#dont-stop-at-diagnosis--fix-it).

Connection setup lives in [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md). This skill assumes the MCP is already connected.

**Applying the fix is part of the workflow, not an add-on.** The default is the local working directory: locate the hot frame's source, make the edit, show the diff. The [fix-it section](#dont-stop-at-diagnosis--fix-it) below is the canonical procedure.

**Optional pairing — GitHub MCP** extends this to remote: if the GitHub MCP is also connected (your client's MCP list shows both), you can reference a specific `<file>:<line>` and **offer to open a pull request** with the change once the local edit is made. Mention the PR option once if both MCPs are available; respect the answer either way. Never push a PR unprompted.

## Standard starter prompt (for customers who don't know what to ask)

> **"Analyze the GPU flamegraph over the last 1 hour and suggest solutions."**

If the customer hands you anything close to that (or shorter — "what's slow", "investigate my GPU"), interpret it as: scope the analysis to the last 1 hour, pull the GPU flamegraph, cross-check the CPU view, follow the output template below. Don't make them remember the specifics — this is the on-ramp.

Variations the customer might use:
- "Analyze [vLLM / SGLang / Triton / my training job] over the last [Nh / since deploy]"
- "Where's the bottleneck right now?"
- "What's wasting GPU time today?"

For any of these: default to the last 1 hour if no time range is given, default to the whole cluster if no workload is named (and ask which to narrow if results look noisy).

## Two request shapes: rank-first vs. drill-down

- **Drill-down** — the user already named a workload ("analyze my vLLM job"). Go straight to the cross-view protocol below.
- **Rank-first** — the user asks *which* thing is hottest or where the best return is ("which process uses the most CPU", "what's eating my CPU", "biggest ROI", "what should I optimize first"). Start by ranking with the MCP's **topentities** (hottest container/pod/host/process) or **topfunctions** (hottest functions), then drill into the top entry with the cross-view protocol. The recap leads with the ranking, then the analysis of the top user-owned entry.

**Scope to code the user controls.** When the user says "focus on apps that are mine" — or whenever the top consumer is something they can't change (kube-proxy, kubelet, systemd, the kernel, other system daemons) — keep those in the ranking for context but mark them **non-actionable** and don't spend 🔴 issues on them. ROI is `time spent × how fixable it is`: rank the user's own code by CPU/GPU share and lead with the entry where a realistic change recovers the most. Say plainly when the single biggest consumer is third-party and the best actionable win is further down.

## Pre-flight

**First, establish which zymtrace instance you're analyzing — you need its zymtrace URL in context.**

Check whether a zymtrace MCP server is connected in your client (in Claude Code, `claude mcp list | grep -i zymtrace`; in Codex or Cursor, the equivalent MCP-list in that tool):

- **Connected** → proceed; the MCP is the preferred data path.
- **Not connected** → route to [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md) to connect. It needs the zymtrace URL: if the user already gave one in this conversation, use it; otherwise **ask** (*"What's your zymtrace URL? — e.g. `https://zymtrace.your-company.com`"*). Never guess or assume `localhost`. If the MCP can't be connected but you have the gateway URL, the zymtrace gateway API for that same instance is the fallback (read its endpoints from `<gateway-url>/api-docs/openapi.json`).

> **Data-source policy — same instance, two paths.** All metrics and flamegraphs come from the user's live zymtrace instance: the **MCP first** (preferred), and the **gateway API** as the fallback when the MCP isn't available. **Never** substitute local profile files (`.pftrace`, `profile_*.json`) — they aren't tied to the user's instance/filter and mislead. **Never** query ClickHouse or the backend DB directly. No data path + no URL → ask for the URL; don't analyze files on disk or work around the instance.

## The cross-view protocol

The MCP pulls the data; you do the analysis *and* the discipline of asking for both sides. Everything below — metrics and flamegraphs — comes from the user's instance via the **MCP** (preferred) or the gateway API (fallback if the MCP isn't available), so establish a data path **first** (Pre-flight). Don't analyze local files or query the backend DB directly — see the data-source policy in Pre-flight.

1. **Pull the workload's metrics first, for context.** Ask the MCP for the entity's metrics — GPU utilization / memory / SM efficiency for GPU work, plus CPU utilization — to establish whether the workload is GPU- or host-bound and which view will be informative. Carry these numbers into the recap; they frame the flamegraph findings.

2. **Query the MCP for the workload's data** at the scope the customer named (executable / container / pod / time range / model — whatever signals they gave).

3. **Pull whichever view the customer's question implies first** — GPU view for a GPU-shaped question, CPU view for a CPU-shaped one. Read which frames are hot from the returned data.

4. **Then explicitly ask the MCP for the OPPOSITE view of the same workload, with the same filter.** Use the exact filter values the MCP locked onto — same executable, same container, same time range. Don't hand-wave the filter; the cross-view is only useful when the slice matches.

5. **Cross-reference the two views** (against the step-1 metrics). Common reveals:
   - GPU at 95% but tokens/sec underwhelming → look at CPU for tokenizer / sampling / Python-side overhead.
   - GPU at 60% utilization → the host is the bottleneck. The CPU view will name it.
   - Specific GPU kernel dominant → the CPU view often shows the launcher / scheduler that's calling it. Useful for understanding launch-overhead vs kernel-time tradeoffs.
   - CPU dominated by `cudaMemcpy*` / `aten::*` synchronization → the workload is sync-bound on device transfers; the GPU view will show idle stretches.

6. **Write the recap using the output template below.** Use the data the MCP returned — metrics, kernel names, percentages, hot stacks, the call tree from the CPU view, and the kernels triggered on the GPU side — to fill the template. The analysis and the recommendation are yours: synthesize a concrete next step from what the numbers show, grounded in the data, not invented.

7. **Apply the fix** (next section). The recap is the midpoint, not the finish line.

## Don't stop at diagnosis — fix it

The recommendation is only half the job. After the recap, **act on the top 🔴 issue's `Fix:`**:

1. **Find the source locally.** The flamegraph names the hot frame — `<module>.<function>` or `<file>:<line>`. Search the working directory for it.
   - **Found** → make the edit: apply the code change for a code-level fix, or edit the launch config / Helm values / manifest for a flag or env-var fix (e.g. `--enable-prefix-caching`, `VLLM_ATTENTION_BACKEND`). Show the diff.
   - **Not found** → **ask the user for the path**: *"I can apply this — where's the source for `<frame>`? (path to the repo / file)"*. Don't guess a path or fabricate a file; wait for the answer, then apply.
2. **Don't auto-apply a risky or ambiguous change.** When the fix needs a judgment call (a real refactor, a behavior change, a flag with tradeoffs), propose the exact edit and confirm before writing. One-line config/flag fixes you can apply directly and show.
3. **Always close with a follow-up question.** Never end on the recap alone. Offer the obvious next move: apply the next 🔴, run/benchmark to confirm the win, open a PR (if the GitHub MCP is connected), or drill into a 🟡. End every analysis with one.

If the **GitHub MCP** is also connected, the local edit can become a `<file>:<line>` PR: make the change, then **ask whether to open a pull request** — only on a yes. Never push a PR unprompted.

## Output template

Every recap follows this shape. Don't deviate — the structure is the value.

```markdown
# <Workload type> Flamegraph Analysis

**Observed Call Tree — GPU profile** (<process path / container / time range>)

<top-level frame>
├── <child frame>
│   ├── <leaf frame>  → <CUDA kernel that was running at this sample>
│   ├── <leaf frame>  → <CUDA kernel ...>
│   └── ...
├── <sync-point frame>  → cudaStreamSynchronize + D→H memcpy  ⚠️
└── <sync-point frame>  → cudaDeviceSynchronize  ⚠️

**CPU cross-check** (<same process / container / time range>)

<1–2 sentences naming what the CPU profile adds — DataLoader stalls, Python overhead,
tokenizer hot spots, host-side launch overhead, or "nothing else surfaced; the
constraint is on the GPU side". Keep short.>

**Key Findings**

<1–2 paragraphs naming what the workload IS and the dominant pattern.
Examples: "kernel-launch-bound / dispatcher-overhead", "memory-bandwidth bound",
"DataLoader-starved", "NCCL-collective-bound".>

---

## 🔴 Top issues (max 3, in priority order)

### 1. <Title>

<Observation paragraph — kernel names + percentages from the actual flamegraph. Plain prose, no label.>

**Fix:** <Concrete action — always present, never gated on whether the customer asked for solutions. For inference: name the specific flag/env var with a 1–3 line snippet when the fix is one line. For training: name the most plausible concrete fix from the data (e.g. "wrap with `torch.compile(mode='reduce-overhead')`", "remove `.item()` from the hot loop", "switch to `channels_last`"), not just a family. The customer can push back if constraints don't fit.>

### 2. <Title>

<Observation paragraph.>

**Fix:** <Concrete action.>

### 3. <Title>

<Observation paragraph.>

**Fix:** <Concrete action.>

---

## 🟡 To consider after the above (max 2)

- <One-line observation> — **Fix:** <one-line action>
- <One-line observation> — **Fix:** <one-line action>

---

**Expected Impact**

<Qualitative description of what the fixes should achieve. Numbers only if the
MCP returned them or they're well-known order-of-magnitude estimates.>
```

**Severity & sizing:**
- 🔴 **Critical** (max 3) — the dominant bottlenecks: >20% of time, sync points eliminating pipelining, or the dominant pattern in the dominant pattern. Hard cap at 3. If you have a 4th, demote it to 🟡 or drop.
- 🟡 **Minor follow-up** (max 2) — secondary issues worth a one-liner. Single line each: observation + fix. Don't write paragraphs here. If you have a 3rd, drop it.
- Anything past 3+2 isn't surfaced. The customer can re-query if they want to drill.

**Call tree conventions:**
- The whole call tree is the **GPU profile** — zymtrace unwinds the full stack from the CUDA kernel back up through dispatcher / Python / host frames. Every frame shown was sampled while the GPU was busy.
- Use `├──` and `└──` for the hierarchy (matches what the MCP returns).
- Use `→` to annotate each leaf with the CUDA kernel that was running when that frame was sampled. This is not a "CPU→GPU" link; it's the kernel underneath that frame.
- Mark sync points (`cudaStreamSynchronize`, `cudaDeviceSynchronize`, `D→H memcpy`) with `⚠️` — they almost always deserve calling out since they kill pipelining.
- Keep frame and kernel names exactly as the MCP returns them; don't paraphrase.

**CPU cross-check conventions:**
- The CPU view is a **separate** flamegraph queried with the same filter — it shows what the host process is doing on its own time (not while waiting on the GPU).
- Keep this section short — 1–2 sentences. It either confirms the GPU diagnosis ("nothing else surfaced") or surfaces a host-side issue worth promoting to a 🔴 issue below (DataLoader stall, tokenizer hot, Python loop, etc.).
- If the CPU view surfaces a host-side bottleneck that's bigger than the GPU one, promote it to a 🔴 and reframe the diagnosis around it.

**Issue body conventions:**
- Each issue is rendered as a `### N. <Title>` sub-heading, then a plain prose paragraph (the observation — no `Observation:` label needed; the paragraph IS the observation), then a blank line, then `**Fix:**` on its own line in bold with the concrete action.
- The blank line between observation and Fix is load-bearing — without it, prose and action blur together visually.
- The observation always cites kernel/frame names + percentages from the actual flamegraph. No inference; no rephrasing of names.
- The `**Fix:**` block is the concrete action.
  - **Inference**: name the specific flag (`--enable-prefix-caching`, `VLLM_ATTENTION_BACKEND=...`, `use_fast=True`). Almost always a config knob; cheap to try.
  - **Training**: name the most plausible concrete fix from the data — e.g. "wrap with `torch.compile`", "set `memory_format=torch.channels_last`", "remove `.item()` from the hot loop", "bump `num_workers` to 4×GPUs, set `pin_memory=True`". Don't punt to "name the family and ask". Lead with the recommendation; the customer pushes back if their constraints don't fit.
  - Include a 1–3 line code/config snippet when the fix is one line. Skip the snippet when the fix needs a real conversation about constraints.
- 🟡 follow-ups use a different shape — inline single line with em-dash separator: `<observation> — **Fix:** <action>`. The em-dash + bold Fix label keeps the visual signal even on one line.

## Done

- [ ] Workload metrics pulled first (GPU/CPU utilization, memory, SM efficiency) and carried into the recap as context.
- [ ] Both GPU **and** CPU flamegraphs pulled for the **same** filter (same executable / container / time).
- [ ] The cross-view interpretation given — which side is the constraint, and why.
- [ ] Recap follows the **Output template** above: title, observed call tree (with `→` GPU annotations + `⚠️` sync markers), CPU cross-check, Key Findings, 🔴 top issues block (max 3, each with `Observation:` + `Fix:`), 🟡 follow-up block (max 2 one-liners), Expected Impact.
- [ ] **Every** 🔴 issue has a concrete `**Fix:**` block — grounded in the actual flamegraph data, never punted ("ask me if you want suggestions") and never invented. Same for the 🟡 follow-ups: each has a `**Fix:**` after the em-dash.
- [ ] No more than 3 🔴 issues and no more than 2 🟡 follow-ups. If you have more, drop the lowest-priority ones; the customer can re-query.
- [ ] Workload identity (executable + time range) included in the recap so the customer can re-query before/after.
- [ ] **Acted on the top fix, not just recommended it:** located the hot frame's source locally and applied the edit (or asked the user for the path when it wasn't local). Risky/ambiguous changes proposed-then-confirmed; one-line config fixes applied and shown.
- [ ] If the GitHub MCP is connected and the fix is code-level: offered to open a pull request, and opened one only on the user's yes.
- [ ] **Closed with a follow-up question** — apply the next fix, run/benchmark to confirm, open a PR, or drill into a 🟡. Never ended on the recap alone.

## Common pitfalls

- **Only pulling one view.** This is the failure mode the skill exists to prevent. Always pull both.
- **Different filters on the two views.** Cross-view only works when the slice matches. Re-use the MCP's resolved filter, don't paraphrase it.
- **Expecting the MCP to name the pattern for you.** It returns raw data — frames, kernels, percentages. Naming the pattern (kernel-launch-bound, DataLoader-starved, sync-bound) and synthesizing across both views is *your* job.
- **Stopping at "here's the data" without a recommendation.** Always close with a specific fix to try, synthesized from the kernel names + percentages the MCP returned.
- **Stopping at the recap.** Diagnosis is the midpoint. Locate the source and apply the top fix; if you can't find it locally, ask for the path. Never hand back analysis alone.
- **Ending without a follow-up question.** Every analysis closes with the next move offered — apply the next fix, run it, open a PR, drill into a 🟡.
- **Guessing a file path or fabricating source.** If the hot frame isn't in the working directory, ask the user where it is. Don't invent a file to edit.
- **Skipping when the customer asks a CPU question.** Cross-view goes both ways — pull GPU for a CPU-shaped question too. CPU-bound workloads with idle GPU are also worth surfacing.

## Security constraints

- **Always** ground the recommendation in the data the MCP returned (kernel names, percentages, hot stacks). Synthesize across the two views — but don't fabricate signals the data doesn't show.
- **Never** analyze local profile files (`.pftrace`, `profile_*.json`) as a substitute for the MCP — see the data-source rule in Pre-flight.
- **Never** declare the investigation done after only one view. Pulling the opposite side with the same filter is the load-bearing step.
- **Never** recommend enabling PC sampling on a workload (which requires `privileged: true`) without flagging the security implication. See [install-zymtrace-profiler § PC sampling](../install-zymtrace-profiler/reference.md#pc-sampling).

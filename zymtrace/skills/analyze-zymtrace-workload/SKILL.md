---
name: analyze-zymtrace-workload
description: |
  Use when investigating a GPU or CPU workload through the zymtrace MCP. The MCP does most of the analysis; this skill enforces the cross-view — always pull the matching opposite-side flamegraph (CPU for GPU workloads, GPU for CPU workloads) with the same filter. Most bottlenecks hide on the side the customer didn't ask about.
  Trigger phrases: "analyze my GPU workload", "where's the bottleneck in vllm", "investigate my training job", "find the hot kernel", "GPU isn't saturated", "investigate using flamegraph", "use zymtrace mcp to analyze".
metadata:
  version: "26.5.0"
  author: zymtrace
  repository: https://github.com/zystem-io/zymtrace-skills
  tags: zymtrace,mcp,profiling,gpu,cpu,flamegraph,analysis,investigation
  tools: claude
---

# Analyze zymtrace Workload

> The zymtrace MCP does most of the work: identifies the workload, fetches flamegraphs, names the hot stacks, surfaces patterns, recommends fixes. This skill's only job is to make sure you **always pull both the GPU and the CPU view with the same filter** — half the time the bottleneck is on the side the customer didn't ask about.

> **Always recommend a fix.** Every 🔴 issue in the recap gets a concrete `**Fix:**` block — whether or not the customer asked for solutions. Don't hedge with "let me know if you want suggestions" or "ask about constraints before recommending". Lead with the most plausible specific fix from the data; the customer can push back if their constraints don't fit. Profile analysis without recommendations is incomplete output.

Connection setup lives in [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md). This skill assumes the MCP is already connected.

**Optional pairing — GitHub MCP**: if the user also has the GitHub MCP connected (your client's MCP list shows both) **and** asks for code-level pointers, you can locate the hot frame in their repo, reference a specific `<file>:<line>` in the fix, and offer to open a pull request with the change. This is a suggestion, not a default — many users don't want or need code access from the session. Mention the option once if both MCPs are available; respect the answer either way.

## Standard starter prompt (for customers who don't know what to ask)

> **"Analyze the GPU flamegraph over the last 1 hour and suggest solutions."**

If the customer hands you anything close to that (or shorter — "what's slow", "investigate my GPU"), interpret it as: scope the analysis to the last 1 hour, pull the GPU flamegraph, cross-check the CPU view, follow the output template below. Don't make them remember the specifics — this is the on-ramp.

Variations the customer might use:
- "Analyze [vLLM / SGLang / Triton / my training job] over the last [Nh / since deploy]"
- "Where's the bottleneck right now?"
- "What's wasting GPU time today?"

For any of these: default to the last 1 hour if no time range is given, default to the whole cluster if no workload is named (and ask which to narrow if results look noisy).

## Pre-flight

**First, establish which zymtrace instance you're analyzing — you need its zymtrace URL in context.**

Check whether a zymtrace MCP server is connected in your client (in Claude Code, `claude mcp list | grep -i zymtrace`; in Codex or Cursor, the equivalent MCP-list in that tool):

- **Connected** → proceed.
- **Not connected** → route to [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md) to connect. It needs the zymtrace URL: if the user already gave one in this conversation, use it; otherwise **ask** (*"What's your zymtrace URL? — e.g. `https://zymtrace.your-company.com`"*). Never guess or assume `localhost`.

> **Data comes only from the live zymtrace MCP for the user's instance** — metrics and flamegraphs both. **Never** substitute local profile files (`.pftrace`, `profile_*.json`) — they aren't tied to the user's instance/filter and mislead. If the MCP isn't connected, connect it first (Pre-flight); don't analyze files on disk or work around the MCP.

## The cross-view protocol

The MCP handles the analysis; you handle the discipline of asking for both sides. Everything below — metrics and flamegraphs — comes from the **MCP**, so the MCP must be connected **first** (Pre-flight). If it isn't, connect it before anything else; don't fetch metrics or profiles any other way.

1. **Pull the workload's metrics first, for context.** Ask the MCP for the entity's metrics — GPU utilization / memory / SM efficiency for GPU work, plus CPU utilization — to establish whether the workload is GPU- or host-bound and which view will be informative. Carry these numbers into the recap; they frame the flamegraph findings.

2. **Ask the MCP to investigate the workload** the customer named (executable / container / pod / time range / model — whatever signals they gave). The MCP picks up the right scope.

3. **Pull whichever view the customer's question implies first** — GPU view for a GPU-shaped question, CPU view for a CPU-shaped one. Let the MCP narrate what's hot.

4. **Then explicitly ask the MCP for the OPPOSITE view of the same workload, with the same filter.** Use the exact filter values the MCP locked onto — same executable, same container, same time range. Don't hand-wave the filter; the cross-view is only useful when the slice matches.

5. **Cross-reference the two views** (against the step-1 metrics). Common reveals:
   - GPU at 95% but tokens/sec underwhelming → look at CPU for tokenizer / sampling / Python-side overhead.
   - GPU at 60% utilization → the host is the bottleneck. The CPU view will name it.
   - Specific GPU kernel dominant → the CPU view often shows the launcher / scheduler that's calling it. Useful for understanding launch-overhead vs kernel-time tradeoffs.
   - CPU dominated by `cudaMemcpy*` / `aten::*` synchronization → the workload is sync-bound on device transfers; the GPU view will show idle stretches.

6. **Write the recap using the output template below.** Use the data the MCP returned — metrics, kernel names, percentages, hot stacks, the call tree from the CPU view, and the kernels triggered on the GPU side — to fill the template. Don't paraphrase the MCP's suggestions verbatim; synthesize into a concrete next step. If the MCP didn't surface a suggestion, you still produce one — grounded in the returned data, not invented.

If the **GitHub MCP** is also connected, take the recommendation one step further: locate the hot frame in the customer's repo (file + line) and propose the specific edit, so the recap's `Fix:` block becomes an actual `<file>:<line>` reference with a code snippet. Then **ask whether to open a pull request** with the change — and only open it on a yes. Never push a PR unprompted.

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
- [ ] If the GitHub MCP is connected and the fix is code-level: offered to open a pull request, and opened one only on the user's yes.
- [ ] Recap follows the **Output template** above: title, observed call tree (with `→` GPU annotations + `⚠️` sync markers), CPU cross-check, Key Findings, 🔴 top issues block (max 3, each with `Observation:` + `Fix:`), 🟡 follow-up block (max 2 one-liners), Expected Impact.
- [ ] **Every** 🔴 issue has a concrete `**Fix:**` block — grounded in the actual flamegraph data, never punted ("ask me if you want suggestions") and never invented. Same for the 🟡 follow-ups: each has a `**Fix:**` after the em-dash.
- [ ] No more than 3 🔴 issues and no more than 2 🟡 follow-ups. If you have more, drop the lowest-priority ones; the customer can re-query.
- [ ] Workload identity (executable + time range) included in the recap so the customer can re-query before/after.

## Common pitfalls

- **Only pulling one view.** This is the failure mode the skill exists to prevent. Always pull both.
- **Different filters on the two views.** Cross-view only works when the slice matches. Re-use the MCP's resolved filter, don't paraphrase it.
- **Re-doing the MCP's pattern recognition.** The MCP names patterns; trust its naming. Your job is to *synthesize across both views* and propose a concrete next step, not to re-discover what the MCP already labeled.
- **Stopping at "the MCP found X" without a recommendation.** Always close with a specific fix to try, grounded in the returned data. If the MCP didn't volunteer one, synthesize from the kernel names + percentages it returned.
- **Skipping when the customer asks a CPU question.** Cross-view goes both ways — pull GPU for a CPU-shaped question too. CPU-bound workloads with idle GPU are also worth surfacing.

## Security constraints

- **Always** ground the recommendation in the data the MCP returned (kernel names, percentages, hot stacks). Synthesize across the two views — but don't fabricate signals the data doesn't show.
- **Never** analyze local profile files (`.pftrace`, `profile_*.json`) as a substitute for the MCP — see the data-source rule in Pre-flight.
- **Never** declare the investigation done after only one view. Pulling the opposite side with the same filter is the load-bearing step.
- **Never** recommend enabling PC sampling on a workload (which requires `privileged: true`) without flagging the security implication. See [install-zymtrace-profiler § PC sampling](../install-zymtrace-profiler/reference.md#pc-sampling).

---
name: optimize-memory-allocation
description: |
  Analyze JVM memory-allocation profiles with zymtrace (Java only): what allocates the most bytes and objects, why GC is busy, and where allocation churn burns CPU (boxing, String churn, collection resizing, buffers). Turns allocation profiling on if it's off, names the allocation sites, and applies the fix in the user's code. Also where a CPU profile turns out allocation- or GC-bound. Non-Java services → optimize-cpu-workloads; GPU memory → optimize-gpu-workloads; OOMKilled or crashes → the troubleshoot skills.
  Trigger phrases: "what's allocating the most memory", "analyze the JVM allocation profile", "why is GC so busy", "reduce GC pressure", "allocation churn", "what creates the most garbage", "reduce heap churn", "which Java code allocates the most", "enable allocation profiling".
---

# Optimize JVM Memory Allocation

> The MCP fetches the data — allocation rankings, allocation flamegraphs, host metrics; **you** analyze: name the hot allocation sites, identify the pattern, recommend and apply the fix.

**Java/JVM only.** zymtrace memory-allocation profiling is supported **only for the JVM** — it reads the **allocation profile**, stacks weighted by *bytes allocated* (and object count), not on-CPU time. A non-Java workload has no allocation profile: stay in [`optimize-cpu-workloads`](../optimize-cpu-workloads/SKILL.md) for its on-CPU hotspots. For GPU/device memory use [`optimize-gpu-workloads`](../optimize-gpu-workloads/SKILL.md). A service that's **crashing/OOMKilled** rather than churning is a profiler/backend problem — route to [`troubleshoot-zymtrace-profiler`](../troubleshoot-zymtrace-profiler/SKILL.md).

The common discipline — data-source policy, pre-flight, rank-first vs. drill-down, scope-to-own-code/ROI, the always-recommend-and-apply-the-fix rule, the output-template skeleton, severity sizing, and security — lives in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md). **Read it.** This skill adds the allocation-specific protocol and call-tree rendering on top.

Connection setup lives in [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md); this skill assumes the MCP is connected.

## Enable allocation profiling first — it's opt-in

JVM allocation profiling is **off by default.** Before analyzing, **confirm the Java service actually has an allocation profile** (try the allocation ranking / flamegraph for it). If it's empty, it isn't enabled yet — turn it on, wait for profiles to arrive, then analyze. Don't fabricate an analysis when there's no allocation data; enable and wait. Full reference: <https://docs.zymtrace.com/allocation-profiling>.

**Prerequisite:** the target runs a supported JVM — **OpenJDK, Azul Zulu, or Azul Zing**.

**To enable, ask the user for these inputs, then apply:**
- **Target** — a CEL expression scoping which workloads to profile (by container / deployment / host / project). Get the scope from the user; see the docs for CEL syntax.
- **Sampling interval** — bytes between allocation samples. Default **`16mib`** (production); **`512kib`** for fine-grained at higher overhead.
- **JVMTI backend** — use JVMTI as the sampling backend? Default **on** where supported.

Apply it one of three ways (per the docs), after the user confirms the rule:
1. **UI — no redeploy (simplest).** **Settings → Agent Config → Allocation Profiles → Add Rule** with the target and interval.
2. **Agent-config API — no redeploy.** `POST <gateway-url>/public/api/v1/agent/config/set` with an `AllocProfile` (and `UseJvmti`) setting. The call replaces the whole rule list: read it with `GET …/agent/config/get` first, append the rule, and send it back with the same `version`; read the exact body from `<gateway-url>/api-docs/openapi.json`. With auth on, an **HTTP 403** means the token can't change agent config — no service token can today — so use the UI instead. There is no MCP tool for agent config.
3. **Profiler startup flag — needs a profiler restart.** `-alloc-profile=<interval>` (env `ZYMTRACE_ALLOC_PROFILE`), e.g. `-alloc-profile=16mib`, plus optional `-use-jvmti` (env `ZYMTRACE_USE_JVMTI`). See [`install-zymtrace-profiler`](../install-zymtrace-profiler/SKILL.md). Use this when editing the profiler launch is easier than a live rule.

## Why allocation matters

Allocation is rarely free: high allocation rate drives **GC frequency and pause time**, and the allocation + collection work burns **CPU** that never shows up as your own hot function. So an allocation analysis pays off two ways — fewer/shorter GC pauses (latency) and reclaimed CPU (throughput / cost). When you've quantified the CPU recovered, dollarize it with the cost method in [`optimize-cpu-workloads` § Cost: annualize the cores](../optimize-cpu-workloads/SKILL.md#cost-annualize-the-cores).

## The allocation analysis protocol

The MCP pulls the data; you do the analysis. Establish a data path first (pre-flight, in the shared doc), and **confirm allocation profiling is enabled** (above) — if the Java service has no allocation profile yet, enable it and wait for data before continuing.

1. **Rank first if the request is rank-shaped** ("what's allocating the most", "which code creates the most garbage") — use **`discover`** / **`top_functions`** with event kind `alloc` (concise rankings), then drill into the top site with `hot_traces`. Rank by **bytes allocated** over the window (show the figure per entry); include host and container names where the data has them. Mark unmodifiable runtime/library allocations (JIT, classloading, framework internals you can't change) non-actionable and drill into the highest user-owned site. See scope-to-own-code/ROI in the shared doc.

2. **Pull allocation-related metrics first, for context.** Allocation rate (bytes/sec), GC time and frequency, heap used / churn — to establish whether GC pressure is actually a problem or allocation is cheap here. Carry these into the recap; they tell you if the fix is worth it.

3. **Pull the allocation call tree** at the named scope (executable / container / pod / host / time range) on the **allocation** dimension — use the **`hot_traces`** MCP tool when available (zymtrace 26.6.0+), else fall back to **`flamegraph`** (see the data-source policy in the shared doc). Read which allocation sites dominate by bytes.

4. **Name the pattern.** The MCP returns raw allocation sites + bytes; naming the dominant pattern is *your* job. Common JVM patterns:
   - **Autoboxing churn** — `Integer.valueOf`, `Long.valueOf`, boxed types in collections / streams (`Map<Integer,…>`, `Collectors.toList()` on a boxed stream).
   - **String churn** — `String` concatenation in loops, `String.format`, `substring`, `getBytes`, repeated `toString()`; `StringBuilder` growth.
   - **Collection resizing** — `ArrayList`/`HashMap` grown from default capacity (`Arrays.copyOf`, `HashMap.resize`) because no initial size was given.
   - **Buffer / array churn** — `new byte[]` / `char[]` per request for I/O, serialization, or codecs that could be pooled or reused.
   - **Transient object graphs** — per-request DTOs and JSON (de)serialization (Jackson/Gson) allocating wrappers, nodes, and temp maps.
   - **Lambda / stream / iterator allocations** — boxed streams, capturing lambdas, iterator objects in hot loops.

5. **Write the recap** using the output template (shared doc) with the allocation call-tree rendering below.

6. **Apply the fix** (shared doc — "Always recommend a fix — then apply it"). The recap is the midpoint, not the finish line. Typical allocation fixes:
   - **Presize collections** — `new ArrayList<>(n)`, `new HashMap<>(expected, 1f)`.
   - **Kill boxing** — primitive arrays or a primitive-collection lib (Eclipse Collections, fastutil), `IntStream` over `Stream<Integer>`.
   - **Reuse buffers** — pool `byte[]`/`ByteBuffer`, reuse `StringBuilder`, stream instead of materializing.
   - **Trim the hot path** — hoist invariant allocations out of loops, replace `String.format` with `StringBuilder`/append, gate debug-log string building behind level checks.

## Allocation call-tree rendering (Observed Call Tree section)

The output-template skeleton is in the shared doc. The allocation **Observed Call Tree** block renders like this:

```markdown
**Observed Call Tree — allocation profile** (<process / container / host / time range>)

<top-level frame>  (<bytes / % of allocated>)
├── <child frame>  (<bytes / %>)
│   └── <leaf alloc site>  (<bytes / %>)  ← allocating type/call, e.g. `Integer.valueOf`, `new byte[]`, `HashMap.resize`
└── <child frame>  (<bytes / %>)  ← hot allocation path
```

**Call-tree conventions:**
- The tree is the **allocation profile** — frames weighted by **bytes allocated** (with object count when the MCP returns it), not on-CPU time.
- Use `├──` and `└──` for the hierarchy (matches what the MCP returns).
- Annotate leaves with the **allocating type or call site** and its byte share; mark the dominant path with `← hot allocation path`.
- Keep frame / type names exactly as the MCP returns them; don't paraphrase.

## Done (allocation-specific, on top of the shared checklist)

- [ ] Allocation profiling confirmed enabled for the Java service; if it wasn't, enabled it (target CEL + sampling interval + JVMTI asked of the user, applied via the UI, the agent-config API, or the profiler flag) and waited for data before analyzing.
- [ ] Ranked first when rank-shaped, on the **allocation** dimension by bytes; runtime/library allocations marked non-actionable, the top user-owned site drilled into.
- [ ] Allocation metrics pulled first (allocation rate, GC time/frequency, heap churn) and carried into the recap — so the fix's worth is established.
- [ ] Allocation call tree pulled at the named scope; the dominant pattern named (boxing, String churn, collection resize, buffer churn, transient graphs).
- [ ] Impact framed as **GC pause + CPU reclaimed**; CPU portion dollarized via the CPU skill's cost method when quantified.

(Plus the common Done checklist in the shared doc — template, every 🔴/🟡 has a `Fix:`, fix applied, follow-up question.)

## Common pitfalls

- **Analyzing before it's enabled.** Empty allocation data means profiling is **off** (it's opt-in), not that the service doesn't allocate. Enable it (agent config / profiler flag), wait for data, then analyze — never invent an analysis from no data.
- **Reading bytes as if they were CPU time.** The allocation profile weights by bytes allocated, not on-CPU samples — a heavy allocator may be cheap if GC keeps up. Pull the GC/allocation-rate metrics (step 2) before calling it a problem.
- **Chasing allocations the user can't change.** JIT, classloading, and framework internals show up but aren't action items — mark them non-actionable and lead with the top user-owned site.
- **Confusing allocation churn with a leak.** This profile shows *allocation rate*, not retained/leaked memory. A steady-state churner isn't a leak; for OOM/leak-and-crash, route to troubleshoot.
- **Expecting the MCP to name the pattern.** It returns sites + bytes; naming boxing/String-churn/resize and the fix is *your* job.

## Security constraints

- Common rules (ground in returned data, never analyze local profile files, never query the DB directly) are in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md).
- **Always** ground the recommendation in the data the MCP returned (allocation sites, bytes, percentages) — don't fabricate signals the data doesn't show.

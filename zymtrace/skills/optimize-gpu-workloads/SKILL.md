---
name: optimize-gpu-workloads
description: |
  Analyze GPU performance with zymtrace — a GPU/CUDA workload, a GPU flamegraph, the hot kernel, why the GPU isn't saturated, or an inference server (vLLM, SGLang, NVIDIA Dynamo-Triton, TensorRT-LLM) or training/fine-tuning job. The zymtrace MCP pulls the data (GPU metrics, flamegraphs); YOU analyze. ALWAYS cross-check the CPU side with the same filter — a GPU workload's bottleneck often hides host-side (tokenizer, DataLoader, Python overhead, sync points) — so pull GPU metrics, the GPU flamegraph, AND the matching CPU flamegraph. Scope to code the user controls; recommend AND apply the fix in the user's source (ask for the path if it isn't local), then close with a follow-up. ANY request mentioning GPU, CUDA, an accelerator, inference, an inference server, or training/fine-tuning routes HERE — including "investigate/troubleshoot/diagnose/look into/what's wrong with" phrasings. (Outright broken rather than slow — no GPU profiles, NVML missing, pods crash-looping — use troubleshoot-zymtrace-profiler.) CPU-only workload with no GPUs → optimize-cpu-workloads.
  Trigger phrases: "analyze/investigate/troubleshoot/diagnose my GPU workload", "investigate my inference/training/fine-tuning job", "look into my vLLM/SGLang/Triton/TensorRT-LLM workload", "what's wrong with my GPU job", "where's the bottleneck in vllm/sglang/triton", "find the hot kernel", "GPU isn't saturated", "GPU utilization is low", "why is my GPU idle", "why is inference slow", "analyze the GPU flamegraph", "which kernel uses the most GPU", "investigate my CUDA workload", "profile my training job".
---

# Optimize GPU Workloads

> The MCP fetches the data — GPU metrics, flamegraphs; **you** analyze. Load-bearing discipline: **always pull both the GPU and CPU views with the same filter** — half the time a GPU workload's bottleneck is host-side.

The common discipline — data-source policy, pre-flight, rank-first vs. drill-down, scope-to-own-code/ROI, the always-recommend-and-apply-the-fix rule, the output-template skeleton, severity sizing, and security — lives in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md). **Read it.** This skill adds the GPU-specific protocol and call-tree rendering on top.

Connection setup lives in [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md); this skill assumes the MCP is connected. **CPU-only workload (no GPUs)?** Use [`optimize-cpu-workloads`](../optimize-cpu-workloads/SKILL.md) — it skips the GPU view, GPU metrics, and inference-server framing entirely.

## Standard starter prompt (for users who don't know what to ask)

> **"Analyze the GPU flamegraph over the last 1 hour and suggest solutions."**

If the user hands you anything close to that (or shorter — "what's slow on my GPU", "investigate my GPU"), interpret it as: scope to the last 1 hour, pull the GPU flamegraph, cross-check the CPU view, follow the template. Variations: "Analyze [vLLM / SGLang / Triton / my training job] over the last [Nh / since deploy]", "Where's the bottleneck right now?", "What's wasting GPU time today?". Default to the last 1 hour and the whole cluster if no workload is named (ask which to narrow if results look noisy).

## The cross-view protocol

The MCP pulls the data; you do the analysis *and* the discipline of asking for both sides. Establish a data path first (pre-flight, in the shared doc).

1. **Pull the workload's GPU metrics first, for context.** GPU utilization, memory used/bandwidth, SM efficiency, Tensor-Core activity, temperature, and PCIe throughput — plus CPU utilization — to establish whether the workload is GPU- or host-bound and which view will be informative. **If the workload is an inference server, also pull its framework metrics where collected — vLLM, SGLang, and NVIDIA Dynamo-Triton** (queue depth / pending requests, running-vs-waiting batch size, tokens/sec, KV-cache utilization, prefix-cache hit rate, time-to-first-token). These tell you whether the GPU is starved, saturated, or memory-bound *before* you read a single frame. Carry the numbers into the recap; they frame the flamegraph findings. (Interpretation patterns: [Inference-server specifics](#inference-server-specifics) below.)

2. **Query the MCP for the workload's data** at the scope the user named (executable / container / pod / time range / model).

3. **Pull the GPU view first** — use the **`hot_traces`** MCP tool when available (zymtrace 26.5.1+), else fall back to **`flamegraph`** (see the data-source policy in the shared doc). Read which kernels/frames are hot from the returned data.

4. **Then explicitly ask the MCP for the CPU view of the same workload, with the same filter** (same tool preference — `hot_traces`, else `flamegraph`). Use the exact filter values the MCP locked onto — same executable, same container, same time range. Don't hand-wave the filter; the cross-view is only useful when the slice matches.

5. **Cross-reference the two views** (against the step-1 metrics). Common reveals:
   - GPU at 95% but tokens/sec underwhelming → look at CPU for tokenizer / sampling / Python-side overhead.
   - GPU at 60% utilization → the host is the bottleneck. The CPU view will name it.
   - Specific GPU kernel dominant → the CPU view often shows the launcher / scheduler calling it (launch-overhead vs kernel-time tradeoffs).
   - CPU dominated by `cudaMemcpy*` / `aten::*` synchronization → sync-bound on device transfers; the GPU view will show idle stretches.

6. **Write the recap** using the output template (shared doc) with the GPU call-tree rendering below.

7. **Apply the fix** (shared doc — "Always recommend a fix — then apply it"). The recap is the midpoint, not the finish line.

## Inference-server specifics

For vLLM, SGLang, and NVIDIA Dynamo-Triton, the framework metrics (when collected) sharpen the diagnosis — read them alongside the flamegraph:

- **Low GPU utilization + healthy queue** → host-side bottleneck (tokenizer, scheduler, Python). Cross-check CPU.
- **High utilization + low tokens/sec** → kernel inefficiency or memory-bandwidth bound, not a starvation problem.
- Common inference fixes are config knobs: `--enable-prefix-caching`, `--enable-chunked-prefill`, `VLLM_ATTENTION_BACKEND=...`, tensor-parallel sizing, batch/`max-num-seqs` tuning. Name the specific flag.

## GPU call-tree rendering (Observed Call Tree section)

The output-template skeleton is in the shared doc. The GPU **Observed Call Tree** block renders like this:

```markdown
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
```

**Call-tree conventions:**
- The whole call tree is the **GPU profile** — zymtrace unwinds the full stack from the CUDA kernel back up through dispatcher / Python / host frames. Every frame shown was sampled while the GPU was busy.
- Use `├──` and `└──` for the hierarchy (matches what the MCP returns).
- Use `→` to annotate each leaf with the CUDA kernel running when that frame was sampled. This is the kernel underneath that frame, not a "CPU→GPU" link.
- Mark sync points (`cudaStreamSynchronize`, `cudaDeviceSynchronize`, `D→H memcpy`) with `⚠️` — they kill pipelining and almost always deserve calling out.
- Keep frame and kernel names exactly as the MCP returns them; don't paraphrase.

**CPU cross-check conventions:**
- The CPU view is a **separate** flamegraph queried with the same filter — it shows what the host process does on its own time (not while waiting on the GPU).
- Keep it short — 1–2 sentences. It either confirms the GPU diagnosis ("nothing else surfaced") or surfaces a host-side issue.
- **If the CPU view surfaces a host-side bottleneck bigger than the GPU one, promote it to a 🔴 and reframe the diagnosis around it.**

## Done (GPU-specific, on top of the shared checklist)

- [ ] GPU metrics pulled first (GPU/CPU utilization, memory, SM efficiency) and carried into the recap.
- [ ] Both GPU **and** CPU flamegraphs pulled for the **same** filter (same executable / container / time).
- [ ] The cross-view interpretation given — which side is the constraint, and why.
- [ ] Observed call tree rendered with `→` kernel annotations + `⚠️` sync markers, followed by the CPU cross-check.

(Plus the common Done checklist in the shared doc — metrics first, template, every 🔴/🟡 has a `Fix:`, fix applied, follow-up question.)

## Common pitfalls

- **Only pulling the GPU view.** This is the failure mode the skill exists to prevent. Always pull the matching CPU view.
- **Different filters on the two views.** Cross-view only works when the slice matches. Re-use the MCP's resolved filter, don't paraphrase it.
- **Expecting the MCP to name the pattern for you.** It returns raw data — frames, kernels, percentages. Naming the pattern (kernel-launch-bound, memory-bandwidth bound, DataLoader-starved, NCCL-collective-bound, sync-bound) is *your* job.
- **Missing a host-side bottleneck.** A GPU at 60% means the host is starving it; the CPU cross-check is where you find out why.

## Security constraints

- Common rules (ground in returned data, never analyze local profile files, never query the DB directly) are in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md).
- **Never** declare the investigation done after only the GPU view. Pulling the CPU side with the same filter is the load-bearing step.
- **Never** recommend enabling PC sampling on a workload (which requires `privileged: true`) without flagging the security implication. See [install-zymtrace-profiler § PC sampling](../install-zymtrace-profiler/reference.md#pc-sampling).
</content>

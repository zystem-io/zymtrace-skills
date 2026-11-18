---
name: optimize-gpu-workloads
description: |
  Analyze GPU performance with zymtrace (NVIDIA CUDA or AMD ROCm): hot kernels, low GPU utilization, inference servers (vLLM, SGLang, Dynamo-Triton, TensorRT-LLM), training jobs, multi-GPU stragglers and slow NCCL collectives, GPU time per model layer. Correlates the GPU profile with the CPU profile, metrics, GPU topology (NVLink/PCIe, NUMA placement) and model shapes for the same hosts and window, then applies the fix. Use for any GPU, CUDA, ROCm, inference or training performance question. Gaps, cadence or high-resolution profiling → analyze-gpu-timeline; broken profiler → troubleshoot-zymtrace-profiler; no GPUs → optimize-cpu-workloads.
  Trigger phrases: "analyze my GPU workload", "investigate my inference/training job", "why is inference slow", "GPU utilization is low", "find the hot kernel", "analyze the GPU flamegraph", "look into my vLLM/SGLang workload", "find the straggler", "which GPU is slowing my training", "NCCL/all-reduce is slow", "which layer uses the most GPU time", "check the GPU topology".
---

# Optimize GPU Workloads

> The MCP fetches the data; **you** analyze. Load-bearing discipline: **every GPU analysis reads five views of the same hosts, GPUs and window — GPU profile, CPU profile, metrics, GPU topology, model shape — and correlates them.** A GPU workload's bottleneck often hides host-side; when it doesn't, the topology or the model's shapes often explain what the kernels alone can't.

The common discipline — data-source policy, pre-flight, rank-first vs. drill-down, scope-to-own-code/ROI, the always-recommend-and-apply-the-fix rule, the output-template skeleton, severity sizing, and security — lives in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md). **Read it.** This skill adds the GPU-specific protocol and call-tree rendering on top.

Connection setup lives in [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md); this skill assumes the MCP is connected. **CPU-only workload (no GPUs)?** Use [`optimize-cpu-workloads`](../optimize-cpu-workloads/SKILL.md) — it skips the GPU view, GPU metrics, and inference-server framing entirely. **Question about order or timing** (gaps between batches or kernels, copy/compute overlap, where syncs land, cadence, jitter, drift) **or a request to enable high-resolution profiling?** Use [`analyze-gpu-timeline`](../analyze-gpu-timeline/SKILL.md) — the flamegraph aggregates and can't show gaps.

## Standard starter prompt (for users who don't know what to ask)

> **"Analyze the GPU flamegraph over the last 1 hour and suggest solutions."**

If the user hands you anything close to that (or shorter — "what's slow on my GPU", "investigate my GPU"), interpret it as: scope to the last 1 hour, run the [correlated protocol](#the-correlated-protocol) (metrics, GPU and CPU profiles, topology, model shape), follow the template. Variations: "Analyze [vLLM / SGLang / Triton / my training job] over the last [Nh / since deploy]", "Where's the bottleneck right now?", "What's wasting GPU time today?", "Which GPU is the straggler in my training job?". Default to the last 1 hour and the whole cluster if no workload is named (ask which to narrow if results look noisy). A multi-GPU job (several ranks, collectives in the GPU view) also gets the [straggler check](#multi-gpu-jobs-stragglers-and-slow-collectives).

## The correlated protocol

Five views of **one scope** — the same hosts, GPUs, process and time window — read together. None of them alone is the answer. Establish a data path first (pre-flight, in the shared doc). Topology and model shapes aren't in the MCP yet; two scripts read them from the gateway API with the token in the environment (`ZYMTRACE_API_TOKEN` or `ZYMTRACE_MCP_TOKEN`, never inlined).

1. **Resolve the scope.** `discover` (event kind `cuda`) for the workload the user named: executable or script, hosts, GPU UUIDs, time range. Write the filter down; every later call reuses it verbatim — paraphrasing it is how a correlation goes wrong.

2. **Metrics first, for context** (`discover_metrics` → `metrics`, same hosts/GPUs and range). GPU utilization, memory used/bandwidth, SM efficiency, Tensor-Core activity, temperature, and PCIe throughput — plus CPU utilization — to establish whether the workload is GPU- or host-bound. **Device health for the GPUs in scope:** throttle reasons (`hw.gpu.clocks_throttle`), XID and PCI errors (`hw.gpu.err.xid`, `hw.gpu.err.pci.count`), row remapping (`hw.gpu.err.remapped.*`), NVLink throughput in total and per link (`hw.gpu.nvlink.rx/tx`, `hw.gpu.nvlink.per_link.rx/tx`). GPU metrics take `Attr("device.id")` **with** the `GPU-` prefix. **If the workload is an inference server, also pull its framework metrics where collected — vLLM, SGLang, and NVIDIA Dynamo-Triton** (queue depth / pending requests, running-vs-waiting batch size, tokens/sec, KV-cache utilization, prefix-cache hit rate, time-to-first-token). TensorRT-LLM has no framework metrics — use its GPU metrics and profiles. Carry the numbers into the recap; they frame everything else. (Interpretation: [Inference-server specifics](#inference-server-specifics).)

3. **GPU profile** — **`hot_traces`** when available (zymtrace 26.6.0+), else **`flamegraph`** (data-source policy in the shared doc). Which kernels and frames are hot, on which GPUs (the trace's `gpu_uuids`), and whether Model Layer frames are present. Host syncs (`cuda-sync: stream-synchronize` under `cudaStreamSynchronize`) show up only as leaves of full `hot_traces`; `top_functions` doesn't list them, so read the full top traces before ruling syncs out.

4. **CPU profile, same filter** (`on_cpu`, and `off_cpu` when the GPU looks starved; same tool preference). Same executable, container, hosts and time range the MCP locked onto.

5. **Topology of the hosts the GPU profile ran on**, over the same window:

   ##### Claude runs
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/optimize-gpu-workloads/scripts/gpu-topology.sh \
     <gateway-url> <project-id> <start-ms> <end-ms> --query 'host.name == "<host from the profile>"'
   ```
   Per host: NUMA nodes; each GPU's NUMA node, NVLinks (type, version, `Inactive`) and row of the connection matrix (`NV<n>`, `PIX`/`PXB`/`PHB`/`NODE`/`SYS`); MIG instances; per profiled process and GPU, the CPUs its CUDA work ran on and how many were **outside the GPU's NUMA node**; PC-sampling stall categories when PC sampling is on. Match the profile's GPUs to rows by UUID — profiles and `discover` print it without the `GPU-` prefix, the script with it. Both scripts save their JSON to `${TMPDIR:-/tmp}/zymtrace/` by default (`--out-dir` to change) and print the path.

6. **Model shape of what those processes ran**, same scope and window:

   ##### Claude runs
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/optimize-gpu-workloads/scripts/model-shapes.sh <gateway-url> <project-id> <start-ms> <end-ms> --query 'host.name == "<host>"'  # models in scope
   bash ${CLAUDE_PLUGIN_ROOT}/skills/optimize-gpu-workloads/scripts/model-shapes.sh <gateway-url> <project-id> <start-ms> <end-ms> --shape <shape_ids>              # structure, GEMM alignment
   bash ${CLAUDE_PLUGIN_ROOT}/skills/optimize-gpu-workloads/scripts/model-shapes.sh <gateway-url> <project-id> <start-ms> <end-ms> --shape <shape_ids> --module <layer frame file>
   ```
   The list gives serving name, architecture, parameters, TP×PP and process count — check them against the GPUs and processes in the profile. Several rows for one serving name are normal (the module structure changed after load); use the row whose process count and first/last seen cover the profile window. The Model Layer root frame is the serving name; a layer frame's `file` is the module path for `--module`. Reading the layers: [§ Model layer attribution](#model-layer-attribution-model-shapes). No models listed → model shapes aren't on for the workload; say so and carry on.

7. **Correlate** every finding against the other views — same GPU, same window:

   | Seen in | Check against | What it means |
   |---|---|---|
   | GPU at ~60% utilization | CPU profile | The host is starving the GPU; the CPU view names it (tokenizer, DataLoader, Python, scheduler). |
   | GPU at 95%, tokens/sec underwhelming | CPU profile | Tokenizer / sampling / Python-side overhead. |
   | One kernel dominant | CPU profile; model shape | The launcher or scheduler calling it (launch overhead vs kernel time); the module it belongs to and that module's tensor shapes. |
   | CPU dominated by `cudaMemcpy*` / `aten::*` sync | GPU profile; topology placement | Sync-bound transfers, idle stretches on the GPU; worse when the copying thread runs off the GPU's NUMA node. |
   | CUDA work on CPUs outside its GPU's NUMA node (placement) | CPU profile (launch thread, copies) | Launches and host↔device copies cross the socket. Pin each rank to its GPU's node: `numactl --cpunodebind=<node> --membind=<node>`, or the launcher's per-rank CPU affinity. |
   | Collectives (`ncclDevKernel_*`) take a big share | topology matrix rows of the job's GPUs; per-link NVLink metrics | `PIX`/`PXB`/`PHB`/`NODE`/`SYS` between ranks, or `Inactive` links → traffic over PCIe or across sockets; one link far below its peers → degraded link. All `NV<n>` and healthy → not the interconnect: check for a [straggler](#multi-gpu-jobs-stragglers-and-slow-collectives). |
   | TP×PP from the model list | topology matrix | A tensor-parallel group spanning GPUs without NVLink runs its all-reduce over PCIe; keep TP inside an NVLink domain. |
   | A model layer hot | the kernels under it; `--module` on that layer | If the time under it is NCCL (FSDP `unshard` → `foreach_all_gather`) and its tensors match its sibling layers', the layer is carrying a collective wait (typically the first all-gather of each step), not compute. Otherwise a GEMM dimension that isn't a multiple of 64 per rank, or a dtype that misses Tensor Cores, explains a slow kernel variant. |
   | Throttle reason, XID, PCI errors or pending row remap on a GPU | that GPU's kernels in the profile | Hardware, not code — [Rule out the hardware path](#rule-out-the-hardware-path). |

   A view that returned nothing (no host, no models, no metric series) is **"not measured"** in the recap, never "healthy".

8. **Write the recap** using the output template (shared doc) with the GPU call-tree rendering and context block below.

9. **Apply the fix** (shared doc — "Always recommend a fix — then apply it"). The recap is the midpoint, not the finish line.

## Inference-server specifics

For vLLM, SGLang, and NVIDIA Dynamo-Triton, the framework metrics (when collected) sharpen the diagnosis — read them alongside the flamegraph:

- **Low GPU utilization + healthy queue** → host-side bottleneck (tokenizer, scheduler, Python). Cross-check CPU.
- **High utilization + low tokens/sec** → kernel inefficiency or memory-bandwidth bound, not a starvation problem.
- Common inference fixes are config knobs: `--enable-prefix-caching`, `--enable-chunked-prefill`, `VLLM_ATTENTION_BACKEND=...`, tensor-parallel sizing, batch/`max-num-seqs` tuning. Name the specific flag.
- **CUDA / HIP graphs are profiled** — engines use them by default, and kernels inside a graph appear in the flamegraph under the code that launched the graph. Don't recommend `--enforce-eager` just to see kernels. (Only full-depth [model layer](#model-layer-attribution-model-shapes) nesting needs it, for a short diagnostic run.)

## AMD (ROCm) workloads

The protocol is the same — GPU view, then the CPU view with the same filter, then the topology and model-shape steps — with these differences:

- The GPU flamegraph shows HIP kernels under the CPU stacks that launched them. **No PC sampling** (it's NVIDIA-only), so no instruction-level or stall-reason data.
- AMD device metrics are per device, **not per process** — attribute a device's utilization to a workload only when it's the only one on that GPU.
- Model shapes need `ZYMTRACE_ROCMPROFILER__MODEL_SHAPE__ENABLED=true` on the workload. If `gpu-topology.sh` shows no connection matrix or links for the AMD GPUs, report the topology as not measured.
- zymtrace's AI-generated recommendations don't cover ROCm yet; do the analysis yourself from the flamegraphs.

## Multi-GPU jobs: stragglers and slow collectives

Use this when the workload spans several GPUs (DDP, FSDP, tensor/pipeline parallel, multi-GPU inference) and collectives (`AllReduce`, `AllGather`, `ReduceScatter`) take a big share of GPU time, one GPU seems to hold the others back, or a distributed job got slower. A collective finishes only when every rank of its communicator has joined, so on the healthy GPUs the `ncclDevKernel_*` time is mostly **waiting for a late rank**. Tuning NCCL there is the wrong fix; find the late rank and why it's late.

**Needs straggler detection on the job** — `ZYMTRACE_CUDAPROFILER__NCCL=true` on every rank, NCCL 2.27+, off by default (setup: [install-zymtrace-profiler reference § GPU features](../install-zymtrace-profiler/reference.md#gpu-features-straggler-detection-model-shapes-timeline)). `communicators_evaluated: 0` means **not measured**, never healthy. Only communicators of 3+ ranks are evaluated, and a rank must be late in 2+ consecutive 60-second windows.

The MCP's `nccl_analysis` prompt (resource `prompt://nccl`) holds the full procedure — read it. In short:

1. **Scope to one job** — container, script, or SLURM job ID, and the run's time range. A script-only scope can merge two runs of the same script.
2. **`nccl_stragglers`.** Per late rank: host, GPU, `peer_wait_per_collective` (lag), `peer_collective_time_waiting` (waiting share), `late: in N agent windows over M episodes`, episode ranges. Episodes marked *propagated* started in another communicator — prefer the non-propagated ones.
3. **`nccl_slow_operations`** (default threshold 30% ≈ 1.43× the time). A slow operation overlapping a straggler of the same communicator is that straggler. With no straggler, every rank slowed together: suspect links, other jobs on the same GPUs or network, or a workload change.
4. **`nccl_causes`** for the top 1–3 episodes, communicator hash and `range` copied verbatim. Throttled clock, active power cap, or NVLink errors → hardware. `none on the checked GPUs` with full coverage → the workload. GPUs listed without metrics → "not measured", never "no cause". NICs, InfiniBand and RoCE are not covered.
5. **Why is the straggler late?** It starts the collective late, so look at what its host and GPU did *before* the collectives, against one healthy peer, over the episode range: `hot_traces` / `top_functions` (`cuda`, `Host` + `GpuUuid` **without** the `GPU-` prefix), `on_cpu` / `off_cpu` (`Host` + `Exe` or `Script`), GPU metrics (`Attr("device.id")` **with** the `GPU-` prefix), and every rank's `nccl.comm.exec_time` (`Attr("nccl.comm_hash")` Eq the hash, spatial fields `Attr("nccl.rank")` + `Host`, Gauge avg/avg, interval 60000).
   Every rank on a host runs the same executable, so the CPU view needs a per-rank split. Check a candidate field before relying on it: `discover` (event kind `cuda`) per `JobTag` or `Thread` value, and see whether its `gpu_uuids` name one GPU. A `JobTag` can be dominated by one GPU yet spread over several, so a per-tag view is approximate — say so. Survey-mode `hot_traces` truncate prefixes; compare the late rank with the peer through `top_functions` over the episode, and when a frame stands out (file writes, GC, data loading) take the `flamegraph` of that slice to see its callers.

Read it right:

- **The late rank has the *lowest* collective time** of its communicator: it arrives last and barely waits. Never call it the fastest GPU, and never blame the rank with the longest collective time — that one waited the most.
- **The per-rank shape names the cause.** One outlier rank with a throttled clock → hardware. A staircase across ranks that mirrors how the data is split (e.g. contiguous slices of a length-sorted batch) → workload imbalance.
- **The healthy peer's CUDA flamegraph names the collective, not the cause** — e.g. DDP's `c10d::Reducer::autograd_hook` → `ncclDevKernel_AllReduce_*`, FSDP's reduce-scatter / all-gather.
- **No straggler doesn't prove healthy hardware**, and a straggler with clean causes is a workload problem until the profiles say otherwise.
- **With PC sampling on**, kernel self time moves into stall-reason / instruction frames — rank NCCL kernels by total, not self.

| Signature | Fix |
|---|---|
| Throttled or degraded GPU (SM clock far below peers, power cap active, NVLink errors) | Operational: drain or repair that GPU (host + UUID from the tool). Stopgap for DDP: re-split micro-batches by each rank's measured speed. Unequal micro-batch counts break FSDP / tensor-parallel collectives — don't use that stopgap there. |
| Data or sequence-length imbalance (exec-time staircase following the split) | Balance work, not sample count: deal length-sorted micro-batches round-robin, reversing each round, or partition by Σ seq_len²; keep micro-batch counts equal. |
| Pipeline stage imbalance (the last stage also runs the loss) | Rebalance layers across stages. Point-to-point `Send`/`Recv` isn't checked by detection — compare the stages' profiles. |
| Rank 0 late while its CPU profile writes files (`PyTorchStreamWriter::writeRecord`, `mz_zip_writer_*`, `writev`, page-cache frames) | Checkpointing on rank 0 while the other ranks wait in their next collective. Write sharded checkpoints so every rank saves its own shard in parallel (FSDP `SHARDED_STATE_DICT`), skip optimizer state when the run won't be resumed, or save less often. |
| Ranks pausing at different times in Python GC | Disable automatic GC in the loop and collect on every rank at the same step. |
| Slow operation, no straggler | Check links ([Rule out the hardware path](#rule-out-the-hardware-path)), other jobs sharing the GPUs or network, recent workload changes. |

**Re-check after the fix:** changing the workload can move the straggler to another rank. Run `nccl_stragglers` again over the new run's range.

In the recap, put a **Stragglers** table above the call tree — rank, host, GPU, lag per collective, waiting share, episodes, possible cause — then render the straggler's call tree (what it did before the collectives) and one line on the healthy peer's NCCL path.

## Model layer attribution (model shapes)

When model shapes are on, the CUDA profile carries **Model Layer** frames — kind `model-layer`, named `<Class> <attr>` (`Qwen3DecoderLayer layers.17`, `Qwen3Attention self_attn`, `Linear lm_head`), with the module path as their `file` (`model.layers.17.self_attn`), under a root frame named after the model's serving name. Use them:

- **Rank layers by total.** A layer frame's self time is 0, so always quote its **total**. `top_functions` lists every layer frame but ranks by self time, so the layers come last: read every page and sort the `kind: model-layer` entries by total (layer frames can span many pages). The MCP `flamegraph` keeps only ~600 nodes, so it shows the biggest layers only. Full `hot_traces` show layer frames inline, without their kind (`Qwen3Model model @ model`).
- **Attribute GPU time to the model:** attention vs MLP, one decoder layer vs another, the output head vs the rest of the forward pass.
- **Tie a slow kernel to its module, then to its shape.** `model-shapes.sh … --shape <ids> --module <layer file>` prints the module's tensors: shape, dtype, `sharded=<dim>` when vLLM tensor parallelism splits it (the per-rank size on that dim is the shape divided by tp; shapes are whole-model, also under FSDP / ZeRO-3). `--shape` alone lists the GEMM weights whose per-rank dims aren't multiples of 64 — candidates, which matter when that module is hot and runs a slow kernel variant. Example: after `resize_token_embeddings(len(tokenizer))`, an output layer of 151,671 rows ran on a Turing-era `cutlass_75_…_align1` GEMM on an H100 and took 12.16% of GPU time; `pad_to_multiple_of=64` moved it to an `nvjet_sm90` kernel at 2.49% and made each training step 1.23× faster.
- **Check the layout against the hardware.** TP×PP and the process count from the model list say how many GPUs the model occupies; compare them with the GPUs in the profile and the topology matrix — a tensor-parallel group belongs inside one NVLink domain.

The shapes come from the UI's internal API, which is unversioned; the script is the interface until the MCP gets a models tool.

Limits: under **CUDA graph replay** (the vLLM / SGLang default) the layer frame sits directly above each kernel — names stay, nesting doesn't; `--enforce-eager` restores full depth but changes performance, so use it only for a short diagnostic and never quote eager timings as production numbers. **Backward-pass kernels**, **CPU flamegraphs**, and launches whose stack ends in a native runtime have no layer frames; fused kernels are attributed to the module that launched them. No layer frames at all → model shapes aren't on for that process (`ZYMTRACE_CUDAPROFILER__MODEL_SHAPE__ENABLED=true` on the workload, `ZYMTRACE_ROCMPROFILER__MODEL_SHAPE__ENABLED=true` on AMD; see [install-zymtrace-profiler](../install-zymtrace-profiler/SKILL.md)).

## Rule out the hardware path

When the GPU looks underused, collectives (NCCL all-reduce, all-gather) are slow, or host↔device copies are slower than they should be — and neither the GPU nor the CPU view shows a code-level cause — the bottleneck may be the machine, not the code.

For a multi-GPU communicator, `nccl_causes` already checks clocks, throttle reasons and NVLink errors for the episode ([above](#multi-gpu-jobs-stragglers-and-slow-collectives)); the steps below cover single GPUs and what it doesn't.

**Metrics** (protocol step 2, same GPUs and window): throttle reasons, XID and PCI errors, row remapping, NVLink throughput per link — one link far below its peers is a degradation signal. The profiler also emits NVLink CRC / replay / recovery error counters (`hw.gpu.nvlink.per_link.flit_error`, `.data_error`, `.replay_error`, `.recovery_error`), ECC counts (`hw.gpu.err.ecc.single_bit`, `.double_bit`) and each link's negotiated speed (`hw.gpu.nvlink.per_link.speed`). Read an absent series right: counters and per-link throughput are sent only when they change, so no series means no new errors (or no traffic) in the window, or a counter the GPU doesn't expose — not proof of health; the link speed is sent whenever the GPU reports it, so no speed series means the GPU doesn't expose it.

**Topology** (`gpu-topology.sh`, protocol step 5): a pair of the job's GPUs on a PCIe path (`PIX`, `PXB`, `PHB`, `NODE`, `SYS`) where its peers have `NV<n>`, `Inactive` NVLinks or one GPU with fewer links than the rest, and CUDA work running off its GPU's NUMA node.

When the counters above aren't reported, ask the user to check **GPU Topology** in the zymtrace UI for the host (device health: ECC errors, retired pages, XID; NVLink error rates).

A placement problem is fixed with `numactl` or the scheduler's CPU/NUMA affinity; a degraded link or ECC/XID errors mean draining or repairing the node. Don't tune code on a node with a sick interconnect. Docs: <https://docs.zymtrace.com/features/gpu-topology>

## GPU call-tree rendering (Observed Call Tree section)

The output-template skeleton is in the shared doc. The GPU **Observed Call Tree** block — call tree, CPU cross-check, and the hardware and model context — renders like this:

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

**Hardware and model context** (<host> · <GPUs used> · <same time range>)

- **Metrics:** <GPU/CPU utilization, plus any throttle, XID, PCI or link numbers that bear on the findings>
- **Topology:** <link between the job's GPUs (NV18 / PIX / SYS …), each GPU's NUMA node, placement: CPUs outside it>
- **Model:** <serving name, architecture, parameters, TP×PP; hot layer → its tensor shapes when relevant>
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

**Context conventions:**
- One line per view, numbers copied from the scripts and tools. A view that returned nothing says "not measured" and why (e.g. "model shapes not on for this workload").
- A context finding that explains the top issue (off-node placement, a PCIe hop between ranks, a misaligned hot layer) goes into that issue's observation and `Fix:` too, not only here.

## Done (GPU-specific, on top of the shared checklist)

- [ ] One scope resolved and reused verbatim for every view: hosts, GPUs, process, time range.
- [ ] Metrics pulled first — utilization plus device health for the GPUs in scope — and carried into the recap.
- [ ] Both GPU **and** CPU profiles pulled for the **same** filter.
- [ ] `gpu-topology.sh` run for the profile's hosts over the same window; the profile's GPUs matched to their rows by UUID.
- [ ] `model-shapes.sh` run for the same scope and window; hot layers (if any) ranked by total and their tensors read with `--module`.
- [ ] The correlated interpretation given — which view names the constraint, and how the others confirm or rule it out.
- [ ] Observed call tree rendered with `→` kernel annotations + `⚠️` sync markers, the CPU cross-check, and the hardware and model context.
- [ ] Multi-GPU job: `nccl_stragglers` + `nccl_slow_operations` run on the job's scope; top episodes checked with `nccl_causes`; the late rank compared with a healthy peer; "not measured" said where data was missing.

(Plus the common Done checklist in the shared doc — metrics first, template, every 🔴/🟡 has a `Fix:`, fix applied, follow-up question.)

## Common pitfalls

- **Only pulling the GPU view.** This is the failure mode the skill exists to prevent. Always pull the matching CPU view, then the topology and model views.
- **Different scopes across views.** Correlation only works when the slice matches: the topology for the hosts the profile ran on, the models for the same scope and window, metrics for the same GPUs. Re-use the resolved filter; don't paraphrase it.
- **Expecting the MCP to name the pattern for you.** It returns raw data — frames, kernels, percentages. Naming the pattern (kernel-launch-bound, memory-bandwidth bound, DataLoader-starved, NCCL-collective-bound, sync-bound, NUMA-misplaced, interconnect-bound) is *your* job.
- **Missing a host-side bottleneck.** A GPU at 60% means the host is starving it; the CPU cross-check is where you find out why.
- **Tuning code on a sick node.** If collectives or copies are slow without a code-level cause, rule out the hardware path (metrics and topology) before spending effort on kernels.
- **Ranking layers from the flamegraph or by self time.** The flamegraph drops most layer frames and their self time is 0; rank by total across every `top_functions` page.
- **Optimizing NCCL on the waiting ranks.** Collective time on healthy GPUs is mostly waiting for a straggler. Find the late rank first.
- **Calling the straggler the fastest GPU** because its collective time is lowest — that's what a late rank looks like.
- **"No cause" where the tool said "not measured"**, or "healthy" when `communicators_evaluated: 0`.
- **Answering a timing question from the flamegraph.** Gaps, cadence and ordering need the timeline — [`analyze-gpu-timeline`](../analyze-gpu-timeline/SKILL.md).
- **Quoting `--enforce-eager` timings.** Eager mode is for full-depth layer attribution only; its performance differs from the graph-mode workload.

## Security constraints

- Common rules (ground in returned data, never analyze local profile files, never query the DB directly) are in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md).
- **Never** declare the investigation done after only the GPU view. Pulling the CPU side with the same filter is the load-bearing step; topology, model shape and metrics complete it.
- The topology and model scripts only read (`host-metadata`, `analyze`, `models`). The internal endpoints are the UI's own API — call them through the scripts, never with hand-built requests that write anything.
- **Never** recommend enabling PC sampling on a workload (which requires `privileged: true`) without flagging the security implication. See [install-zymtrace-profiler § PC sampling](../install-zymtrace-profiler/reference.md#pc-sampling).

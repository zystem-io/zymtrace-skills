---
name: analyze-gpu-timeline
description: |
  Capture and analyze the zymtrace GPU execution timeline (NVIDIA): turn on high-resolution profiling for a short, scoped window (UI or agent-config API, no restart), then find repeated launch patterns, idle gaps, cadence, jitter and drift with the MCP timeline tools or the public pattern API, cross-check the flamegraphs, and apply the fix. Use for questions about the order or timing of GPU work; which kernel or code path is hottest → optimize-gpu-workloads.
  Trigger phrases: "enable high-resolution profiling", "capture a GPU timeline", "analyze the GPU timeline", "timeline pattern analysis", "gaps between kernels", "idle time between batches", "kernel launch cadence", "GPU jitter", "step time varies", "are copies overlapping compute", "where do the syncs happen".
---

# Analyze the GPU Timeline

The flamegraph aggregates: it tells you **which** kernels and code paths take GPU time. The timeline
keeps every event in order with nanosecond timestamps, so it answers what the flamegraph can't:
**gaps** between launches, **overlap** of copies and compute, **where syncs land**, and **how
durations change** across a run. It needs **high-resolution profiling**, which is off by default,
has real overhead, and is meant for short, scoped windows.

The common analysis discipline — 💚 plan, data-source policy, recommend-then-apply-the-fix, output
template, severity sizing, security — is in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md).
**Read it.** API payloads, the response schema and jq recipes (with a python3 fallback) are in
`${CLAUDE_PLUGIN_ROOT}/skills/analyze-gpu-timeline/reference.md`. The scripts use jq when it's
installed and python3 otherwise; with neither, they stop and say how to install jq.

| Question | Skill |
|---|---|
| Which kernel / code path dominates GPU time, why is the GPU underused | [`optimize-gpu-workloads`](../optimize-gpu-workloads/SKILL.md) |
| Gaps, ordering, overlap, sync placement, cadence, jitter, drift over a run | **this skill** |
| One GPU holding back a multi-GPU job | [`optimize-gpu-workloads` § Multi-GPU jobs](../optimize-gpu-workloads/SKILL.md#multi-gpu-jobs-stragglers-and-slow-collectives) |

Limits: NVIDIA CUDA only (the AMD timeline is on the roadmap). Only processes that run the zymtrace
GPU profiler (manual `CUDA_INJECTION64_PATH` or automatic injection) produce timeline data.

## Pre-flight

1. **Instance and data path** (shared conventions § Pre-flight). Two paths to the same data:
   - **MCP** (preferred for analysis): `timeline_density` + `timeline_patterns`, and the MCP's own
     procedure in the `timeline_analysis` prompt (resource `prompt://timeline`) — read it.
   - **Public REST API** (automation, CI, no MCP, and the only way to enable high-resolution
     profiling programmatically): `<gateway-url>/public/api/v1/...`. When auth is on, the user
     exports a service token as `ZYMTRACE_API_TOKEN` (an MCP token works for the pattern API);
     never ask for it in chat. The instance's spec is `<gateway-url>/api-docs/openapi.json`.
2. **Project and scope.** Resolve the project (`discover_projects` / `discover`, or
   `GET /public/api/v1/projects`) and the narrowest scope that holds the work: a pod, container,
   script or process (`k8s.pod.name == "trainer-0"`), a host only when needed.
3. **Is the GPU profiler loaded there?** A CUDA profile must exist for that scope (`hot_traces` /
   `discover` with event kind `cuda`). None → the workload isn't GPU-profiled; route to
   [`install-zymtrace-profiler`](../install-zymtrace-profiler/SKILL.md) (or
   [`troubleshoot-zymtrace-profiler`](../troubleshoot-zymtrace-profiler/SKILL.md) if it should be).

## Step 1 — Is there high-resolution data already?

- **MCP:** `timeline_density` on the scope and range. `first_ms: null` → none in the range (widen
  or move it). Otherwise its `buckets` (`[start_ms, high_res_event_count, gpu_seconds]`, width
  snapped to a round interval) show where the data is, and `event_cap` (1,000,000) is the most
  events one pattern window accepts. The cap counts the same events: sum the buckets of a
  candidate window to size it.
- **REST:** there is no public density endpoint. Run the pattern script on a short window where
  you expect data; `no high-resolution events in this window` means none.

Data present for the window the user cares about → skip to Step 3.

## Step 2 — Capture a window (enable high-resolution profiling)

High-resolution profiling records **every** kernel launch, copy and sync instead of sampling them,
and samples GPU memory many times per second. On a high-throughput workload it costs roughly
**400 millicores of extra CPU** for the profiled scope, on top of the profiler's baseline. So:

- **Scope it** to the pod / container / process under investigation. The UI asks for confirmation
  when a rule matches more than five hosts; treat that as the upper bound too.
- **Time-box it:** 1 second to 10 minutes, default 5 minutes. The rule turns itself off.
- **Make the workload busy** during the window — send inference traffic, run training steps.
  Kernels are recorded only while they run.
- **Always confirm with the user** before creating the rule: show the exact scope, duration, and
  overhead. It changes what every matching agent does, immediately, without a redeploy.

Pick the path the user can use:

| Path | How |
|---|---|
| **UI — CUDA timeline page** | On the CUDA timeline, enable high-resolution profiling for the current query: a 5-minute rule. |
| **UI — Agent Config** | **Settings → Agent Config → CUDA Profiler → Add Rule** → CEL expression → **High-resolution profiling** on → **Turn off automatically after** (≤ 10 min). Saved as its own short-lived rule. |
| **API** | `high-res-rule.sh` below. If it stops with **HTTP 403 (exit code 4)**, the token isn't allowed to change agent config — no service token is today — so tell the user and switch to a UI path. Don't hunt for another token. |

##### Claude runs (API path — dry run first, then `--apply` after the user confirms)
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/analyze-gpu-timeline/scripts/high-res-rule.sh <gateway-url> list
bash ${CLAUDE_PLUGIN_ROOT}/skills/analyze-gpu-timeline/scripts/high-res-rule.sh <gateway-url> \
  enable --expr 'k8s.pod.name == "trainer-0"' --duration 5m            # dry run: prints the rule
bash ${CLAUDE_PLUGIN_ROOT}/skills/analyze-gpu-timeline/scripts/high-res-rule.sh <gateway-url> \
  enable --expr 'k8s.pod.name == "trainer-0"' --duration 5m --apply    # after confirmation
```

The script reads the rule list and its version, replaces any earlier high-resolution rule for the
same scope with one entry holding only `HighResProfiling: true` and `expires_at` = now + duration,
and writes the list back with that version, retrying if someone saved in between (the API replaces
the whole list — never write a hand-built list). `hosts` lists GPU hosts that reported in the last
hour; `disable [--expr …] --apply` ends a capture early. Payloads: reference.md § Agent config API.

**Recurring captures** (e.g. 2 minutes of every 20, to catch behavior that comes and goes): the
same ≤ 10-minute limit applies to every window. Confirm the schedule and its duty cycle with the user.

```bash
# Foreground loop: on for --duration every --every; removes the rule after each window and on
# Ctrl-C / SIGTERM. Each rule also expires on its own (duration + up to 60 s, never past 10 min).
bash ${CLAUDE_PLUGIN_ROOT}/skills/analyze-gpu-timeline/scripts/high-res-rule.sh <gateway-url> \
  run --expr 'host.name == "gpu-1"' --duration 2m --every 20m --apply
# Or cron, one window per run (each call replaces the previous rule, so nothing piles up).
# The root-only env file must `export ZYMTRACE_API_TOKEN=...` (a plain assignment isn't seen by the script):
# */20 * * * * . /etc/zymtrace/highres.env && /path/to/high-res-rule.sh <gateway-url> enable --expr 'host.name == "gpu-1"' --duration 2m --apply
```

Rule changes and expiry reach the profilers within about a minute (ingest and each profiler
refresh every 30 s), so a window starts and ends up to ~1 minute late. Keep the off period above
60 s; `run` warns when it isn't.

When the window has run, go back to Step 1 to locate the new data.

## Step 3 — Detect patterns

Pattern detection finds the repeated back-to-back sequences on each lane (one per CUDA stream, plus
its `(sync)` lane): a training step, a batch, the layers inside it, the kernel groups inside those.
Patterns nest (`P<i>`), and a run of repeats is `<sym>*<n>`.

**Never analyze the whole range or a single window.** Pick **3–5 narrow windows** — start, middle,
end, the busiest bucket, any anomalous bucket, the period the user asked about — each holding
several repetitions of the work and well under the 1,000,000-event cap. Compare them: typical vs
outlier, and whether durations or periods drift. Put window edges on whole seconds (bucket
starts): events in the last partial second of a range are dropped, so round `last_ms` up.
`P<i>` and `L<i>` indices are per response, so match a pattern between windows by its template
resolved to leaf names, never by index.

**MCP path:** follow `prompt://timeline`. `timeline_patterns` with `occurrences=false` per window;
then, when you can write files and run jq (or python3 if jq isn't installed), `occurrences=true` on
a small section of a typical and each anomalous window, **redirected to a file — never into your
context** — and analyze it with jq or python3 only. The MCP response uses single-letter keys;
reference.md § jq recipes has the key map and a normalizer to reuse the recipes.

**REST path:**

##### Claude runs
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/analyze-gpu-timeline/scripts/timeline-patterns.sh \
  <gateway-url> <project-id> <start-ms> <end-ms> --query 'k8s.pod.name == "trainer-0"'
# per occurrence (large file, jq or python3 only); saved to ${TMPDIR:-/tmp}/zymtrace/patterns_<start>_<end>_occ.json:
#   ... --occurrences
```

It saves the response to a file and prints per lane the root patterns by total time: `count`,
`span%` of the window, median and max duration, spread (`dur_cv` = stddev/mean), median period,
`gap_med` (median period − median duration = time between repeats) and the template with leaf
names. A run root (`P23 x150`) that occurs once gets the stats of its repeats, so its period is
the cadence of `P23`. Output defaults to `${TMPDIR:-/tmp}/zymtrace/` (`--out` overrides). Exit
code 3 = above the event cap: narrow the window or the query and retry.

Stats arrays are `[count, min, max, total, mean, median, stddev, mean_abs_dev]` in nanoseconds.

## Step 4 — Read the patterns

Name the pattern from the numbers, then confirm it with a second view over the **same window and
scope**. Every period, gap or duration you state must come from a stats array or a jq/python3 query, with
the window it came from.

| What the numbers show | Likely cause | Confirm with | Typical fix |
|---|---|---|---|
| Median period ≫ median duration on the step/batch pattern, and no other span on the lane between repeats (spans recipe) | Host-side gap: input prep, tokenization, data loading, Python between launches | CPU profile (`on_cpu`, `off_cpu`) of the same window | Overlap input prep with GPU work (prefetch thread, DataLoader workers), more work per launch |
| Each H2D copy followed by a `stream-synchronize` on the sync lane | Pageable host memory: the CPU waits for each copy before issuing the next | Leaf names in the template; copy launch stack in the flamegraph | Pinned memory + `non_blocking=True`, one batched copy |
| High spread (`dur_cv`, max ≫ median) or duration drifting between windows | Variable input shapes (sequence length, padding — attention is quadratic in padded length), or clocks dropping | Per-item `elements` stats (which item varies); GPU clock/power metrics for the window | Batch by token length / bucket shapes; clocks dropped → hardware path in `optimize-gpu-workloads` |
| Stable duration, jittery period | The launching thread is delayed: GIL contention, GC pauses, CPU contention | `off_cpu` (scheduler latency), `on_cpu` GC frames | Less Python on the launch thread, `sys.setswitchinterval`, CPU/NUMA pinning |
| Long runs of short kernels (`L<i>*n`) with gaps comparable to their duration | Launch-bound eager dispatch | Run item's `elements` period vs duration | CUDA graphs, `torch.compile`, larger batch |

Three boundaries: an empty interval on one stream doesn't mean the GPU was idle — check the other
lanes; a pattern's duration runs from its first span's start to its last span's end, idle inside
included, so `span%` and gaps are not GPU-busy time (that's `gpu_seconds` in `timeline_density`);
and the timeline shows **that** a gap exists and what borders it, not what the CPU did inside it —
that's the CPU profile of the same window. To see which kernels dominate inside a pattern, pull
`hot_traces` (event kind `cuda`) on the same window.

## Step 5 — Report, fix, re-measure

Write the recap with the shared output template. The view-specific block is:

```markdown
**Observed timeline** (<scope>, high-resolution, windows <start–end UTC> ×<n>)

| Lane | Pattern | Count | Median duration | Median period | Gap between | Spread | Window |
|---|---|---|---|---|---|---|---|
| <process / GPU / stream> | <template with leaf names> | … | … ms | … ms | … ms | cv … | <window> |

**Cross-check** (<CPU / CUDA flamegraph, same window>): <1–2 sentences — what fills the gap>.
```

Then apply the top fix (shared conventions § Always recommend a fix — then apply it). To prove the
win, capture another short window after the change (Step 2) and compare the same pattern's
duration, period and idle gap, before vs after, in one table.

## Done

- [ ] Scope resolved and confirmed GPU-profiled; data located with `timeline_density` (MCP) or a probe window (REST).
- [ ] If no data: high-resolution rule proposed with scope, duration ≤ 10 min and overhead, created **only after the user confirmed**, and the workload kept busy during it.
- [ ] Patterns detected on 3–5 narrow windows, each under the event cap; typical vs anomalous compared.
- [ ] Occurrence data (if fetched) went to a file and was only queried with jq or python3.
- [ ] Each stated number cites its stats field or query and window; the cause is confirmed by a second view of the same window.
- [ ] Recap with the Observed timeline block, fix applied, follow-up question (re-capture to compare?).

## Common pitfalls

- **Treating the timeline like a flamegraph.** It answers order and timing questions. For "what's hottest", use `optimize-gpu-workloads`.
- **One big window.** Rejected above 1,000,000 events, and hides drift. Several narrow windows.
- **No data, so "nothing to see".** High-resolution profiling is off by default; `first_ms: null` means not captured, not idle.
- **A rule without an expiry, or on a whole fleet.** The API accepts both; the overhead stays on. Always ≤ 10 minutes, narrowest scope.
- **Capturing an idle workload.** No launches, no timeline. Drive traffic during the window.
- **Inferring a cadence or dependency from names.** Only from stats or query output.
- **Working around a 403 on agent config.** It means the token can't change agent config, and no service token can today. Use the UI; don't try other tokens or user credentials.
- **AMD / ROCm.** No timeline in the UI yet; use the flamegraph path in `optimize-gpu-workloads`.

## Security constraints

- **Never** create, extend or widen a high-resolution rule without the user's explicit confirmation of scope and duration. Never without an expiry; never longer than 10 minutes; never an empty expression unless the user asks for the whole project and accepts the overhead.
- **Never** hand-build the full rule list for `agent/config/set`; read it, change one entry, write it back with the version you read (the script does this).
- **Never** inline a token in chat, files or commands; read it from the environment (`ZYMTRACE_API_TOKEN`, `ZYMTRACE_MCP_TOKEN`) or a root-only env file.
- **Never** read an `occurrences=true` response into context; query it with jq or python3 only.
- Common rules (ground claims in returned data, no local profile files, no direct DB queries) are in [`shared/analysis-conventions.md`](../../shared/analysis-conventions.md).

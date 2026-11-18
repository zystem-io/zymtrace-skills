# analyze-gpu-timeline — Reference

API details and jq recipes the SKILL.md links to. Read on demand.

The public API is described by the instance's own spec: `<gateway-url>/api-docs/openapi.json`
(API version = the zymtrace release). Endpoints below are relative to
`<gateway-url>/public/api/v1`. When auth is on, every call takes `Authorization: Bearer <token>`;
the token comes from the environment, never inline. Which token depends on the call — see below.
Service tokens: <https://docs.zymtrace.com/authentication/service-tokens>.

---

## Agent config API (high-resolution rules)

High-resolution profiling is the agent-config setting `HighResProfiling`. The agent sends it to
every matching process that runs the zymtrace GPU profiler library — loaded through
`CUDA_INJECTION64_PATH` or injected automatically — so the workload needs no restart.

| Call | Permission | Notes |
|---|---|---|
| `GET /agent/config/get` | `admin:config:get` | Returns every rule and the config `version`. The spec lists a request body; the server ignores it. |
| `POST /agent/config/set` | `admin:config:set` (plus project update rights for a rule with `project`) | **Replaces the whole rule list.** Send every existing entry back plus your change, with the `version` you read. A stale version is rejected: read again and retry. |
| `POST /agent-inventory` | `admin:audit:read` | Hosts that reported in a time range, with `has_gpu` and profiler version. Use it to pick a host scope; skip it if the token lacks the permission. |

**HTTP 403 on these calls** (the script exits with code 4) means the token isn't allowed to change
agent config. Service tokens get fixed permissions by kind — CLI and Agent `project:read` +
`project:update`, MCP `project:read` — and none of them includes `admin:config:*` today. So with
auth on, high-resolution profiling can't be turned on through the API for now: use a UI path.
With auth off, the calls need no token.

The pattern API below needs only `project:read`, so any service token works for it, including
the MCP one.

Response of `GET /agent/config/get` (the request body of `set` has the same shape):

```json
{
  "config": {
    "version": 7,
    "config": {
      "entries": [
        {
          "expression": "k8s.namespace.name == \"ml\"",
          "expires_at": null,
          "settings": [{ "setting": { "InjectCudaProfiler": true } }]
        }
      ]
    }
  }
}
```

The entry the UI writes for high-resolution profiling, and the one
`${CLAUDE_PLUGIN_ROOT}/skills/analyze-gpu-timeline/scripts/high-res-rule.sh` appends:

```json
{
  "expression": "k8s.pod.name == \"trainer-0\"",
  "project": "00000000-0000-0000-0000-000000000000",
  "expires_at": "2026-11-17T09:05:00Z",
  "settings": [{ "setting": { "HighResProfiling": true } }]
}
```

Rules:

- **Its own rule.** The UI always saves high-resolution profiling as a separate entry with only
  this setting, so its short expiry never cuts other settings short. Do the same.
- **Expiry is mandatory in practice.** `expires_at` is an RFC 3339 timestamp. The UI only allows
  1 second to 10 minutes (default 5 minutes from the CUDA timeline page); the API itself doesn't
  enforce it, so the skill must. A high-resolution entry with `expires_at: null` stays on forever.
- **Order.** Rules are evaluated in order and the last matching rule for a setting wins, so append.
- **One rule per scope.** Replace an earlier high-resolution rule for the same expression and
  project instead of appending another; expired entries stay in the list until someone removes
  them, so a recurring capture that only appends grows it without bound.
- **Propagation.** Ingest re-reads the rules every 30 s (`refresh-agent-config-interval-ms`) and
  each profiler polls ingest every 30 s (`-refresh-config-interval`). Ingest drops expired entries
  when it re-reads; profilers never see `expires_at`. A change or an expiry takes effect within
  about 60 s.
- **Scope.** `expression` is a CEL expression over agent and process fields: `host.name`,
  `host.arch`, `cluster.name`, `user.tag`, `container.name`, `k8s.namespace.name`,
  `k8s.deployment.name`, `k8s.pod.name`, `process.executable.name`, `script.name`,
  `slurm.job.id`, `slurm.job.name`, `slurm.job.user`. `HighResProfiling` accepts process-level
  fields, which is what you want: one pod, container or script, not a whole host. An empty
  expression matches every agent. `project` (optional) limits the rule to one project.
- **Validation errors** come back as HTTP 400 with a structured reason, e.g. `CelError` (with the
  entry index) for an expression that doesn't parse.

Agent inventory request (hosts seen in the last hour):

```json
{ "start_ts": 1794874800000, "end_ts": 1794878400000,
  "pagination": { "sort": [], "page": { "page": 1, "page_size": 500 } } }
```

Response: `{"hosts": [{"host_name", "cluster_name", "service_version", "has_gpu"}], "pagination": {...}}`.

---

## Timeline pattern API

`POST /projects/{project_id}/timeline/pattern[?occurrences=true]` — needs read access to the
project. Detects repeated back-to-back span sequences per lane (one lane per CUDA stream, plus
its sync lane) in the high-resolution CUDA events of one window. The MCP tool
`timeline_patterns` runs the same detection.

Request:

```json
{
  "filter": {
    "start_ts": 1794878000000,
    "end_ts": 1794878030000,
    "query": "k8s.pod.name == \"trainer-0\""
  }
}
```

- `start_ts` inclusive, `end_ts` exclusive, epoch milliseconds. Events in the last partial second
  are dropped (an end of `…334259` or `…334999` missed events at `…334257`; `…335000` caught
  them), here and in `timeline_density`: end windows on a whole second.
- `query` is a CEL filter with the query-bar fields (`host.name`, `k8s.pod.name`,
  `container.name`, `process.executable.name`, `script.name`, `gpu.uuid`, `gpu.name`,
  `slurm.job.id`, …). Omit it for the whole project. `process.executable.name` is the full path
  `discover` shows (`/usr/bin/python3.12`), not the lane's short name (`python3.12`).
- The event kind is always CUDA and only high-resolution events count; `event_kind` and
  `frame_mask` in the filter are ignored. `display_options` is optional (server defaults).
- **Event cap: 1,000,000 events per window.** Above it the call fails with HTTP 400 and
  `The selected range contains <N> events, above the 1000000 maximum. Narrow the time range or add filters.`
  Use `<N>` to size the next window (`window × 1,000,000 / N`, then a margin).
- An empty result is `{"base_epoch_ms": 0, "leaves": [], "lanes": []}`: no high-resolution data
  for that scope and window. A query that matches nothing and a project ID that doesn't exist
  return the same, not an error.
- There is **no public density endpoint**. Over REST, locate data by probing short windows;
  over MCP, `timeline_density` returns buckets of event counts plus the cap.
- Indices are per response: `L<i>` (even for the same window, leaf order can change between
  calls) and `P<i>`. Compare patterns across windows or calls by template resolved to leaf names.

Response (`occurrences` only with `?occurrences=true`):

| REST key | MCP key | Meaning |
|---|---|---|
| `base_epoch_ms` | `b` | Epoch ms of relative ns 0 for every extent |
| `leaves` | `l` | Leaf names (kernels, copies, syncs); `L<i>` in a template = `leaves[i]` |
| `lanes` | `n` | Lanes with at least one span, in timeline order |
| lane `path` | `k` | Lane identity (root group → lane) |
| lane `names` | `m` | Display names parallel to `path` (process, GPU, stream) |
| lane `patterns` | `p` | Patterns of the lane |
| lane `roots` | `r` | Indices into `patterns` not nested in another pattern |
| pattern `template` | `t` | Sequence: `L<i>` leaf, `P<i>` nested pattern of the same lane, `<sym>*<n>` = n back-to-back repeats |
| pattern `duration` | `d` | Stats over every occurrence's duration |
| pattern `period` | `i` | Stats over start-to-start gaps between occurrences; `null` with fewer than two |
| pattern `elements` | `e` | Per-template-item stats (`duration`, and `period` for a run item), in template order |
| pattern `occurrences` | `o` | Each occurrence, sorted by start |
| occurrence `extents` | `x` | `[start_ns, end_ns)` per template item relative to `base_epoch_ms`; a run item `*n` contributes n extents |
| occurrence `spans` | `s` | Inclusive lane span index range `[first, last]` |

Every stats value is a positional array of nanoseconds:
`[count, min, max, total, mean, median, stddev, mean_abs_dev]` (index 0–7).

Derived numbers worth reporting, per pattern:

- **Gap between repetitions** ≈ `period[5] - duration[5]` (median period minus median duration).
  The stream is idle in it only when no other span on the lane falls between consecutive
  occurrences: check with the spans recipe below. Nested patterns often have siblings in the gap.
- **Spread** = `duration[6] / duration[4]` (stddev / mean), and `duration[2]` vs `duration[5]`
  (max vs median) for outliers.
- **Share of the window spanned** = `duration[3]` / window length in ns (root patterns only;
  nested patterns are inside their parents). An occurrence runs from its first span's start to
  its last span's end, idle inside included, so this is not GPU-busy time; that's `gpu_seconds`
  in `timeline_density`.
- **Run roots** (template `X*n`) that occur once (`duration[0] == 1`): the per-repeat timing of
  `X` is in `elements[0]` (`duration` over the n repeats, `period` between them). A run root
  that occurs more than once is reported like any other root.

---

## jq recipes

All recipes use the REST keys. To reuse them on a saved MCP `timeline_patterns` result, normalize
it first (if your client saved the MCP envelope, extract the JSON text from it before this):

```bash
jq 'def lane: {path: .k, names: .m, roots: .r, patterns: [.p[] | {template: .t, duration: .d,
      period: .i, elements: [.e[]? | {duration: .d, period: .i}],
      occurrences: [.o[]? | {extents: .x, spans: .s}]}]};
    {base_epoch_ms: .b, leaves: .l, lanes: [.n[] | lane]}' mcp_patterns.json > patterns_occ.json
```

Never `cat` or read an `occurrences=true` file into context; run only queries that return a
few numbers. `$l` is the lane index, `$p` the pattern index within it. File names below are
placeholders: `timeline-patterns.sh` saves to `${TMPDIR:-/tmp}/zymtrace/` by default, so keep
saved responses there rather than in the user's working directory.

```bash
# Lanes: index, display path, number of patterns
jq -r '.lanes | to_entries[] | "\(.key)\t\(.value.names | join(" / "))\t\(.value.patterns | length) patterns"' patterns.json

# Per-item stats of one pattern: template item, instances, median and max duration (ms)
jq -r --argjson l 0 --argjson p 0 '.lanes[$l].patterns[$p] as $pt
  | range(0; $pt.template | length) as $j
  | [$pt.template[$j], $pt.elements[$j].duration[0],
     ($pt.elements[$j].duration[5] / 1e6), ($pt.elements[$j].duration[2] / 1e6)] | @tsv' patterns.json

# Occurrences (occurrences=true): duration and gap (next start - this end) min/median/max, ms
jq --argjson l 0 --argjson p 0 '
  def q: sort | {min: .[0], median: .[length / 2 | floor], max: .[-1]} | map_values(. / 1e6);
  .lanes[$l].patterns[$p].occurrences
  | map({s: .extents[0][0], e: ([.extents[][1]] | max)})
  | {count: length,
     duration_ms: (map(.e - .s) | q),
     gap_ms: (if length < 2 then null else [range(1; length) as $i | .[$i].s - .[$i - 1].e] | q end)}' patterns_occ.json

# Is the gap idle? Spans of the lane between consecutive occurrences: 0 = the stream was idle in it
jq -c --argjson l 0 --argjson p 0 '
  .lanes[$l].patterns[$p].occurrences
  | [range(1; length) as $i | .[$i].spans[0] - .[$i - 1].spans[1] - 1]
  | {gaps: length, idle_gaps: (map(select(. == 0)) | length), spans_between_median: (sort | .[length / 2 | floor])}' patterns_occ.json

# Five slowest occurrences with their epoch-ms start (to zoom the next window on them)
jq -c --argjson l 0 --argjson p 0 '
  .base_epoch_ms as $b | .lanes[$l].patterns[$p].occurrences
  | map({start_ms: ($b + .extents[0][0] / 1e6 | floor),
         dur_ms: ((([.extents[][1]] | max) - .extents[0][0]) / 1e6)})
  | sort_by(-.dur_ms) | .[0:5][]' patterns_occ.json

# Drift inside one window: median duration of the first third vs the last third
jq --argjson l 0 --argjson p 0 '
  def med: sort | .[length / 2 | floor];
  [.lanes[$l].patterns[$p].occurrences[] | ([.extents[][1]] | max) - .extents[0][0]] as $d
  | ($d | length / 3 | floor) as $k
  | if $k < 1 then "need at least 3 occurrences" else
      {first_third_ms: ($d[:$k] | med / 1e6), last_third_ms: ($d[-$k:] | med / 1e6)} end' patterns_occ.json
```

For drift across a whole run, compare the same pattern's `duration[5]` and `period[5]` between
windows taken at the start, middle and end (statistics only, no occurrences needed), matching it
by template resolved to leaf names: indices differ between responses.

**No jq?** Use `which jq` first; if it's missing, python3 does the same. Every recipe above in one
script: the normalizer, lanes, per-item stats of pattern `$p` in lane `$l`, and, on an
`occurrences=true` file, the occurrence summary (duration, gap, idle gaps, slowest occurrences, drift):

```bash
python3 - patterns_occ.json 0 0 <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1])); l, p = int(sys.argv[2]), int(sys.argv[3])
if "n" in doc:  # MCP short keys -> REST keys
    doc = {"base_epoch_ms": doc["b"], "leaves": doc["l"], "lanes": [
        {"path": n["k"], "names": n["m"], "roots": n["r"], "patterns": [
            {"template": q["t"], "duration": q["d"], "period": q["i"],
             "elements": [{"duration": e["d"], "period": e.get("i")} for e in q.get("e") or []],
             "occurrences": [{"extents": o["x"], "spans": o["s"]} for o in q.get("o") or []]}
            for q in n["p"]]} for n in doc["n"]]}
for i, lane in enumerate(doc["lanes"]):  # lanes: index, display path, number of patterns
    print(f"{i}\t{' / '.join(lane['names'])}\t{len(lane['patterns'])} patterns")
pt = doc["lanes"][l]["patterns"][p]
for t, el in zip(pt["template"], pt["elements"]):  # item, instances, median and max duration (ms)
    print(f"{t}\t{el['duration'][0]}\t{el['duration'][5] / 1e6}\t{el['duration'][2] / 1e6}")
occ = pt.get("occurrences") or []
if not occ:
    sys.exit()  # statistics only: no occurrence summary
se = [(o["extents"][0][0], max(x[1] for x in o["extents"])) for o in occ]
q = lambda v: v and {"min": min(v) / 1e6, "median": sorted(v)[len(v) // 2] / 1e6, "max": max(v) / 1e6}
dur = [e - s for s, e in se]
print({"count": len(se), "duration_ms": q(dur),
       "gap_ms": q([se[i][0] - se[i - 1][1] for i in range(1, len(se))]) or None})
sb = [occ[i]["spans"][0] - occ[i - 1]["spans"][1] - 1 for i in range(1, len(occ))]
print("spans_between:", {"gaps": len(sb), "idle_gaps": sb.count(0), "median": sorted(sb)[len(sb) // 2] if sb else None})
print("slowest:", sorted(({"start_ms": doc["base_epoch_ms"] + s // 10**6, "dur_ms": (e - s) / 1e6}
                          for s, e in se), key=lambda r: -r["dur_ms"])[:5])
k = len(dur) // 3
if k:
    print("drift:", {"first_third_ms": sorted(dur[:k])[k // 2] / 1e6, "last_third_ms": sorted(dur[-k:])[k // 2] / 1e6})
EOF
```

---

## Sources

- GPU Timeline docs (enabling high-resolution profiling, reading the timeline): <https://docs.zymtrace.com/gpu/nvidia/timeline>
- Blog, with a worked example (568 s → 82 s): <https://zymtrace.com/article/gpu-timeline/>
- Service tokens: <https://docs.zymtrace.com/authentication/service-tokens>
- Profiler resource guide (overhead baseline): <https://docs.zymtrace.com/install/profiler/profiler-resource-guide>

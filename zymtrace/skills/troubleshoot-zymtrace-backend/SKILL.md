---
name: troubleshoot-zymtrace-backend
description: |
  Use when a deployed zymtrace backend isn't working as expected — no data appearing in the UI, profiles not arriving, ingest errors, ClickHouse storage full, license / auth failures, slow queries. Walks symptom → diagnosis → fix. Routes between backend (ingest, ClickHouse) and profiler (DaemonSet, CUDA injection) checks.
  Trigger phrases: "zymtrace not working", "no data in zymtrace UI", "zymtrace UI is empty", "no profiles appearing", "profiles not showing up", "ingest is failing", "clickhouse disk full", "license error in zymtrace", "license expired", "zymtrace queries are slow", "zymtrace broken after upgrade", "fix zymtrace", "diagnose zymtrace".
metadata:
  version: "26.5.0"
  author: zymtrace
  repository: https://github.com/zystem-io/zymtrace-skills
  tags: zymtrace,profiling,kubernetes,helm,troubleshoot,diagnose,backend,profiler
  tools: helm,kubectl,curl
---

# Troubleshoot zymtrace Backend

Helps the user diagnose problems on a deployed zymtrace install — the most common one is "no data is showing up in the UI."

This skill spans both backend (ingest, ClickHouse, MinIO) and profiler-side (agent reporting, CUDA injection) checks because "no data" usually requires walking both. Pure profiler-agent issues (CrashLoopBackOff, ImagePullBackOff, OOMKilled, NVML, license rejected on agent side) are handled by [`troubleshoot-zymtrace-profiler`](../troubleshoot-zymtrace-profiler/SKILL.md) — route there if the user's symptom is agent-specific.

## Greet the user

Open warmly. People reaching for a troubleshoot skill are usually frustrated.

> 👋 Sorry zymtrace isn't behaving — let's find it. Tell me what you're seeing (e.g. "the UI loads but no profiles", "ingest pods crash-looping", "got a license error") and I'll walk the diagnosis with you.
>
> **Stuck or need a human?**
> - Community Slack: <https://join.slack.com/t/zymtrace/shared_invite/zt-3fdidjufl-q~NHxDzQlzal2B9mujfaoQ>
> - Email: <support@zymtrace.com>
>
> **Once data is flowing again**, connect the zymtrace MCP to your agent (Claude Code, Codex, or Cursor) — see [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md) — and analyze GPU + CPU flamegraphs in natural language. Docs: <https://docs.zymtrace.com/mcp>

If the user already named a specific symptom, skip the prompt and jump to the matching section below.

## Pre-flight

##### Claude runs
```bash
helm version --short && kubectl version --client
kubectl cluster-info | head -2
helm list -A | grep -i zymtrace
```

Resolve **two** sets of (namespace, release) — backend AND profiler — since "no data" can be either side:

| Variable | Resolve by |
|---|---|
| Backend release + namespace | `helm list -A \| grep -iE 'backend.*zymtrace\|zymtrace.*backend'` |
| Profiler release + namespace | `helm list -A \| grep -iE 'profiler.*zymtrace\|zymtrace.*profiler'` |
| `global.namePrefix` (drives resource names) | `helm get values <REL> -n <NS> \| awk '/^\s*namePrefix:/ {print $2}'` (defaults to `zymtrace`) |

> If the profiler release isn't installed at all, that explains "no data". Route to `install-zymtrace-profiler`.

## Symptom router

Ask which symptom matches. Don't guess — the diagnostics differ.

| Symptom | Section |
|---------|---------|
| **No data in the UI** | [§ No data coming through](#no-data-coming-through) — most common, full walkthrough below |
| **License invalid / expired** in ingest logs | [§ License errors](#license-errors) |
| **Ingest pods CrashLoopBackOff** | [§ Ingest crash loop](#ingest-crash-loop) |
| **Query is slow** | [§ Slow queries](#slow-queries) |
| **Disk filling rapidly** | [§ Storage growth](#storage-growth) |

If the user's symptom isn't listed → ask them to describe what they see (UI behavior, recent logs), and pick the closest section above.

---

## No data coming through

The end-to-end profile path is: **workload → profiler agent → backend gateway (gRPC) → ingest → ClickHouse → UI**. Any link broken = no data. Walk all four steps; don't stop at step 1.

##### Claude runs
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/troubleshoot-zymtrace-backend/scripts/diagnose-no-data.sh <backend-NS> <backend-REL> <profiler-NS> <profiler-REL>
```

The script automates all four checks below. The manual walkthrough:

### Step 1 — Profiler agent reporting data?

```bash
# DaemonSet healthy?
kubectl get ds -n <profiler-NS> <PREFIX>-profiler

# Pick a pod, tail the logs
POD=$(kubectl get pods -n <profiler-NS> -l app.kubernetes.io/component=profiler -o name | head -1)
kubectl logs -n <profiler-NS> "$POD" --tail=100
```

Look for:
- `Your license is valid until ...` — agent reached the backend, license accepted.
- `streaming connection established` — agent is sending profiles.
- `buffers_processed` or `bytes_sent` counters incrementing — actual data leaving the agent.

If you see `connection refused`, `dns lookup failed`, or `no such host` → the `--collection-agent` target is wrong. Fix the values file (`profiler.args[0]`) and re-apply with `helm upgrade --install ... --reset-then-reuse-values --atomic`.

If you see no positive signals but no errors → the agent might be running on nodes that have **no workloads to profile**. Confirm there are processes on the node (`kubectl get pods --all-namespaces -o wide | grep $(node-name)`).

### Step 2 — (GPU only) CUDA injection working?

This is the silent failure mode for GPU profiling: the agent is happily running, but no workload has actually loaded the CUDA profiler library, so no GPU profiles flow. The agent logs the **interception event** when a workload picks up the library:

```bash
kubectl logs -n <profiler-NS> "$POD" --tail=500 | grep -i 'intercepted.*implant'
```

Expected line (one per profiled GPU process):
```
level=info msg="Intercepted zymtrace implant at /proc/576236/root//var/lib/zymtrace/profiler/libzymtracecudaprofiler.so"
```

If this line is **absent**, no workload is being GPU-profiled. Common causes:
- Workload pods don't have `CUDA_INJECTION64_PATH` env var set.
- Workload pods don't have the `/var/lib/zymtrace/profiler` host path mounted in.
- Workload runs on a node where the profiler DaemonSet didn't extract the library (check `ls /var/lib/zymtrace/profiler` on the node — should contain `libzymtracecudaprofiler.so`).
- The workload was started **before** the profiler DaemonSet — restart the workload after the agent is up.

CPU profiling does not need this check — there is no injection, the eBPF profiler attaches to processes directly.

### Step 3 — Backend ingest service healthy?

```bash
# Pods OK?
kubectl get pods -n <backend-NS> -l app.kubernetes.io/component=ingest

# Recent logs
kubectl logs -n <backend-NS> deployment/<PREFIX>-ingest --tail=100 --all-containers=true
```

Look for:
- `Your license is valid until ...` — backend accepted the license.
- Periodic `received profile` / `processed batch` lines (or quiet logs with no errors).

Red flags:
- `clickhouse: connection refused` / `clickhouse: dial tcp` → ClickHouse pod down or unreachable (Step 4 will tell you which).
- `forbidden`, `unauthorized` → license or service-token issue (jump to [§ License errors](#license-errors)).
- `disk full` / `out of space` → jump to Step 4.

### Step 4 — ClickHouse storage / health?

```bash
# Pod running?
kubectl get pods -n <backend-NS> -l app.kubernetes.io/component=clickhouse

# PVC fill level
kubectl get pvc -n <backend-NS> | grep -i clickhouse
kubectl exec -n <backend-NS> <PREFIX>-clickhouse-0 -- df -h /var/lib/clickhouse

# Recent CH logs
kubectl logs -n <backend-NS> <PREFIX>-clickhouse-0 --tail=50
```

If `df -h` shows the data volume **>85%** → ClickHouse stops accepting writes. Free space by lowering `global.dataRetentionDays` and waiting for the next compaction, or expand the PVC. The latter only works on storage classes with `allowVolumeExpansion: true`:

```bash
kubectl get sc <storage-class> -o yaml | grep allowVolumeExpansion
# If true:
kubectl edit pvc data-<PREFIX>-clickhouse-0 -n <backend-NS>
# bump spec.resources.requests.storage
```

If ClickHouse is healthy but ingest still can't reach it → check the `use_existing` config in the values file (host/port/credentials). For `mode: create`, the chart wires this automatically.

### Done

Data should appear in the UI within ~30 seconds of fixing the broken link. Refresh the browser. If you went through all four steps and still see no data, capture the four `kubectl logs` outputs (steps 1–4) and email <support@zymtrace.com> with the chart version (`helm list -A | grep zymtrace`).

---

## License errors

Symptoms in ingest or profiler logs: `license expired`, `license invalid`, `forbidden`, `unauthorized`.

##### Claude runs
```bash
# Backend ingest
kubectl logs -n <backend-NS> deployment/<PREFIX>-ingest --tail=50 | grep -iE 'license|forbidden|unauthorized'

# Profiler
POD=$(kubectl get pods -n <profiler-NS> -l app.kubernetes.io/component=profiler -o name | head -1)
kubectl logs -n <profiler-NS> "$POD" --tail=50 | grep -iE 'license|forbidden|unauthorized'
```

Fix paths:
- **Expired** → renew via <support@zymtrace.com> or <https://zymtrace.com/getstarted/>. Update the values file's `global.licenseKey` (or the referenced secret), `helm upgrade --install ... --reset-then-reuse-values --atomic`.
- **Inline license vs secret-ref mismatch** → `global.licenseKey` AND `global.licenseKeySecretName` both set means the secret wins. Decide which path you want.
- **Service-token auth mismatch** (`auth.serviceToken.enabled: true` on backend, profiler missing `--auth-token`) → set `profiler.args` to include `--auth-token "$ZYMTRACE_AUTH_TOKEN"` or disable service-token auth in dev.

---

## Ingest crash loop

##### Claude runs
```bash
kubectl describe pod -n <backend-NS> -l app.kubernetes.io/component=ingest | tail -50
kubectl logs -n <backend-NS> deployment/<PREFIX>-ingest --previous --tail=100
```

Most common causes:
- **Missing secret** referenced in values (license, OIDC client secret, signing keys). `kubectl get secret -n <backend-NS>` to verify.
- **ClickHouse not reachable** at startup → ingest retries forever. Check ClickHouse pod state first.
- **OOMKilled** in describe output → bump `services.ingest.resources.limits.memory`.
- **`use_existing` ClickHouse host on native port 9000** → must be HTTP `8123`/`8443`. See install skill's pitfalls.

---

## Slow queries

##### Claude runs
```bash
kubectl top pods -n <backend-NS> 2>/dev/null | grep -iE 'web|clickhouse'
kubectl logs -n <backend-NS> <PREFIX>-clickhouse-0 --tail=100 | grep -iE 'query|exception'
```

Common causes:
- ClickHouse undersized for retention — bump `clickhouse.create.resources` or shorten `global.dataRetentionDays`.
- High agent count without HPA on `web` — enable `services.common.hpa` in the values file.
- Query touching a long retention window — UI filters help.

---

## Storage growth

If ClickHouse / MinIO PVCs are filling faster than expected:

```bash
kubectl exec -n <backend-NS> <PREFIX>-clickhouse-0 -- du -sh /var/lib/clickhouse/*
kubectl exec -n <backend-NS> <PREFIX>-minio-0 -- du -sh /data
```

Knobs:
- `global.dataRetentionDays` — lower it (default 30, can go down to 7 in dev). Existing data ages out at the next compaction.
- Profiler `-samples-per-second` (default 19) — lower it on agents to reduce ingestion volume.
- Stop the profiler on noisy / low-value nodes (`profiler.nodeSelector` to scope which nodes report).

---

## Done

Exit when the user confirms data is flowing again or escalates to support. Always recap which step fixed it, so future-them can pattern-match.

## Security constraints

- **Never** modify Kubernetes secrets via `kubectl edit` mid-diagnosis without confirming with the user — leaks the value into shell history.
- **Never** run `kubectl delete pvc`, `kubectl delete namespace`, or `helm uninstall` without explicit user confirmation. Backups don't come from this skill.
- **Never** apply config changes (helm upgrade) without `--reset-then-reuse-values` — see [`shared/conventions.md`](../../shared/conventions.md).
- **Never** suggest disabling TLS, auth, or NetworkPolicies as a "fix" without flagging the trade-off explicitly.
- **Never** declare "fixed" without re-running the relevant verify step (Done above).

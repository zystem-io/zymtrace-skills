---
name: troubleshoot-zymtrace-profiler
description: |
  Use when the zymtrace profiler agent is misbehaving — pods crash-looping, image pull errors, OOMKilled, CPU profiles working but no GPU profiles, NVML library not found, PC sampling not producing SASS-level data, or license errors on the profiler side. Walks symptom → diagnosis → fix. Focused on the agent itself; for "no data anywhere" use troubleshoot-zymtrace-backend.
  Trigger phrases: "profiler not working", "profiler pods crashing", "profiler CrashLoopBackOff", "profiler ImagePullBackOff", "agent OOMKilled", "no GPU profiles", "CPU profiles work but GPU doesn't", "NVML library not found", "PC sampling not working", "profiler license rejected", "agent restart cycle", "zymtrace agent unhealthy", "fix the profiler".
---

# Troubleshoot zymtrace Profiler

Helps the user diagnose problems with the **profiler agent** — the DaemonSet (or Docker / binary) that ships profiles to the backend. Backend / ClickHouse / ingest problems live in [`troubleshoot-zymtrace-backend`](../troubleshoot-zymtrace-backend/SKILL.md). If the customer's symptom is "the UI is empty" without a clearer signal, route there instead — it covers the cross-cutting "no data" diagnostic across both sides.

## Greet the user

Open warmly. Diagnostic conversations start frustrated.

> 👋 Sorry the profiler isn't behaving — let's track it down. Tell me what you're seeing (e.g. "agent pods CrashLoopBackOff", "CPU profiles arrive but no GPU traces", "OOMKilled every 5 min", "license rejected") and I'll walk the diagnosis with you.
>
> **Need a human?**
> - Community Slack: <https://join.slack.com/t/zymtrace/shared_invite/zt-3fdidjufl-q~NHxDzQlzal2B9mujfaoQ>
> - Email: <support@zymtrace.com>
>
> **Once the agent is healthy again**, connect the zymtrace MCP to your agent (Claude Code, Codex, or Cursor) — see [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md) — to analyze GPU + CPU flamegraphs in natural language. Docs: <https://docs.zymtrace.com/mcp>

If the user already named a symptom, skip the prompt and jump to the matching section below.

## Pre-flight

##### Claude runs
```bash
helm version --short && kubectl version --client
kubectl cluster-info | head -2
helm list -A | grep -iE 'profiler.*zymtrace|zymtrace.*profiler'
```

If the profiler release isn't installed at all, that's not a "troubleshoot" — route to `install-zymtrace-profiler`.

## Pre-resolve what you can

> Recommend defaults `zymtrace` / `profiler`. Resolve the customer's actual values first. Full policy: [`shared/conventions.md`](../../shared/conventions.md). Commands below use `<NS>` / `<REL>` / `<PREFIX>` placeholders.

| Variable | Resolve by |
|---|---|
| Profiler release + namespace | `helm list -A \| grep -iE 'profiler.*zymtrace\|zymtrace.*profiler'` |
| `global.namePrefix` (drives DaemonSet name) | `helm get values <REL> -n <NS> \| awk '/^\s*namePrefix:/ {print $2}'` (defaults to `zymtrace`) |
| Backend release (for cross-cluster context) | `helm list -A \| grep -iE 'backend.*zymtrace'` |
| GPU profiling enabled? | `helm get values <REL> -n <NS> \| grep -A1 cudaProfiler \| grep enabled` |
| Current values (so any fix re-applies cleanly) | `helm get values <REL> -n <NS>` |

Things you may need to ask:
- The exact symptom (CrashLoopBackOff vs OOMKilled vs no-GPU-profiles are different paths).
- Recent changes: helm upgrade, node OS update, NVIDIA driver upgrade.

## Symptom router

| Symptom | Section |
|---------|---------|
| Agent pods **CrashLoopBackOff / not Ready** | [§ CrashLoopBackOff](#crashloopbackoff) |
| Agent pods **ImagePullBackOff** | [§ ImagePullBackOff](#imagepullbackoff) |
| Agent **OOMKilled** / pod restart cycle | [§ OOMKilled / restart cycle](#oomkilled--restart-cycle) |
| **CPU profiles flow, but no GPU profiles** | [§ No GPU profiles](#no-gpu-profiles) |
| **NVML library not found** in agent logs | [§ NVML library not found](#nvml-library-not-found) |
| **PC sampling enabled but no SASS-level data** | [§ PC sampling produces nothing](#pc-sampling-produces-nothing) |
| **License rejected** on the profiler side | [§ License rejected](#license-rejected) |
| **UI is empty entirely** (could be agent OR backend) | → [`troubleshoot-zymtrace-backend`](../troubleshoot-zymtrace-backend/SKILL.md) |

If the symptom isn't listed, ask the user to describe what they're seeing and pick the closest section.

A one-shot script that gathers the most common signals:

##### Claude runs
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/troubleshoot-zymtrace-profiler/scripts/diagnose-agent-not-reporting.sh <NS> <REL>
```

It dumps DaemonSet readiness, pod status, recent logs, license/connection signals, and a `describe` for any non-Running pod. Use it as the opening move for most scenarios below.

---

## CrashLoopBackOff

Most agent CrashLoopBackOff failures are one of four causes. Walk them in order.

##### Claude runs
```bash
kubectl describe pod -n <NS> -l app.kubernetes.io/component=profiler | tail -60
kubectl logs -n <NS> -l app.kubernetes.io/component=profiler --tail=100 --previous 2>/dev/null
```

### Cause A — Kernel too old for eBPF

The eBPF unwinder needs a recent enough kernel (~5.4+ is safe; 4.18 is the minimum for some features). On the failed pod's node:

```bash
NODE=$(kubectl get pod -n <NS> -l app.kubernetes.io/component=profiler -o jsonpath='{.items[0].spec.nodeName}')
kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}'
```

If the kernel is older than 5.4, recommend a node OS upgrade. There's no in-skill workaround.

### Cause B — `CAP_SYS_ADMIN` stripped

Pod Security Admission, OPA Gatekeeper, Kyverno, or PSP-style admission controllers can strip required capabilities. Look in `describe` output for:
- `pod has invalid spec: capabilities not allowed`
- Admission webhook denials mentioning `SYS_ADMIN`
- `seccomp` denials

Fix: get the cluster admin to add an exception for the profiler namespace, or run the agent in a less-restricted namespace.

### Cause C — `/sys/kernel/debug` not mounted on the host

Some hardened distros (Talos, Bottlerocket, some GKE Sandbox configurations) don't expose `/sys/kernel/debug` to privileged pods. Logs will mention `failed to open /sys/kernel/debug/tracing` or similar.

Fix: either remount debugfs on the host (`sudo mount -t debugfs none /sys/kernel/debug` — node-side, not in skill), or accept that CPU profiling won't work on those nodes and `nodeSelector`-exclude them.

### Cause D — SELinux / AppArmor denying BPF

RHEL/CentOS with SELinux in enforcing mode can block BPF syscalls. Logs may show `Operation not permitted` on syscalls.

Fix: ask the cluster admin to add a SELinux policy exception, or relabel the profiler with `system_u:object_r:container_runtime_exec_t:s0`. This is org-specific — surface and stop.

---

## ImagePullBackOff

##### Claude runs
```bash
kubectl describe pod -n <NS> -l app.kubernetes.io/component=profiler 2>/dev/null \
  | grep -A2 -iE 'failed.*pull|imagepullbackoff|errimagepull|unauthorized'
```

Three usual causes:

| Sign in events | Cause | Fix |
|---|-------|------|
| `unauthorized: authentication required` | Pull secret missing or wrong | `kubectl get secret -n <NS>` to find pull secret; set `global.registry.username` + `password` via `--set` on `helm upgrade --install --reset-then-reuse-values --atomic` |
| `not found` / `manifest unknown` | Tag doesn't exist | Verify at <https://hub.docker.com/u/zystemio> or <https://github.com/orgs/zystem-io/packages>; fix `profiler.image.tag` or `services.common.imageTag` |
| `connection refused` / DNS failure / private registry hostname | Air-gapped, image not mirrored | Mirror `ghcr.io/zystem-io/zymtrace-pub-profiler:<VERSION>` into the customer's registry; set `global.imageRegistry`. See [install-zymtrace-profiler reference.md § Air-gapped install](../install-zymtrace-profiler/reference.md#air-gapped-install). |

---

## OOMKilled / restart cycle

##### Claude runs
```bash
kubectl describe pod -n <NS> -l app.kubernetes.io/component=profiler \
  | grep -A2 -iE 'oomkilled|exit code: 137|last state'
kubectl top pods -n <NS> -l app.kubernetes.io/component=profiler 2>/dev/null
```

If `Last State: Terminated` with `Reason: OOMKilled` (or exit code 137), the agent's memory limit is too low for the workload it's seeing. Common drivers:

1. **High GPU kernel-launch rate** — every CUDA kernel costs ~25 µs of profiler CPU + heap. >10k kernels/s sustained needs more memory.
2. **PC sampling enabled on a hot workload** — SASS-level data is much larger than aggregated kernel stats.
3. **`--samples-per-second` too aggressive** — default is 19 Hz; bumping to 99 Hz quadruples CPU profile volume.

**Fix:** bump resource limits in the canonical values file, then re-apply.

```yaml
profiler:
  resources:
    requests:
      cpu: "500m"
      memory: "512Mi"
    limits:
      cpu: "2000m"
      memory: "2Gi"
```

Backup the canonical file first per [`shared/conventions.md`](../../shared/conventions.md), then:

```bash
helm upgrade --install <REL> zymtrace/profiler \
  --namespace <NS> -f <values-file> \
  --reset-then-reuse-values --atomic --debug
```

If OOMKills persist after bumping to 2Gi/2 CPU, ask: is PC sampling on? Recommend turning it off in steady state and enabling on-demand for debugging only.

Full sizing reference: [install-zymtrace-profiler reference.md § Resource sizing](../install-zymtrace-profiler/reference.md#resource-sizing).

---

## No GPU profiles

Agent is running, CPU profiles appear in the UI, but no GPU/CUDA traces. The agent is healthy — the **workload** isn't loading the CUDA injection library.

##### Claude runs
```bash
POD=$(kubectl get pods -n <NS> -l app.kubernetes.io/component=profiler -o name | head -1)
kubectl logs -n <NS> "$POD" --tail=2000 | grep -E 'Intercepted.*zymtrace.*implant' | head -3
```

If the search returns lines like:
```
level=info msg="Intercepted zymtrace implant at /proc/576236/root//var/lib/zymtrace/profiler/libzymtracecudaprofiler.so"
```
…the agent is intercepting workloads. The issue is downstream (backend ingest / ClickHouse). Hand off to [`troubleshoot-zymtrace-backend`](../troubleshoot-zymtrace-backend/SKILL.md).

If the search is empty, **no workload is being GPU-profiled**. Walk the workload-side checks:

1. **`cudaProfiler.enabled: true`** in the agent's values? `helm get values <REL> -n <NS> | grep -A1 cudaProfiler`. If not, enable it and `helm upgrade --install ... --reset-then-reuse-values --atomic`.
2. **Library on the host?** `kubectl debug node/<gpu-node> -it --image=busybox -- ls /host/var/lib/zymtrace/profiler` (needs node-debugger RBAC). Should contain `libzymtracecudaprofiler.so`. Absent → the agent didn't extract it; restart the DaemonSet pod on that node.
3. **Workload has the env var?** `kubectl get pod <gpu-workload> -n <ws-ns> -o jsonpath='{.spec.containers[*].env[?(@.name=="CUDA_INJECTION64_PATH")]}'`. Empty → patch the workload's pod spec.
4. **Workload has the volume mount?** Same pod, look for `mountPath: /var/lib/zymtrace/profiler` or `/opt/zymtrace/profiler`. Missing → patch the workload spec.
5. **Workload started before the agent?** Restart the workload after the DaemonSet is Ready on its node.

Workload-side recipes (vLLM, SGLang, Triton, PyTorch / training jobs): [install-zymtrace-profiler reference.md § Profiling real workloads](../install-zymtrace-profiler/reference.md#profiling-real-workloads-training-and-inference).

---

## NVML library not found

In the agent logs:
```
Failed to load NVML library
Could not find libnvidia-ml.so
```

The profiler can't find `libnvidia-ml.so` to collect GPU metrics. (CUDA profiling itself doesn't depend on NVML — kernel-level profiling will still work; only the GPU metrics path is broken.)

##### Claude runs
```bash
POD=$(kubectl get pods -n <NS> -l app.kubernetes.io/component=profiler -o name | head -1)
kubectl exec -n <NS> "$POD" -- find / -name 'libnvidia-ml*' 2>/dev/null | head -5
```

If the search returns nothing, the host doesn't have the NVIDIA driver mounted into the pod — install / fix the NVIDIA device plugin or GPU operator first.

If the search returns a path, set it explicitly in the values file:

```yaml
profiler:
  args:
    - "-collection-agent=..."
    - "--enable-gpu-metrics"
    - "--nvml-path=/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1"   # use the path found above
```

Drop `--nvml-auto-scan` once you have the path — it's only useful for first-install discovery. Re-apply via `helm upgrade --install ... --reset-then-reuse-values --atomic`.

---

## PC sampling produces nothing

The customer enabled PC sampling on a workload but the UI shows no SASS / stall data.

##### Claude runs
```bash
WORKLOAD_NS=<ws-ns>
WORKLOAD_POD=<workload-pod>
kubectl get pod "$WORKLOAD_POD" -n "$WORKLOAD_NS" -o jsonpath='{.spec.containers[*].securityContext.privileged}'
kubectl get pod "$WORKLOAD_POD" -n "$WORKLOAD_NS" -o jsonpath='{range .spec.containers[*].env[?(@.name=="ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING")]}{.value}{"\n"}{end}'
```

Two requirements that must both hold:

1. The workload container must have `securityContext.privileged: true`, **or** be started under `sudo` if it's bare-metal.
2. `ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING=true` must be set on the workload (not the agent).

If both look correct and PC sampling still doesn't work, check the NVIDIA driver setting on the node — ask the user to run:

```bash
# Node-side, hand to user
cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly
```

If `RmProfilingAdminOnly=1`, NVIDIA's admin-only restriction is in effect. Options:
- Run the workload as root inside the privileged container (usually already the case).
- Lift the restriction host-wide via `/etc/modprobe.d/` (driver reload required). Full procedure: [install-zymtrace-profiler reference.md § PC sampling](../install-zymtrace-profiler/reference.md#pc-sampling).

---

## License rejected

Agent logs report:
- `license invalid`
- `license expired`
- `forbidden`
- `unauthorized`

##### Claude runs
```bash
POD=$(kubectl get pods -n <NS> -l app.kubernetes.io/component=profiler -o name | head -1)
kubectl logs -n <NS> "$POD" --tail=200 | grep -iE 'license|forbidden|unauthorized' | head -10
```

Three usual causes:

| Symptom | Cause | Fix |
|---|-------|------|
| `license expired` | License is past expiry | Renew via <support@zymtrace.com> or new GPU trial at <https://zymtrace.com/getstarted/>; update the **backend** values file (license lives there, not on the agent) and `helm upgrade --install <backend-REL> ... --reset-then-reuse-values --atomic` |
| `forbidden` / `unauthorized` from gateway | Backend has `auth.serviceToken.enabled: true`; agent missing `--auth-token` | Add `profiler.args: - --auth-token=$ZYMTRACE_AUTH_TOKEN` to the agent values; backup canonical file first; re-apply |
| `license invalid` immediately | Wrong license format (truncated JWT, copy-paste corruption) | Re-fetch the license, update backend values, re-apply |

The license is validated at the **backend gateway**, not on the agent — the agent only sees the result. If license fixes don't take effect, also check the backend pods (`troubleshoot-zymtrace-backend` § License errors).

---

## Done

Exit when:

- [ ] Agent pods are Running on every targeted node (`kubectl get ds -n <NS> <PREFIX>-profiler` shows `DESIRED == READY`).
- [ ] Recent agent logs (`kubectl logs ... --tail=50`) show either `license is valid until ...` OR `streaming connection established` and no `connection refused` / `forbidden` / OOM-related errors.
- [ ] If GPU profiling enabled: the `Intercepted zymtrace implant` line appears in agent logs after a representative workload starts.
- [ ] Customer confirms profiles are visible in the UI (or, if backend-side issue is suspected, hand off to `troubleshoot-zymtrace-backend`).

Recap which step fixed it so future-them can pattern-match.

## Security constraints

- **Never** disable PC sampling, license validation, or service-token auth as a "fix" — those are symptoms, not the problem. Surface the underlying issue.
- **Never** modify the canonical values file without taking a backup first per [`shared/conventions.md`](../../shared/conventions.md).
- **Never** run `kubectl delete pod` / `kubectl delete ds` without explicit user confirmation, even if it would "force a restart".
- **Never** `helm upgrade` without `--reset-then-reuse-values --atomic`.
- **Never** assume node-shell / SSH access. Use `kubectl exec` into pods, `kubectl debug node/...` (with appropriate RBAC), or hand the command to the user. Same rule as the install skills.
- **Never** declare "fixed" without re-running the relevant check in the Done checklist.

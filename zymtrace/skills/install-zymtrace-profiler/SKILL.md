---
name: install-zymtrace-profiler
description: |
  Use when installing the zymtrace profiler agent on Kubernetes (Helm DaemonSet), Docker, or as a binary with systemd, and wiring workloads up to it. Covers CPU-only profiling, off-CPU profiling, NVIDIA GPU profiling (CUDA 12.x+; automatic injection from the UI or CUDA_INJECTION64_PATH), AMD GPU profiling (ROCm 7.x+), inference engines (vLLM, SGLang, NVIDIA Dynamo-Triton, TensorRT-LLM), GPU and inference server metrics, and air-gapped installs via a custom registry. Connects the agent to an existing backend gateway.
  Trigger phrases: "install profiler", "install zymtrace profiler", "install zymtrace agent", "deploy the profiler", "deploy zymtrace DaemonSet", "set up GPU profiling", "set up CUDA profiling", "set up ROCm / AMD GPU profiling", "profile my GPU workloads", "profile vLLM / SGLang / Triton / TensorRT-LLM", "enable off-CPU profiling", "install profiler on EKS / GKE / Slurm / bare-metal", "install profiler on every node", "start collecting profiles".
---

# Install zymtrace Profiler

Helps the user install the zymtrace **profiler agent** — the low-overhead eBPF + CUDA profiler that runs on every node and ships profiles to the backend gateway.

> The backend must be installed first (`install-zymtrace-backend` skill). Profiler agents have nowhere to send profiles otherwise.

Deep details (NVML library paths, PC sampling, env var reference, air-gapped image mirroring, framework metrics) live in `${CLAUDE_PLUGIN_ROOT}/skills/install-zymtrace-profiler/reference.md`.

## Greet the user (start here)

Open with a short welcome before any commands or questions:

> 👋 Thanks for installing the **zymtrace profiler**! It's a low-overhead agent (<1% CPU, ~256 MB RAM) that ships profiles to your backend.
>
> **Stuck? Reach out:**
> - Community Slack: <https://join.slack.com/t/zymtrace/shared_invite/zt-3fdidjufl-q~NHxDzQlzal2B9mujfaoQ>
> - Email: <support@zymtrace.com>
>
> **Tip — analyze GPU and CPU flamegraphs via MCP:** once profiles start flowing, connect the zymtrace MCP to your agent (Claude Code, Codex, or Cursor) — see [`configure-zymtrace-mcp`](../configure-zymtrace-mcp/SKILL.md) — and analyze GPU + CPU flamegraphs in natural language. Docs: <https://docs.zymtrace.com/mcp>
>
> **Here's the plan:**
> 1. Verify your tools and locate the backend gateway.
> 2. Decide CPU-only vs CUDA (GPU) profiling.
> 3. Install the DaemonSet (or Docker / binary).
> 4. Verify the agent is reporting.
>
> Ready when you are.

If the user has already specified Helm / GPU / target, skip the roadmap and dive in.

## Sources of truth

- Live chart `values.yaml`: <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/profiler/values.yaml>
- Profiler install docs: <https://docs.zymtrace.com/install/profiler/install-profiler>
- GPU profiler quick-start: <https://docs.zymtrace.com/install/profiler/gpu-profiler-quick-start>
- CLI args + env vars: <https://docs.zymtrace.com/profiler-configuration>
- Latest release + what changed: <https://docs.zymtrace.com/changelog> (newest version at the top) — the **fallback** for the latest version when `helm search` can't reach the repo (just added / stale cache / air-gapped).

## Pre-flight: verify the tools

##### Claude runs
```bash
helm version --short && kubectl version --client
kubectl cluster-info | head -2
helm list -A | grep -i zymtrace      # locate the backend release
```

If `helm`/`kubectl` are missing → point to install docs; do **not** install them. If no backend release is found anywhere → STOP and route to `install-zymtrace-backend` first; the profiler has nowhere to send data without it.

## Pre-resolve what you can

> **Recommend defaults `zymtrace` / `profiler`** for namespace + release name. Full policy: [`shared/conventions.md`](../../shared/conventions.md).

| Variable | Resolve by |
|---|---|
| Backend release & its namespace | `helm list -A \| grep -i 'backend.*zymtrace'` |
| Backend gateway service FQDN | `<PREFIX>-gateway.<backend-NS>.svc.cluster.local:80` (in-cluster) or external ingress host |
| NVIDIA GPU nodes present? | `kubectl get nodes -l nvidia.com/gpu=true 2>/dev/null \| wc -l` |
| AMD GPU nodes present? | `kubectl get nodes -o custom-columns='NAME:.metadata.name,AMD_GPU:.status.capacity.amd\.com/gpu' \| grep -v '<none>'` |
| NVIDIA device plugin / GPU operator? | `kubectl get pods -A \| grep -E 'nvidia-device-plugin\|gpu-operator'` |
| **CUDA runtime ≥ 12.x?** (required for GPU profiling) | `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.nvidia\.com/cuda\.runtime-version\.major}{"\n"}{end}' \| sort -u` — must be `12` or higher. If labels are missing, `kubectl exec` into an existing GPU pod and run `nvidia-smi`, or ask the user to run `nvidia-smi` on a GPU node themselves and report back (the skill usually can't SSH into the node). |
| Existing profiler release? | `helm list -A \| grep -i 'profiler.*zymtrace'` |
| Customer-provided values file? | Ask — same rule as backend skills. Filename respected. |

Things you **must** ask:
- CPU-only or GPU profiling, and if GPU, NVIDIA (CUDA) or AMD (ROCm)?
- Backend gateway endpoint (in-cluster vs external).

## Blockers vs recommendations (don't conflate)

**Blockers** (stop, surface):
- Backend gateway endpoint unreachable from where the agent will run.
- **NVIDIA GPU profiling requested with CUDA < 12.x** — unsupported; offer CPU-only profiling instead or have the user upgrade CUDA first.
- **AMD GPU profiling requested on ROCm < 7.x or a non-x86_64 host** — unsupported; offer CPU-only profiling.

**Recommendations** (note, proceed):
- **NVIDIA driver / device plugin missing** on GPU nodes — CPU profiling still works, GPU profiling won't until the driver is installed.
- **PC sampling** disabled (default) — useful for production; explicitly enabled only when the user asks (requires CAP_SYS_ADMIN, see [reference.md § PC sampling](reference.md#pc-sampling)).
- **Off-CPU profiling** disabled (default) — offer it when the user cares about latency or waiting (locks, I/O). Host-wide; enable with `--enable-off-cpu` or a rule in the UI. See [reference.md § Off-CPU profiling](reference.md#off-cpu-profiling).

## Decision tree

### 1. Install method

| Method | When |
|--------|------|
| **Helm DaemonSet** (recommended) | Kubernetes — gives you the full chart with GPU support and framework metrics. |
| **kubectl manifest** | Kubernetes without Helm. CPU-only is fine; GPU profiling has fewer config knobs. |
| **Docker** | Single host (non-k8s) — same VM the workload runs on. |
| **Binary + systemd** | Bare-metal Linux (Slurm nodes, on-prem GPU servers). |

### 2. CPU or GPU?

| Profiling | Template | What it gives you |
|-----------|----------|-------------------|
| **CPU only** | [`values/helm-cpu.yaml`](values/helm-cpu.yaml) | eBPF unwinder for native, Python, Go, Java, Node. No CUDA libraries. |
| **GPU (NVIDIA or AMD)** | [`values/helm-gpu.yaml`](values/helm-gpu.yaml) | Above + GPU kernel profiling (CUDA or ROCm) + GPU metrics + vLLM/SGLang/Dynamo-Triton metrics. Same template works for MIG slices and dense multi-GPU nodes; for AMD nodes, change its `nodeSelector`. |

> **NVIDIA GPU profiling requires CUDA 12.x or higher; AMD requires ROCm 7.x or higher on x86_64.** If the customer's NVIDIA nodes are on CUDA 11.x, GPU profiling is a blocker — recommend CPU-only profiling until they upgrade the CUDA toolkit / driver. Architecture: AMD64/x86_64 and ARM64 are both supported.

If GPU nodes exist on the cluster **and** the CUDA / ROCm version is supported, default-recommend GPU profiling. The agent works on CPU nodes too — `cudaProfiler.enabled: true` (which extracts both the CUDA and ROCm libraries) is a no-op when there's no GPU driver.

### 3. Backend gateway endpoint

Where does the agent send profiles? The format is **always `<host-or-ip>:<port>` — never a URL with `https://` in front.** TLS is controlled by the `-disable-tls` flag, not by the URL scheme.

| Setup | Set `-collection-agent` to |
|-------|--------------------------|
| Same cluster as backend (default in templates) | `<PREFIX>-gateway.<backend-NS>.svc.cluster.local:80` + `-disable-tls` |
| Different cluster, backend has TLS ingress | `<gateway-host>:443` — **remove** `-disable-tls` |
| Different cluster, NodePort | `<any-node-ip>:<nodeport>` + `-disable-tls` |

Resolve `<PREFIX>` and `<backend-NS>` from the backend release: `helm list -A | grep -i 'backend.*zymtrace'`.

### 4. Air-gapped / private registry

If mentioned, mirror `ghcr.io/zystem-io/zymtrace-pub-profiler:<VERSION>` into the customer's registry and set:
```yaml
global:
  imageRegistry: "<your-registry>"
  registry:
    requirePullSecret: true   # only if registry needs auth
```
Full procedure: [reference.md § Air-gapped install](reference.md#air-gapped-install).

---

## Kubernetes install (Helm — recommended)

### Pre-flight: verify the tools (see Pre-flight above)

### Step 1: Add the Helm repo

##### Claude runs
```bash
helm repo add zymtrace https://helm.zystem.io   # idempotent if already added
helm repo update zymtrace
helm search repo zymtrace/profiler --versions | head -5
```

**Version to install.** `helm search` (above) is the source of truth for available chart versions — install the newest it lists unless the user pins one. **If it returns nothing** (repo just added and the cache is stale, or air-gapped), fall back to the changelog at <https://docs.zymtrace.com/changelog> — the top entry is the latest release. Keep the profiler on the same version as the backend. Tell the user which version you're installing before Step 3.

### Step 2: Generate the canonical values file

Copy the matching template from `values/` to `zymtrace-profiler-values.yaml` in the user's working directory. **Don't ask the customer if they already have one** — customers typically don't ship with a profiler values file (the backend often does, the profiler rarely does). Only respect a different filename if they explicitly volunteer that they have one (per [`shared/conventions.md`](../../shared/conventions.md)).

Pick the template that fits and edit:
- `profiler.args[0]` `-collection-agent=...` to the backend gateway endpoint.
- Remove `-disable-tls` if pointing at an HTTPS endpoint.
- For GPU: confirm `nodeSelector: nvidia.com/gpu: "true"` matches your cluster's GPU label.

### Step 3: Confirm with the user before running

Print the exact command + resolved values (release name, namespace, target backend gateway, GPU yes/no, image tag if pinned). Wait for explicit confirmation.

### Step 4: Install

##### Claude runs
```bash
helm upgrade --install <REL> zymtrace/profiler \
  --namespace <NS> --create-namespace \
  -f <values-file> \
  --reset-then-reuse-values \
  --atomic --debug
```

Default `<REL>` = `profiler`, `<NS>` = `zymtrace` (same namespace as backend works fine — no conflict).

ERROR: `daemonset.apps/zymtrace-profiler is not ready: pods are not ready` → expected for ~30s while pods start. Wait. If it persists past 2 min, `kubectl describe ds -n <NS> <PREFIX>-profiler`.

ERROR: ImagePullBackOff → registry / version mismatch. Verify image tag at <https://github.com/orgs/zystem-io/packages>.

ERROR: pod CrashLoopBackOff with `permission denied` on `/sys/kernel/debug` → kernel doesn't support eBPF or the security context is being stripped. `kubectl describe pod` to confirm, and check `securityContext.capabilities.add: [SYS_ADMIN]` is honored.

### Step 5: Verify

##### Claude runs
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/install-zymtrace-profiler/scripts/verify-profiler.sh <NS> <REL>
```

Checks DaemonSet readiness, license validity in logs, GPU library extraction (if `cudaProfiler.enabled`), and connection-to-gateway evidence (no `connection refused` or `dns lookup failed` in last 50 log lines).

### Step 6: Persist the canonical values file

##### Claude runs
```bash
helm get values <REL> -n <NS> > <values-file>
```

Recommend the customer commit the file: `git add <values-file> && git commit -m "zymtrace: profiler install for <NS>/<REL>"`.

### Step 7: Hand off to GPU workload setup (GPU installs only)

If GPU profiling was enabled, the agent is running but **no workload is being profiled yet** — the GPU profiler library has to be loaded into each workload process. Pick one:

- **NVIDIA, automatic (recommended):** in the zymtrace UI, **Settings → Agent Config → CUDA Profiler → Add Rule**, target the workload with a process query, and turn on **Inject CUDA Profiler**. No manifest changes, no restarts. Doesn't capture NVTX.
- **NVIDIA, manual:** set `CUDA_INJECTION64_PATH` on the workload.
- **AMD:** set `ROCP_TOOL_LIBRARIES` and `ROCPROFILER_REGISTER_LIBRARY` on the workload and restart it. AMD has no automatic injection.

Point the user at [`reference.md § Profiling real workloads`](reference.md#profiling-real-workloads-training-and-inference) — it covers:

- **Training jobs** (PyTorch / DDP / FSDP / DeepSpeed / Megatron) — set-and-forget env var, with bare-metal/Slurm and Kubernetes examples.
- **Inference engines** (vLLM, SGLang, NVIDIA Dynamo-Triton, TensorRT-LLM) — a table linking each engine's docs page and full manifest, the pod-spec pattern, engine-specific notes, and how to verify the library loaded.

Authoritative docs: <https://docs.zymtrace.com/install/profiler/profiling-gpu-workloads> and <https://docs.zymtrace.com/install/profiler/profiling-inference-engines>.

CPU-only installs are done at this point — profiles for every process on every node start flowing within ~30 seconds.

---

## Other install methods

For kubectl manifest, Docker, or binary+systemd installs, see [reference.md § Other install methods](reference.md#other-install-methods). The same pre-flight rules apply; only Step 4 (install) differs.

---

## Done

Exit when ALL of the following are true (substitute `<NS>` / `<REL>` / `<PREFIX>`):

- [ ] `helm status <REL> -n <NS>` reports `STATUS: deployed`.
- [ ] DaemonSet `<PREFIX>-profiler` has `DESIRED == READY` (`kubectl get ds -n <NS>`).
- [ ] At least one pod has logged `Your license is valid until …` OR `streaming connection established` (means the agent reached the backend).
- [ ] No `connection refused`, `dns lookup failed`, or `forbidden` in the last 50 log lines of any pod.
- [ ] For GPU installs: `ls -la /var/lib/zymtrace/profiler` on a GPU node shows `libzymtracecudaprofiler.so` (NVIDIA) or `libzymtracerocmprofiler.so` (AMD) — the agent extracted it for workload mounts.

If any box fails, route by symptom:
- **Agent-side issues** (CrashLoopBackOff, ImagePullBackOff, OOMKilled, no GPU profiles, NVML, license rejected) → hand off to [`troubleshoot-zymtrace-profiler`](../troubleshoot-zymtrace-profiler/SKILL.md).
- **Cross-cutting "no data anywhere"** → hand off to [`troubleshoot-zymtrace-backend`](../troubleshoot-zymtrace-backend/SKILL.md), which walks the full backend ↔ profiler path.

Both have first-pass diagnostic scripts to run before going manual.

## Common pitfalls

- **`-collection-agent` accepts only `host:port`, never a URL.** Use `zymtrace.example.com:443` — NOT `https://zymtrace.example.com:443` or `https://zymtrace.example.com/`. Adding a scheme prefix makes the agent fail to parse the value and retry forever. TLS is controlled separately by presence/absence of the `-disable-tls` flag, not by the URL scheme.
- **Wrong `-collection-agent`** (typo in `<backend-NS>`, or pointed at a non-existent service) → agent retries forever, no profiles appear. Test with `kubectl run -it --rm dns-test --image=busybox -- nslookup <PREFIX>-gateway.<backend-NS>.svc.cluster.local`.
- **`-disable-tls` left on when targeting HTTPS ingress** → handshake fails. Remove the flag.
- **`-disable-tls` removed when targeting in-cluster ClusterIP** → connection refused (service is HTTP). Add it back.
- **GPU template applied on CPU-only nodes** → harmless (CUDA profiler no-ops without NVIDIA driver), but wastes pod resources via the nodeSelector mismatch. Either remove `nodeSelector` or scope to GPU nodes.
- **NodeSelector targets a label the cluster doesn't actually set** → DaemonSet schedules 0 pods. `kubectl get nodes --show-labels` to confirm.
- **`--nvml-auto-scan` left on permanently** → fine for first install (detects NVML path), but for production, switch to `--nvml-path=<path>` once the path is known (saves startup scan).
- **Disabling CUDA graphs (`--enforce-eager`) or adding `privileged: true` "to make profiling work"** on an inference engine → neither is needed. CUDA and HIP graphs are supported; `privileged` is only for PC sampling.
- **Checking the GPU flamegraph before the engine serves any requests** → kernels are profiled only while the GPU is working. Send traffic first.

---

## Security constraints

- **Never** issue `helm upgrade` / `helm upgrade --install` for this chart without `--reset-then-reuse-values`. See [`shared/conventions.md`](../../shared/conventions.md).
- **Never** include `-project=` / `ZYMTRACE_PROJECT` in profiler args, env vars, or values templates. Always use the default project — the agent creates it automatically.
- **Never** create overlay / temporary values files alongside the canonical one — edit in place.
- **Never** run the install without explicit user confirmation showing the resolved target gateway endpoint.
- **Never** turn on PC sampling silently. It's a powerful feature (NVIDIA only) — gives you SASS-level disassembly + stall reasons — but NVIDIA requires the *workload* to run with elevated privileges to enable it: either `privileged: true` on the k8s pod, or `sudo` when running a bare binary. That's a workload-side change that needs explicit user confirmation. Recommend it for dev/staging deep-dives or on-demand production debugging. See [reference.md § PC sampling](reference.md#pc-sampling).
- **Never** create an Agent Config rule (automatic injection, off-CPU) without the user's confirmation — it changes what every matching agent does, without a redeploy.
- **Never** skip Step 5 verification — DaemonSet "Ready" doesn't mean the agent is reaching the backend.

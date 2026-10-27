# install-zymtrace-profiler — Reference

Detailed material the SKILL.md links to but does not inline. Read on demand.

---

## Other install methods

### kubectl manifest (no Helm)

Quickest path for k8s clusters without Helm. CPU profiling out of the box; GPU profiling has fewer configuration options.

```bash
kubectl create namespace zymtrace
kubectl apply -n zymtrace -f https://helm.zystem.io/k8s-manifests/profiler/deploy.yaml
```

To change the `-collection-agent` target, download first and edit:
```bash
curl -O https://helm.zystem.io/k8s-manifests/profiler/deploy.yaml
# edit deploy.yaml — find the args list, set -collection-agent=<host>:<port>
kubectl apply -n zymtrace -f deploy.yaml
```

For GPU profiling, use Helm instead — the manifest path doesn't expose `cudaProfiler.enabled`.

### Docker (single host)

Canonical command (CPU + GPU profiling, includes the host-path mount that lets workloads pick up the CUDA profiler library):

```bash
docker run --cgroupns=host --pid=host --privileged --net=host \
  -v /etc/machine-id:/etc/machine-id:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /var/lib/zymtrace/profiler:/opt/zymtrace-cuda-profiler \
  --rm -d --name zymtrace-profiler \
  ghcr.io/zystem-io/zymtrace-pub-profiler:<VERSION> \
  --disable-tls \
  --collection-agent <gateway-host>:<port> \
  --enable-gpu-metrics \
  --nvml-auto-scan
```

Notes:
- The `-v /var/lib/zymtrace/profiler:/opt/zymtrace-cuda-profiler` mount is **required for GPU profiling** — the container extracts `libzymtracecudaprofiler.so` to this host path, and your GPU workloads later mount the same path with `CUDA_INJECTION64_PATH` set.
- Use `:443` + drop `--disable-tls` when pointing at an HTTPS endpoint (e.g. `--collection-agent zymtrace.example.com:443`).
- For **CPU-only** profiling, drop both `-v /var/lib/zymtrace/profiler:/opt/zymtrace-cuda-profiler` and the `--enable-gpu-metrics --nvml-auto-scan` flags.
- `--nvml-auto-scan` is fine for first install. Switch to `--nvml-path=/path/to/libnvidia-ml.so` once you know the path (saves startup scan).
- For service-token auth (`auth.serviceToken.enabled: true` on the backend), add `--auth-token "$ZYMTRACE_AUTH_TOKEN"`.
- Resolve the image tag `<VERSION>` from the changelog (<https://docs.zymtrace.com/changelog>, newest at the top) — there's no Helm repo to `helm search` on this path. Match the backend's version.

### Binary (bare-metal)

#### Download + extract
```bash
# AMD64
curl -LO https://dl.zystem.io/zymtrace/<VERSION>/amd64/zymtrace-profiler.tar.gz
# ARM64
# curl -LO https://dl.zystem.io/zymtrace/<VERSION>/arm64/zymtrace-profiler.tar.gz

sudo tar -xzvf zymtrace-profiler.tar.gz -C / --no-same-owner
```

Resolve `<VERSION>` from the changelog (<https://docs.zymtrace.com/changelog>, newest at the top) — no Helm repo to `helm search` here. Match the backend's version and tell the user which one you're pinning.

#### Run option A — `nohup` background (quickest for ad-hoc testing)
```bash
sudo nohup /opt/zymtrace/profiler/zymtrace-profiler \
  --collection-agent <gateway-host>:443 \
  --enable-gpu-metrics \
  --nvml-auto-scan \
  --auth-token "$ZYMTRACE_AUTH_TOKEN" \
  > ./zymtrace-profiler.log 2>&1 &
```

Use `:80` + `--disable-tls` if pointing at a NodePort / in-cluster service without TLS. `--auth-token` is needed only when the backend has `auth.serviceToken.enabled: true`.

#### Run option B — systemd (persistent service)

```ini
# /etc/systemd/system/zymtrace.service
[Unit]
Description=zymtrace profiler service
After=network.target

[Service]
Type=simple
ExecStart=/opt/zymtrace/profiler/zymtrace-profiler \
  --collection-agent <gateway-host>:443 \
  --enable-gpu-metrics \
  --nvml-auto-scan
Restart=always
RestartSec=10
WorkingDirectory=/opt/zymtrace/profiler

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now zymtrace
sudo journalctl -u zymtrace -f
```

For CPU-only profiling on bare-metal, drop `--enable-gpu-metrics --nvml-auto-scan` from either form.

For an external HTTPS backend with service-token auth, set `ZYMTRACE_AUTH_TOKEN` in the environment (or `EnvironmentFile=/etc/zymtrace/env` for the systemd unit).

---

## CUDA version requirement

GPU profiling requires **CUDA 12.x or higher**. CUDA 11.x and earlier are not supported — the CUDA profiler library uses CUPTI features that only exist from CUDA 12.0 onward.

Both AMD64/x86_64 and ARM64 architectures are supported (e.g. Grace Hopper).

Check the runtime. The kubectl-label path works from anywhere; the `nvidia-smi` paths assume access this skill usually lacks:

```bash
# Preferred — reads NVIDIA GPU operator labels. Works from any kubectl-authed shell.
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.nvidia\.com/cuda\.runtime-version\.major}{"\n"}{end}' | sort -u

# Fallback A — exec into an existing GPU pod (works if one is already running)
kubectl exec -n <NS> <gpu-pod> -- nvidia-smi | grep "CUDA Version"

# Fallback B — ask the user to run it themselves on a GPU node and report back
#   $ nvidia-smi
#   The "CUDA Version" column reports the maximum runtime the driver supports.
```

The skill typically does **not** have SSH or node-shell access, so don't assume `nvidia-smi` runs in Claude's session. Use the kubectl label or a `kubectl exec` into a workload pod when you can; otherwise hand the command to the user.

If the customer is on CUDA 11.x, recommend either:
1. CPU-only profiling now, upgrade CUDA later.
2. Pause the install until they bump the CUDA toolkit and driver.

---

## NVML library path

The profiler needs to load `libnvidia-ml.so` to collect GPU metrics. Two ways to find it:

| Flag | Behavior |
|------|---------|
| `--nvml-auto-scan` | Scans common paths at startup, prints the one it found. Use **once** to discover; switch to explicit path afterwards. |
| `--nvml-path=/path/to/libnvidia-ml.so` | Explicit path. Faster startup. Recommended for production. |

Common paths by distro:
- Ubuntu/Debian: `/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1`
- RHEL/CentOS: `/usr/lib64/libnvidia-ml.so.1`
- Container with NVIDIA runtime: `/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1` (mounted from host)

To find it on a running pod:
```bash
kubectl exec -n <NS> <profiler-pod> -- find / -name 'libnvidia-ml*' 2>/dev/null
```

After auto-scan, the profiler logs the discovered path — grep for it:
```bash
kubectl logs -n <NS> <profiler-pod> | grep -i nvml
```

---

## PC sampling

PC sampling is the **deepest GPU profiling mode** zymtrace offers — it captures stall reasons, SASS-level disassembly, and memory offsets per kernel. This is the level you reach for when you need to know *exactly* which instruction is bottlenecked.

It's off by default not because it's risky, but because NVIDIA requires the **workload process** to start with elevated privileges to enable it. So enabling it is a per-workload decision, not a profiler-agent setting. The agent's CUDA library is already installed and ready — turning on PC sampling is a flag the workload sets.

### How NVIDIA gates it

Per [CVE-2024-0090](https://nvidia.custhelp.com/app/answers/detail/a_id/5551), NVIDIA restricts profiling APIs to admin users by default (`RmProfilingAdminOnly=1` in the driver). PC sampling falls under that restriction, which means the workload must run with either:

- **Kubernetes**: `securityContext.privileged: true` on the workload pod, OR
- **Bare-metal / Docker**: start the process with `sudo` (or run the container `--privileged`).

### Enable on Kubernetes

On the **workload** pod (not the profiler agent):
```yaml
securityContext:
  privileged: true
env:
  - name: CUDA_INJECTION64_PATH
    value: "/opt/zymtrace/profiler/libzymtracecudaprofiler.so"
  - name: ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING
    value: "true"
```

### Enable on bare-metal / binary

Start the process with `sudo`:
```bash
sudo env RUST_LOG="zymtracecudaprofiler=info" \
  CUDA_INJECTION64_PATH="/opt/zymtrace/profiler/libzymtracecudaprofiler.so" \
  ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING="true" \
  python -u your_workload.py
```

### Enable host-wide (optional)

If running PC sampling across many workloads, drop the admin-only driver restriction (one-time host config):
```bash
cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly
# If RmProfilingAdminOnly=1, disable the admin-only restriction:
echo "options nvidia NVreg_RestrictProfilingToAdminUsers=0" | sudo tee /etc/modprobe.d/nvidia-pc-sampling.conf
sudo update-initramfs -u && sudo reboot
```
After that, PC sampling works without the `privileged: true` / `sudo` per workload.

### When to use it

Recommend **freely in dev/staging** where the workload pods already run with elevated privs or where convenience trumps least-privilege. In production, enable **on demand** when you need to chase a specific kernel-level bottleneck — flip the workload, capture for a few minutes, flip it back.

---

## Smoke-test GPU profiling (HuggingFace GPU Fryer)

After the agent is running with GPU profiling enabled, run a 500-iteration GPU stress workload to confirm the full path works. Shows up nicely in the UI with cross-language unwinding (CUDA + Rust + Python).

```bash
docker run --gpus all --privileged \
  -v /opt/zymtrace/profiler:/opt/zymtrace/profiler:ro \
  -e RUST_LOG="zymtracecudaprofiler=info" \
  -e ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING="true" \
  -e CUDA_INJECTION64_PATH="/opt/zymtrace/profiler/libzymtracecudaprofiler.so" \
  --rm -d --name gpu-fryer \
  ghcr.io/huggingface/gpu-fryer:1.1.0 500
```

Within ~30 seconds you should see profiles for `gpu-fryer` in the zymtrace UI with SASS-level disassembly (because PC sampling is on). The `--privileged` flag + `ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING=true` are the workload-side requirements from § PC sampling.

This is **also useful for customer demos** — short, predictable, no model weights to download.

---

## Profiling real workloads (training and inference)

Installing the profiler agent gets it running on every node — that's the eBPF profiler for CPU code. **GPU profiling additionally requires the GPU profiler library to be loaded into the workload process.** There are two ways to do that.

### Automatic injection via the UI (NVIDIA, recommended)

On NVIDIA, the profiler can inject the CUDA profiler into matching processes itself — no manifest or env-var changes on the workload. In the zymtrace UI: **Settings → Agent Config → CUDA Profiler → Add Rule**, set a process query (CEL — the same syntax as the query bar, e.g. a container, namespace, or executable), and turn on **Inject CUDA Profiler**. The **GPU Profiler Config** setting on the same tab takes the `ZYMTRACE_CUDAPROFILER__*` options. Rules apply on the fly; no profiler or workload restart.

- **NVTX is not captured in this mode.** If the user needs NVTX ranges, use manual injection.
- **AMD (ROCm) has no automatic injection** — ROCm workloads must be started with the env vars below.

Docs: <https://docs.zymtrace.com/install/profiler/profiling-gpu-workloads#automatic-injection>

### Manual injection via env vars

| GPU | Set on the workload | Library (host path the DaemonSet populates: `/var/lib/zymtrace/profiler`; binary install: `/opt/zymtrace/profiler`) |
|---|---|---|
| **NVIDIA (CUDA)** | `CUDA_INJECTION64_PATH` | `libzymtracecudaprofiler.so` |
| **AMD (ROCm)** | `ROCP_TOOL_LIBRARIES` **and** `ROCPROFILER_REGISTER_LIBRARY` | `libzymtracerocmprofiler.so` and `librocprofiler-sdk.so.1` |

The same variables enable profiling for every framework: PyTorch, DDP, FSDP, DeepSpeed, Megatron, JAX, vLLM, SGLang, Dynamo-Triton, TensorRT-LLM, custom CUDA/HIP code. The variation between training and inference is mostly *where* you set them (Slurm prolog, k8s pod spec, Docker `-e`). The ROCm profiler can't attach to an already-running process — restart the workload with the variables set.

### Training jobs (the env-var-and-done case)

Training workloads — PyTorch, DDP, FSDP, DeepSpeed, Megatron, custom CUDA — all profile the same way: set `CUDA_INJECTION64_PATH` on the training process. There's no framework-specific pod spec or launcher tweak needed.

#### Bare-metal / Slurm

The library is at `/opt/zymtrace/profiler/libzymtracecudaprofiler.so` after the binary install.

```bash
# Basic GPU profiling (no privileged access required)
env CUDA_INJECTION64_PATH="/opt/zymtrace/profiler/libzymtracecudaprofiler.so" \
    python -u train.py
```

```bash
# With PC sampling for deeper SASS-level data (requires sudo — see § PC sampling)
sudo env RUST_LOG="zymtracecudaprofiler=info" \
    CUDA_INJECTION64_PATH="/opt/zymtrace/profiler/libzymtracecudaprofiler.so" \
    ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING="true" \
    python -u train.py
```

**Set-and-forget pattern**: drop the env var in `/etc/profile.d/zymtrace.sh` (system-wide) or `~/.bashrc` (per user). Slurm users can put it in the job prolog or sbatch wrapper. Every subsequent Python/PyTorch/etc. launch picks it up automatically.

```bash
# /etc/profile.d/zymtrace.sh
export CUDA_INJECTION64_PATH=/opt/zymtrace/profiler/libzymtracecudaprofiler.so
```

#### Kubernetes (Job, StatefulSet, multi-node DDP)

Mount the host path that the profiler DaemonSet populates, then set the env var. Same pattern as inference — there's nothing PyTorch-specific.

```yaml
spec:
  template:
    spec:
      volumes:
      - name: zymtrace-profiler
        hostPath:
          path: /var/lib/zymtrace/profiler
          type: Directory
      containers:
      - name: trainer
        env:
        - name: CUDA_INJECTION64_PATH
          value: "/var/lib/zymtrace/profiler/libzymtracecudaprofiler.so"
        volumeMounts:
        - name: zymtrace-profiler
          mountPath: /var/lib/zymtrace/profiler
          readOnly: true
```

Multi-node DDP / FSDP / DeepSpeed don't need special treatment — each pod loads the library independently.

### Inference engines (vLLM, SGLang, Dynamo-Triton, TensorRT-LLM)

Inference engines use the same variables. The docs have a tested page per engine, each with Kubernetes, Docker, and binary instructions and a full manifest. **Fetch the engine's page and adapt its manifest** rather than writing one from scratch:

| Engine | NVIDIA | AMD | Docs | Full Kubernetes manifest |
|---|---|---|---|---|
| vLLM | ✓ | ✓ | <https://docs.zymtrace.com/install/profiler/profiling-inference-engines/vllm> | <https://gist.github.com/iogbole/0060415b87d6d8ecff8cdc4b5a3143e4> |
| SGLang | ✓ | ✓ | <https://docs.zymtrace.com/install/profiler/profiling-inference-engines/sglang> | <https://gist.github.com/iogbole/16c39f0915cb4998a7a201c8c0864ba8> |
| NVIDIA Dynamo-Triton | ✓ | — | <https://docs.zymtrace.com/install/profiler/profiling-inference-engines/dynamo-triton> | <https://gist.github.com/iogbole/2fda4ed7e53f70beb2df949d3eb320ef> |
| TensorRT-LLM | ✓ | — | <https://docs.zymtrace.com/install/profiler/profiling-inference-engines/tensorrt-llm> | <https://gist.github.com/iogbole/2cba56573253f0f9e1caf86d1953929e> |

The pod-spec pattern every engine page uses (NVIDIA shown; for AMD swap the env var for the two ROCm ones above and the GPU resource for `amd.com/gpu`):

```yaml
spec:
  hostIPC: true                     # engines use shared memory for IPC
  containers:
  - name: engine
    env:
    - name: CUDA_INJECTION64_PATH
      value: /opt/zymtrace/profiler/libzymtracecudaprofiler.so
    resources:
      limits:
        nvidia.com/gpu: 1
    volumeMounts:
    - name: zymtrace-profiler
      mountPath: /opt/zymtrace/profiler
      readOnly: true
  volumes:
  - name: zymtrace-profiler
    hostPath:
      path: /var/lib/zymtrace/profiler
      type: Directory
```

Docker equivalent: `-v /var/lib/zymtrace/profiler:/opt/zymtrace/profiler:ro -e CUDA_INJECTION64_PATH=/opt/zymtrace/profiler/libzymtracecudaprofiler.so --ipc=host`. AMD Docker also needs `--device /dev/kfd --device /dev/dri --group-add video`.

Engine-specific notes:

- **vLLM** — exposes Prometheus metrics by default; zymtrace collects them. Port 8000. ROCm image: `vllm/vllm-openai-rocm`.
- **SGLang** — only exposes metrics when started with **`--enable-metrics`** (SGLang's own flag, needed only if the user wants SGLang metrics in zymtrace). Port 30000.
- **NVIDIA Dynamo-Triton** — NVIDIA only, container image only. Serves a model repository (`--model-repository`); the docs example uses the vLLM backend. Inference on port 8000, metrics on port 8002 (collected by default).
- **TensorRT-LLM** — NVIDIA only. Docker needs NVIDIA's recommended `--ulimit memlock=-1 --ulimit stack=67108864`. zymtrace collects GPU profiles and GPU metrics; there are no TensorRT-LLM framework metrics.
- **CUDA and HIP graphs** are supported out of the box; engines use them by default. Don't disable graphs (e.g. `--enforce-eager`) to make profiling work. On NVIDIA, graph launches are sampled (`ZYMTRACE_CUDAPROFILER__GRAPH_SAMPLING__*`, see the env var table).
- **PC sampling** (NVIDIA only) is the only reason to add `privileged: true` / `--privileged` to an engine. See § PC sampling.
- Kernels are profiled only while the engine is serving requests — send traffic before checking the flamegraph.

**Verify** the library loaded by adding to the engine's environment:
- NVIDIA: `RUST_LOG=zymtracecudaprofiler=info` + `ZYMTRACE_CUDAPROFILER__QUIET=false` → the engine log shows `loaded zymtrace CUDA profiler version ...`.
- AMD: `RUST_LOG=zymtracerocmprofiler=info` + `ZYMTRACE_ROCMPROFILER__QUIET=false` → the engine log shows `zymtracerocmprofiler` lines.

---

## Framework metrics

The profiler agent automatically collects framework-specific metrics when the relevant processes are detected on the node. **All enabled by default** — listed here for explicit disable / debugging.

| Framework | Default | Flag | Env var |
|-----------|---------|------|---------|
| vLLM | on | `--enable-vllm-metrics=false` to disable | `ZYMTRACE_ENABLE_VLLM_METRICS=false` |
| SGLang | on | `--enable-sglang-metrics=false` | `ZYMTRACE_ENABLE_SGLANG_METRICS=false` |
| NVIDIA Dynamo-Triton | on | `--enable-triton-metrics=false` | `ZYMTRACE_ENABLE_TRITON_METRICS=false` |
| AWS Neuron | on | `--enable-neuron-metrics=false` | `ZYMTRACE_ENABLE_NEURON_METRICS=false` |
| Host metrics (CPU, mem, disk) | on | `--enable-host-metrics=false` | `ZYMTRACE_ENABLE_CPU_METRICS=false` |
| GPU metrics (NVIDIA) | on | `--enable-gpu-metrics=false` | `ZYMTRACE_ENABLE_GPU_METRICS=false` |

TensorRT-LLM has no framework metrics; zymtrace collects its GPU profiles and GPU metrics. Disable metrics only if you don't want them in the UI; the overhead is negligible. Every metric and dashboard: <https://docs.zymtrace.com/gpu/metrics-reference>.

---

## Off-CPU profiling

Off by default. Off-CPU profiles show where threads **wait** (locks, I/O, sleeps, waiting for a CPU) rather than where they run — the view to use when a service is slow but its CPU usage is low. It's a **host-wide** setting: rules can target hosts, not individual processes.

Enable it either way:
- **UI (no redeploy):** **Settings → Agent Config → Off-CPU → Add Rule**, a host CEL expression (or empty for all hosts), turn on **Off-CPU profiling**. Applies without restarting the profiler.
- **Profiler flag:** add `--enable-off-cpu` to `profiler.args` (env `ZYMTRACE_ENABLE_OFF_CPU=true`). `--off-cpu-sampling-rate=<Hz>` (default 19) also enables it when non-zero.

Docs: <https://docs.zymtrace.com/features/off-cpu-profiling>

---

## CUDA profiler env vars (advanced)

The CUDA profiler library reads these env vars from the **profiled workload** (not the agent):

| Variable | Purpose |
|---|---|
| `CUDA_INJECTION64_PATH` | Required. Path to `libzymtracecudaprofiler.so`. |
| `NVTX_INJECTION64_PATH` | Optional. Same path enables NVTX range capture. |
| `ZYMTRACE_CUDAPROFILER__COLLECT_PER_GPU` | Aggregate kernels per GPU vs globally. Default: true. |
| `ZYMTRACE_CUDAPROFILER__ENABLE_NVTX` | NVTX support. Requires `NVTX_INJECTION64_PATH`. Default: true. |
| `ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING` | Enable PC sampling (see above). Default: false. |
| `ZYMTRACE_CUDAPROFILER__PRINT_STATS` | Periodically dump stats to stdout. Default: false. |
| `ZYMTRACE_CUDAPROFILER__QUIET` | Silence all output. Default: true (must set false for PRINT_* to work). |
| `ZYMTRACE_CUDAPROFILER__STACK_TRACE_SAMPLING__ENABLED` | Sample kernels vs profile all. Default: true. |
| `ZYMTRACE_CUDAPROFILER__STACK_TRACE_SAMPLING__TARGET` | Kernels per thread per window. Default: 200. |
| `ZYMTRACE_CUDAPROFILER__STACK_TRACE_SAMPLING__WINDOW_SIZE` | Sampling window. Default: 1s. |
| `ZYMTRACE_CUDAPROFILER__GRAPH_SAMPLING__ENABLED` | Sample CUDA graph launches rather than profiling every launch; a sampled launch profiles every kernel in the graph. Default: true. |
| `ZYMTRACE_CUDAPROFILER__GRAPH_SAMPLING__TARGET` | Graph launches to profile, per OS thread, per second. Default: 20. |

Full reference: <https://docs.zymtrace.com/profiler-gpu-variables>

---

## Cross-cluster gateway target

Profiling agents in one cluster, backend in another. Three common setups:

### Backend exposed via ALB/NGINX with TLS (recommended)
```yaml
profiler:
  args:
    - "-collection-agent=zymtrace.example.com:443"
    # NO -disable-tls flag — TLS is on
```

### Backend exposed via NodePort
```yaml
profiler:
  args:
    - "-collection-agent=<any-node-ip>:32080"
    - "-disable-tls"
```

### Multiple clusters → one backend
Set `global.ClusterMetadata.cluster_id` per cluster install:
```yaml
global:
  ClusterMetadata:
    cluster_id: "prod-us-west-2"   # cluster A
    # cluster_id: "prod-eu-west-1"  # cluster B
    # cluster_id: "dev-singapore"    # cluster C
```
In the UI you filter profiles by `cluster_id`.

---

## Air-gapped install

The profiler image lives at `ghcr.io/zystem-io/zymtrace-pub-profiler:<VERSION>`. Mirror procedure:

```bash
# Pull from public
docker pull ghcr.io/zystem-io/zymtrace-pub-profiler:<VERSION>

# Tag for your mirror
docker tag ghcr.io/zystem-io/zymtrace-pub-profiler:<VERSION> \
  <your-registry>/zymtrace-pub-profiler:<VERSION>

# Push to mirror
docker push <your-registry>/zymtrace-pub-profiler:<VERSION>
```

Then in your values file:
```yaml
global:
  imageRegistry: "<your-registry>"
  registry:
    requirePullSecret: true       # only if registry needs auth
    username: ""                   # via --set on CLI, not in values file
    password: ""                   # via --set on CLI, not in values file
```

Full doc: <https://docs.zymtrace.com/install/custom-registry>

---

## Resource sizing

The agent runs as a DaemonSet with a single pod per node. Resource usage scales with **GPU kernel launch rate**, not number of GPUs.

| Component | CPU | Memory |
|-----------|-----|--------|
| eBPF profiler (always-on) | <1% of one core | ~256 MB |
| CUDA profiler (per workload) | ~25 µs / kernel launch | ~314 MB heap |
| Per workload, ~10k kernels/s | +0.25 CPU cores | +700 MB host, +300 MB GPU |

Default chart limits (`200m`/`256Mi` requests, `1000m`/`1Gi` limits) work for most workloads. For dense multi-GPU (>4 GPUs/node) or >10k kernels/s sustained, bump `profiler.resources.requests` to `cpu: 500m` / `memory: 512Mi` and `limits` to `cpu: 2000m` / `memory: 2Gi` in the values file.

Full reference: <https://docs.zymtrace.com/install/profiler/profiler-resource-guide>

---

## Multi-project (rarely needed)

The profiler agent supports a `-project=<name>` flag for logical grouping in the UI. **Skip this in install** — the agent creates a default project automatically. Only surface the flag if the customer explicitly asks for multi-project organization (multi-tenant clusters, dev workload separation).

Full env-var reference: <https://docs.zymtrace.com/profiler-configuration>

---

## Sources

- Profiler chart: <https://github.com/zystem-io/zymtrace-charts/tree/main/charts/profiler>
- Live `values.yaml`: <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/profiler/values.yaml>
- Install doc: <https://docs.zymtrace.com/install/profiler/install-profiler>
- GPU quick-start: <https://docs.zymtrace.com/install/profiler/gpu-profiler-quick-start>
- GPU workload setup (automatic + manual injection, ROCm): <https://docs.zymtrace.com/install/profiler/profiling-gpu-workloads>
- Inference engines (vLLM, SGLang, Dynamo-Triton, TensorRT-LLM): <https://docs.zymtrace.com/install/profiler/profiling-inference-engines>
- Off-CPU profiling: <https://docs.zymtrace.com/features/off-cpu-profiling>
- Resource guide: <https://docs.zymtrace.com/install/profiler/profiler-resource-guide>
- CLI args + env: <https://docs.zymtrace.com/profiler-configuration>
- GPU env vars: <https://docs.zymtrace.com/profiler-gpu-variables>
- GPU metrics: <https://docs.zymtrace.com/gpu/gpu-metrics>
- MIG: <https://docs.zymtrace.com/gpu/mig-support>
- Multi-GPU: <https://docs.zymtrace.com/gpu/multi-gpu>

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

### Binary (bare-metal)

#### Download + extract
```bash
# AMD64
curl -LO https://dl.zystem.io/zymtrace/<VERSION>/amd64/zymtrace-profiler.tar.gz
# ARM64
# curl -LO https://dl.zystem.io/zymtrace/<VERSION>/arm64/zymtrace-profiler.tar.gz

sudo tar -xzvf zymtrace-profiler.tar.gz -C / --no-same-owner
```

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

Installing the profiler agent gets it running on every node — that's the eBPF profiler for CPU code. **GPU profiling additionally requires the workload to load the CUDA injection library**, controlled per-process via `CUDA_INJECTION64_PATH`. How you set that depends on the install method and workload type.

> The same one env var (`CUDA_INJECTION64_PATH`) enables profiling for every CUDA framework: PyTorch, DDP, FSDP, DeepSpeed, Megatron, vLLM, SGLang, Triton, TGI, custom CUDA code. The variation between training vs inference is mostly about *how* you set the env var (Slurm prolog, k8s pod spec, Docker `-e`).

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

### Inference servers (vLLM, SGLang, Triton, TGI)

Inference servers add a few framework-specific tunables on top of the same env var. The agent install side is identical; what differs is the workload pod / Docker launch.

The host path is fixed at `/var/lib/zymtrace/profiler`. The in-container path is your choice — common patterns:
- Mount to the same path (`/var/lib/zymtrace/profiler` inside the container) and set `CUDA_INJECTION64_PATH=/var/lib/zymtrace/profiler/libzymtracecudaprofiler.so`.
- Mount to `/opt/zymtrace/profiler` and set `CUDA_INJECTION64_PATH=/opt/zymtrace/profiler/libzymtracecudaprofiler.so`.

Both work — pick one and stay consistent.

#### Concrete Docker example — SGLang serving gpt-oss-20b with PC sampling

```bash
docker rm -f gpt-oss-zymtrace-sglang 2>/dev/null || true
docker run --gpus all --privileged \
    --shm-size 32g \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    -v /var/lib/zymtrace/profiler:/opt/zymtrace/profiler:ro \
    --rm -d \
    -e RUST_LOG="zymtracecudaprofiler=info" \
    -e ZYMTRACE_CUDAPROFILER__PRINT_STATS="true" \
    -e ZYMTRACE_CUDAPROFILER__QUIET="false" \
    -e ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING="true" \
    -e CUDA_INJECTION64_PATH="/opt/zymtrace/profiler/libzymtracecudaprofiler.so" \
    -p 30000:30000 \
    --ipc=host \
    --name gpt-oss-zymtrace-sglang \
    lmsysorg/sglang:latest \
    python3 -m sglang.launch_server --model-path openai/gpt-oss-20b --host 0.0.0.0 --port 30000 --enable-metrics
```

Notes for SGLang specifically:
- `--shm-size 32g` — SGLang's runtime needs large `/dev/shm` for KV cache and IPC. Don't drop it.
- `--ipc=host` plus `--shm-size` — same reason.
- `--enable-metrics` on `sglang.launch_server` exposes the metrics endpoint zymtrace's `--enable-sglang-metrics` then scrapes.
- `--privileged` + `ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING=true` go together — see § PC sampling.

#### Concrete Docker example — vLLM serving gpt-oss-20b on a MIG slice

```bash
docker rm -f vllm-gpt-oss 2>/dev/null || true
docker run --gpus "device=MIG-f23532fd-1e7a-514e-90f7-4c940831a592" --privileged \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    -v /var/lib/zymtrace/profiler:/opt/zymtrace/profiler:ro \
    --rm -d \
    -e RUST_LOG="zymtracecudaprofiler=info" \
    -e ZYMTRACE_CUDAPROFILER__PRINT_STATS="true" \
    -e ZYMTRACE_CUDAPROFILER__QUIET="false" \
    -e ZYMTRACE_CUDAPROFILER__ENABLE_PC_SAMPLING="true" \
    -e CUDA_INJECTION64_PATH="/opt/zymtrace/profiler/libzymtracecudaprofiler.so" \
    -e VLLM_ATTENTION_BACKEND="TRITON_ATTN_VLLM_V1" \
    -p 8000:8000 \
    --ipc=host \
    --name vllm-gpt-oss \
    vllm/vllm-openai:gptoss \
    --model openai/gpt-oss-20b
```

Notes for vLLM specifically:
- `--gpus "device=MIG-<UUID>"` — targets a **specific MIG slice** instead of a whole GPU. Get UUIDs with `nvidia-smi -L`. Use `--gpus all` for a full GPU.
- `VLLM_ATTENTION_BACKEND="TRITON_ATTN_VLLM_V1"` — switches vLLM to Triton attention kernels. These give cleaner per-kernel profiling than FlashAttention (which obscures internals).
- No `--shm-size` flag — vLLM uses `--ipc=host` directly without needing the size bump.
- Port 8000 is the vLLM default (compare SGLang's 30000).

#### Concrete Kubernetes example — vLLM DeepSeek-R1 on GKE

Full manifest with profiler volume mount, env vars, and a sidecar load generator for demos:

- <https://gist.github.com/iogbole/0060415b87d6d8ecff8cdc4b5a3143e4>

The pod-spec pattern that applies to any container-based GPU workload:

```yaml
spec:
  hostIPC: true                     # required for vLLM, SGLang, and most inference servers
  containers:
  - name: workload
    image: vllm/vllm-openai:latest
    securityContext:
      privileged: true              # required if PC sampling on; inference servers also benefit for shared memory
    env:
    - name: CUDA_INJECTION64_PATH
      value: "/var/lib/zymtrace/profiler/libzymtracecudaprofiler.so"
    # Optional tuning:
    - name: RUST_LOG
      value: "zymtracecudaprofiler=info"
    - name: ZYMTRACE_CUDAPROFILER__PRINT_STATS
      value: "true"
    - name: ZYMTRACE_CUDAPROFILER__QUIET
      value: "false"
    volumeMounts:
    - name: zymtrace-profiler
      mountPath: /var/lib/zymtrace/profiler
      readOnly: true
  volumes:
  - name: zymtrace-profiler
    hostPath:
      path: /var/lib/zymtrace/profiler
      type: Directory
```

Authoritative doc with more framework examples: <https://docs.zymtrace.com/install/profiler/cuda-gpu-profiler>.

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
| GPU metrics | **off** by default — needs explicit `--enable-gpu-metrics` | `ZYMTRACE_ENABLE_GPU_METRICS=true` | |

Disable framework metrics only if you don't want them in the UI; the overhead is negligible.

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
- CUDA workload setup: <https://docs.zymtrace.com/install/profiler/cuda-gpu-profiler>
- Resource guide: <https://docs.zymtrace.com/install/profiler/profiler-resource-guide>
- CLI args + env: <https://docs.zymtrace.com/profiler-configuration>
- GPU env vars: <https://docs.zymtrace.com/profiler-gpu-variables>
- GPU metrics: <https://docs.zymtrace.com/gpu/gpu-metrics>
- MIG: <https://docs.zymtrace.com/gpu/mig-support>
- Multi-GPU: <https://docs.zymtrace.com/gpu/multi-gpu>

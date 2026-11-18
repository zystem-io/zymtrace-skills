# Canonical References

When a skill needs source-of-truth content (docs, chart values, compose files), look it up here. Use `WebFetch` to read.

**Can't find the right page?** The docs publish an index for agents: <https://docs.zymtrace.com/llms.txt> (every page with a one-line summary). <https://docs.zymtrace.com/llms-full.txt> has the full text of every page.

## zymtrace Backend (Helm chart + Docker Compose)

### Helm chart — [`zystem-io/zymtrace-charts`](https://github.com/zystem-io/zymtrace-charts/tree/main/charts)
- **values.yaml** (source of truth for every key the backend accepts)
  <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/backend/values.yaml>
- **Chart README** (install/upgrade commands, values reference table)
  <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/backend/README.md>
- **Templates** browse:
  <https://github.com/zystem-io/zymtrace-charts/tree/main/charts/backend/templates>

### Docker Compose
- Versioned download (pins to a release):
  `https://dl.zystem.io/zymtrace/<VERSION>/noarch/docker-compose.yml`

### Backend install docs (`docs.zymtrace.com`)
| Topic | URL |
|-------|-----|
| Prerequisites | https://docs.zymtrace.com/install/prerequisites |
| Helm & Docker | https://docs.zymtrace.com/install/backend/helm-docker |
| Service Ingress | https://docs.zymtrace.com/install/backend/ingress |
| mTLS | https://docs.zymtrace.com/install/backend/mtls |
| Storage overview | https://docs.zymtrace.com/install/backend/config-storage |
| HPA | https://docs.zymtrace.com/install/backend/hpa |
| Custom registry (air-gapped) | https://docs.zymtrace.com/install/custom-registry |
| Changelog — latest release + what changed (fallback for the latest version when `helm search` / the repo is unavailable) | https://docs.zymtrace.com/changelog |

### Database & auth docs (referenced from install flows)
| Topic | URL |
|-------|-----|
| Architecture | https://docs.zymtrace.com/architecture |
| ClickHouse | https://docs.zymtrace.com/databases/clickhouse |
| Postgres | https://docs.zymtrace.com/databases/postgres |
| Object storage | https://docs.zymtrace.com/databases/object-storage |
| Authentication | https://docs.zymtrace.com/authentication/overview |

### Profiler & profiling features (`docs.zymtrace.com`)
| Topic | URL |
|-------|-----|
| JVM memory allocation profiling (enable + config) | https://docs.zymtrace.com/allocation-profiling |
| Off-CPU profiling (enable + read) | https://docs.zymtrace.com/features/off-cpu-profiling |
| GPU workloads (CUDA injection, automatic injection via the UI, ROCm) | https://docs.zymtrace.com/install/profiler/profiling-gpu-workloads |
| GPU profiler env vars (CUDA and ROCm) | https://docs.zymtrace.com/install/profiler/profiler-gpu-variables |
| Inference engines overview (CUDA/HIP graphs, PC sampling, verification) | https://docs.zymtrace.com/install/profiler/profiling-inference-engines |
| vLLM (NVIDIA + AMD) | https://docs.zymtrace.com/install/profiler/profiling-inference-engines/vllm |
| SGLang (NVIDIA + AMD) | https://docs.zymtrace.com/install/profiler/profiling-inference-engines/sglang |
| NVIDIA Dynamo-Triton | https://docs.zymtrace.com/install/profiler/profiling-inference-engines/dynamo-triton |
| TensorRT-LLM | https://docs.zymtrace.com/install/profiler/profiling-inference-engines/tensorrt-llm |
| Inference server metrics | https://docs.zymtrace.com/gpu/inference-server-metrics |
| AMD GPU metrics & profiles | https://docs.zymtrace.com/gpu/amd/gpu-metrics |
| Metrics reference (every metric + dashboard) | https://docs.zymtrace.com/gpu/metrics-reference |
| GPU Straggler Detector (enable NCCL metrics, stragglers, slow collectives, causes) | https://docs.zymtrace.com/gpu/nvidia/nccl |
| NCCL metrics (every key and attribute) | https://docs.zymtrace.com/gpu/metrics-reference#nccl |
| Model shapes (enable, Models page, Model Layer frames, limitations) | https://docs.zymtrace.com/gpu/models |
| GPU Timeline (high-resolution profiling, reading the timeline) | https://docs.zymtrace.com/gpu/nvidia/timeline |

### Analysis features in the UI (`docs.zymtrace.com`)
| Topic | URL |
|-------|-----|
| Recommendations (AI-generated reports, settings) | https://docs.zymtrace.com/features/recommendations |
| K8s Resource IQ (Kubernetes request/limit right-sizing) | https://docs.zymtrace.com/features/right-sizing |
| GPU Topology (NVLink, ECC/XID, NUMA placement) | https://docs.zymtrace.com/features/gpu-topology |
| AI Assistant (in-app) | https://docs.zymtrace.com/ai-assistant/using-ai-assistant |
| Public REST API spec of an instance (agent config, timeline pattern API, …) | `<gateway-url>/api-docs/openapi.json` |

### Feature write-ups with worked examples (`zymtrace.com`)
| Topic | URL |
|-------|-----|
| GPU Straggler Detector — sequence-length and throttled-GPU stragglers, from detection to fix | https://zymtrace.com/article/gpu-straggler-detector/ |
| Model-aware GPU profiling — a misaligned output layer found through Model Layer frames | https://zymtrace.com/article/model-aware-gpu-profiling/ |
| GPU execution timeline — gaps, copies and drift in an embedding workload (568 s → 82 s) | https://zymtrace.com/article/gpu-timeline/ |

### Public images & artifacts
- Backend services: `ghcr.io/zystem-io/zymtrace-pub-backend:<VERSION>` (also `docker.io/zystemio/zymtrace-pub-backend`)
- UI: `ghcr.io/zystem-io/zymtrace-pub-ui:<VERSION>`
- Helm repo: `https://helm.zystem.io` (chart name: `zymtrace/backend`)
- Versioned binary download root: `https://dl.zystem.io/zymtrace/<VERSION>/`
- Image catalog: <https://hub.docker.com/u/zystemio> · <https://github.com/orgs/zystem-io/packages>

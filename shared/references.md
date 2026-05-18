# Canonical References

When a skill needs source-of-truth content (docs, chart values, compose files), look it up here. Use `WebFetch` to read.

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

### Database & auth docs (referenced from install flows)
| Topic | URL |
|-------|-----|
| Architecture | https://docs.zymtrace.com/architecture |
| ClickHouse | https://docs.zymtrace.com/databases/clickhouse |
| Postgres | https://docs.zymtrace.com/databases/postgres |
| Object storage | https://docs.zymtrace.com/databases/object-storage |
| Authentication | https://docs.zymtrace.com/authentication |

### Public images & artifacts
- Backend services: `ghcr.io/zystem-io/zymtrace-pub-backend:<VERSION>` (also `docker.io/zystemio/zymtrace-pub-backend`)
- UI: `ghcr.io/zystem-io/zymtrace-pub-ui:<VERSION>`
- Helm repo: `https://helm.zystem.io` (chart name: `zymtrace/backend`)
- Versioned binary download root: `https://dl.zystem.io/zymtrace/<VERSION>/`
- Image catalog: <https://hub.docker.com/u/zystemio> · <https://github.com/orgs/zystem-io/packages>

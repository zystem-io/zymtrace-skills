# install-zymtrace-backend — Reference

Detailed material the SKILL.md links to but does not inline. Read on demand.

---

## License placement

zymtrace tiers:

| Tier | Needs key? | Includes |
|------|-----------|----------|
| **Free** | No | CPU profiling — install and run without any key. |
| **GPU trial** (generous, long-running) | Yes | CPU + GPU profiling. Ask the team for one. |
| **Paid** | Yes | Full features, support, higher limits. |

Where to get a GPU trial key:
- Sign up: <https://zymtrace.com/getstarted/>
- Community Slack: <https://join.slack.com/t/zymtrace/shared_invite/zt-3fdidjufl-q~NHxDzQlzal2B9mujfaoQ>
- Email: <support@zymtrace.com>

Once they have a key, decide where it lives:
- **Inline** → set `global.licenseKey` in their values file. Fine for dev/PoC.
- **Kubernetes secret (recommended for prod)** → set `global.licenseKeySecretName` and `global.licenseKeySecretKey`. The chart does **not** pre-check that the secret exists; if missing, pods fail at startup — Step 5 verification catches this.

CPU-only deployments: leave `global.licenseKey` empty and proceed.

---

## Creating secrets

Use these imperatively — never write the values into YAML manifests, the values file, or the conversation.

### License key
```bash
kubectl create namespace zymtrace
kubectl create secret generic zymtrace-license \
  --namespace zymtrace \
  --from-literal=license-key="<paste-key>"
```

### OIDC client secret (only if `auth.type: oidc`)
```bash
kubectl create secret generic oidc-creds \
  --namespace zymtrace \
  --from-literal=client-secret="<paste-secret>"
```

### Admin password (only if `auth.type: local`)
```bash
kubectl create secret generic zymtrace-admin \
  --namespace zymtrace \
  --from-literal=admin-password="<paste-password>"
```

### Ed25519 signing keys (only if `auth.type: local` or `oidc`)
```bash
openssl genpkey -algorithm ED25519 -out /tmp/private.pem
openssl pkey -in /tmp/private.pem -pubout -out /tmp/public.pem
kubectl create secret generic zymtrace-signing-keys \
  --namespace zymtrace \
  --from-file=private-key=/tmp/private.pem \
  --from-file=public-key=/tmp/public.pem
rm /tmp/private.pem /tmp/public.pem
```

### Database credentials (only for `use_existing` external DBs)
```bash
kubectl create secret generic clickhouse-creds \
  --namespace zymtrace --from-literal=password="<paste>"

kubectl create secret generic postgres-creds \
  --namespace zymtrace --from-literal=password="<paste>"

kubectl create secret generic s3-creds \
  --namespace zymtrace \
  --from-literal=access-key="<paste>" \
  --from-literal=secret-key="<paste>"
```

---

## Why always reset-then-reuse-values

Add the flag to every `helm upgrade --install` and `helm upgrade` for this chart, including the first install.

- Safe on first install (no prior values to reuse, so it's a no-op).
- Values from `-f <values-file>` still take precedence — the flag does not override your file.
- The flag is the only thing standing between a partial `--set` upgrade (e.g., bumping an image tag) and silent reset of every other value to chart defaults. Resetting `licenseKey`, `clickhouse.use_existing.host`, or `auth.*` to default = production outage.

The chart's own README is permissive (`--reuse-values` only when `--set`); this skill is stricter on purpose.

---

## Docker Compose install

Use case: laptop / PoC / single VM. No HA, no ingress story, no GPU profiling at scale.

1. Download the compose file (pin to a specific version):
   ```bash
   mkdir zymtrace && cd zymtrace
   curl -LO https://dl.zystem.io/zymtrace/<VERSION>/noarch/docker-compose.yml
   ```
   Versioned download root: <https://dl.zystem.io/zymtrace/>

2. Set the license (optional — free tier works without):
   ```bash
   echo 'ZYMTRACE_LICENSE_KEY="paste-key-here"' > .env
   ```

3. Start:
   ```bash
   docker compose up -d --remove-orphans
   ```

4. Endpoints:
   - UI: `http://localhost:8080`
   - Ingest gRPC: `127.0.0.1:8375` (profiler agents target this with `--disable-tls`)

5. Verify:
   ```bash
   docker compose ps
   docker compose logs --tail=30 web
   docker compose logs --tail=30 ingest
   ```

Services in the compose file: `migrate`, `clickhouse`, `psql`, `minio`, `createbuckets`, `ingest`, `identity`, `web`, `symdb`, `ui`.

---

## Air-gapped install

If the user mentions air-gapped, JFrog, internal Artifactory, or no Docker Hub access:

1. **Mirror images** into the internal registry. Required at minimum:
   - `zymtrace-pub-backend`
   - `zymtrace-pub-ui`

   Also required if any database is in `mode: create`:
   - `clickhouse-server`
   - `postgres`
   - `minio`

   Source registries:
   - `ghcr.io/zystem-io/zymtrace-pub-backend:<VERSION>`
   - `ghcr.io/zystem-io/zymtrace-pub-ui:<VERSION>`
   - `docker.io/clickhouse/clickhouse-server:<VERSION>`
   - `docker.io/postgres:<VERSION>`
   - `docker.io/minio/minio:<VERSION>`

2. **Point the chart at the mirror.** In the values file:
   ```yaml
   global:
     imageRegistry: "<your-registry>"        # for DB/storage images
     appImageRegistry: "<your-registry>"     # for zymtrace backend images
     registry:
       requirePullSecret: true
       username: "<set via --set on CLI, not values file>"
       password: "<set via --set on CLI, not values file>"
   ```

3. **Create a pull secret** if the registry needs auth — the chart can create one for you via `--set global.registry.username=… --set global.registry.password=…`, OR you can pre-create your own and reference it.

4. Full doc: <https://docs.zymtrace.com/install/custom-registry>

---

## mTLS setup

mTLS provides bidirectional auth between profiler agents and the gateway, using client certificates signed by your CA. The gateway's Envoy proxy terminates TLS and validates the client cert.

### Prerequisites
- CA certificate + private key (signs both server and client certs).
- Server certificate + private key for the gateway.
- Per-client certificates for each agent group.
- Ingress controller with **SSL passthrough** support — NGINX or Traefik. **AWS ALB does not support SSL passthrough**; use NGINX in front of ALB if you need both.

### Enable on NGINX
SSL passthrough must be enabled on the controller (not just the ingress):
```bash
kubectl patch configmap nginx-configuration -n ingress-nginx \
  --patch '{"data":{"enable-ssl-passthrough":"true"}}'
```
Or via Helm:
```bash
helm upgrade nginx-ingress ingress-nginx/ingress-nginx -n ingress-nginx \
  --set controller.extraArgs.enable-ssl-passthrough=true
```

### Values
Two hosts: regular ingress (`zymtrace.example.com`) for UI/non-mTLS clients, plus mTLS ingress (`mtls.zymtrace.example.com`) for agents. They **must be different hostnames**.

```yaml
services:
  gateway:
    mtls:
      enabled: true
      # Prefer --set-file on CLI rather than inlining cert/key/ca:
      # --set-file services.gateway.mtls.cert=server.crt
      # --set-file services.gateway.mtls.key=server.key
      # --set-file services.gateway.mtls.ca=ca.crt
      port: 9090

ingress:
  enabled: true
  hosts:
    gateway:
      enabled: true
      host: "zymtrace.example.com"
      mtls:
        enabled: true
        host: "mtls.zymtrace.example.com"
        annotations:
          nginx.ingress.kubernetes.io/ssl-passthrough: "true"
          nginx.ingress.kubernetes.io/proxy-body-size: "0"
```

### Verify
```bash
kubectl get ingress -n zymtrace
# Expect both zymtrace-gateway-ingress and zymtrace-gateway-ingress-mtls

curl --cacert ca.crt --cert client.crt --key client.key \
  https://mtls.zymtrace.example.com/health
```

Full doc: <https://docs.zymtrace.com/install/backend/mtls>

---

## Exposure (Ingress / LoadBalancer / NodePort)

Exposure decisions live in the [`expose-zymtrace-backend`](../../expose-zymtrace-backend/SKILL.md) skill — including the ALB HTTP2 quirk, ACM cert handling, NGINX cert-manager TLS, and NodePort. This skill no longer carries duplicate exposure templates.

---

## Sources

- Helm charts: <https://github.com/zystem-io/zymtrace-charts/tree/main/charts>
- Live `values.yaml`: <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/backend/values.yaml>
- Docs : <https://docs.zymtrace.com>
- Helm repo: `helm repo add zymtrace https://helm.zystem.io`
- Docker compose : `https://dl.zystem.io/zymtrace/<VERSION>/`
- Full URL map: [`shared/references.md`](../../shared/references.md)

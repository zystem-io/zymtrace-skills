---
name: expose-zymtrace-backend
description: |
  Use when configuring external/internal network exposure for an already-installed zymtrace backend — adding NodePort, LoadBalancer, or Ingress (NGINX or AWS ALB) with TLS. Edits the customer's canonical values file in place and applies via `helm upgrade --install`.
  Trigger phrases: "expose zymtrace", "expose the gateway", "make zymtrace accessible", "add ingress to zymtrace", "set up ALB for zymtrace", "internal ALB for zymtrace", "set up NGINX ingress for zymtrace", "add TLS to zymtrace", "get a real hostname for zymtrace", "add NodePort to zymtrace", "connect agents from another cluster".
metadata:
  version: "26.5.0"
  author: zymtrace
  repository: https://github.com/zystem-io/zymtrace-skills
  tags: zymtrace,kubernetes,helm,ingress,nodeport,loadbalancer,tls,alb,nginx
  tools: helm,kubectl,curl,aws
---

# Expose zymtrace Backend

Helps the user expose the gateway service externally. The zymtrace gateway is the single external surface — UI, ingest (gRPC), and symdb (HTTP) all flow through it.

Deep details (LoadBalancer one-liner, ACM cert lookup, cert-manager) live in [`reference.md`](reference.md).

> Backend must already be installed (`helm list -A | grep -i zymtrace` shows a release). If not, use `install-zymtrace-backend`.

## Sources of truth

- Live chart `values.yaml` (ingress + gateway service keys): <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/backend/values.yaml>
- Ingress doc: <https://docs.zymtrace.com/install/backend/ingress>

## Pre-flight: verify the tools

##### Claude runs
```bash
helm version --short && kubectl version --client
kubectl cluster-info | head -2
helm list -A | grep -i zymtrace
kubectl get ingressclass
```

If `helm`/`kubectl` are missing → point to install docs; do **not** install them. If no zymtrace release exists → wrong skill, route to `install-zymtrace-backend`.

## Pre-resolve what you can

> **Resolve namespace + release name first.** Recommended defaults `zymtrace` / `backend`; for an existing release use *its* namespace and name. Full policy: [`shared/conventions.md`](../../shared/conventions.md). Commands use `<NS>` and `<REL>` as placeholders.

| Variable | Resolve by |
|---|---|
| Existing release | `helm list -A \| grep -i zymtrace` (one match → use it; multiple → ask) |
| Current values (so we layer onto them) | `helm get values <REL> -n <NS> > current-values.yaml` |
| Available ingress controllers | `kubectl get ingressclass` (`alb` / `nginx` / `traefik`) |
| AWS LBC installed? | `kubectl get deploy -n kube-system aws-load-balancer-controller` |
| Cloud / region (for ACM cert lookup) | `kubectl config current-context` → ARN parts; or `aws configure get region` |
| Existing ingress in this NS | `kubectl get ingress -n <NS>` |

Things you **must** ask:
- Which exposure mode (table below)?
- Hostname (for ingress paths).
- TLS source (ACM cert ARN for ALB / cert-manager issuer for NGINX / existing TLS secret).

## Decision table

Pick the row that fits, then go to **Standard flow** below.

| Mode | Template / how | When |
|------|----------------|------|
| **ClusterIP** (default) | Already done. `kubectl port-forward -n <NS> svc/<PREFIX>-gateway 8080:80` | Dev / verify only. No external exposure. |
| **NodePort** | [`values/nodeport.yaml`](values/nodeport.yaml) | PoC, on-prem clusters with no cloud LB. No TLS. |
| **LoadBalancer (cloud LB)** | `--set services.gateway.service.type=LoadBalancer` (no dedicated template) — see [reference.md § LoadBalancer one-liner](reference.md#loadbalancer-one-liner) | Rare. Most prod paths use Ingress instead because of cost + routing flexibility. |
| **Ingress: NGINX + TLS** | [`values/ingress-nginx.yaml`](values/ingress-nginx.yaml) | On-prem / non-AWS k8s with NGINX controller. cert-manager TLS. |
| **Ingress: AWS ALB + TLS** | [`values/ingress-alb.yaml`](values/ingress-alb.yaml) | EKS. HTTPS via ACM (required). Internal or internet-facing via annotation toggle. |

> **ALB is HTTPS-only.** Never propose HTTP-only ALB exposure, including internal-scheme ALBs. The template always requires an ACM cert ARN.

> **gRPC backend-protocol depends on the controller.** NGINX/Traefik → `backend-protocol: "GRPC"`. ALB → `backend-protocol: HTTP` + `backend-protocol-version: HTTP2` (the [464 trap](reference.md#alb-http2-quirk)).

---

## Standard flow

### Step 1: Resolve the canonical values file

First ask: **does the customer already have a values file for this release?**

- **Yes** → use the **filename they give you** for the rest of this flow (e.g. `acme-zymtrace.yaml`, `backend-values.yaml`). Don't rename — their CI scripts and git history reference that name.
- **No** → seed `zymtrace-custom-values.yaml` from the live release. From then on it's canonical.

##### Claude runs (only if the customer doesn't have a file)
```bash
helm get values <REL> -n <NS> > zymtrace-custom-values.yaml
cat zymtrace-custom-values.yaml
```

See [`shared/conventions.md`](../../shared/conventions.md) for the full rule. Use `<values-file>` below as a placeholder for whichever filename you settled on.

### Step 2: Back up, then edit the canonical file in place

**Before any edit**, take a timestamped backup so the customer can revert if anything goes wrong:

##### Claude runs
```bash
cp <values-file> <values-file>.bak.$(date +%Y%m%d-%H%M%S)
```

Tell the user the backup path. See [`shared/conventions.md` § Always back up before writing](../../shared/conventions.md).

Then use the matching template in `values/` as a **reference snippet** — not a separate file. Read it, then edit the customer's canonical file directly to add or replace the `ingress:` block (and `services.gateway.service:` if NodePort).

Things to customize while editing:
- Hostname (`ingress.hosts.gateway.host`).
- ACM ARN (`alb.ingress.kubernetes.io/certificate-arn`) for ALB.
- ClusterIssuer name for NGINX (defaults to `letsencrypt-prod`).
- Scheme toggle for ALB (`internal` ↔ `internet-facing`).

**Show the diff to the user and get confirmation before saving.** If the customer has comments / ordering in their file, preserve them — targeted insert/replace, not a wholesale rewrite.

If the canonical file already has an `ingress:` block, replace it (don't append a duplicate key).

### Step 3: Refresh the Helm repo

##### Claude runs
```bash
helm repo update zymtrace
```

Mandatory before any helm upgrade — see [`shared/conventions.md`](../../shared/conventions.md).

### Step 4: Confirm with the user before running

Print the exact command + the resolved values (release name, namespace, canonical values-file path, target hostname, TLS source). **Wait for explicit confirmation.** Do not run on assumed consent.

### Step 5: Apply

##### Claude runs
```bash
helm upgrade --install <REL> zymtrace/backend \
  --namespace <NS> \
  -f <values-file> \
  --reset-then-reuse-values \
  --atomic --debug
```

Single `-f` — the canonical file already contains the new ingress block from Step 2. `--atomic` rolls back the helm release on failure; the file edit from Step 2 stays on disk (git lets the user revert it if needed).

ERROR: `failed pre-install: timed out waiting for the condition` — usually means the ALB / NGINX LB isn't provisioning. Check:
- AWS LBC logs: `kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50`.
- Ingress events: `kubectl describe ingress -n <NS>`.
- Subnet auto-discovery tags: subnets need `kubernetes.io/role/internal-elb=1` (internal) or `kubernetes.io/role/elb=1` (internet-facing).

ERROR: ALB returns HTTP 464 to your `curl` — you set `backend-protocol: GRPC` instead of `backend-protocol: HTTP` + `backend-protocol-version: HTTP2`. Fix and re-apply.

ERROR: TLS cert mismatch (`ssl_error_bad_cert_domain` in browser) — ACM cert CN/SAN doesn't include the hostname you set under `hosts.gateway.host`. Issue a new ACM cert or use a hostname that matches.

### Step 6: Verify

##### Claude runs
```bash
./scripts/verify-exposure.sh <NS> <REL>
```

Checks: ingress address resolves, TLS handshake succeeds (if TLS), gateway HTTP probe returns a non-5xx response, agent gRPC port is reachable.

### Step 7: Recommend the commit

The canonical `<values-file>` already reflects the deployed state (Step 2 edited it, Step 5 applied it, Step 6 verified it). Recommend the user commit:

```bash
git add <values-file>
git commit -m "zymtrace: add <controller> exposure for <NS>/<REL>"
```

No `helm get values` refresh needed — the file you edited *is* the source of truth.

---

## Done

Exit when ALL of the following are true (substitute `<NS>` / `<REL>` / `<PREFIX>`):

- [ ] `helm status <REL> -n <NS>` reports `STATUS: deployed` and `REVISION` incremented.
- [ ] For ingress: `kubectl get ingress -n <NS>` shows a populated `ADDRESS` column (FQDN or IP — may take 1–3 min for cloud LBs).
- [ ] For NodePort: `kubectl get svc -n <NS> <PREFIX>-gateway` shows `NodePort` and a port in 30000-32767.
- [ ] For ingress with TLS: `curl -fsI https://<host>` returns 2xx/3xx/4xx (not connection-refused / cert error / 5xx).
- [ ] DNS resolves (if a hostname was set): `dig +short <host>` returns the LB address.
- [ ] Agent-path smoke test: `grpcurl -insecure <host>:443 list` (or equivalent) reaches the gateway's gRPC listener. (Optional but recommended before pointing agents at the new exposure.)

## Common pitfalls

- **NGINX without `backend-protocol: "GRPC"`** → UI works, profiler agents can't push. Always set it.
- **ALB with `backend-protocol: GRPC`** → HTTP 464 for UI/health checks. Use `HTTP` + `backend-protocol-version: HTTP2`. See [reference.md](reference.md#alb-http2-quirk).
- **`proxy-body-size` unset or too small** → symbol uploads fail silently.
- **NodePort + OIDC without explicit `redirectUri`** → OAuth callback fails because chart can't auto-derive the URL. Set it in the canonical values file when adding NodePort.
- **Subnet tagging** for AWS LBC — internal needs `kubernetes.io/role/internal-elb=1` on private subnets; external needs `kubernetes.io/role/elb=1` on public subnets. Missing tags = LB never provisions.
- **ACM cert in wrong region** — must be the same region as the EKS cluster. Cross-region cert refs are ignored.

---

## Security constraints

- **Never** propose HTTP-only ALB exposure, including internal-scheme ALBs — ALB is HTTPS-only in this skill. Always require an ACM cert ARN.
- **Never** issue `helm upgrade` / `helm upgrade --install` for this chart without `--reset-then-reuse-values`. See [`shared/conventions.md`](../../shared/conventions.md).
- **Never** create overlay / temporary values files alongside the canonical one. Edit the canonical file in place; helm only ever takes one `-f <values-file>`.
- **Never** run `helm repo update` against the wrong repo or skip it before the upgrade. Stale cache → wrong chart version pulled.
- **Never** apply without explicit user confirmation showing the resolved command, hostname, TLS source, and the diff of the Step 2 edit.
- **Never** rely on NodePort for production exposure — no TLS, no host routing, ports collide.
- **Never** skip Step 6 verification. An ingress with an empty `ADDRESS` column is not exposed.

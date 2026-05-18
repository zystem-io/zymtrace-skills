---
name: install-zymtrace-backend
description: |
  Use when installing the zymtrace backend (the AI optimization platform that ingests CPU/GPU profiling data). Covers Kubernetes (Helm) and single-node Docker Compose. Handles license setup, choosing in-cluster vs external ClickHouse/Postgres/object storage, ingress with gRPC and TLS, and air-gapped installs via a custom image registry.
  Trigger phrases: "install zymtrace", "install zymtrace backend", "deploy zymtrace", "set up zymtrace on kubernetes", "set up zymtrace on EKS / GKE / AKS / on-prem", "helm install zymtrace", "docker compose zymtrace", "stand up the zymtrace platform", "first zymtrace install", "deploy the backend services".
metadata:
  version: "26.5.0"
  author: zymtrace
  repository: https://github.com/zystem-io/zymtrace-skills
  tags: zymtrace,profiling,kubernetes,helm,docker-compose,install,backend
  tools: helm,kubectl,curl,docker
---

# Install zymtrace Backend

Helps the user install the zymtrace **backend** — gateway, ingest, web, symdb, identity, UI, migrate, plus data stores (ClickHouse, Postgres, S3-compatible object storage).

> The profiler agent is a separate install (`install-zymtrace-profiler` skill). This skill is only the backend that receives data.

Deep details, secret-creation commands, Docker Compose, and air-gapped live in [`reference.md`](reference.md) — read it when the decision tree points you there.

## Greet the user (start here)

Before any commands or questions, open with a warm welcome. Adapt to context, but always cover: a thank-you, the support channels, and a quick map of what's coming. Sample:

> 👋 Thanks for choosing **zymtrace**! I'll walk you through installing the backend — the platform that ingests your CPU/GPU profiling data, surfaces optimization insights, and serves the UI.
>
> **If you get stuck at any point, reach out:**
> - Community Slack: <https://join.slack.com/t/zymtrace/shared_invite/zt-3fdidjufl-q~NHxDzQlzal2B9mujfaoQ>
> - Email: <support@zymtrace.com>
> - Sign up / GPU trial license: <https://zymtrace.com/getstarted/>
>
> **Tip — analyze GPU and CPU flamegraphs via MCP:** once zymtrace is running, run `/mcp` in this Claude Code session to connect to the zymtrace MCP server and analyze GPU + CPU flamegraphs from this terminal. Docs: <https://docs.zymtrace.com/mcp>
>
> **Here's the plan:**
> 1. Verify your tools (`helm`, `kubectl`) and resolve cluster / namespace.
> 2. Check whether you already have a values file — if not, we'll build one together.
> 3. Install, verify, then start a quick port-forward so you can see the UI right away.
> 4. Decide on long-term exposure (NodePort / ALB / NGINX / Cloud LB).
> 5. Hand off to the profiler install so you have data to look at.
>
> Ready when you are — let's start.

Trim the greeting if the user has already given you specifics (cluster, values file, target version). Always include the support links **once** per session.

## Sources of truth (never invent keys)

- Live chart `values.yaml` (every key is documented inline): <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/backend/values.yaml>
- Docs: <https://docs.zymtrace.com/install/backend/helm-docker> (no public source repo — fetch URLs)
- Full URL map: [`shared/references.md`](../../shared/references.md)

## Pre-flight: verify the tools

**Do not run any install command until both binaries are confirmed installed.**

##### Claude runs
```bash
helm version --short && kubectl version --client
kubectl cluster-info | head -2
```

If `helm` is missing → point user to <https://helm.sh/docs/intro/install/>. Do **not** offer to install it. Same rule for `kubectl` → <https://kubernetes.io/docs/tasks/tools/>. If `kubectl cluster-info` fails, ask the user to set their kubeconfig.

## Check for a customer-provided values file

**Before walking the decision tree, ask:**

> Did Zymtrace send you a values file (often named `custom-values.yaml`, `backend-values.yaml`, or `<company>-values.yaml`)? It usually contains your license, DB modes, and other pre-agreed settings.

If yes → read it, skip any decision-tree question whose answer is already set in the file, and go directly to Step 4 with `-f <their-file>`. Full policy: [`shared/conventions.md` § Customer-provided values file](../../shared/conventions.md#customer-provided-values-file).

If no → walk the decision tree below; at the end, write the result to `./custom-values.yaml` and tell them to commit it to source control.

## Pre-resolve what you can

Before asking the user any question, resolve from the environment. Only ask when a check fails or returns ambiguous output.

> **Namespace + release name.** **Recommend `zymtrace` / `backend`** — these are the defaults in every doc and example, keep them unless the user has a specific reason to deviate. If a release already exists on the cluster, use *its* namespace and name. Full policy: [`shared/conventions.md`](../../shared/conventions.md). Commands below use `<NS>` and `<REL>` as placeholders; resolve before running.

| Variable | Resolve by |
|---|---|
| Current cluster context | `kubectl config current-context` |
| Existing zymtrace release? | `helm list -A \| grep -i zymtrace` |
| Latest chart version | `helm search repo zymtrace/backend --versions \| head -3` (after `helm repo add`) |
| Ingress controllers present | `kubectl get ingressclass` |
| Metrics-server (HPA prereq) | `kubectl top nodes` — returns metrics if installed, errors `Metrics API not available` if not. On EKS, do **not** confuse with `v1.metrics.eks.amazonaws.com` (EKS extension API, doesn't satisfy HPA). |
| Default storage class | `kubectl get sc` |

Things you **must** ask:
- Tier: free CPU-only / GPU trial / paid (licensing).
- DB modes for each of ClickHouse / Postgres / object storage.
- Domain + TLS arrangement (if production).
- Auth type and IdP details if OIDC.
- Scale tier (agent count + retention).
- Private/air-gapped registry?

## Blockers vs recommendations (don't conflate)

Tone matters. Frame findings precisely so the customer doesn't think they have an outage when they don't.

**Blockers** (stop the install, surface, ask the user to resolve first):
- `helm` or `kubectl` not installed.
- `kubectl cluster-info` fails.
- Referenced Kubernetes secret missing (chart will fail).
- Values file fails `helm template` (schema error / invalid YAML).
- Previous release is stuck in an in-progress state.

**Recommendations** (note in one short line, proceed):
- **Metrics-server not installed** with `hpa.enabled: true` → install succeeds, HPAs just won't scale. Customer can install metrics-server later.
- **License key inline** in values file → fine for dev/PoC. Recommend `licenseKeySecretName` for prod, don't block.
- **`auth.type: none`** → trusted-network installs run this way on purpose.
- **No ingress configured** → ClusterIP + port-forward is a valid temporary state; the expose skill adds ingress whenever the customer is ready.

Rule of thumb: if the operation will succeed but something is suboptimal, that's a **recommendation**, not a blocker. Phrase it as one short line, not a multi-bullet alarm.

## Decision tree

Walk these in order. Don't guess defaults — fetch the chart `values.yaml` when uncertain.

### 1. Platform

| Answer | Path |
|--------|------|
| Single node / eval / laptop | → see [reference.md § Docker Compose install](reference.md#docker-compose-install). Stop here, don't continue this tree. |
| Kubernetes (prod, staging, on-prem, GKE/EKS/AKS) | → continue. |

If unsure, default to Kubernetes — Docker Compose has no HA/ingress story.

### 2. License

- Free CPU-only tier needs **no key**.
- GPU trial / Paid: ask where to put it (inline vs Kubernetes secret). Recommend secret for prod.
- Where to get a trial key, tier table, and placement details: [reference.md § License placement](reference.md#license-placement).

### 3. Databases

zymtrace needs ClickHouse, Postgres, and S3-compatible object storage. Each has a `mode`:

| Mode | When to use |
|------|------------|
| `create` (default) | In-cluster, chart-managed. Fastest path. Fine for dev/PoC, viable for small prod. |
| `use_existing` | External (ClickHouse Cloud, on-prem CH, RDS, AWS S3, GCS, MinIO). Pick this if the org already runs managed DBs. |
| `aws_aurora` / `gcp_cloudsql` | Postgres only. IAM-authenticated. Requires IRSA (Aurora) or Workload Identity (CloudSQL). |

Ask which mode per service. Assemble from [`values/k8s-external-dbs.yaml`](values/k8s-external-dbs.yaml).

> ⚠️ Postgres `secure: true` needed for TLS-enforced managed Postgres. ClickHouse `use_existing.host` MUST be the scheme + HTTP port (`https://host:8443`) — **not** native 9000. Only the HTTP interface is supported.

### 4. Network exposure

Two paths:

- **Install without exposure** → leave `ingress.enabled: false` (default). Gateway becomes `ClusterIP`-only; the user can reach it via `kubectl port-forward` for verify, then add exposure later.
- **Install with exposure already configured** → hand off to the [`expose-zymtrace-backend`](../expose-zymtrace-backend/SKILL.md) skill for the exposure decision (NodePort / LoadBalancer / NGINX Ingress / ALB Ingress). That skill will edit the same canonical values file in place before this install proceeds.

Either way, exposure can be added or changed at any time via the expose skill — it doesn't have to be locked in at install.

### 5. Auth

- `none` — open access; trusted networks only.
- `local` — built-in user/password + admin user; requires Ed25519 signing keys.
- `oidc` — Google / Okta / Auth0 / Azure AD. Need `clientId`, `clientSecret`, `issuerUri`, registered redirect URI.

> **Don't propose `basic`** — deprecated and being removed.

Prod default: `oidc` if they have an IdP, else `local` with admin password from a secret.

### 6. Scale

How many agents will report, and what retention? Drives ClickHouse sizing more than anything else.

| Scale | Template |
|-------|----------|
| < 20 agents, < 14d | `k8s-minimal.yaml`. Defaults fine. |
| 20–100 agents, mixed CPU/GPU, 30d | [`values/k8s-large-scale.yaml`](values/k8s-large-scale.yaml). Bumped CH (500Gi, 2–6 CPU, up to 16Gi mem), tuned probes, HPA scale-down. |
| 100+ agents, multi-region, long retention | Combine `k8s-large-scale.yaml` + `k8s-external-dbs.yaml`. Externalize ClickHouse. |

Storage rule of thumb: **~5Gi per agent per 30 days** for mixed CPU+GPU. GPU-heavy agents produce ~5–8× the events of CPU-only.

### 7. Air-gapped / private registry

If mentioned: see [reference.md § Air-gapped install](reference.md#air-gapped-install). Mirror `zymtrace-pub-backend`, `zymtrace-pub-ui` (plus DB images if `mode: create`), then set `global.imageRegistry` + `global.appImageRegistry`.

---

## Kubernetes install (Helm)

### Prerequisites
- Kubernetes 1.20+, Helm 3.x.
- Metrics Server (only if HPA enabled — verify with `kubectl top nodes`, NOT just by listing APIServices on EKS).
- CNI with NetworkPolicy enforcement (Calico/Cilium/Weave). Plain Flannel → set `services.activateNetworkPolicies: false`.

### Step 1: Add the Helm repo

##### Claude runs
```bash
helm repo add zymtrace https://helm.zystem.io
helm repo update
helm search repo zymtrace/backend --versions | head -5
```

ERROR: `not a valid chart repository` → network/proxy issue, or air-gapped. Switch to the air-gapped path.

### Step 2: Pick a values template and customize

Pick one of these install bundles as the starting point for the customer's canonical values file:

- [`values/k8s-minimal.yaml`](values/k8s-minimal.yaml) — chart-managed DBs, NodePort, no auth. Fastest path for dev.
- [`values/k8s-external-dbs.yaml`](values/k8s-external-dbs.yaml) — external ClickHouse + Postgres + S3 (incl. Aurora / CloudSQL).
- [`values/k8s-large-scale.yaml`](values/k8s-large-scale.yaml) — 100+ agents, 30d retention, bumped CH, tuned probes.

Copy to the canonical filename (e.g. `zymtrace-custom-values.yaml` if the customer doesn't have one) and edit placeholders. **Need ingress now?** Run the [`expose-zymtrace-backend`](../expose-zymtrace-backend/SKILL.md) skill — it'll edit the same canonical file in place — then come back to Step 3 here.

### Step 3: Create secrets

##### What you need to do in a terminal

Secrets must be created by the user — never write license keys, OIDC client secrets, admin passwords, or DB passwords into the conversation or values files.

Create only the secrets your values file references. Command reference: [reference.md § Creating secrets](reference.md#creating-secrets).

Typical minimum for prod: `zymtrace-license`, plus one of `oidc-creds` / `zymtrace-admin`, plus `zymtrace-signing-keys` (auth=local/oidc).

The chart does **not** pre-check that referenced secrets exist — missing secrets surface as `CrashLoopBackOff` in Step 5.

### Step 4: Install

> `<REL>` and `<NS>` are placeholders for the resolved release name + namespace. **Recommended defaults: `backend` / `zymtrace`** — use them unless the user has a specific reason to deviate. Substitute before running.

##### Claude runs
```bash
helm upgrade --install <REL> zymtrace/backend \
  --namespace <NS> --create-namespace \
  -f <values-file>.yaml \
  --reset-then-reuse-values \
  --atomic --debug
```

`--reset-then-reuse-values` is **mandatory on every run for this chart**, including first install. Why: [reference.md § Why always reset-then-reuse-values](reference.md#why-always-reset-then-reuse-values).

`--atomic` rolls back on failure (avoids half-deployed state). `--debug` prints rendered manifests.

ERROR: `failed pre-install: timed out` → usually a missing secret. Run `kubectl get events -n <NS> --sort-by=.lastTimestamp | tail -20`, fix the secret per Step 3, re-run.

ERROR: `another operation … in progress` → a previous helm op is stuck. `helm history <REL> -n <NS>`; resolve with `helm rollback` or `helm uninstall` (destructive — confirm with the user first).

### Step 5: Verify

##### Claude runs
```bash
./scripts/verify-backend.sh <NS> <REL>
```

If the user has overridden `global.namePrefix`, also pass it: `PREFIX=<value> ./scripts/verify-backend.sh <NS> <REL>`.

Runs `helm status`, dumps `kubectl get` for pods/jobs/svc/ingress/hpa, dumps logs for each backend service, describes any non-Running pod. Use the Done checklist below as exit criteria — do not declare success until every box checks.

### Step 6: Persist the canonical values file

##### Claude runs
```bash
# Back up first if the file already exists (won't on a true greenfield install)
[ -f <values-file> ] && cp <values-file> <values-file>.bak.$(date +%Y%m%d-%H%M%S)

helm get values <REL> -n <NS> > <values-file>
```

`<values-file>` is whatever name the customer gave you in §0 / Pre-resolve (e.g. `acme-zymtrace.yaml`). If they didn't provide one, default to `zymtrace-custom-values.yaml` — that's now their canonical file. See [`shared/conventions.md`](../../shared/conventions.md) for the rules on respecting customer filenames and backing up before writing.

If a backup was created, tell the user the path. Recommend they commit the new canonical file: `git add <values-file> && git commit -m "zymtrace: capture <NS>/<REL> values after install"`.

### Step 7: Quick-win port-forward (let them see the UI now)

Once Done is satisfied, **offer to port-forward immediately** — this is the fastest way to give the customer a visible result before they commit to a long-term exposure decision.

> Want me to start a port-forward right now so you can open the UI? It runs in the background; you can switch to a permanent exposure (NodePort / LoadBalancer / Ingress) afterwards.

If yes:

##### Claude runs
```bash
kubectl port-forward -n <NS> svc/<PREFIX>-gateway 8080:80 > /tmp/zymtrace-pf.log 2>&1 &
echo "port-forward PID: $!"
sleep 2
curl -fsI http://localhost:8080 | head -1   # sanity check
```

Then tell them:

> The UI is at <http://localhost:8080>. To stop the port-forward later: `pkill -f 'kubectl port-forward.*<PREFIX>-gateway'`. If port 8080 is taken, change it to `8081:80` (or any free local port).

If no, skip to Step 8.

ERROR: `Unable to listen on port 8080: bind: address already in use` → pick another local port. Re-run with `8081:80` etc.

### Step 8: Ask how they want to expose the backend long-term

**Always ask** — don't assume port-forward is good enough.

| Option | When it fits |
|--------|-------------|
| **1. NodePort** | PoC, on-prem, no cloud LB available |
| **2. AWS ALB Ingress** (HTTPS via ACM) | EKS — internal or internet-facing |
| **3. NGINX Ingress** (TLS via cert-manager) | On-prem / non-AWS, or already running NGINX |
| **4. Cloud LoadBalancer** (direct NLB/CLB) | Rare; ask what they want before suggesting |

If they prefer to stick with port-forward for now → skip to Step 9.
For any of 1–4 → hand off to the [`expose-zymtrace-backend`](../expose-zymtrace-backend/SKILL.md) skill, which edits the canonical values file in place and applies via `helm upgrade --install`. Ask them to provide the hostname themselves — don't suggest a specific pattern. Once that completes, return here for Step 9.

### Step 9: Hand off to profiler install

The backend has no data until a profiler agent reports to it. Suggest the `install-zymtrace-profiler` skill next.

---

## Done

Exit when ALL of the following are true (substitute `<NS>` / `<REL>` / `<PREFIX>`):

- [ ] `helm status <REL> -n <NS>` reports `STATUS: deployed`.
- [ ] All pods in the `<NS>` namespace are `Running`.
- [ ] Migration succeeded — either `<PREFIX>-migrate` Job is at `1/1` succeeded, **or** the Job is absent (Helm `pre-install` hook auto-deletes on success). With `helm status STATUS: deployed`, absence is the expected state, not a failure.
- [ ] `<PREFIX>-gateway` service exists; if `ingress.enabled=true`, an Ingress object also exists.
- [ ] No license / auth / forbidden errors in `kubectl logs deployment/<PREFIX>-ingest -n <NS> --tail=50`.
- [ ] Gateway responds: `curl -fsI http://<host>` returns anything except connection-refused / timeout / 5xx.

If any box fails, hand off to the `troubleshoot-zymtrace-backend` skill, or use `scripts/verify-backend.sh` output.

## Common pitfalls

- **NGINX/Traefik missing `backend-protocol: "GRPC"`** → agents can't push profiles; UI may still work.
- **ALB set to GRPC backend** → HTTP/1.1 clients get HTTP 464. Use HTTP + HTTP2. See [reference.md](reference.md#alb-http2-quirk).
- **`proxy-body-size` unset / too small** → symbol uploads fail silently.
- **NodePort + OIDC** → `redirectUri` must be set explicitly (chart can't auto-derive) and registered with the IdP.
- **ClickHouse `use_existing.host` on native port `9000`** → ingest crashes. Use HTTP `8123`/`8443`.
- **`auth.admin.password=admin`** in prod → use `passwordSecretName`.
- **HPA on without metrics-server** (recommendation, **not a blocker**) → install succeeds; HPAs sit at `<unknown>/80%` and stay at `minReplicas`. Truth check: `kubectl top nodes`. To enable scaling later: `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml`. On EKS, `v1.metrics.eks.amazonaws.com` is **not** the metrics-server HPA needs — don't be fooled by it.

---

## Security constraints

- **Never** write a raw license key, OIDC client secret, admin password, or DB password into any values file, session message, or commit. Use `*SecretName` / `*SecretKey` and create the secret imperatively with `kubectl create secret`.
- **Never** generate a Kubernetes `Secret` YAML manifest from this skill — always `kubectl create secret generic …` so values never land on disk.
- **Never** use namespace `default` for zymtrace resources. Always pass `--namespace <NS>` with an explicit (non-`default`) namespace.
- **Never** run `helm uninstall`, `kubectl delete namespace`, `kubectl delete pvc`, or any operation that drops persistent data without explicit user confirmation.
- **Never** propose `auth.type: basic` — deprecated.
- **Never** issue `helm upgrade` or `helm upgrade --install` for this chart without `--reset-then-reuse-values` — even on first install, even with `-f`. The flag is harmless on a fresh install and is the only guard against silent data loss on subsequent partial `--set` upgrades.
- **Never** disable TLS in production (`--disable-tls` is fine for dev/NodePort only).
- **Never** skip Step 5 verification — pods can be `Running` while ingest is silently rejecting profiles.

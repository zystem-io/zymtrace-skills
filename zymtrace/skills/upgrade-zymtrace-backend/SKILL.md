---
name: upgrade-zymtrace-backend
description: |
  Use when upgrading a zymtrace backend that's already deployed via Helm. Covers image-tag-only bumps, chart-version bumps, and combined upgrades. Handles the migration job, --reset-then-reuse-values requirement, rollback when --atomic fails, and post-upgrade verification.
  Trigger phrases: "upgrade zymtrace", "upgrade zymtrace backend", "bump zymtrace version", "update zymtrace to 26.5.0 / latest", "helm upgrade zymtrace", "upgrade the chart", "bump backend image tag", "move zymtrace to a new release", "patch zymtrace", "roll back zymtrace upgrade".
metadata:
  version: "26.5.0"
  author: zymtrace
  repository: https://github.com/zystem-io/zymtrace-skills
  tags: zymtrace,profiling,kubernetes,helm,upgrade,backend
  tools: helm,kubectl,curl
---

# Upgrade zymtrace Backend

Helps the user upgrade an already-installed zymtrace backend. Three paths:

| Path | What changes | When to use |
|------|-------------|------------|
| **A. Image-only bump** | `services.common.imageTag` (and pulled image) | Apply a patch/hotfix on the same chart. Lowest risk. |
| **B. Chart version bump** | Helm chart version + templates + defaults | New chart features, schema additions, new config keys. |
| **C. Combined** | Chart + image together | The common case for moving between zymtrace minor/major releases. |

Deep details (backup, rollback, schema migrations, the `migrate` job) live in `${CLAUDE_PLUGIN_ROOT}/skills/upgrade-zymtrace-backend/reference.md`.

> Fresh install? Use the `install-zymtrace-backend` skill instead.

## Sources of truth

- Live `values.yaml`: <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/backend/values.yaml>
- Chart releases (versions & appVersions): `helm search repo zymtrace/backend --versions`
- Docs: <https://docs.zymtrace.com/install/backend/helm-docker>

## Pre-flight: verify the tools

##### Claude runs
```bash
helm version --short && kubectl version --client
kubectl cluster-info | head -2
helm list -A | grep -i zymtrace
```

If `helm`/`kubectl` are missing → point to install docs; do **not** install for them. If `helm list -A | grep -i zymtrace` shows no zymtrace release → wrong skill, route to `install-zymtrace-backend`.

## Check for a customer-provided values file

**Before any chart-version bump (Path B / C), ask:**

> Do you have the values file Zymtrace originally sent you (often named `custom-values.yaml`, `backend-values.yaml`, or `<company>-values.yaml`)?

If **yes** → use that file directly with `helm upgrade --install ... -f <their-file>`. Read it first to confirm it matches what's currently deployed (`helm get values <REL> -n <NS>`).

If **no** → reconstruct from the live release: `helm get values <REL> -n <NS> > values-current.yaml`. Note this captures only user-set values, not chart defaults (which is fine for `helm upgrade`).

Full policy: [`shared/conventions.md` § Customer-provided values file](../../shared/conventions.md#customer-provided-values-file).

For Path A (image-only bump) this check can be skipped — no values file is required.

## Pre-resolve what you can

> **Resolve namespace + release name first.** **Recommended defaults: `zymtrace` / `backend`.** For an existing release, use whatever namespace and name it lives under — confirm with `helm list -A | grep -i zymtrace`. Full policy: [`shared/conventions.md`](../../shared/conventions.md). The variables below use `<NS>` and `<REL>` as placeholders — substitute the resolved values.

| Variable | Resolve by |
|---|---|
| Namespace + release | `helm list -A \| grep -i zymtrace` (one row → use it; multiple → ask user) |
| Current chart version | `helm list -n <NS> -o yaml \| awk '/chart:/ {print $2}'` |
| Current revision (for rollback) | `helm history <REL> -n <NS>` |
| `global.namePrefix` (for kubectl resource names) | `helm get values <REL> -n <NS> \| awk '/^\s*namePrefix:/ {print $2}'` (default: `zymtrace`) |
| Current image tag | `kubectl get deploy <PREFIX>-ingest -n <NS> -o jsonpath='{.spec.template.spec.containers[0].image}'` |
| Available chart versions | `helm repo update && helm search repo zymtrace/backend --versions \| head -5` |
| `helm-diff` plugin? | `helm plugin list \| grep diff` (optional but useful) |
| Database modes (drives backup warning) | `helm get values <REL> -n <NS> \| grep -E 'mode:'` |

Things you **must** ask:
- Which path (A / B / C above)?
- Target chart version (if B or C).
- Target image tag (if A or C).
- Backup posture for in-cluster DBs (we surface a warning but do not block — see Step 2).

## Decision tree

### 1. Path selection

| Asked / inferred | Path |
|---|---|
| "Just bump to 26.5.0" with no chart context, current chart unchanged | A (image-only) |
| "Upgrade the chart" / "we want feature X added in chart Y.Z" | B (chart-only — rare) |
| "Upgrade zymtrace to 27.x" | C (chart + image — most common) |

### 2. Backup expectations

| DB mode | Action |
|---------|--------|
| `mode: create` (in-cluster) | **Warn** that ClickHouse/Postgres/MinIO PVCs should be snapshotted first. Proceed when user acknowledges. Procedure: [reference.md § Backing up in-cluster data](reference.md#backing-up-in-cluster-data). |
| `mode: use_existing` / `aws_aurora` / `gcp_cloudsql` | DB backups are the org's responsibility — don't surface a warning. |

### 3. Schema migrations

Every upgrade re-runs the `zymtrace-migrate` Job. Migrations are normally additive (safe forward, less safe to roll back across). Skip flags exist (`global.skipDBMigrations`, `global.skipPostgresMigration`, `global.skipClickHouseMigration`) but **don't propose them** unless the user explicitly asks; the default is correct.

If the user is jumping multiple **major** versions (e.g. 24.x → 26.x), advise stepping through intermediate versions to limit migration surface area.

---

## Standard flow

### Step 1: Pre-flight checks

##### Claude runs
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/upgrade-zymtrace-backend/scripts/preflight-upgrade.sh <NS> <REL>
```

Pass the namespace and release resolved in Pre-resolve. If the user has overridden `global.namePrefix`, also pass it: `PREFIX=<value> bash ${CLAUDE_PLUGIN_ROOT}/skills/upgrade-zymtrace-backend/scripts/preflight-upgrade.sh <NS> <REL>`.

Prints current release state, target version availability, pending operations, plus a values diff if `helm-diff` is installed. Use the output to confirm the upgrade target with the user before continuing.

ERROR: `another operation … in progress` → a previous helm op is stuck. Inspect with `helm history <REL> -n <NS>`; resolve before proceeding.

### Step 2: Backup (warn, don't block)

If any DB is `mode: create`, surface this exactly once:

> ⚠️ Your ClickHouse / Postgres / MinIO data is in-cluster on PVCs. Take a snapshot of those PVCs (or `kubectl exec` a logical dump) before continuing. See [reference.md § Backing up in-cluster data](reference.md#backing-up-in-cluster-data).

Then **proceed regardless** of the user's response. Do not gate the upgrade on backups.

### Step 3: Refresh the Helm repo

##### Claude runs
```bash
helm repo update zymtrace
helm search repo zymtrace/backend --versions | head -5
```

`helm repo update` is **mandatory** before any upgrade — the local cache may be stale and `helm upgrade --version X.Y.Z` will fail if X.Y.Z isn't in the cache yet. After the update, verify the target version (and `appVersion`) appears in the listing.

ERROR: target version not listed → either the version hasn't been published, or `helm repo add` was never run. `helm repo list` to check, `helm repo add zymtrace https://helm.zystem.io` if needed.

### Step 4: Confirm with the user before running

Before executing any `helm upgrade` command in this skill, **always print the exact command + the resolved values** (release name, target chart version, target image tag, namespace, values file path) and ask the user to confirm. Wait for explicit approval. Do not run on assumed consent.

Then run the path that matches:

> `<REL>` and `<NS>` are placeholders for the resolved release name and namespace from Pre-resolve. Substitute before running.

#### Path A — image-only bump

##### Claude runs
```bash
helm upgrade --install <REL> zymtrace/backend \
  --namespace <NS> \
  --reset-then-reuse-values \
  --set services.common.imageTag=<NEW_TAG> \
  --atomic --debug
```

This keeps every other value as last applied. `services.common.imageTag` is the canonical key — it cascades to `ingest`, `web`, `symdb`, `identity`, `migrate`, `gateway`, and `ui` unless a service overrides `image.tag`.

#### Path B — chart-only bump

##### Claude runs
```bash
helm upgrade --install <REL> zymtrace/backend \
  --namespace <NS> \
  --version <NEW_CHART_VERSION> \
  -f <values-file>.yaml \
  --reset-then-reuse-values \
  --atomic --debug
```

The `-f <values-file>.yaml` must be the same file used at install (or its current source-controlled successor). If the user doesn't have it, reconstruct it: `helm get values <REL> -n <NS> > values-current.yaml`.

#### Path C — chart + image together

##### Claude runs
```bash
helm upgrade --install <REL> zymtrace/backend \
  --namespace <NS> \
  --version <NEW_CHART_VERSION> \
  -f <values-file>.yaml \
  --set services.common.imageTag=<NEW_IMAGE_TAG> \
  --reset-then-reuse-values \
  --atomic --debug
```

If the new chart's `appVersion` matches your target image, you can omit `--set services.common.imageTag=` — the chart default tracks `appVersion`.

ERROR: `failed pre-install: timed out waiting for the condition` → usually a referenced secret is missing or the migrate Job is taking longer than 1h (`migrate.timeoutSeconds: 3600`). Run `kubectl get events -n <NS> --sort-by=.lastTimestamp | tail -20`. For slow migrations, watch `kubectl logs -n <NS> job/<PREFIX>-migrate -f` and decide whether to wait or rollback.

ERROR: `another operation … in progress` → `helm history <REL> -n <NS>`; resolve with rollback (Step 7) or, only with user confirmation, `helm uninstall` (destructive).

ERROR: image pull / `ImagePullBackOff` → tag doesn't exist, or air-gapped registry isn't mirrored. Verify tag at <https://hub.docker.com/u/zystemio>.

### Step 5: Verify

##### Claude runs
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/install-zymtrace-backend/scripts/verify-backend.sh <NS> <REL>
```

Pass `PREFIX=<value>` env var if `global.namePrefix` is overridden.

The same script the install skill uses — `helm status`, pod/job/svc/ingress/hpa, logs per service, describe of any non-Running pod. Use the **Done checklist** below as exit criteria.

Cross-check the running image tag matches the target (substitute `<NS>` and `<PREFIX>`):
```bash
kubectl get deploy <PREFIX>-ingest <PREFIX>-web <PREFIX>-gateway <PREFIX>-symdb <PREFIX>-identity <PREFIX>-ui -n <NS> \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

### Step 6: Persist the canonical values file

##### Claude runs
```bash
cp <values-file> <values-file>.bak.$(date +%Y%m%d-%H%M%S)
helm get values <REL> -n <NS> > <values-file>
```

`<values-file>` is whatever filename the customer is already using (e.g. `acme-zymtrace.yaml`). Don't rename it. If they don't have one yet, default to `zymtrace-custom-values.yaml`. See [`shared/conventions.md`](../../shared/conventions.md) for the rules on respecting customer filenames and backing up before writing.

After a successful upgrade this refreshes the single source-of-truth file so install/upgrade/expose all keep reading from the same place. Tell the user the backup path; recommend they commit the new canonical file.

### Step 7: Rollback (if needed)

If `--atomic` rolled back automatically, the cluster is already on the previous revision — investigate why before retrying.

To roll back manually after the fact:

##### Claude runs
```bash
helm history <REL> -n <NS>
helm rollback <REL> <REVISION> -n <NS> --wait
```

This is safe to run freely. What rollback does (and doesn't do) to the migrate Job and schema state, plus escalation criteria for post-rollback data-shape errors: [reference.md § Rollback specifics](reference.md#rollback-specifics).

---

## Done

Exit when ALL of the following are true (substitute `<NS>` / `<REL>` / `<PREFIX>`):

- [ ] `helm status <REL> -n <NS>` reports `STATUS: deployed` and `REVISION` is incremented.
- [ ] All pods Running on the new image tag (cross-check command from Step 5).
- [ ] Migration for the current revision succeeded — either `<PREFIX>-migrate` Job is at `1/1` succeeded, **or** the Job is absent (Helm `pre-upgrade` hook auto-deletes on success). With `helm status STATUS: deployed` and `REVISION` incremented, absence is the expected state. If the migration actually failed, `--atomic` would have rolled back — check `helm history <REL> -n <NS>` for failed revisions.
- [ ] No `license` / `auth` / `forbidden` errors in `kubectl logs deployment/<PREFIX>-ingest -n <NS> --tail=50`. (Job logs are only available if the Job hasn't been hook-deleted yet.)
- [ ] Gateway responds: `curl -fsI http://<host>` returns 2xx/3xx/4xx (not 5xx / connection-refused / timeout).
- [ ] If `helm-diff` was used pre-upgrade: the rendered changes match what `helm get manifest <REL> -n <NS>` shows now.

If any box fails after `--atomic` did NOT auto-rollback, run Step 7.

## Common pitfalls

- **Forgetting `--reset-then-reuse-values`** → values reset to chart defaults. With `--set` this is silent data loss. See [reference.md § Why always reset-then-reuse-values in install](../install-zymtrace-backend/reference.md#why-always-reset-then-reuse-values).
- **Major-version jump without intermediate steps** → migrate Job may not handle large schema deltas cleanly. Step through intermediate releases.
- **Per-service `image.tag` overrides linger** → `services.common.imageTag` won't override a per-service `image.tag` that's set in your values file. Inspect with `helm get values <REL> -n <NS>` if image versions are mixed after upgrade.
- **Reconstructing values from `helm get values`** drops the chart's defaults. That's fine for `helm upgrade` (defaults re-apply), but don't treat the output as a complete values file for archival.
- **`migrate` Job timeout** → default 1h. Long migrations on large ClickHouse tables can need more; bump `services.migrate.timeoutSeconds`.
- **Rollback after image-only bump** = safe. **Rollback after chart bump that added/renamed schema** = may need support intervention.

---

## Security constraints

- **Never** run `helm upgrade` / `helm upgrade --install` without first running `helm repo update zymtrace` in the same session. Stale repo cache → wrong / missing chart version.
- **Never** run the upgrade without explicitly printing the resolved command + target version + image tag and waiting for the user to confirm. Implicit consent does not apply to upgrades.
- **Never** issue `helm upgrade` or `helm upgrade --install` for this chart without `--reset-then-reuse-values` — even on a partial `--set` bump, even with `-f`. The flag is the only guard against silent reset of values like `licenseKey`, `clickhouse.use_existing.host`, or `auth.*` to chart defaults.
- **Never** propose `global.skipDBMigrations: true` / `skipPostgresMigration` / `skipClickHouseMigration` unless the user explicitly asks. The default (run migrations) is correct.
- **Never** run `helm uninstall`, `kubectl delete pvc`, `kubectl delete namespace`, or anything that drops persistent data without explicit user confirmation.
- **Never** modify a values file in-place during an upgrade without source-control commit — if rollback is needed, you'll want the previous values file too.
- **Never** silently fall back to `--force` on a failed upgrade. Investigate the failure and resolve the root cause (usually a missing secret or stuck operation).
- **Never** skip Step 4 verification. Pods can be Running on the new tag while the migrate Job left the schema in a half-applied state.

# upgrade-zymtrace-backend — Reference

Detailed material the SKILL.md links to but does not inline. Read on demand.

---

## Backing up in-cluster data

If any database is `mode: create`, the chart manages its PVC inside the cluster. The user — not the skill — owns backups. Surface the recommendation once (Step 2 in SKILL.md) and proceed regardless of their response.

> Commands below use `<NS>` for namespace and `<PREFIX>` for `global.namePrefix`. Both default to `zymtrace`. Substitute the resolved values.

### Volume-snapshot path (recommended for cloud clusters)
If the cluster supports `VolumeSnapshot` (EBS, PD, Azure Disk) and a `VolumeSnapshotClass` is installed:

```bash
# Identify the PVCs
kubectl get pvc -n <NS>
# Example output (with default PREFIX=zymtrace):
#   data-zymtrace-clickhouse-0   Bound   pvc-aaa…  500Gi   gp3
#   data-zymtrace-postgres-0     Bound   pvc-bbb…  50Gi    gp3
#   data-zymtrace-minio-0        Bound   pvc-ccc…  100Gi   gp3

# Snapshot each
for pvc in data-<PREFIX>-clickhouse-0 data-<PREFIX>-postgres-0 data-<PREFIX>-minio-0; do
  cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${pvc}-$(date +%Y%m%d-%H%M%S)
  namespace: <NS>
spec:
  volumeSnapshotClassName: csi-snapshotter
  source:
    persistentVolumeClaimName: ${pvc}
EOF
done
```

Verify with `kubectl get volumesnapshot -n <NS>` — `READYTOUSE=true` means the snapshot is complete.

### Logical dump fallback (no snapshot support)
- **ClickHouse**: `kubectl exec <PREFIX>-clickhouse-0 -n <NS> -- clickhouse-client --query "BACKUP DATABASE <PREFIX>_profiling TO Disk('backups', 'profiling-$(date +%s).zip')"` (requires a backup disk configured in CH).
- **Postgres**: `kubectl exec <PREFIX>-postgres-0 -n <NS> -- pg_dumpall -U postgres > pg-$(date +%s).sql`
- **MinIO**: `kubectl exec <PREFIX>-minio-0 -n <NS> -- mc mirror /data /backup/minio-$(date +%s)`

The skill does not run these for the user — they're org-specific and may need credentials the skill doesn't have.

---

## Reconstructing a values file from a live release

When the user wants to upgrade but the original values file is lost:

```bash
helm get values <REL> -n <NS> > <values-file>
```

What this gives you: the values the user explicitly set at install / last upgrade. **Not** the chart defaults. Safe to feed back into `helm upgrade --install -f current-values.yaml` — defaults re-apply from the chart.

What it does **not** give you:
- Anything passed via `--set` flags (those are merged at apply time but not retained as "user values" beyond what's persisted in the release secret).
- Sensitive values that resolved through `*SecretName` references — only the secret names, not the values.

Append `--all` to dump the merged values (user + defaults), but **never commit that output** — it captures chart defaults which will drift across versions, and it can include resolved sensitive defaults.

---

## helm-diff plugin

Optional but useful for previewing changes before upgrading.

### Install
```bash
helm plugin install https://github.com/databus23/helm-diff
helm plugin list | grep diff
```

### Use before any upgrade
```bash
helm diff upgrade backend zymtrace/backend \
  --namespace zymtrace \
  --version <NEW_CHART_VERSION> \
  -f values.yaml \
  --reset-then-reuse-values
```

The output is a `diff -u`-style preview of every Kubernetes resource the upgrade will change. Look for:
- Image tag changes (expected).
- Resource-request changes (expected if chart defaults moved).
- Removed resources (suspicious — investigate).
- Schema changes to PVCs / StatefulSets (these can fail to apply on existing PVCs).

---

## The `migrate` Job

The chart deploys a Helm pre-upgrade Job named `<PREFIX>-migrate` (default: `zymtrace-migrate`) that runs `zymtrace-cli migrate` against ClickHouse and Postgres. It must succeed before the rest of the release rolls forward.

Default timeout: `services.migrate.timeoutSeconds: 3600` (1 hour). Long migrations on large ClickHouse tables can exceed this — bump it via `--set services.migrate.timeoutSeconds=10800` (3h) for known-slow upgrades.

### Skip flags

Don't propose these unless the user explicitly asks.

| Flag | Effect |
|------|--------|
| `global.skipDBMigrations` | Skip all DB migrations. |
| `global.skipPostgresMigration` | Skip Postgres migrations only (sets `SKIP_PSQL_MIGRATE=true`). |
| `global.skipClickHouseMigration` | Skip ClickHouse migrations only (sets `SKIP_CH_MIGRATE=true`). |

Use cases: emergency rollback to fix a misbehaving migration; running an out-of-band manual migration; very fast iteration in dev. **Not** for production upgrades.

### Watching it
```bash
kubectl logs -n <NS> job/<PREFIX>-migrate -f
# or
kubectl get pods -n <NS> -l app.kubernetes.io/component=migrate -w
```

---

## Rollback specifics

`helm rollback` is safe to run freely (see SKILL.md Step 6 — that's the policy). Here's what actually happens.

### What rollback does
- Re-applies the previous revision's manifests (so deployments, services, configmaps revert).
- **Re-runs the pre-upgrade `migrate` Job** for the prior revision's chart. It runs *that* chart's migration scripts, not a reverse migration.
- Pod images return to the prior tag.

### What rollback does NOT do
- It does **not** undo forward schema changes that the new chart's migration applied. ClickHouse and Postgres migrations in zymtrace are normally additive (new columns / new tables) — the prior code is generally compatible because it doesn't know about the new columns and ignores them.
- It does **not** restore PVC contents to a pre-upgrade state. If you need that, restore from snapshot (see § Backing up in-cluster data).

### When rollback might surface errors
- New columns marked NOT NULL with no default → old code's INSERT statements break. Rare in zymtrace; surface to support if seen.
- Table renames between versions → old code references the old name; reads fail. Very rare.
- ClickHouse `ALTER TABLE` operations that changed sort key / partition key → can't be undone; rollback can't fix a broken layout.

### Escalation
If post-rollback shows data-shape errors in `kubectl logs deployment/<PREFIX>-ingest`:
1. Capture: `helm history <REL> -n <NS>`, `kubectl logs job/<PREFIX>-migrate --tail=200`, recent ingest logs.
2. Restore from PVC snapshot to a known-good state (last pre-upgrade snapshot).
3. Email <support@zymtrace.com> with the captured logs and the chart-version transition.

---

## Cross-major-version upgrades

Jumping multiple major versions in one shot (e.g. 24.x → 26.x) compounds migration risk: each release's migration script assumes the prior version's schema. Skipping versions can mean a migration step is missing.

Strategy: step through intermediate releases.

```bash
# Determine path
helm search repo zymtrace/backend --versions | head -30

# Sequential upgrade
helm upgrade --install backend zymtrace/backend --version 25.0.0 -f values.yaml \
  --reset-then-reuse-values --atomic
# verify, then
helm upgrade --install backend zymtrace/backend --version 26.0.0 -f values.yaml \
  --reset-then-reuse-values --atomic
# verify, then
helm upgrade --install backend zymtrace/backend --version 26.4.4 -f values.yaml \
  --reset-then-reuse-values --atomic
```

At each step, run the Done checklist before proceeding. If a step fails, you have only that step's delta to debug.

For zymtrace specifically, every minor release in a major line is usually safe to skip; only major boundaries warrant stepping.

---

## Air-gapped upgrade considerations

If `global.imageRegistry` / `global.appImageRegistry` point at a mirror, the new image tag **must already be in the mirror** before the upgrade. The upgrade itself doesn't mirror images.

Pre-upgrade checklist for air-gapped:
1. Pull the new tags from public registries (or zymtrace download root).
2. Tag for your registry.
3. Push to your registry.
4. Verify access from the cluster: `kubectl run img-check --rm -it --image=<your-registry>/zymtrace-pub-backend:<NEW_TAG> -- /bin/sh -c "echo ok"`.
5. Only then run the helm upgrade.

Full mirroring procedure: <https://docs.zymtrace.com/install/custom-registry>.

---

## Reading the chart CHANGELOG between versions

Before a chart-version bump:

```bash
# Browse the chart repo on GitHub
open https://github.com/zystem-io/zymtrace-charts/blob/main/charts/backend/Chart.yaml
# Compare values.yaml between tags
curl -s https://raw.githubusercontent.com/zystem-io/zymtrace-charts/v<OLD>/charts/backend/values.yaml > /tmp/old.yaml
curl -s https://raw.githubusercontent.com/zystem-io/zymtrace-charts/v<NEW>/charts/backend/values.yaml > /tmp/new.yaml
diff -u /tmp/old.yaml /tmp/new.yaml
```

Things to flag and ask the user about:
- **Removed keys** → if their values file references one, the upgrade may silently ignore that block.
- **Renamed keys** → same problem; user values keep the old key, which goes nowhere.
- **New required keys** → chart may fail to render if the user's values don't supply them.
- **Changed defaults that affect resources / replicas / probes** → may impact running workload sizing.

---

## Sources

- Helm charts: <https://github.com/zystem-io/zymtrace-charts/tree/main/charts>
- Live `values.yaml`: <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/backend/values.yaml>
- Docs: <https://docs.zymtrace.com>
- Install skill (verify script + install reference): [`../install-zymtrace-backend/`](../install-zymtrace-backend/)
- Helm repo: `helm repo add zymtrace https://helm.zystem.io`
- Support: <support@zymtrace.com> · Slack: <https://join.slack.com/t/zymtrace/shared_invite/zt-3fdidjufl-q~NHxDzQlzal2B9mujfaoQ>

# zymtrace skill conventions

Cross-skill rules. Every helm-based skill in this repo (install, upgrade, troubleshoot, …) inherits these. Read once; the skill SKILL.md just points back here.

---

## Namespace resolution

**We recommend installing zymtrace into a namespace named `zymtrace`.** It keeps install/upgrade/troubleshoot commands predictable, aligns with the chart's defaults, and matches every example in the docs. Only deviate when the customer has a specific reason — internal naming policy, multi-tenant cluster, or an existing release already in another namespace.

### Resolution order

1. **Existing zymtrace release on the cluster** — if `helm list -A | grep -i zymtrace` returns exactly one row, use the namespace from that row regardless of what the user might assume.
2. **Multiple existing releases** — list them and ask the user which one to act on.
3. **Explicit user override** — if the user named a non-`zymtrace` namespace and gave a reason, use it but note in your response that `zymtrace` is the recommended default.
4. **Fresh install, no preference stated** — use `zymtrace`. Don't ask.

Never hardcode `zymtrace` in commands without first running the auto-detect (step 1) — there *might* already be an install elsewhere.

### Auto-detect command
```bash
helm list -A -o yaml | awk '
  /^- name:/ { name=$3 }
  /  namespace:/ && name { print name, $2; name="" }
' | grep -i zymtrace
```

Or simpler (less precise but works for most cases):
```bash
helm list -A | grep -i zymtrace
```

### In examples and templates

Documentation, values templates, and SKILL.md examples may use `zymtrace` literally as the canonical default — that's fine for prose. But **commands you actually execute** must pass the resolved namespace via `--namespace`/`-n` rather than assuming the literal.

---

## Release name resolution

Same rule: defaults are `backend` for the backend chart and `profiler` for the profiler chart, but customers can name releases anything.

### Resolution order
1. **Explicit user input** — use it.
2. **Match by chart name in `helm list -n <NS>`** — the chart column shows `backend-<version>` or `profiler-<version>`; use the release whose chart starts with the expected name.
3. **Multiple matches** — ask the user.
4. **No matches** — same handling as namespace.

### Auto-detect command (backend)
```bash
helm list -n <NS> -o yaml | awk '
  /^- name:/ { name=$3 }
  /  chart:/ && name { print name, $2; name="" }
' | awk '$2 ~ /^backend-/ {print $1}'
```

---

## Namespace + release together

Almost every command in a helm skill is parameterized by `(namespace, release)`. The skills' shell scripts (`verify-backend.sh`, `preflight-upgrade.sh`, etc.) take both as positional arguments:

```bash
./scripts/<script>.sh <namespace> <release>
```

Default to `zymtrace backend` in the script defaults. The SKILL.md walkthroughs must instruct Claude to call them with the *resolved* values, not the defaults, whenever the user is on a cluster.

---

## `global.namePrefix`

Inside the chart, resource names (deployments, services, jobs) are built as `<global.namePrefix>-<service>`. The default `namePrefix` is `zymtrace`, so a default install produces `zymtrace-ingest`, `zymtrace-gateway`, etc.

**If the user has overridden `global.namePrefix`**, every `kubectl get deployment/<name>` / `kubectl logs deployment/<name>` command in the skills breaks. Auto-detect with:

```bash
helm get values <RELEASE> -n <NS> 2>/dev/null | awk '/^\s*namePrefix:/ {print $2}'
```

Pass it to scripts as `PREFIX=<value> ./scripts/<script>.sh …`. Both `verify-backend.sh` and `preflight-upgrade.sh` honor the `PREFIX` env var.

---

## The single values file

Every helm-based skill (install / upgrade / expose / future) works from **one** values file — the customer's source of truth, the thing they commit to source control, and the only `-f` argument to `helm upgrade --install` after every operation.

### Rules

1. **Always ask the customer first** whether they have an existing values file for this release. Don't assume it exists on the local filesystem — they may need to point at a path or paste it.
2. **If they provide one**, use the **exact filename they give** (e.g. `acme-zymtrace.yaml`, `backend-values.yaml`). Do not rename it — their CI, docs, and git history reference that name. Keep using that filename for the rest of the session.
3. **If they don't have one**, generate one with the default name **`zymtrace-custom-values.yaml`** before running anything. Save it to their working directory. From then on it's canonical.
4. **After every successful helm operation**, update whichever file is canonical from the live release:
   ```bash
   helm get values <REL> -n <NS> > <canonical-filename>
   ```
   This collapses any `-f overlay.yaml` you used during the operation back into a single file. Recommend the user commit it.
5. **Never leave overlays lying around.** If the operation used `-f base.yaml -f overlay.yaml`, immediately collapse via step 4. Future upgrades reduce to `helm upgrade --install <REL> zymtrace/backend -f <canonical-filename> --reset-then-reuse-values --atomic`.

### Asking the customer

Before the decision tree or any upgrade / expose path:

> Do you have an existing values file for this zymtrace release (sometimes called `custom-values.yaml`, `backend-values.yaml`, `<company>-values.yaml`, or similar)? If so, please share the path or its contents.

If **yes**:
1. Use the filename they give. Don't rename.
2. Read it end-to-end.
3. Note what's already set: `global.licenseKey*`, `clickhouse.mode`, `postgres.mode`, `storage.mode`, `ingress.*`, `auth.*`, `services.common.imageTag`, `global.imageRegistry`.
4. **Skip** any decision-tree question whose answer is already in the file.
5. Only ask the user about genuine gaps.
6. Use the file directly with `helm upgrade --install ... -f <their-path> --reset-then-reuse-values --atomic`.
7. After success, update the same file (rule 4 above).

If **no**:
- Walk the full decision tree (install) or reconstruct from the live release with `helm get values <REL> -n <NS> > zymtrace-custom-values.yaml` (upgrade / expose).
- Save the result as `./zymtrace-custom-values.yaml` and tell the user to commit it.

### Always back up before writing

Any operation that **edits or overwrites** the canonical values file must first take a timestamped backup. Helm's `--atomic` rolls back the cluster on failure, but a local file edit persists — without a backup, the file ends up ahead of reality and the customer can't easily revert.

```bash
cp <values-file> <values-file>.bak.$(date +%Y%m%d-%H%M%S)
```

This applies to:
- **Edit-in-place steps** — e.g. `expose-zymtrace-backend` adding an `ingress:` block.
- **`helm get values > <values-file>` persist steps** — `install` Step 6, `upgrade` Step 6.

Mention the backup path in the user-facing output. Don't auto-clean — leave the `.bak.*` files visible so the customer can compare before/after and delete when satisfied.

### What the file may NOT contain

- Raw secret values (license key, OIDC client secret, admin password, DB passwords) — these must be `*SecretName` references. The actual secrets are created in-cluster via `kubectl create secret`, not stored in the values file.
- The Helm chart version they're targeting (typically tracked separately in the install runbook or in `helm history`).

Treat the file as values, not as a complete deployment spec.

---

## Summary

Three knobs the user can move from defaults, plus one external artifact:
| Knob | Default | How to detect | Skill responsibility |
|------|---------|--------------|---------------------|
| Namespace | `zymtrace` | `helm list -A \| grep -i zymtrace` | Always resolve before acting |
| Release name | `backend` (or `profiler`) | `helm list -n <NS>` | Always resolve before acting |
| `global.namePrefix` | `zymtrace` | `helm get values <RELEASE> -n <NS>` | Pass as `PREFIX=…` to scripts |

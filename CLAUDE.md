# zymtrace-skills — Development Guide

Claude Code skills for installing, upgrading, exposing, troubleshooting, and analyzing
[zymtrace](https://zymtrace.com) — continuous CPU/GPU profiling. This guide is for
people *developing* the skills; end-user docs live in [README.md](README.md).

## Repository structure

A single plugin at `zymtrace/` that installs into **Claude Code, OpenAI Codex, and Cursor**
from one canonical source, plus repo-root marketplace manifests (one per tool) and the test
suite.

```
.claude-plugin/marketplace.json   # Claude Code marketplace manifest
.agents/plugins/marketplace.json  # Codex (and generic) marketplace manifest
.cursor-plugin/marketplace.json   # Cursor marketplace manifest
zymtrace/                         # Plugin root  (== ${CLAUDE_PLUGIN_ROOT} at runtime)
  .claude-plugin/plugin.json      # Claude Code plugin manifest
  .codex-plugin/plugin.json       # Codex plugin manifest  (declares "skills": "./skills/")
  .cursor-plugin/plugin.json      # Cursor plugin manifest (declares "skills": "./skills/")
  shared/                         # Cross-skill docs (conventions.md, references.md)
  skills/<skill-name>/            # THE canonical source — every tool reads these
    SKILL.md                      # Required. Frontmatter + workflow.
    reference.md                  # Optional. Deep details for progressive disclosure.
    scripts/*.sh                  # Optional. Verify/diagnose helpers (executable).
    values/*.yaml                 # Optional. Helm values templates.
tests/                           # Structural pytest suite (no API keys / cluster)
```

## Key conventions

- **Versions stay in sync — the repo-root `VERSION` file is the single source of truth.**
  The plugin is the versioned unit; **skills carry no version**. All three product `plugin.json`
  files (`.claude-plugin/`, `.codex-plugin/`, `.cursor-plugin/`) and the Claude `marketplace.json`
  plugin entry must match `VERSION`. Don't hand-edit them — run `./scripts/sync-version.sh` (or
  `./scripts/sync-version.sh <new>` to bump) to propagate, then `make test` to enforce it
  (`test_version_file_is_source_of_truth`).
- **Multi-platform manifests are hand-written, not generated.** One canonical source
  (`zymtrace/skills/`); each tool gets its own `plugin.json` (inside `zymtrace/`) and a
  repo-root marketplace file, all pointing at the same `skills/`. They differ only in
  per-tool metadata and field names. zymtrace bundles **no MCP server, no hooks, no
  commands** — the MCP is connected separately via `configure-zymtrace-mcp` and the
  gateway URL is per-deployment, so Codex install `authentication` is `NONE`. The product
  maps `PRODUCT_PLUGIN_JSONS` / `PRODUCT_MARKETPLACE_JSONS` in `tests/conftest.py` drive
  the structural tests that catch drift. Codex reads `.agents/plugins/marketplace.json`;
  Cursor reads `.cursor-plugin/marketplace.json`.
- **Intra-plugin paths use `${CLAUDE_PLUGIN_ROOT}`, never bare relative paths.** Skills
  run with the user's working directory, *not* the skill directory, as cwd. Any script
  the skill runs or reference file it reads must be addressed as
  `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/scripts/<x>.sh` /
  `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/reference.md`. Enforced by
  `tests/structural/test_paths.py`. (Markdown navigation links *between* skills, e.g.
  `[expose-zymtrace-backend](../expose-zymtrace-backend/SKILL.md)`, may stay relative —
  the agent resolves those when reading a known file.)
- **Scripts are executable** (`chmod +x`) and invoked as `bash ${CLAUDE_PLUGIN_ROOT}/...`.
- **Skill `name` == directory name.**
- **Frontmatter** must include `name` and `description` (with `Trigger phrases:`) — the only
  required fields. zymtrace skills also carry optional `metadata.author/repository/tags`; no
  per-skill `version` (the plugin is versioned, not the skill).
- **Secrets never touch disk or chat** — see each skill's `## Security constraints`.
- **Helm conventions** (namespace/release resolution, the single canonical values file,
  `--reset-then-reuse-values`, backups) are centralized in
  `zymtrace/shared/conventions.md`; skills link back to it rather than repeating it.

## Local build

Install the plugin from a local checkout to test changes before publishing. This
keeps plugin semantics, so `${CLAUDE_PLUGIN_ROOT}` resolves and the helper scripts /
`reference.md` files behave exactly as they do from the marketplace:

```bash
git clone https://github.com/zystem-io/zymtrace-skills.git
cd zymtrace-skills
claude plugin validate ./zymtrace              # fast check: manifest parses (plugin root is zymtrace/)
claude plugin marketplace add "$PWD"           # register the repo-root marketplace (zymtrace-skills)
claude plugin install zymtrace@zymtrace-skills # install the plugin from it
```

Restart the Claude Code session to pick up edits (after editing, `claude plugin marketplace
update zymtrace-skills` re-reads the local manifest). Inspect what loaded — including agents and
per-component token cost — with `claude plugin details zymtrace`. Prefer this plugin install over
copying skills into `~/.claude/skills/` — the raw copy loses `${CLAUDE_PLUGIN_ROOT}`, so the
bundled scripts won't resolve.

## Tests

```bash
python -m venv .venv && source .venv/bin/activate
make install   # pytest + PyYAML
make test      # structural tests only
```

The structural suite verifies:
- Plugin + marketplace manifests parse, have required fields, and use semver
- Version consistency across plugin.json, marketplace.json, and every skill
- Frontmatter presence + required fields; `name` matches the directory
- Directory layout matches `REQUIRED_SKILLS` (no orphan or undeclared skills)
- Path portability: no bare `./scripts/` invocations; every `${CLAUDE_PLUGIN_ROOT}`
  path resolves; referenced scripts are executable

No API keys, cluster, or network access are needed.

## Adding a new skill

1. Create `zymtrace/skills/<skill-name>/SKILL.md` with frontmatter:
   ```yaml
   ---
   name: <skill-name>          # must equal the directory name
   description: |
     What this skill does and when to use it.
     Trigger phrases: "phrase one", "phrase two", ...
   metadata:                   # optional, informational; no per-skill version
     author: zymtrace
     repository: https://github.com/zystem-io/zymtrace-skills
     tags: zymtrace,...
   ---
   ```
2. Address any scripts/reference files via `${CLAUDE_PLUGIN_ROOT}/skills/<skill-name>/...`
   and `chmod +x` the scripts.
3. Add `<skill-name>` to `REQUIRED_SKILLS` in `tests/constants.py`.
4. Add a row to the skills table in `README.md`.
5. Run `make test`.

## Releasing a new version

**Edit the `VERSION` file and commit it to `main`. That's the whole release step.**

```bash
echo 26.6.0 > VERSION
git commit -am "release 26.6.0" && git push   # to main
```

The **Sync version** GitHub Actions workflow (`.github/workflows/sync-version.yml`) fires on any
`VERSION` change pushed to `main`: it runs `scripts/sync-version.sh` to propagate the version into
the three product `plugin.json` files and the `.claude-plugin/marketplace.json` plugin entry, then
commits the result back to `main`. The follow-up commit runs the
structural tests (which enforce that everything matches `VERSION`); the bare `VERSION` commit itself is
skipped via `paths-ignore`, so you never see a red check mid-bump. (The Codex and Cursor marketplace
files carry no version field — version lives in their `plugin.json`.)

You don't run anything by hand. `scripts/sync-version.sh` exists for CI (and is runnable locally —
`./scripts/sync-version.sh [new-version]` — if you ever want to propagate without pushing).

**Requires** the workflow to be able to push to `main` (`contents: write`, already set). If `main`
is a protected branch that blocks Actions pushes, either allow the `github-actions` bot or do the
bump on a branch and run the script locally before the PR.

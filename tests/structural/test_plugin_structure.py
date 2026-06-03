"""Plugin manifest, marketplace manifest, and directory-layout tests."""

import json
import re

import pytest

from tests.conftest import (
    PRODUCT_MARKETPLACE_JSONS,
    PRODUCT_PLUGIN_JSONS,
    REPO_ROOT,
    SKILLS_DIR,
    VERSION_FILE,
    parse_frontmatter,
)
from tests.constants import REQUIRED_SKILLS


def test_plugin_json_valid(plugin_json_path):
    """plugin.json exists, parses, and has required semver fields."""
    assert plugin_json_path.exists(), f"plugin.json not found at {plugin_json_path}"
    data = json.loads(plugin_json_path.read_text())
    assert data["name"] == "zymtrace"
    for field in ("version", "description"):
        assert data.get(field), f"plugin.json field '{field}' is missing or empty"
    parts = data["version"].split(".")
    assert len(parts) == 3 and all(p.isdigit() for p in parts), (
        f"version should be semver, got: {data['version']}"
    )


def test_marketplace_json_valid(marketplace_json_path):
    """marketplace.json exists, parses, and has required fields."""
    assert marketplace_json_path.exists(), f"marketplace.json not found at {marketplace_json_path}"
    data = json.loads(marketplace_json_path.read_text())
    for field in ("name", "owner", "plugins"):
        assert field in data, f"marketplace.json missing required field: {field}"
    assert isinstance(data["plugins"], list) and data["plugins"], "plugins must be a non-empty list"


def test_marketplace_plugin_source_exists(marketplace_json_path):
    """Each plugin source path in marketplace.json resolves to a directory."""
    data = json.loads(marketplace_json_path.read_text())
    for plugin in data["plugins"]:
        resolved = (REPO_ROOT / plugin["source"]).resolve()
        assert resolved.is_dir(), (
            f"plugin source '{plugin['source']}' does not resolve to a directory: {resolved}"
        )


def test_version_sync(plugin_json_path, marketplace_json_path):
    """plugin.json version == the matching marketplace.json plugin entry version."""
    plugin = json.loads(plugin_json_path.read_text())
    marketplace = json.loads(marketplace_json_path.read_text())
    for entry in marketplace["plugins"]:
        if entry["name"] == plugin["name"]:
            assert entry["version"] == plugin["version"], (
                f"version mismatch: marketplace.json has {entry['version']}, "
                f"plugin.json has {plugin['version']}"
            )
            break
    else:
        pytest.fail(f"plugin '{plugin['name']}' not found in marketplace.json plugins list")


@pytest.mark.parametrize("skill_name", REQUIRED_SKILLS)
def test_skill_has_skill_md(skills_dir, skill_name):
    """Every required skill directory has a SKILL.md."""
    assert (skills_dir / skill_name / "SKILL.md").is_file(), f"SKILL.md missing for: {skill_name}"


def test_no_unexpected_skill_dirs(skills_dir):
    """skills/ contains exactly the directories declared in REQUIRED_SKILLS."""
    actual = {p.name for p in skills_dir.iterdir() if p.is_dir()}
    unexpected = actual - set(REQUIRED_SKILLS)
    missing = set(REQUIRED_SKILLS) - actual
    assert not unexpected, f"undeclared skill directories (add to REQUIRED_SKILLS): {unexpected}"
    assert not missing, f"declared skills with no directory: {missing}"


def test_readme_lists_all_skills():
    """README's skills table must reference exactly the skills in REQUIRED_SKILLS.

    Catches doc drift: a skill added/removed in tests/constants.py (and on disk)
    without a matching update to the README table, or vice versa. Skill rows are
    detected by their `zymtrace/skills/<name>/` links (the `cp ... skills/*` line
    in the install section uses `*` and is correctly ignored).
    """
    readme = (REPO_ROOT / "README.md").read_text()
    documented = set(re.findall(r"zymtrace/skills/([a-z][a-z0-9-]+)", readme))
    required = set(REQUIRED_SKILLS)
    missing = required - documented
    extra = documented - required
    assert not missing, f"skills missing from the README table: {sorted(missing)}"
    assert not extra, f"README references skills not in REQUIRED_SKILLS (drift): {sorted(extra)}"


# --- Multi-platform manifests (Claude, Codex, Cursor) --------------------------
#
# One canonical source (zymtrace/skills/). Each product has a hand-written plugin
# manifest inside zymtrace/ and a root-level marketplace entry, all pointing at the
# same skills/. These tests catch drift between them.


@pytest.mark.parametrize("product,path", PRODUCT_PLUGIN_JSONS.items())
def test_product_plugin_jsons(product, path):
    """Each supported product has a valid plugin manifest for the shared plugin root."""
    assert path.exists(), f"{product} plugin manifest not found at {path}"
    data = json.loads(path.read_text())
    assert data["name"] == "zymtrace", f"{product} plugin.json name should be 'zymtrace'"
    for field in ("version", "description"):
        assert data.get(field), f"{product} plugin.json field '{field}' is missing or empty"
    parts = data["version"].split(".")
    assert len(parts) == 3 and all(p.isdigit() for p in parts), (
        f"{product} version should be semver, got: {data['version']}"
    )


@pytest.mark.parametrize("product,path", PRODUCT_MARKETPLACE_JSONS.items())
def test_product_marketplace_jsons(product, path):
    """Each supported product has a repo-level marketplace entry for zymtrace/."""
    assert path.exists(), f"{product} marketplace not found at {path}"
    data = json.loads(path.read_text())
    assert data["name"] == "zymtrace-skills", f"{product} marketplace name should be 'zymtrace-skills'"
    assert isinstance(data["plugins"], list) and data["plugins"], (
        f"{product} marketplace plugins must be a non-empty list"
    )
    assert any(entry["name"] == "zymtrace" for entry in data["plugins"]), (
        f"{product} marketplace has no 'zymtrace' plugin entry"
    )


def test_product_plugin_versions_in_sync():
    """Every product plugin.json carries the same version (Claude is the source of truth)."""
    claude_version = json.loads(PRODUCT_PLUGIN_JSONS["claude"].read_text())["version"]
    for product, path in PRODUCT_PLUGIN_JSONS.items():
        version = json.loads(path.read_text())["version"]
        assert version == claude_version, (
            f"{product} plugin.json version {version} != claude {claude_version}"
        )


@pytest.mark.parametrize(
    "product", [p for p in PRODUCT_PLUGIN_JSONS if p != "claude"]
)
def test_product_skills_pointer_resolves(product):
    """Codex/Cursor manifests declare a `skills` pointer that resolves to zymtrace/skills/."""
    data = json.loads(PRODUCT_PLUGIN_JSONS[product].read_text())
    assert data.get("skills") == "./skills/", (
        f"{product} plugin.json should declare \"skills\": \"./skills/\""
    )
    resolved = (PRODUCT_PLUGIN_JSONS[product].parent.parent / "skills").resolve()
    assert resolved == SKILLS_DIR.resolve() and resolved.is_dir(), (
        f"{product} skills pointer does not resolve to {SKILLS_DIR}"
    )


def test_codex_marketplace_entry_shape():
    """Codex/generic marketplace entry: local source + install policy, no auth (MCP is separate)."""
    data = json.loads(PRODUCT_MARKETPLACE_JSONS["codex"].read_text())
    entry = next(item for item in data["plugins"] if item["name"] == "zymtrace")
    assert entry["source"] == {"source": "local", "path": "./zymtrace"}
    assert entry["policy"]["installation"] == "AVAILABLE"
    assert entry["policy"]["authentication"] == "NONE"
    assert entry["category"]
    assert (REPO_ROOT / entry["source"]["path"]).resolve().is_dir()


def test_cursor_marketplace_source_shape():
    """Cursor marketplace source is a repo-root-relative string that resolves to a dir."""
    data = json.loads(PRODUCT_MARKETPLACE_JSONS["cursor"].read_text())
    entry = next(item for item in data["plugins"] if item["name"] == "zymtrace")
    assert entry["source"] == "zymtrace"
    assert (REPO_ROOT / entry["source"]).resolve().is_dir()


def test_version_file_is_source_of_truth():
    """The repo-root VERSION file is the single source of truth; everything matches it.

    Bump with `scripts/sync-version.sh` (see CLAUDE.md). This catches a manual edit that
    drifted from VERSION, or a file the sync script missed.
    """
    version = VERSION_FILE.read_text().strip()
    assert re.match(r"^\d+\.\d+\.\d+$", version), f"VERSION is not semver: {version!r}"

    for product, path in PRODUCT_PLUGIN_JSONS.items():
        v = json.loads(path.read_text())["version"]
        assert v == version, f"{product} plugin.json version {v} != VERSION {version}"

    # Only the Claude marketplace carries a version (Codex/Cursor marketplaces don't).
    mkt = json.loads(PRODUCT_MARKETPLACE_JSONS["claude"].read_text())
    entry = next(e for e in mkt["plugins"] if e["name"] == "zymtrace")
    assert entry["version"] == version, (
        f"marketplace.json version {entry['version']} != VERSION {version}"
    )

    for skill in REQUIRED_SKILLS:
        fm = parse_frontmatter(SKILLS_DIR / skill / "SKILL.md")
        v = str(fm["metadata"]["version"])
        assert v == version, f"{skill} metadata.version {v} != VERSION {version}"

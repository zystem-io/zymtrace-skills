"""Plugin manifest, marketplace manifest, and directory-layout tests."""

import json
import re

import pytest

from tests.conftest import REPO_ROOT
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

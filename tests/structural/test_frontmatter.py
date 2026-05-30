"""SKILL.md YAML frontmatter validation.

Structural checks only: required fields present, name matches directory, and
metadata.version stays in lockstep with plugin.json (single source of truth).
Content quality (wording, trigger-phrase counts) is intentionally not tested.
"""

import json

import pytest

from tests.conftest import PLUGIN_JSON, parse_frontmatter
from tests.constants import REQUIRED_SKILLS

PLUGIN_VERSION = json.loads(PLUGIN_JSON.read_text())["version"]


@pytest.mark.parametrize("skill_name", REQUIRED_SKILLS)
def test_skill_frontmatter_fields(skills_dir, skill_name):
    """SKILL.md has frontmatter with name, description, and metadata.version."""
    fm = parse_frontmatter(skills_dir / skill_name / "SKILL.md")
    assert fm is not None, f"{skill_name}/SKILL.md has no YAML frontmatter"
    assert fm.get("name"), f"{skill_name} frontmatter missing 'name'"
    assert fm.get("description"), f"{skill_name} frontmatter missing 'description'"
    assert fm.get("metadata", {}).get("version"), f"{skill_name} missing 'metadata.version'"


@pytest.mark.parametrize("skill_name", REQUIRED_SKILLS)
def test_skill_name_matches_directory(skills_dir, skill_name):
    """frontmatter `name` equals the skill's directory name."""
    fm = parse_frontmatter(skills_dir / skill_name / "SKILL.md")
    assert fm["name"] == skill_name, (
        f"{skill_name}/SKILL.md declares name '{fm['name']}', expected '{skill_name}'"
    )


@pytest.mark.parametrize("skill_name", REQUIRED_SKILLS)
def test_skill_version_matches_plugin(skills_dir, skill_name):
    """Each skill's metadata.version matches plugin.json (single source of truth)."""
    fm = parse_frontmatter(skills_dir / skill_name / "SKILL.md")
    version = str(fm["metadata"]["version"])
    assert version == PLUGIN_VERSION, (
        f"{skill_name} metadata.version is {version}, but plugin.json is {PLUGIN_VERSION}. "
        f"All versions must stay in sync (see CLAUDE.md)."
    )

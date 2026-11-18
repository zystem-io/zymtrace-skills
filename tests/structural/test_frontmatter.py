"""SKILL.md YAML frontmatter validation.

Structural checks only: required fields present and name matches directory. Skills
carry no version — the plugin is the versioned unit (see VERSION + plugin.json).
Content quality (wording, trigger-phrase counts) is intentionally not tested.
"""

import pytest

from tests.conftest import parse_frontmatter
from tests.constants import REQUIRED_SKILLS


@pytest.mark.parametrize("skill_name", REQUIRED_SKILLS)
def test_skill_frontmatter_fields(skills_dir, skill_name):
    """SKILL.md has frontmatter with name and description (the required fields)."""
    fm = parse_frontmatter(skills_dir / skill_name / "SKILL.md")
    assert fm is not None, f"{skill_name}/SKILL.md has no YAML frontmatter"
    assert fm.get("name"), f"{skill_name} frontmatter missing 'name'"
    assert fm.get("description"), f"{skill_name} frontmatter missing 'description'"


@pytest.mark.parametrize("skill_name", REQUIRED_SKILLS)
def test_skill_name_matches_directory(skills_dir, skill_name):
    """frontmatter `name` equals the skill's directory name."""
    fm = parse_frontmatter(skills_dir / skill_name / "SKILL.md")
    assert fm["name"] == skill_name, (
        f"{skill_name}/SKILL.md declares name '{fm['name']}', expected '{skill_name}'"
    )


# The Agent Skills spec caps `description` at 1024 characters, and Codex refuses to load a
# skill whose description is longer (openai/codex#13941).
MAX_DESCRIPTION_CHARS = 1024


@pytest.mark.parametrize("skill_name", REQUIRED_SKILLS)
def test_skill_description_within_spec_limit(skills_dir, skill_name):
    """frontmatter `description` fits the 1024-character limit every client enforces."""
    description = parse_frontmatter(skills_dir / skill_name / "SKILL.md")["description"]
    assert len(description) <= MAX_DESCRIPTION_CHARS, (
        f"{skill_name} description is {len(description)} characters; the limit is "
        f"{MAX_DESCRIPTION_CHARS} (Codex won't load the skill)"
    )

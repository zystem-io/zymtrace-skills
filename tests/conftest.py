"""Pytest fixtures and helpers for zymtrace structural tests.

These tests are structural only: layout, frontmatter fields, version sync, and
intra-plugin path resolution. No API keys, no cluster, no network needed.
"""

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_ROOT = REPO_ROOT / "zymtrace"
SKILLS_DIR = PLUGIN_ROOT / "skills"
PLUGIN_JSON = PLUGIN_ROOT / ".claude-plugin" / "plugin.json"
MARKETPLACE_JSON = REPO_ROOT / ".claude-plugin" / "marketplace.json"


def parse_frontmatter(path: Path):
    """Return the parsed YAML frontmatter dict for a markdown file, or None."""
    text = path.read_text()
    if not text.startswith("---"):
        return None
    # Split on the closing '---' fence.
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None
    return yaml.safe_load(parts[1])


@pytest.fixture
def repo_root():
    return REPO_ROOT


@pytest.fixture
def plugin_root():
    return PLUGIN_ROOT


@pytest.fixture
def skills_dir():
    return SKILLS_DIR


@pytest.fixture
def plugin_json_path():
    return PLUGIN_JSON


@pytest.fixture
def marketplace_json_path():
    return MARKETPLACE_JSON


@pytest.fixture
def skill_md_files():
    return sorted(SKILLS_DIR.glob("*/SKILL.md"))

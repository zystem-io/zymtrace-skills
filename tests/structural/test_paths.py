"""Intra-plugin path portability checks.

Skills run with an arbitrary working directory (usually the user's repo), so any
script the skill tells the agent to run, or any reference file it tells the agent
to read, must be addressed via ${CLAUDE_PLUGIN_ROOT} — never a bare relative path.
These tests lock that rule in and verify the referenced files actually exist.
"""

import os
import re
import stat

import pytest

from tests.conftest import PLUGIN_ROOT, SKILLS_DIR

# A ${CLAUDE_PLUGIN_ROOT}/... path, stopping at whitespace, backtick, paren, or quote.
PLUGIN_ROOT_PATH = re.compile(r"\$\{CLAUDE_PLUGIN_ROOT\}(/[^\s`)\]\"']+)")

# Bare script invocations that would break when cwd isn't the skill directory.
BARE_SCRIPT_PATTERNS = [
    re.compile(r"(?<!\})\./scripts/"),          # ./scripts/foo.sh
    re.compile(r"\.\./[\w-]+/scripts/[\w./-]+\.sh"),  # ../other-skill/scripts/foo.sh
]


def _skill_md_files():
    return sorted(SKILLS_DIR.glob("*/SKILL.md"))


@pytest.mark.parametrize("skill_md", _skill_md_files(), ids=lambda p: p.parent.name)
def test_no_bare_script_invocations(skill_md):
    """No SKILL.md invokes a script via a bare/relative path; use ${CLAUDE_PLUGIN_ROOT}."""
    violations = []
    for lineno, line in enumerate(skill_md.read_text().splitlines(), 1):
        for pat in BARE_SCRIPT_PATTERNS:
            if pat.search(line):
                violations.append(f"{skill_md.parent.name}/SKILL.md:{lineno}: {line.strip()}")
    assert not violations, (
        "Bare script paths found — use ${CLAUDE_PLUGIN_ROOT}/skills/<skill>/scripts/<x>.sh:\n"
        + "\n".join(violations)
    )


@pytest.mark.parametrize("skill_md", _skill_md_files(), ids=lambda p: p.parent.name)
def test_plugin_root_paths_resolve(skill_md):
    """Every ${CLAUDE_PLUGIN_ROOT}/... path referenced in a SKILL.md exists on disk."""
    missing = []
    for match in PLUGIN_ROOT_PATH.finditer(skill_md.read_text()):
        rel = match.group(1).lstrip("/")
        # Strip a trailing markdown-anchor fragment if one slipped through.
        rel = rel.split("#", 1)[0]
        if not (PLUGIN_ROOT / rel).exists():
            missing.append(f"{skill_md.parent.name}/SKILL.md -> ${{CLAUDE_PLUGIN_ROOT}}/{rel}")
    assert not missing, "Referenced ${CLAUDE_PLUGIN_ROOT} paths that do not exist:\n" + "\n".join(missing)


@pytest.mark.parametrize("skill_md", _skill_md_files(), ids=lambda p: p.parent.name)
def test_referenced_scripts_executable(skill_md):
    """Any *.sh referenced via ${CLAUDE_PLUGIN_ROOT} has its executable bit set."""
    not_exec = []
    for match in PLUGIN_ROOT_PATH.finditer(skill_md.read_text()):
        rel = match.group(1).lstrip("/").split("#", 1)[0]
        if rel.endswith(".sh"):
            target = PLUGIN_ROOT / rel
            if target.exists() and not (target.stat().st_mode & stat.S_IXUSR):
                not_exec.append(str(target))
    assert not not_exec, "Referenced scripts missing executable bit (chmod +x):\n" + "\n".join(not_exec)


def test_every_script_on_disk_is_executable():
    """All scripts shipped in the plugin are executable, regardless of references."""
    not_exec = [
        str(p)
        for p in SKILLS_DIR.glob("*/scripts/*.sh")
        if not (p.stat().st_mode & stat.S_IXUSR)
    ]
    assert not not_exec, "Scripts missing executable bit (chmod +x):\n" + "\n".join(not_exec)

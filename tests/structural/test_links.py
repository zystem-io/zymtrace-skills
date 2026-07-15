"""Internal markdown link + anchor integrity across plugin docs.

The skills are heavily cross-linked — sibling ``SKILL.md`` files, ``shared/*.md``
conventions, and ``reference.md`` sections all point at each other by relative path
and ``#heading`` fragment. A renamed file or a drifted heading silently breaks the
navigation the agent is told to follow, and nothing else in the suite catches it.

These checks resolve every *relative* inline link to a file on disk and, when the
link carries a ``#fragment`` into a markdown file, verify some heading produces that
GitHub-style anchor. Out of scope (so the suite stays offline and deterministic):

- External links (``http:``/``https:``/``mailto:`` …) — no network is used.
- ``${CLAUDE_PLUGIN_ROOT}/...`` paths — covered by ``test_paths.py``.
- Links and ``#`` headings inside fenced code blocks and YAML frontmatter — those
  are examples/metadata, not live navigation.
"""

import re

import pytest

from tests.conftest import PLUGIN_ROOT

MD_FILES = sorted(PLUGIN_ROOT.glob("**/*.md"))

# Inline links: [text](target). Targets in these docs never contain a literal ')'.
INLINE_LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
# ATX heading, tolerating up to 3 leading spaces and an optional closing run of '#'.
ATX_HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
# Fenced code block open/close (``` or ~~~), possibly indented / with a language tag.
FENCE = re.compile(r"^\s*(?:`{3,}|~{3,})")
# A scheme-prefixed (external) target: http:, https:, mailto:, tel: …
SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*:", re.I)


def _iter_body(lines):
    """Yield (lineno, line, in_fence) for body lines, skipping YAML frontmatter.

    lineno is 1-indexed against the original file so failures point at the real line.
    """
    start = 0
    if lines and lines[0].strip() == "---":
        for j in range(1, len(lines)):
            if lines[j].strip() == "---":
                start = j + 1
                break
    in_fence = False
    for i in range(start, len(lines)):
        line = lines[i]
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        yield i + 1, line, in_fence


def _slug(text):
    """GitHub-style heading anchor: lowercase, drop punctuation/emoji, spaces->hyphens.

    GitHub replaces each whitespace char with its own hyphen (no collapsing), so
    ``OOMKilled / restart cycle`` -> ``oomkilled--restart-cycle`` (the removed ``/``
    leaves two spaces, hence two hyphens).
    """
    s = text.strip().lower()
    s = re.sub(r"[^\w\s-]", "", s)
    s = re.sub(r"\s", "-", s)
    return s.strip("-")


def _heading_anchors(lines):
    """Set of anchors a markdown file exposes, with GitHub's duplicate -1/-2 suffixes."""
    anchors, counts = set(), {}
    for _lineno, line, in_fence in _iter_body(lines):
        if in_fence:
            continue
        m = ATX_HEADING.match(line)
        if not m:
            continue
        base = _slug(m.group(2))
        if not base:
            continue
        n = counts.get(base, 0)
        anchors.add(base if n == 0 else f"{base}-{n}")
        counts[base] = n + 1
    return anchors


def _links(lines):
    for lineno, line, in_fence in _iter_body(lines):
        if in_fence:
            continue
        for m in INLINE_LINK.finditer(line):
            yield lineno, m.group(1).strip()


_ANCHOR_CACHE = {}


def _anchors_for(path):
    key = path.resolve()
    if key not in _ANCHOR_CACHE:
        _ANCHOR_CACHE[key] = _heading_anchors(path.read_text().splitlines())
    return _ANCHOR_CACHE[key]


@pytest.mark.parametrize("md", MD_FILES, ids=lambda p: str(p.relative_to(PLUGIN_ROOT)))
def test_internal_links_resolve(md):
    """Every relative link resolves to a file, and every #fragment to a heading."""
    lines = md.read_text().splitlines()
    own_anchors = _heading_anchors(lines)
    problems = []

    for lineno, target in _links(lines):
        if not target or target.startswith("$") or SCHEME.match(target) or target.startswith("//"):
            continue  # empty, ${CLAUDE_PLUGIN_ROOT}, external, or protocol-relative

        if target.startswith("#"):  # same-file anchor
            frag = target[1:]
            if frag and frag not in own_anchors:
                problems.append(f":{lineno}: missing same-file anchor '#{frag}'")
            continue

        path_part, _, frag = target.partition("#")
        if not path_part:
            continue
        resolved = (md.parent / path_part).resolve()
        if not resolved.exists():
            problems.append(f":{lineno}: broken link -> {target}")
            continue
        if frag and resolved.suffix == ".md" and frag not in _anchors_for(resolved):
            problems.append(f":{lineno}: missing anchor '#{frag}' in {path_part}")

    assert not problems, f"{md.relative_to(PLUGIN_ROOT)}\n" + "\n".join(problems)

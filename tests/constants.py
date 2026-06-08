"""Shared constants for structural tests."""

# Every skill directory that must exist under zymtrace/skills/.
# Add a new skill's directory name here when you add a skill (see CLAUDE.md).
REQUIRED_SKILLS = [
    "install-zymtrace-backend",
    "upgrade-zymtrace-backend",
    "expose-zymtrace-backend",
    "install-zymtrace-profiler",
    "troubleshoot-zymtrace-backend",
    "troubleshoot-zymtrace-profiler",
    "configure-zymtrace-mcp",
    "optimize-cpu-workloads",
    "optimize-gpu-workloads",
    "optimize-memory-allocation",
]

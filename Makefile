.PHONY: install test

# Install test dependencies (run inside a virtualenv).
install:
	python -m pip install -r tests/requirements.txt

# Run the structural test suite — layout, frontmatter, version sync, path portability.
# No API keys, cluster, or network required.
test:
	python -m pytest

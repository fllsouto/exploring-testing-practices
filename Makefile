# MSR X-Ray — project Makefile
# Tabs are significant in recipe lines. Keep them as TABs, never spaces.

PYTHON_VERSION := $(shell awk '/^python/ {print $$2}' .tool-versions)
VENV          := .venv
PY            := $(VENV)/bin/python
PIP           := uv pip
NOTEBOOK      := notebooks/msr\ xray.ipynb
KERNEL_NAME   := msr-xray
KERNEL_LABEL  := MSR X-Ray (Python $(PYTHON_VERSION))

export VIRTUAL_ENV := $(CURDIR)/$(VENV)
# Prefer the venv's own binaries over asdf shims so `jupyter` can dispatch
# to its sibling scripts (`jupyter-notebook`, `jupyter-lab`) without hitting
# the asdf shim for the parent python.
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)

.DEFAULT_GOAL := help
.PHONY: help setup python install kernel lab notebook execute freeze clean distclean doctor

help:  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: python $(VENV) install kernel  ## Full bootstrap: asdf python + venv + deps + jupyter kernel

python:  ## Ensure asdf has the pinned Python version installed
	@asdf current python 2>/dev/null | grep -q "$(PYTHON_VERSION)" || { \
		echo "Installing Python $(PYTHON_VERSION) via asdf..."; \
		asdf install python $(PYTHON_VERSION); \
	}
	@echo "Python: $$(asdf which python)"

$(VENV):  ## Create the virtualenv bound to asdf python
	uv venv --python "$$(asdf which python)" $(VENV)

install: $(VENV)  ## Install / sync dependencies from requirements.txt
	$(PIP) install -r requirements.txt

kernel: $(VENV)  ## Register .venv as a Jupyter kernel named $(KERNEL_NAME)
	$(PY) -m ipykernel install --user --name $(KERNEL_NAME) --display-name "$(KERNEL_LABEL)"

lab: $(VENV)  ## Launch JupyterLab (preferred)
	$(VENV)/bin/jupyter lab notebooks/

notebook: $(VENV)  ## Launch classic Jupyter Notebook
	$(VENV)/bin/jupyter notebook notebooks/

execute: $(VENV)  ## Run the notebook headless (smoke test)
	$(VENV)/bin/jupyter nbconvert --to notebook --execute $(NOTEBOOK) \
		--output executed-msr-xray.ipynb --ExecutePreprocessor.timeout=600

freeze: $(VENV)  ## Freeze resolved dependency versions to requirements.lock.txt
	$(PIP) freeze > requirements.lock.txt
	@echo "Wrote requirements.lock.txt"

doctor:  ## Print environment diagnostics
	@echo "== asdf =="; asdf --version
	@echo "== python (.tool-versions → $(PYTHON_VERSION)) =="; asdf current python
	@echo "== uv =="; uv --version
	@echo "== venv =="; test -d $(VENV) && $(PY) --version || echo ".venv missing — run 'make setup'"
	@echo "== jupyter =="; test -x $(VENV)/bin/jupyter && $(VENV)/bin/jupyter --version | head -5 || echo "jupyter missing"

clean:  ## Remove notebook checkpoints and executed artefacts
	find . -type d -name ".ipynb_checkpoints" -prune -exec rm -rf {} +
	rm -f notebooks/executed-msr-xray.ipynb

distclean: clean  ## Also remove the venv (fresh-start)
	rm -rf $(VENV)

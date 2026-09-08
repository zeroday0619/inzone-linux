.DEFAULT_GOAL := all

# The installed CLI uses the system Python interpreter and its packages.
PYTHON ?= /usr/bin/python3
SUDO ?= sudo
INSTALL_HOME ?= $(HOME)
FETCH_FLAGS ?=

.PHONY: all fetch assets build install check test help check-user

all: install

check-user:
	@if [ "$$(id -u)" -eq 0 ]; then \
		printf '%s\n' 'Run make as the desktop user; only the install step uses sudo.' >&2; \
		exit 1; \
	fi

fetch: check-user
	"$(PYTHON)" tools/fetch_assets.py $(FETCH_FLAGS) --download-only

assets: fetch
	"$(PYTHON)" tools/fetch_assets.py $(FETCH_FLAGS)

build: assets
	$(MAKE) -C native

install: build
	@test -d "$(INSTALL_HOME)" || { printf '%s\n' 'INSTALL_HOME must be an existing desktop user home directory.' >&2; exit 1; }
	$(SUDO) "$(PYTHON)" tools/install_profiles.py --home "$(INSTALL_HOME)"

check: build
	"$(PYTHON)" -m unittest discover -s tests -p 'test_*.py'

test: check

help:
	@printf '%s\n' \
		'make / make install  Download, extract, build, and install for the desktop user.' \
		'make fetch           Download and verify the pinned installer only.' \
		'make assets          Download and extract the required runtime assets.' \
		'make build           Prepare assets and build the native DSP plugin.' \
		'make check / test    Prepare assets, build, and run unit tests without installing.' \
		'' \
		'Variables: PYTHON=/usr/bin/python3, SUDO=sudo, INSTALL_HOME=$$HOME, FETCH_FLAGS=' \
		'Offline: make FETCH_FLAGS=--offline' \
		'Run make without sudo; administrator privileges are requested only for installation.'

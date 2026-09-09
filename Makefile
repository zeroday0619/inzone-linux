.DEFAULT_GOAL := all

SWIFT ?= swift
SWIFTC ?= $(if $(findstring /,$(SWIFT)),$(dir $(SWIFT))swiftc,swiftc)
SWIFT_FLAGS ?=
SWIFT_CONFIGURATION ?= release
SWIFT_BINARY ?= $(CURDIR)/.build/$(SWIFT_CONFIGURATION)/inzone-profile
SWIFT_TOOLS_BINARY ?= $(CURDIR)/.build/$(SWIFT_CONFIGURATION)/inzone-tools
INSTALL_HOME ?= $(HOME)
FETCH_FLAGS ?=

# Swift must use its own Clang and linker instead of inherited C build overrides.
SWIFT_ENV = env -u CC -u CXX -u LD -u AR -u CFLAGS -u CXXFLAGS -u LDFLAGS

.PHONY: all sync fetch assets native-build swift-build swift-test build install check test help check-user

all: install

check-user:
	@if [ "$$(id -u)" -eq 0 ]; then \
		printf '%s\n' 'Run make as the desktop user; only the install step uses sudo.' >&2; \
		exit 1; \
	fi

sync: check-user
	$(SWIFT_ENV) "$(SWIFT)" package resolve $(SWIFT_FLAGS)

fetch: swift-build
	"$(SWIFT_TOOLS_BINARY)" fetch --repository "$(CURDIR)" $(FETCH_FLAGS) --download-only

assets: swift-build
	"$(SWIFT_TOOLS_BINARY)" fetch --repository "$(CURDIR)" $(FETCH_FLAGS)

native-build: check-user
	$(MAKE) -C native SWIFTC="$(SWIFTC)"

swift-build: check-user
	$(SWIFT_ENV) "$(SWIFT)" build -c "$(SWIFT_CONFIGURATION)" --static-swift-stdlib $(SWIFT_FLAGS)
	@test -x "$(SWIFT_BINARY)" || { printf '%s\n' 'The built executable was not found; set SWIFT_BINARY for custom output paths.' >&2; exit 1; }
	@test -x "$(SWIFT_TOOLS_BINARY)" || { printf '%s\n' 'The built tools executable was not found; set SWIFT_TOOLS_BINARY for custom output paths.' >&2; exit 1; }

swift-test: native-build
	$(SWIFT_ENV) "$(SWIFT)" test $(SWIFT_FLAGS)

build: assets native-build swift-build

install: build
	@test -d "$(INSTALL_HOME)" || { printf '%s\n' 'INSTALL_HOME must be an existing desktop user home directory.' >&2; exit 1; }
	"$(SWIFT_TOOLS_BINARY)" install-all --home "$(INSTALL_HOME)" --repository "$(CURDIR)" --binary "$(SWIFT_BINARY)"

check: build
	INZONE_TEST_BINARY="$(SWIFT_BINARY)" $(SWIFT_ENV) "$(SWIFT)" test $(SWIFT_FLAGS)

test: check

help:
	@printf '%s\n' \
		'make / make install  Download assets, build Swift, and install the CLI, DSP, and configs.' \
		'make sync            Resolve the Swift package dependencies.' \
		'make fetch           Download and verify the pinned installer only.' \
		'make assets          Download and extract the required runtime assets.' \
		'make native-build    Build the LADSPA DSP plugin with Embedded Swift.' \
		'make swift-build     Build inzone-profile and inzone-tools with a statically linked Swift runtime.' \
		'make swift-test      Run Swift unit tests without preparing vendor assets.' \
		'make build           Prepare assets and build the Swift executables and DSP plugin.' \
		'make check / test    Prepare assets, build, and run Swift tests without installing.' \
		'' \
		'Variables: INSTALL_HOME=$$HOME, FETCH_FLAGS=' \
		'Swift: SWIFT=swift, SWIFT_FLAGS=, SWIFT_CONFIGURATION=release, SWIFT_BINARY=.build/release/inzone-profile' \
		'Tools: SWIFT_TOOLS_BINARY=.build/release/inzone-tools' \
		'DSP: SWIFTC=swiftc, SWIFT_DSP_FLAGS=-O -whole-module-optimization' \
		'Offline assets: make assets FETCH_FLAGS=--offline (requires prepared Swift packages and extraction tools)' \
		'Runtime: native Swift executable at $$INSTALL_HOME/.local/bin/inzone-profile.' \
		'Configs: profile templates, WirePlumber rules, a systemd user unit, and udev rules.' \
		'Reinstall: back up existing files, refresh templates, and preserve user state and legacy installed files.' \
		'Run make without sudo; install writes user files first and requests administrator privileges only for fixed system paths.'

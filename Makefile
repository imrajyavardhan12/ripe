# Command Line Tools installs (no Xcode) don't put the Swift Testing macro plugin on the
# compiler's search path; point at it when it exists. No-op with Xcode selected.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))
SOURCES := Package.swift Sources Tests

.PHONY: build test lint format release install uninstall run clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

lint:
	swift format lint --strict --recursive --parallel $(SOURCES)

format:
	swift format --in-place --recursive --parallel $(SOURCES)

# Optimized binary in dist/. Universal (arm64 + x86_64) in CI; host-only locally, because
# toolchains built for macOS 27+ no longer ship x86_64 runtime libraries.
ARCHS ?= $(if $(CI),arm64 x86_64,$(shell uname -m))
ARCH_FLAGS := $(foreach arch,$(ARCHS),--arch $(arch))

release:
	swift build -c release $(ARCH_FLAGS)
	mkdir -p dist
	cp "$$(swift build -c release $(ARCH_FLAGS) --show-bin-path)/ripe" dist/ripe
	strip -rSTx dist/ripe
	lipo -info dist/ripe

# Install the optimized binary for local use until the Homebrew formula is public.
PREFIX ?= $(HOME)/.local
install: release
	mkdir -p "$(PREFIX)/bin"
	install -m 755 dist/ripe "$(PREFIX)/bin/ripe"
	@echo "installed $(PREFIX)/bin/ripe ($$("$(PREFIX)/bin/ripe" --version))"

uninstall:
	rm -f "$(PREFIX)/bin/ripe"

run:
	swift run ripe $(ARGS)

clean:
	rm -rf .build dist

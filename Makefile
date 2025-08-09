ZIG ?= zig
ZIG_PROJECT := zig-xtc
BUILD_DIR := zig-out
BIN := bin/xtc

.PHONY: all build debug release test run install clean help

all: build

build:; $(ZIG) build

debug: build

test:; $(ZIG) build test

install:
	$(ZIG) build
	mkdir -p $(dir $(BIN))
	install -m 755 $(BUILD_DIR)/bin/xtc $(BIN)

clean:
	rm -rf .zig-cache zig-out

help:
	@echo "Targets:"
	@echo "  build     - zig build (Debug)"
	@echo "  release   - zig build (ReleaseSafe)"
	@echo "  test      - zig build test"
	@echo "  run       - run xtc on an XML file (make run FILE=foo.xml)"
	@echo "  clean     - remove build artifacts"


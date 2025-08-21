.PHONY: vscode-build-and-test

vscode-build-and-test:
	@echo "[begin compile]"
	@zig build --summary new || { status=$$?; echo "[end compile]"; exit $$status; }
	@echo "[end compile]"
	@echo "[begin test]"
	@zig build test --summary new || { status=$$?; echo "[end test]"; exit $$status; }
	@echo "[end test]"

ZIG ?= zig
ZIG_PROJECT := zig-xtc
BUILD_DIR := zig-out
BIN := bin/xtc

.PHONY: all build debug release test run install clean help

all: build

build:; $(ZIG) build --summary new

debug: build

test:; $(ZIG) build test --summary new

install:
	$(ZIG) build
	mkdir -p $(dir $(BIN))
	install -m 755 $(BUILD_DIR)/bin/xtc $(BIN)

clean:
	rm -rf .zig-cache zig-out

help:
	@echo "Targets:"
	@echo "  build     - zig build --summary new (Debug)"
	@echo "  release   - zig build (ReleaseSafe)"
	@echo "  test      - zig build test --summary new"
	@echo "  run       - run xtc on an XML file (make run FILE=foo.xml)"
	@echo "  clean     - remove build artifacts"

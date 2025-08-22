ZIG ?= zig
ZIG_PROJECT := zig-xtc
BUILD_DIR := zig-out
BIN := bin/xtc

.PHONY: all build build-fast test install clean

all: build test
build:; $(ZIG) build --summary new
build-fast:; $(ZIG) build --summary new --release-fast
test:; $(ZIG) build test --summary new

install:
	$(ZIG) build
	mkdir -p $(dir $(BIN))
	install -m 755 $(BUILD_DIR)/bin/xtc $(BIN)

clean:
	rm -rf .zig-cache zig-out

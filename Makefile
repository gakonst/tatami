.POSIX:

ZIG := ./zig/zig

.PHONY: all setup build test run install uninstall clean

# Default: build release binary
all: build

# Download pinned Zig toolchain into ./zig
setup $(ZIG):
	./zig/download.sh

# Build tatami and tatami-sim
build: $(ZIG)
	$(ZIG) build -Doptimize=ReleaseSafe

# Run unit and scenario tests
test: $(ZIG)
	$(ZIG) build test --summary all

# Run tatami locally in the foreground with verbose logging
run: build
	./scripts/run.sh

# Build, copy to ~/.local/bin, and load the launchd agent
install: $(ZIG)
	./scripts/install.sh

# Stop tatami, restore parked windows, and remove launchd agent & binary
uninstall:
	./scripts/uninstall.sh

# Remove build artifacts and cache
clean:
	rm -rf zig-out .zig-cache

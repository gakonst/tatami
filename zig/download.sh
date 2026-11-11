#!/usr/bin/env sh
# Downloads the pinned Zig toolchain into ./zig/. tatami has no other build dependency.
set -eu

ZIG_VERSION="0.17.1"
ZIG_SHA256_AARCH64_MACOS="75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d"

cd "$(dirname "$0")"

if [ -x ./zig ] && [ "$(./zig version)" = "$ZIG_VERSION" ]; then
    echo "zig $ZIG_VERSION already present"
    exit 0
fi

arch="$(uname -m)"
os="$(uname -s)"
if [ "$os" != "Darwin" ] || [ "$arch" != "arm64" ]; then
    echo "unsupported host: $os $arch (tatami targets Apple Silicon macOS)" >&2
    exit 1
fi

name="zig-aarch64-macos-$ZIG_VERSION"
url="https://ziglang.org/download/$ZIG_VERSION/$name.tar.xz"

echo "downloading $url"
curl --fail --silent --show-error --location --output "$name.tar.xz" "$url"

actual="$(shasum -a 256 "$name.tar.xz" | cut -d ' ' -f 1)"
if [ "$actual" != "$ZIG_SHA256_AARCH64_MACOS" ]; then
    echo "checksum mismatch: expected $ZIG_SHA256_AARCH64_MACOS, got $actual" >&2
    rm -f "$name.tar.xz"
    exit 1
fi

tar -xf "$name.tar.xz"
rm -f "$name.tar.xz"
rm -rf ./lib ./doc ./zig
mv "$name/zig" ./zig
mv "$name/lib" ./lib
[ -d "$name/doc" ] && mv "$name/doc" ./doc
rm -rf "$name"

echo "zig $(./zig version) installed in $(pwd)"

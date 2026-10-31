#!/bin/sh
# Builds Core/Artifacts/HermesTailnet.xcframework: the userspace tailnet node of the app, bound from
# tailnet/ with gomobile. Needs Go and Xcode, and runs only on macOS.
#
# The artifact is not committed and the app builds without it: the tailnet route then says the node
# is not in this build. The node is the same Go package the Android client binds with
# scripts/build-tailnet.sh in juev/hermes, with a proxy URLSession can use (see tailnet/proxy.go).
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)

if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-tailnet.sh: gomobile binds Apple platforms only, and this is not a Mac." >&2
    exit 1
fi

export GOTOOLCHAIN=auto
version=$(go -C "$root/tailnet" list -m -f '{{.Version}}' golang.org/x/mobile)
gobin=$(go env GOPATH)/bin
go install "golang.org/x/mobile/cmd/gomobile@$version" "golang.org/x/mobile/cmd/gobind@$version"

mkdir -p "$root/Core/Artifacts"
cd "$root/tailnet"
# -target=macos builds both architectures, so the app stays a universal binary. -macosversion keeps
# the node at the deployment target of the app.
PATH="$gobin:$PATH" gomobile bind \
    -target=macos \
    -macosversion 15.0 \
    -ldflags "-s -w" \
    -trimpath \
    -o "$root/Core/Artifacts/HermesTailnet.xcframework" \
    .
ls -lh "$root/Core/Artifacts/HermesTailnet.xcframework"

# What the Swift side calls, printed so a rename of a binding shows up in the log of a failed build.
header=$(find "$root/Core/Artifacts/HermesTailnet.xcframework" -name 'HermesTailnet.h' | head -1)
if [ -n "$header" ]; then
    grep -E "^\+ \(|^@interface" "$header"
fi

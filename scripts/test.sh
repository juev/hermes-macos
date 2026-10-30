#!/bin/sh
# The tests of the protocol and the model: no window, no Xcode project, a few seconds.
set -eu

cd "$(dirname "$0")/.."

swift test --package-path Core "$@"

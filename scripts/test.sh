#!/bin/sh
# The tests of the protocol and the model: no window, no Xcode project, a few seconds.
set -eu

cd "$(dirname "$0")/.."

# The payloads the tests replay live in the contract, not here: copy them first.
scripts/sync-fixtures.sh

swift test --package-path Core "$@"

#!/bin/sh
# Generates Hermes.xcodeproj from project.yml and builds the app, without a window and without
# taking the keyboard.
set -eu

cd "$(dirname "$0")/.."

xcodegen generate --quiet

# A stable identity, when there is one: with ad-hoc signing every rebuild is a different app to the
# Keychain, and it asks for the password for the app's item again. scripts/dev-signing.sh makes one.
signing=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Hermes Dev"'; then
	signing='CODE_SIGN_IDENTITY=Hermes Dev CODE_SIGN_STYLE=Manual'
fi

# shellcheck disable=SC2086
xcodebuild \
	-project Hermes.xcodeproj \
	-scheme Hermes \
	-configuration "${CONFIGURATION:-Debug}" \
	-derivedDataPath build \
	$signing \
	build

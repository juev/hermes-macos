#!/bin/sh
# Generates Hermes.xcodeproj from project.yml and builds the app, without a window and without
# taking the keyboard.
set -eu

cd "$(dirname "$0")/.."

xcodegen generate --quiet

# A stable identity, when there is one: with ad-hoc signing every rebuild is a different app to the
# Keychain, and it asks for the password for the app's item again. The release identity is the one to
# use — scripts/import-signing-identity.sh puts it in the keychain — and a local "Hermes Dev" identity
# is the fallback for a Mac that has none.
signing=""
for identity in "Hermes macOS" "Hermes Dev"; do
	if security find-identity -v -p codesigning 2>/dev/null | grep -q "'"'"'"$identity"'"'"'" \
		|| security find-certificate -c "$identity" >/dev/null 2>&1; then
		signing="CODE_SIGN_IDENTITY=$identity CODE_SIGN_STYLE=Manual"
		break
	fi
done

# shellcheck disable=SC2086
xcodebuild \
	-project Hermes.xcodeproj \
	-scheme Hermes \
	-configuration "${CONFIGURATION:-Debug}" \
	-derivedDataPath build \
	$signing \
	build

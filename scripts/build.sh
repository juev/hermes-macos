#!/bin/sh
# Generates Hermes.xcodeproj from project.yml and builds the app, without a window and without
# taking the keyboard.
set -eu

cd "$(dirname "$0")/.."

xcodegen generate --quiet

xcodebuild \
	-project Hermes.xcodeproj \
	-scheme Hermes \
	-configuration "${CONFIGURATION:-Debug}" \
	-derivedDataPath build \
	build

# Signed by a name, when this Mac has an identity: a binary signed by nobody is a new app to the
# Keychain after every rebuild, and it asks for the app's password again. Xcode itself signs ad-hoc
# here — the identity is not trusted by the system policy, only present in the keychain — so the app
# is signed again by hand, which codesign is happy to do.
app="build/Build/Products/${CONFIGURATION:-Debug}/Hermes.app"
keychain="$HOME/Library/Keychains/login.keychain-db"
for identity in "Hermes macOS" "Hermes Dev"; do
	if security find-certificate -c "$identity" -a "$keychain" >/dev/null 2>&1; then
		codesign --force --deep --keychain "$keychain" --sign "$identity" "$app"
		echo "signed $app with \"$identity\""
		break
	fi
done

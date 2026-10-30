#!/bin/sh
# Puts the release signing identity into this Mac's login keychain, so every local build has the same
# signature as a release. One identity for everything is what stops the Keychain asking again after a
# rebuild: a binary signed by nobody is a new app to it each time.
#
#   scripts/import-signing-identity.sh          # from Bitwarden, through rbw
#   scripts/import-signing-identity.sh <file>   # from a p12 on disk
#
# The password of the p12 is read from Bitwarden when the material comes from there.
set -eu

cd "$(dirname "$0")/.."

entry="macOS signing: Hermes macOS release"
keychain="$HOME/Library/Keychains/login.keychain-db"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ $# -ge 1 ]; then
	cp "$1" "$work/identity.p12"
	printf 'p12 password: '
	stty -echo
	read -r password
	stty echo
	printf '\n'
else
	command -v rbw >/dev/null 2>&1 || {
		echo "no rbw: pass a p12 file instead" >&2
		exit 2
	}
	rbw unlocked >/dev/null 2>&1 || rbw unlock
	password="$(rbw get "$entry")"
	rbw get --full "$entry" | awk '/-----BEGIN P12 BASE64-----/{flag=1;next}/-----END P12 BASE64-----/{flag=0}flag' \
		| base64 -d -i - -o "$work/identity.p12"
fi

if security find-certificate -c "Hermes macOS" -a "$keychain" >/dev/null 2>&1; then
	echo "the identity \"Hermes macOS\" is already in $keychain"
	exit 0
fi

security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign -A >/dev/null
echo "the identity \"Hermes macOS\" is in $keychain; scripts/build.sh signs with it from now on"

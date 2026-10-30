#!/bin/sh
# A stable signing identity for local builds.
#
# Why: the debug build is ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`), so every rebuild is a different
# app to macOS and the Keychain asks for the password again for the item the app keeps its secrets in.
# A self-signed certificate gives every build the same identity, and "Always Allow" then sticks.
#
#   scripts/dev-signing.sh create   # make the identity once
#   scripts/dev-signing.sh status   # is it there?
#   scripts/dev-signing.sh remove   # take it out again
#
# The key lives in your login keychain and is used by codesign only. Nothing leaves the machine.
set -eu

name="Hermes Dev"
keychain="$HOME/Library/Keychains/login.keychain-db"

case "${1:-status}" in
create)
	if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$name\""; then
		echo "the identity \"$name\" is already there"
		exit 0
	fi
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
		-keyout "$work/key.pem" -out "$work/cert.pem" \
		-subj "/CN=$name" \
		-addext "basicConstraints=critical,CA:false" \
		-addext "keyUsage=critical,digitalSignature" \
		-addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
	openssl pkcs12 -export -out "$work/id.p12" -inkey "$work/key.pem" -in "$work/cert.pem" \
		-passout pass:hermes -name "$name" >/dev/null 2>&1
	security import "$work/id.p12" -k "$keychain" -P hermes -T /usr/bin/codesign >/dev/null
	echo "the identity \"$name\" is in $keychain; the next build signs with it"
	echo "macOS will ask once whether codesign may use the key — choose Always Allow"
	;;
remove)
	security delete-identity -c "$name" "$keychain" 2>/dev/null || true
	security delete-certificate -c "$name" "$keychain" 2>/dev/null || true
	echo "the identity \"$name\" is gone; builds are ad-hoc signed again"
	;;
status)
	if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$name\""; then
		echo "signed with \"$name\""
	else
		echo "ad-hoc: every rebuild is a new app to the Keychain, and it will ask for the password again"
	fi
	;;
*)
	echo "usage: $0 [create|status|remove]" >&2
	exit 2
	;;
esac

#!/bin/sh
# The client's own code against a live dashboard: reads the tokens the app keeps in the Keychain, then
# lists the chats, searches, builds a transcript, downloads a delivered file and opens the socket.
#
#   scripts/smoke.sh [address]
#
# The address defaults to https://hermes.evsyukov.org. Nothing is written anywhere.
set -eu

cd "$(dirname "$0")/.."

server="${1:-https://hermes.evsyukov.org}"

if ! security find-generic-password -w -s org.evsyukov.hermes.macos -a "$server" >/dev/null 2>&1; then
	echo "no tokens for $server in the Keychain: open the app and sign in first" >&2
	exit 2
fi

security find-generic-password -w -s org.evsyukov.hermes.macos -a "$server" 2>/dev/null \
	| HERMES_SERVER="$server" swift run --package-path Core --quiet hermes-live
